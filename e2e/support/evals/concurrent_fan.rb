require_relative "shell"

module E2E
  module Evals
    # THE PLAIN CONCURRENT FAN, read off one bash command: where it runs a program, and in how many
    # BACKGROUND JOBS. A run is the program's path at a command's head, bare or behind `sh`/`bash`
    # (`sh bin/fetch a`, `./bin/fetch a`, `bin/fetch a`, `$(sh bin/fetch a)`); `cat bin/fetch` names
    # it and runs nothing. A run's job is the list a lone `&` ends — its pipeline, the `&&`/`||`
    # chain around it, or the `( … )`/`{ …; }` group that holds them — and a job inside a loop counts
    # once per iteration: a `for` loop's words (a brace's alternatives each), at least two where the
    # text holds no count (a substitution, a parameter, a glob or a range among the words, a
    # `while`/`until` loop). A chain run in the background is one job, its runs in turn; a loop whose
    # body ends on `;` runs its iterations in turn, backgrounded or not, so a loop with no `&` inside
    # is a sequence, as `a && b && c` is. THE FAN IS CONCURRENT when two jobs or more start before a
    # `wait` with no `wait` between them: `a & wait; b & wait`, or `… & wait` inside a loop's body,
    # waits on each job before the next starts. Words are the shell's (`Shell`'s quotes, escapes and
    # `${…}`); a comment, a quoted string and a redirect onto a file descriptor (`2>&1`, `&>`) run and
    # background nothing. Left unread: a script handed to `sh -c`, a function's body run by its name,
    # a file the command runs.
    module ConcurrentFan
      # A word's pieces: a quoted string or an escape, a `${…}` parameter, a redirect onto a file
      # descriptor, or one character that is neither a blank nor an operator's.
      PIECE = /#{Shell::QUOTED}|\$\{[^}]*\}|\d*[<>]&\d*-?|&>>?|[^\s;&|()'"\\]/m
      TOKEN = /(?<skip>[ \t]+|\\\n|\#[^\n]*)|(?<word>(?:#{PIECE})+)|(?<operator>&&|\|\||;;|[;&|\n()])/m
      OPERATORS = ["&&", "||", ";;", ";", "&", "|", "\n", "(", ")"].freeze
      # The lists a job does not outlive: the next command runs once this one is done.
      SEQUENCE = [";", ";;", "\n"].freeze
      SHELLS = %w[sh bash].freeze
      # The words a compound command opens and closes with; the reserved words that keep a head.
      OPENERS = %w[{ for while until if case].freeze
      CLOSERS = %w[} done fi esac].freeze
      RESERVED = %w[do then else elif ! time].freeze
      LOOPS = %w[for while until].freeze
      LOOP_END = "done".freeze
      WAIT = "wait".freeze
      # A loop whose iterations the text does not count runs at least this many.
      UNCOUNTED = 2

      module_function

      # How many runs of `program` the command spells, each where it stands.
      def runs(command, program) = run_indexes(tokens(command), program).size

      # How many background jobs run `program`, each counted once per iteration of every loop around it.
      def background_jobs(command, program)
        words = tokens(command)
        jobs(words, program).sum { |_job, at| times(words, at) }
      end

      def waits?(command) = waits(tokens(command)).any?

      # Two background jobs or more that run `program`, started before a `wait` with none between
      # them; a loop counts its iterations only when its body waits for none.
      def concurrent?(command, program)
        words = tokens(command)
        found = jobs(words, program)
        barriers = waits(words)
        barriers.each_with_index.any? do |barrier, index|
          after = index.zero? ? -1 : barriers[index - 1]
          found.select { |job, _at| job > after && job < barrier }.sum { |_job, at| times(words, at, waiting: barriers) } >= 2
        end
      end

      # The `wait` commands, by index.
      def waits(words) = words.each_index.select { |at| words[at] == WAIT && head?(words, at) }

      # Each background job that runs `program`, once: `[the index of the & that ends it, its first run's]`.
      def jobs(words, program) = run_indexes(words, program).filter_map { |at| (job = background_job(words, at)) && [job, at] }.uniq(&:first)

      def tokens(command)
        command.to_s.to_enum(:scan, TOKEN).filter_map { Regexp.last_match[:word] || Regexp.last_match[:operator] }
      end

      def operator?(token) = OPERATORS.include?(token)

      # A word opens a command at the command line's start, after an operator, after a reserved word
      # or an opener, or after an assignment that heads its command (`IFS='|' read …`).
      def head?(words, at)
        return true if at.zero?

        before = words[at - 1]
        operator?(before) || RESERVED.include?(before) || OPENERS.include?(before) ||
          (before.match?(/\A[A-Za-z_]\w*=/) && head?(words, at - 1))
      end

      def run_indexes(words, program)
        paths = [program, "./#{program}"]
        words.each_index.select do |at|
          name = Shell.unquoted(words[at])
          head?(words, at) && (paths.include?(name) || (SHELLS.include?(name) && paths.include?(Shell.unquoted(words[at + 1].to_s))))
        end
      end

      # The index of the lone `&` that ends the run's job, or nil: read forward from the run, the
      # groups it opens are skipped, a `;` or a line ends its own list — the group around it then
      # decides — and the `done` of a loop around it ends the search, since the loop runs its body
      # in turn.
      def background_job(words, from)
        depth = 0
        ended = false
        words.each_with_index.drop(from + 1).each do |word, at|
          opens = word == "(" || (OPENERS.include?(word) && head?(words, at))
          closes = word == ")" || (CLOSERS.include?(word) && head?(words, at))
          if opens
            depth += 1
          elsif closes && depth.positive?
            depth -= 1
          elsif closes
            return nil if word == LOOP_END

            ended = false
          elsif depth.zero? && !ended
            return at if word == "&"

            ended = SEQUENCE.include?(word)
          end
        end
        nil
      end

      # The product of the iteration counts of the compound commands open around the run; with
      # `waiting` (the `wait` commands' indexes), a loop whose body holds one counts once.
      def times(words, at, waiting: [])
        open = words.first(at).each_with_index.each_with_object([]) do |(word, index), found|
          if opens?(words, index)
            found.push(index)
          elsif word == ")" || (CLOSERS.include?(word) && head?(words, index))
            found.pop
          end
        end
        open.map { |index| iterations(words, index, waiting) }.inject(1, :*)
      end

      def opens?(words, at) = words[at] == "(" || (OPENERS.include?(words[at]) && head?(words, at))

      # A compound command's iterations: a `for` loop's words, a `while`/`until` loop's uncounted, any
      # other group once — and a loop whose body waits, once.
      def iterations(words, at, waiting)
        return 1 unless LOOPS.include?(words[at])

        ends = closer(words, at)
        return 1 if waiting.any? { |barrier| barrier > at && barrier < ends }

        words[at] == "for" ? loop_words(words, at) : UNCOUNTED
      end

      # The index of the word that closes the compound command opened at `at` (past the end when none).
      def closer(words, at)
        depth = 0
        words.each_with_index.drop(at).each do |word, index|
          depth += 1 if opens?(words, index)
          depth -= 1 if word == ")" || (CLOSERS.include?(word) && head?(words, index))
          return index if depth.zero?
        end
        words.size
      end

      # A `for NAME in WORDS` loop's iterations, each word's alternatives summed; a C-style `for ((…))`
      # is uncounted; `for NAME` alone loops over the arguments, one here.
      def loop_words(words, at)
        return UNCOUNTED if words[at + 1] == "("
        return 1 unless words[at + 2] == "in"

        [words.drop(at + 3).take_while { |word| !operator?(word) && word != "do" }.sum { |word| alternatives(word) }, 1].max
      end

      # How many words one word of a `for` list expands to: a brace's alternatives (`{a,b,c}` three),
      # uncounted for a substitution, a parameter, a glob or a range (`{1..3}`); a quoted word is one.
      def alternatives(word)
        return UNCOUNTED if word.match?(/[$`]/) || Shell.glob?(word)

        braces = Shell.expanded(word).scan(/\{([^{}]*)\}/).map(&:first)
        return UNCOUNTED if braces.any? { |inside| inside.include?("..") }

        braces.map { |inside| inside.count(",") + 1 }.inject(1, :*)
      end
    end
  end
end
