require "json"
require "pathname"
require "shellwords"
require "strscan"
require_relative "shell"
require_relative "trace"

module E2E
  module Evals
    module Coverage
      GLOB = File::FNM_EXTGLOB | File::FNM_PATHNAME
      READERS = %w[cat head tail grep egrep rg sed awk less more bat yq].freeze
      # The readers whose first operand is a pattern or a program, not a file.
      PROGRAM_FIRST = %w[grep egrep rg sed awk yq].freeze
      # The flags that carry the pattern, so no operand is one.
      PATTERNED = %w[-e --regexp -f --file].freeze
      # Flags whose value is the next word, never an operand.
      VALUED = %w[-g --glob --iglob --include --exclude --exclude-dir -t --type -T --type-not -e --regexp -f --file
                  -A -B -C -m --max-count --context --after-context --before-context].freeze
      # The filter flags among them, each value a glob; `--exclude` excludes what its glob matches.
      FILTERS = { "-g" => "", "--glob" => "", "--iglob" => "", "--include" => "", "--exclude" => "!" }.freeze
      # ripgrep's listing mode prints names and reads no content, like `ls`.
      LISTS = %w[--files].freeze
      # A bash error is the command's exit status, which a reader that ran still returns (grep's
      # no-match is 1); a read or a grep that answered an error read nothing.
      UNREAD_ON_ERROR = %w[read grep].freeze
      SEGMENT = /&&|\|\||[;|&\n]/
      # THE PLAIN FOR-LOOP: its variable, its word list up to the `;` or newline before `do`, and
      # its body up to its own `done` (`closing_done`). A word list with an expansion in it (`$(ls
      # config)`, a brace) or a body holding another loop is not plain, and stays as written.
      FOR_HEAD = /\bfor\s+(?<var>[A-Za-z_]\w*)\s+in\s+(?<words>[^;\n]*?)\s*[;\n]\s*do\b/
      EXPANSION = /[$`(){}<>|&]/
      LOOP_WORD = /\b(?:for|while|until|do)\b/
      RECURSIVE = /\A(?:--recursive|-[^-]*[rR])/
      # A word of a delegation's text, with the quote or backtick it opens on.
      WORD = %r{([`'"]?)([\w.\-/*?\[\]~]+)}
      COVERS = {
        "read" => ->(input, files, root) { files.select { |file| names?(input["path"], file, root) } },
        "grep" => ->(input, files, root) { grep_covers(input, files, root) },
        "bash" => ->(input, files, root) { bash_covers(input["command"].to_s, files, root, folder(input["workdir"], files, root)) },
        Trace::TASK => ->(input, files, root) { text_covers(input["prompt"].to_s, files, root) },
      }.freeze
      NOTHING = ->(_input, _files, _root) { [] }

      # A reader's command line as its flags take it: a flag that takes a value consumes the next
      # word, which is never an operand; a filter flag's value is a glob, "!"-led when it excludes.
      Invocation = Data.define(:reader, :flags, :operands, :globs) do
        def self.parse(words)
          args = words.drop(1)
          owners = args.each_index.map { |index| index.positive? && VALUED.include?(args[index - 1]) ? args[index - 1] : nil }
          flags, operands = args.zip(owners).filter_map { |word, owner| word if owner.nil? }.partition { |word| word.start_with?("-") }
          given = args.zip(owners).filter_map { |word, owner| [owner, word] if owner } +
                  flags.filter_map { |flag| flag.split("=", 2) if flag.include?("=") }
          new(reader: File.basename(words.first.to_s), flags: flags.map { |flag| flag.split("=", 2).first }, operands: operands,
            globs: given.filter_map { |flag, value| "#{FILTERS.fetch(flag)}#{value}" if FILTERS.key?(flag) })
        end

        def lists? = reader == "rg" && flags.intersect?(LISTS)

        def recursive? = reader == "rg" || flags.any? { |flag| RECURSIVE.match?(flag) }

        # Its operands past the pattern or program; the working folder when a recursive search
        # names none.
        def paths
          named = PROGRAM_FIRST.include?(reader) && !flags.intersect?(PATTERNED) ? operands.drop(1) : operands
          named.empty? && recursive? ? ["."] : named
        end
      end

      module_function

      # The files, in their own order, that the rows covered — every call of the run by default.
      def covered(trace, files, rows: trace.calls)
        root = trace.fact(:root).to_s.chomp("/")
        found = rows.select { |row| read_anything?(row) }
          .flat_map { |row| COVERS.fetch(row["tool_name"].to_s, NOTHING).call(trace.input_of(row), files, root) }
        files & found
      end

      # Only a call that settled `completed` read anything: rg refused a grep, a read found no file.
      def read_anything?(row)
        row["status"] == "completed" && !(UNREAD_ON_ERROR.include?(row["tool_name"].to_s) && Hash(row["result"])["is_error"])
      end

      # A path as the project names it: "./config/" is "config", and the root "." is "".
      def normal(path, root)
        text = below(path.to_s.strip, root).delete_prefix("./").chomp("/")
        text == "." ? "" : text
      end

      # A path under the run's root spelled absolutely is the path below it, the root itself ".";
      # any other path stays as written.
      def below(text, root)
        if !root.empty? && (text == root || text.start_with?("#{root}/"))
          rest = text.delete_prefix(root).delete_prefix("/")
          rest.empty? ? "." : rest
        else
          text
        end
      end

      # The file itself, relative or absolute.
      def names?(path, file, root)
        text = normal(path, root)
        text == file || (text.start_with?("/") && text.end_with?("/#{file}"))
      end

      # The file's path under a folder that holds it, nil when the folder does not hold it: the root
      # holds every file, and an absolute folder outside the run's root holds a file when it ends in
      # one of the file's own folders.
      def under(folder, file, root)
        text = normal(folder, root)
        if text.empty?
          file
        elsif file.start_with?("#{text}/")
          file.delete_prefix("#{text}/")
        elsif text.start_with?("/")
          held = ancestors(file).find { |dir| text.end_with?("/#{dir}") }
          held && file.delete_prefix("#{held}/")
        end
      end

      def ancestors(file)
        parts = File.dirname(file).split("/") - ["."]
        parts.each_index.map { |index| parts[0..index].join("/") }
      end

      # ripgrep's match of a glob against a path from its cwd: one without "/" against the file's
      # name, one with "/" against the whole path; a leading "!" excludes what the rest matches.
      def glob?(glob, path)
        pattern = glob.delete_prefix("!")
        File.fnmatch?(pattern, pattern.include?("/") ? path : File.basename(path), GLOB) != glob.start_with?("!")
      end

      def grep_covers(input, files, root)
        path = input["path"] || "."
        files.select do |file|
          names?(path, file, root) || (!under(path, file, root).nil? && (input["glob"].nil? || tool_glob?(input["glob"], file)))
        end
      end

      # rho's grep runs rg from the daemon's cwd, never the project, and ripgrep anchors a glob with
      # "/" to its cwd: such a glob reaches a project file only when it opens with "**/", and an
      # anchored exclusion excludes nothing.
      def tool_glob?(glob, file)
        pattern = glob.delete_prefix("!")
        pattern.include?("/") && !pattern.start_with?("**/") ? glob.start_with?("!") : glob?(glob, file)
      end

      # A command reads from its working folder: its `workdir`, then each `cd` before the reader.
      def bash_covers(command, files, root, workdir)
        commands = unrolled(command).split(SEGMENT).map { |segment| shell_words(segment) }
        commands.reduce([workdir, []]) do |(dir, found), words|
          if words.first == "cd"
            [folder(words[1], files, root, from: dir), found]
          else
            [dir, found + reader_covers(words, files, root, dir)]
          end
        end.last
      end

      # A plain for-loop reads as its body once per word, the variable — bare, braced or quoted —
      # spelled as that word; any other loop stays as written, and so does a loop with no `done`.
      def unrolled(command)
        head = FOR_HEAD.match(command)
        close = head && closing_done(head.post_match)
        if close.nil?
          command
        else
          body = head.post_match[0...close]
          rest = head.post_match[(close + "done".size)..]
          "#{head.pre_match}#{plain?(head, body) ? unroll(head, body) : "#{head[0]}#{body}done"}#{unrolled(rest)}"
        end
      end

      # THE LOOP'S OWN `done`: the offset of the first `done` that opens a command, outside quotes —
      # a `done` inside a quoted message (`echo "--- $f (done below)"`) is text.
      def closing_done(text)
        scanner = StringScanner.new(text)
        opens = true
        until scanner.eos? || (opens && scanner.match?(/done\b/))
          if scanner.skip(SEGMENT)
            opens = true
          elsif !scanner.skip(/[ \t]+/)
            scanner.skip(Shell::QUOTED) || scanner.getch
            opens = false
          end
        end
        scanner.eos? ? nil : scanner.pos
      end

      def plain?(head, body) = !head[:words].match?(EXPANSION) && !body.match?(LOOP_WORD)

      def unroll(head, body)
        variable = /\$(?:\{#{head[:var]}\}|#{head[:var]}\b)/
        shell_words(head[:words]).map { |word| body.gsub(variable) { word } }.join(";")
      end

      # The folder a `workdir` or a `cd` names, as the project names it: a relative one under the
      # folder it starts from; the run's root or a folder under it spelled absolutely as the path
      # below the root; another absolute one as the files' own folder it ends in, else the root the
      # reader cannot tell it from.
      def folder(path, files, root, from: ".")
        spelled = path.to_s.strip
        text = normal(spelled, root)
        if spelled.empty?
          from
        elsif text.start_with?("/")
          files.flat_map { |file| ancestors(file) }.select { |dir| text.end_with?("/#{dir}") }.max_by(&:size) || "."
        elsif spelled.start_with?("/")
          text.empty? ? "." : text
        else
          Pathname(from).join(spelled).cleanpath.to_s
        end
      end

      # A quote the command never closed still names what it names.
      def shell_words(segment)
        Shellwords.split(segment)
      rescue ArgumentError
        segment.split
      end

      def reader_covers(words, files, root, dir)
        call = Invocation.parse(words)
        if call.lists? || !READERS.include?(call.reader)
          []
        else
          paths = call.paths.map { |path| path.start_with?("/") ? path : Pathname(dir).join(path).cleanpath.to_s }
          files.select { |file| paths.any? { |path| reads?(call, path, file, root, dir) } }
        end
      end

      # The operand names the file or a shell glob over it, or a recursive search's folder holds it
      # and the filters, matched from the working folder, let it through.
      def reads?(call, path, file, root, dir)
        names?(path, file, root) || File.fnmatch?(normal(path, root), file, GLOB) ||
          (call.recursive? && !under(path, file, root).nil? && filtered?(call.globs, from_folder(file, dir)))
      end

      # The file's path from the working folder, which ripgrep matches a glob with "/" against; from
      # a folder outside the project the reader keeps the project's own path.
      def from_folder(file, dir)
        dir.split("/").first == ".." ? file : Pathname(file).relative_path_from(Pathname(dir)).to_s
      end

      # ripgrep's filters: a file passes when an including glob matches it (or none is given) and no
      # excluding one does.
      def filtered?(globs, path)
        including, excluding = globs.partition { |glob| !glob.start_with?("!") }
        (including.empty? || including.any? { |glob| glob?(glob, path) }) && excluding.all? { |glob| glob?(glob, path) }
      end

      # A delegation's text names a file, a glob over it, or one of its folders written as a path
      # ("config/", "./config") or quoted (`config`, a param's "config"); a bare prose word such as
      # "the app config" names no folder, as "." names no root.
      def text_covers(text, files, root)
        words = text.scan(WORD).map do |quote, raw|
          word = raw.sub(/[.?!:]+\z/, "")
          [normal(word, root), word.include?("/") || !quote.empty?]
        end
        named = words.reject { |word, _pathy| word.empty? }.uniq
        files.select do |file|
          named.any? do |word, pathy|
            names?(word, file, root) || (pathy && ancestors(file).include?(word)) || (word.match?(/[*?\[]/) && glob?(word, file))
          end
        end
      end
    end
  end
end
