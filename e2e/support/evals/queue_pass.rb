require "pathname"
require_relative "coverage"
require_relative "shell"

module E2E
  module Evals
    # WHAT ONE BASH COMMAND DID TO A QUEUE DIRECTORY, read off the command as the shell runs it
    # (`Shell.simples`) and never off the words it spells. Every operand is read from the folder its
    # command runs in — the call's `workdir`, then each `cd`/`pushd`/`popd` — so a move made inside
    # the queue names its item bare. `taken` counts the distinct items it took out — an `mv` or `rm`
    # of a path under the queue, spelled out (`queue/item-01.txt`, `"queue/$head"`), held in a
    # variable the command bound from the queue (`f=$(ls queue/* | head -n1)`, a `read` of its
    # listing, a `mapfile` array) or picked inline (`$(ls queue/* | head -n1)`); `several` is a
    # glob, a brace, the directory whole, a variable or a substitution that holds more than a
    # one-line pick, or a take inside a loop. `read` counts the distinct items whose contents a
    # reader (`Coverage::READERS`) named, in the command or in a substitution of it; `read_all` is
    # a reader over a glob, a brace, a variable holding several, or the directory searched
    # recursively. `looped` is a shell loop over the queue: a `for`, `while` or `until` whose word
    # list, condition, feed — the pipeline before it or the redirection after its `done` — or body
    # names it, or an `xargs`, a `parallel` or a `find -exec` in a pipeline that names it. A
    # listing, a loop over the results and a message that says "queue" do none of these. Left
    # unread: a script handed to `sh -c`, and a take inside a command substitution.
    module QueuePass
      Pass = Data.define(:taken, :several, :read, :read_all, :looped) do
        def took? = several || taken.positive?
        def several? = several || taken > 1
        # The count a reason names: "several" where a glob or a loop hides it.
        def count_word = several ? "several" : taken.to_s
        def read_several? = read_all || read > 1
        def read_word = read_all ? "several" : read.to_s
      end

      # What one operand names in the queue: the path as the project root sees it, and whether it
      # stands for several items.
      Pick = Data.define(:path, :several)

      LOOPS = %w[for while until].freeze
      TAKERS = %w[mv rm].freeze
      # The pipelines' walkers: each runs a command once per line it is fed.
      WALKERS = %w[xargs parallel].freeze
      EXECUTES = %w[-exec -execdir -ok -okdir -delete].freeze
      ARRAY_READERS = %w[mapfile readarray].freeze
      # The flags whose value is the next word, never a name: `read`'s, and `mapfile`'s.
      READ_VALUED = %w[-d -i -n -N -p -t -u].freeze
      ARRAY_VALUED = %w[-d -n -O -s -u -C -c].freeze
      ASSIGNMENT = /\A(?<name>[A-Za-z_]\w*)=(?<value>.*)\z/m
      NAME = /\A[A-Za-z_]\w*\z/
      REDIRECTION = /\A\d*(?:>>?|<|&>)/
      BARE_REDIRECTION = /\A\d*(?:>>?|<|&>)\z/
      # A word the folder does not qualify: absolute, a variable or substitution, a flag, a
      # redirection, the home.
      UNQUALIFIED = %r{\A[/$`~<>-]}

      module_function

      def read(command, dir:, workdir: nil) = Reading.new(dir, workdir).call(Shell.simples(command))

      # ONE READING OF ONE COMMAND, its commands in order: the folder each runs in, the variables
      # bound from the queue as they run, the loops open around each, what each take, each read
      # and each loop adds.
      class Reading
        # A LOOP OPEN AROUND THE COMMANDS AS THEY RUN: the names its `read` takes, the words it
        # gathered — header, feed, body, the words after `done` — and whether any named the queue
        # from the folder its command ran in.
        Frame = Struct.new(:reads, :words, :queued, keyword_init: true) do
          def gather(more, named)
            words.concat(more)
            self.queued ||= named
          end
        end

        def initialize(dir, workdir)
          @path = %r{(?:\A(?:\./)?|/)#{Regexp.escape(dir)}(?:/|\z)}
          @whole = %r{(?:\A(?:\./)?|/)#{Regexp.escape(dir)}/?\z}
          @bound = {}
          @folder = workdir.to_s.strip.empty? ? "." : Pathname(workdir.to_s.strip).cleanpath.to_s
          @previous = @folder
          @folders = []
        end

        def call(commands)
          frames = []
          closed = []
          ran = []
          takes = []
          reads = []
          commands.each_with_index do |command, index|
            own = command.own
            named = refers_any?(command.words)
            ran << [command, named]
            if LOOPS.include?(own.first)
              frames.each { |frame| frame.gather(own, named) }
              frames << opened(commands, index, named)
            elsif own.first == "done"
              closed << closing(frames, own.drop(1))
            else
              frames.each { |frame| frame.gather(own, named) }
              words = assigned(own)
              moved_folder(words)
              takes.concat(taken_by(words, inside: !frames.empty?))
              reads.concat(read_by(command.words))
            end
          end
          walked = walkers(ran)
          looped = (closed.compact + frames).any?(&:queued) || walked.any?
          several = takes.any?(&:several) || (looped && takes_in_loops?(closed.compact + frames, walked))
          Pass.new(taken: takes.map(&:path).uniq.size, several: several, read: reads.map(&:path).uniq.size,
            read_all: reads.any?(&:several), looped: looped)
        end

        private

          # A loop's own words: its header and the pipeline feeding it, then — as the commands run —
          # its body. A `for` over the queue binds its variable to one item at a time, and so does a
          # `while read` the queue feeds.
          def opened(commands, index, named)
            header = commands[index].own
            feed = commands[0...index].reverse.take_while(&:piped?)
            fed = feed.any? { |command| refers_any?(command.words) }
            if header.first == "for" && header[2] == "in" && refers_any?(header.drop(3))
              @bound[header[1]] = false
            elsif header.first == "for"
              @bound.delete(header[1])
            end
            reads = header.first == "for" ? [] : read_names(header)
            reads.each { |name| @bound[name] = false } if fed
            Frame.new(reads: reads, words: header + feed.flat_map(&:words), queued: named || fed)
          end

          # THE WORDS AFTER `done` ARE THE LOOP'S: a redirection, a process substitution or a
          # here-string feeding it (`done < <(ls queue/*)`), gathered by it and by every loop open
          # around it; a `while read` it feeds binds the names it reads.
          def closing(frames, after)
            named = refers_any?(after)
            frame = frames.pop
            frame&.gather(after, named)
            frame&.reads&.each { |name| @bound[name] = false } if named
            frames.each { |outer| outer.gather(after, named) }
            frame
          end

          # The command's words past its assignments, each assignment bound first; a `read` or a
          # `mapfile` the queue feeds binds its names too.
          def assigned(own)
            assignments = own.take_while { |word| word.match?(ASSIGNMENT) }
            assignments.each { |word| bind(word.match(ASSIGNMENT)) }
            words = own.drop(assignments.size)
            program = File.basename(words.first.to_s)
            if program == "read" && refers_any?(words.drop(1))
              read_names(words).each { |name| @bound[name] = false }
            elsif ARRAY_READERS.include?(program) && refers_any?(words.drop(1))
              @bound[array_name(words.drop(1))] = true
            end
            words
          end

          # A variable holds what its value picks from the queue — an array literal (`( queue/* )`)
          # its words' picks — and a value that picks nothing unbinds it.
          def bind(assignment)
            value = assignment[:value]
            pick = value.match?(Shell::GROUP) ? listed(Shell.simples(value[1...-1]).flat_map(&:words)) : picked(value)
            if pick
              @bound[assignment[:name]] = pick.several
            else
              @bound.delete(assignment[:name])
            end
          end

          # An array's words: several when more than one names the queue, or one names several.
          def listed(words)
            picks = words.filter_map { |word| picked(word) }
            picks.empty? ? nil : Pick.new(path: picks.first.path, several: picks.size > 1 || picks.any?(&:several))
          end

          # The names `read` assigns: its operands past its flags and their values (`-a`'s array is
          # a name).
          def read_names(words)
            at = words.index("read")
            args = at ? words.drop(at + 1) : []
            names_past(args, READ_VALUED)
          end

          # The array `mapfile` fills: its last name past its flags, `MAPFILE` when it names none.
          def array_name(args) = names_past(args, ARRAY_VALUED).last || "MAPFILE"

          def names_past(args, valued)
            args.each_with_index.filter_map { |word, i| word if word.match?(NAME) && !(i.positive? && valued.include?(args[i - 1])) }
          end

          # THE FOLDER THE NEXT COMMANDS RUN IN: `cd DIR` and `pushd DIR` move it — relative to where
          # it stands, `cd` alone to the home — and `cd -` and `popd` move it back.
          def moved_folder(words)
            name, *args = words
            target = operands(args).reject { |word| word.start_with?("-") && word != "-" }.first
            case name
            when "cd"
              @previous, @folder = @folder, (target == "-" ? @previous : seen(target || "~"))
            when "pushd"
              @folders.push(@folder)
              @folder = seen(target || "~")
            when "popd"
              @folder = @folders.pop || @folder
            else
              @folder
            end
          end

          # What one command takes out of the queue: the picks its `mv`/`rm` operands name, each
          # several inside a loop.
          def taken_by(words, inside:)
            name, *args = words
            program = File.basename(name.to_s)
            if TAKERS.include?(program)
              picks = sources(program, args).filter_map { |word| picked(word) }
              inside ? picks.map { |pick| pick.with(several: true) } : picks
            else
              []
            end
          end

          # The operands `mv` moves — every one but the destination, unless `-t` named the target
          # first — or `rm` removes; a redirection is none of them.
          def sources(name, args)
            words = operands(args)
            flagged = words.index("-t")
            words = words.reject.with_index { |_word, i| flagged && i == flagged + 1 }
            targeted = flagged || words.any? { |word| word.start_with?("--target-directory") }
            operands = words.reject { |word| word.start_with?("-") }
            name == "mv" && !targeted ? operands[0...-1] : operands
          end

          def operands(args)
            args.each_with_index.reject do |word, i|
              word.match?(REDIRECTION) || (i.positive? && args[i - 1].match?(BARE_REDIRECTION))
            end.map(&:first)
          end

          # WHAT ONE COMMAND READS OF THE QUEUE'S CONTENTS: the picks a content reader's file
          # operands name (the directory only when it searches recursively), and — since a
          # substitution runs where its command does — what the readers inside each of its
          # substitutions name.
          def read_by(words)
            name, *args = words.drop_while { |word| word.match?(ASSIGNMENT) || Shell::RESERVED.include?(word) }
            call = Coverage::Invocation.parse([File.basename(name.to_s), *operands(args)])
            own = Coverage::READERS.include?(call.reader) ? call.paths.filter_map { |word| read_pick(word, call) } : []
            inner = words.flat_map { |word| Shell.substitutions(word) }.flat_map { |text| Shell.simples(text) }
            own + inner.flat_map { |command| read_by(command.own) }
          end

          def read_pick(word, call)
            pick = picked(word)
            pick unless pick.nil? || (whole?(pick.path) && !call.recursive?)
          end

          # WHAT AN OPERAND NAMES IN THE QUEUE, nil when nothing: a variable the command bound from
          # it (the binding's count when the word is the variable alone, one item when a path goes
          # on after it), a substitution whose own commands name it (one item when it is a one-line
          # pick), the directory whole, or a path under it (several when the shell globs or braces
          # it).
          def picked(word)
            path = seen(word)
            name = leading(path)
            substituted = sole_substitution(path)
            if name
              Pick.new(path: path, several: alone?(path, name) ? @bound.fetch(name) : Shell.glob?(word) || Shell.brace?(word))
            elsif substituted && refers_any?(Shell.simples(substituted).flat_map(&:words))
              Pick.new(path: path, several: !Shell.one_line?(substituted))
            elsif whole?(path)
              Pick.new(path: path, several: true)
            elsif @path.match?(path)
              Pick.new(path: path, several: Shell.glob?(word) || Shell.brace?(word))
            end
          end

          # A word's path as the project root sees it: unquoted, a relative one read from the folder
          # its command runs in.
          def seen(word)
            text = Shell.unquoted(word)
            text.empty? || text.match?(UNQUALIFIED) ? text : Pathname(@folder).join(text).cleanpath.to_s
          end

          # The bound variable a path opens with (`$f`, `${f}`, `$f/x`).
          def leading(path) = @bound.keys.find { |name| path.match?(/\A\$\{?#{Regexp.escape(name)}\b/) }

          # The word is the variable alone — an array whole (`${items[@]}`) included.
          def alone?(path, name) = path.match?(/\A\$(?:\{#{Regexp.escape(name)}(?:\[[@*]\])?\}|#{Regexp.escape(name)})\z/)

          # The command a word is when it is one substitution and nothing else.
          def sole_substitution(path)
            found = path.match(Shell::SUBSTITUTION)
            Shell.substitutions(path).first if found && found.pre_match.empty? && found.post_match.empty?
          end

          # THE QUEUE NAMED AS A PATH: the directory or a path under it, relative or absolute, read
          # from the folder the command runs in; a variable bound from it; or a substitution whose
          # own words name it.
          def refers?(word)
            path = seen(word)
            @path.match?(path) || !leading(path).nil? ||
              Shell.substitutions(word).any? { |text| refers_any?(Shell.simples(text).flat_map(&:words)) }
          end

          def refers_any?(words) = words.any? { |word| refers?(word) }

          def whole?(path) = @whole.match?(path)

          # The pipelines that walk the queue: an `xargs` or a `parallel` fed by it, or a `find`
          # under it that runs a command on (or deletes) what it finds — each command judged in the
          # folder it ran in.
          def walkers(ran)
            ran.slice_when { |(before, _), _after| !before.piped? }.select do |pipe|
              walker = pipe.any? { |command, _| WALKERS.include?(File.basename(command.own.first.to_s)) || executes?(command.own) }
              walker && pipe.any? { |_, named| named }
            end.map { |pipe| pipe.map(&:first) }
          end

          def executes?(words) = File.basename(words.first.to_s) == "find" && words.intersect?(EXECUTES)

          # A loop over the queue that moves or removes inside it took several, however it spelled
          # the items.
          def takes_in_loops?(frames, walked)
            words = frames.flat_map(&:words) + walked.flatten.flat_map(&:words)
            words.include?("-delete") || words.any? { |word| TAKERS.include?(File.basename(word)) }
          end
      end
    end
  end
end
