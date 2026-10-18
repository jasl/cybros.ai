require "strscan"
require_relative "declared_set"

module E2E
  module TaskBench
    # WHAT A FIXTURE CAN ANSWER: a message is READ-CLASS when it holds at least one call and every
    # call reads this machine — a tool rho announces `read_only` on the closed world (rho's own
    # effect profiles, the membership rule rho's allow list is written from; never a name list of
    # the harness's) whose `path`, when it names one, lands inside the fixture, or a `bash` whose
    # workdir lands there and whose command is a pipeline of the admitted read commands. The
    # two-step probe answers such a message from the fixture and asks the next one; any other
    # message is the one it scores.
    #
    # The model's output is untrusted, and what the emulator answers goes back to a provider: a
    # path that LANDS outside the fixture — absolute elsewhere, `~`, a `..` that climbs out — would
    # read the harness machine's own files (a provider key among them) into a prompt, so such a
    # call is no read and nothing answers it. A tool's `path` and bash's `workdir` are judged where
    # rho lands them, under the draw's own `ToolEnv`; a bash argv path by its spelling (relative,
    # no `..`), so it can only descend from a workdir that is inside. A command is tokenized here,
    # WITHOUT a shell, exactly as far as bash would split it — quotes, backslash escapes, the pipe
    # — and anything a shell would expand, redirect, chain, background or glob is refused rather
    # than interpreted: the emulator runs the argv itself, so the argv admitted is the argv run.
    module ReadClass
      # Raised inside the tokenizer and the per-command checks; `bash_argv` answers nil for it.
      Unadmitted = Class.new(StandardError)

      # One lexeme of a command: blanks, a single- or double-quoted run (a double-quoted `$` or
      # backquote would expand, so it does not match), a backslash escape, the pipe, or a plain run
      # of characters no shell treats specially. Anything else — `;&<>()$`{}*?[]`, a newline — is
      # no lexeme, and the command is refused.
      LEXEME = /
        (?<blank>[ \t]+) |
        '(?<single>[^']*)' |
        "(?<double>(?:[^"\\$`]|\\.)*)" |
        \\(?<escaped>[^\n]) |
        (?<pipe>\|) |
        (?<plain>[^ \t\n'"\\|;&<>()$`{}*?\[\]]+)
      /x
      # Inside double quotes a backslash escapes only these; before any other character it is kept.
      DOUBLE_ESCAPED = /\\(["\\$`])/

      # THE ADMITTED COMMANDS, each with the arguments it may carry. Flags are allowlisted per
      # command: `find` takes no action primary (`-exec`, `-execdir`, `-ok`, `-delete`, `-fprint*`
      # are all outside the list) and no `-L`; `grep` never reads patterns from a file (`-f`,
      # `--file`); `sed` is `-n` and one print script over line numbers, never `-i` or `w`.
      LS_FLAGS = /\A-[laAR1hFtrSdp]+\z/
      CAT_FLAGS = /\A-[nbs]+\z/
      WC_FLAGS = /\A-[lwcm]+\z/
      HEAD_COUNT = /\A-(?:[nc])?\d+\z/
      SED_PRINT = /\A(?:\d+|\$)(?:,(?:\d+|\$))?p\z/
      GREP_FLAGS = /\A-[rRnilLcwxvEFHhosI]+\z/
      GREP_VALUED = %w[-e -A -B -C -m].freeze
      GREP_ATTACHED = /\A-[ABCm]\d+\z/
      GREP_LONG = /\A--(?:(?:include|exclude|exclude-dir)=.+|color=never|colour=never|no-messages)\z/
      FIND_BARE = %w[-print -o -or -a -and -not ! ( ) -empty].freeze
      FIND_VALUED = %w[-name -iname -path -ipath -type -maxdepth -mindepth].freeze
      FIND_TYPES = %w[f d l].freeze
      DIGITS = /\A\d+\z/

      module_function

      # THE OFFERED SET'S OWN FACTS: rho's announcement entries (name and effect profile) for the
      # tools a rho turn declares — the hidden ones (`RunDeclaration.undeclared`) left out, as the
      # declared set leaves them.
      def declarations
        @declarations ||= begin
          offered = DeclaredSet.function_definitions.reject { |entry| Nexus::ToolDeclarations.canonical_of(entry) }.map { |entry| entry.dig("function", "name") }
          DeclaredSet.registry.announcement.select { |entry| offered.include?(entry.fetch("name")) }.freeze
        end
      end

      # `calls` are resolved (`Objectives::Call`): a spelling the set never declared resolves to no
      # declaration and is no read. `env` is the draw's `Rho::Runner::ToolEnv`, rooted at its copy.
      def all?(calls, declarations:, env:)
        calls.any? && calls.all? { |call| read?(call, declarations: declarations, env: env) }
      end

      def read?(call, declarations:, env:)
        if call.arguments.nil?
          false
        elsif call.tool == Rho::Runner::Tools::Bash::NAME
          !bash_argv(call.argument("command")).nil? && inside?(call.argument("workdir"), env)
        else
          profile = declarations.find { |entry| entry.fetch("name") == call.tool }&.fetch("effect_profile")
          profile&.values_at("kind", "effect_scope") == %w[read_only closed] && inside?(call.argument("path"), env)
        end
      end

      # WHERE RHO LANDS A TOOL'S `path` OR BASH'S `workdir`: absent or empty is the root (find's
      # `searchDir || "."`, grep's and ls's `path || "."`, bash's empty workdir); anything else is
      # resolved against the root, absolute spellings too, and is inside when it lands at the root or
      # under it — rho's own predicate, `ToolEnv#in_roots?` (the spelled prefix, `..` and symlinks
      # judged where they land). `~` (a home; `~user` makes the expansion raise) and NUL (the
      # expansion raises on it) are refused before it.
      def inside?(path, env)
        spelled = path.to_s
        spelled.empty? || (!spelled.start_with?("~") && !spelled.include?("\u0000") && env.in_roots?(spelled))
      end

      # A bash argv path, judged by its spelling: relative, no `..`, no `~`, no NUL.
      def relative?(path)
        !path.empty? && !path.start_with?("/", "~") && !path.include?("\u0000") && path.split("/").none?("..")
      end

      # The command as one argv per pipeline stage, or nil when it is not a pipeline of admitted
      # read commands.
      def bash_argv(command)
        split = stages(String.try_convert(command) || raise(Unadmitted))
        split.each { |argv| admit(argv) }
        split
      rescue Unadmitted
        nil
      end

      # The words of each stage, as bash would split them.
      def stages(command)
        scanner = StringScanner.new(command)
        done = []
        stage = []
        word = nil
        until scanner.eos?
          raise Unadmitted unless scanner.scan(LEXEME)

          if scanner[:blank]
            stage, word = closed(stage, word), nil
          elsif scanner[:pipe]
            done, stage, word = done + [piped(closed(stage, word))], [], nil
          else
            word = extended(word, scanner)
          end
        end
        done + [piped(closed(stage, word))]
      end

      def closed(stage, word) = word.nil? ? stage : stage + [word]

      # A stage with no words — `| wc`, `ls |`, `ls || true` — is refused.
      def piped(stage) = stage.empty? ? raise(Unadmitted) : stage

      # A word opening with `#` is a comment and one opening with `~` a home directory to bash.
      def extended(word, scanner)
        raise Unadmitted if word.nil? && scanner[:plain]&.start_with?("#", "~")

        "#{word}#{scanner[:single] || scanner[:escaped] || scanner[:plain] || scanner[:double].gsub(DOUBLE_ESCAPED, '\1')}"
      end

      def admit(argv)
        command, *arguments = argv
        case command
        when "cat" then plain(arguments, CAT_FLAGS)
        when "ls" then plain(arguments, LS_FLAGS)
        when "wc" then plain(arguments, WC_FLAGS)
        when "head" then head(arguments)
        when "sed" then sed(arguments)
        when "grep" then grep(arguments)
        when "find" then find(arguments)
        else raise Unadmitted
        end
      end

      # Flags from the command's set, then paths inside the fixture, in any order.
      def plain(arguments, flags)
        arguments.each { |argument| flags.match?(argument) || fixture_path(argument) }
      end

      def fixture_path(argument)
        raise Unadmitted if argument.start_with?("-") || !relative?(argument)
      end

      # `-n N` / `-c N` first, or the count attached (`-n20`, `-20`), then paths.
      def head(arguments)
        plain(%w[-n -c].include?(arguments.first) ? counted(arguments.drop(1)) : arguments, HEAD_COUNT)
      end

      def counted(arguments) = DIGITS.match?(arguments.first.to_s) ? arguments.drop(1) : raise(Unadmitted)

      def sed(arguments)
        flag, script, *paths = arguments
        raise Unadmitted unless flag == "-n" && SED_PRINT.match?(script.to_s)

        paths.each { |path| fixture_path(path) }
      end

      # Flags first (a pattern given by `-e`, a context or count by value), then the pattern
      # unless `-e` gave one — a pattern is a pattern, never a path — then paths inside the fixture.
      def grep(arguments)
        patterns, positionals = grep_options(arguments)
        paths = patterns.empty? ? positionals.drop(1) : positionals
        raise Unadmitted if patterns.empty? && positionals.empty?

        paths.each { |path| fixture_path(path) }
      end

      def grep_options(arguments, patterns = [])
        head, *rest = arguments
        if head.nil? then [patterns, []]
        elsif head == "--" then [patterns, rest]
        elsif head == "-e" then grep_options(rest.drop(1), patterns + [rest.first || raise(Unadmitted)])
        elsif GREP_VALUED.include?(head) then grep_options(counted(rest), patterns)
        elsif GREP_ATTACHED.match?(head) || GREP_FLAGS.match?(head) || GREP_LONG.match?(head) then grep_options(rest, patterns)
        elsif head.start_with?("-") then raise Unadmitted
        else [patterns, arguments]
        end
      end

      # The starting points (fixture paths, none = the tool's default), then an expression of
      # tests and grouping alone.
      def find(arguments)
        roots = arguments.take_while { |argument| !argument.start_with?("-") && !FIND_BARE.include?(argument) }
        roots.each { |root| fixture_path(root) }
        find_expression(arguments.drop(roots.length))
      end

      def find_expression(tokens)
        head, value, *rest = tokens
        if head.nil? then nil
        elsif FIND_BARE.include?(head) then find_expression(tokens.drop(1))
        elsif FIND_VALUED.include?(head) && find_value?(head, value) then find_expression(rest)
        else raise Unadmitted
        end
      end

      def find_value?(primary, value)
        case primary
        when "-type" then FIND_TYPES.include?(value)
        when "-maxdepth", "-mindepth" then DIGITS.match?(value.to_s)
        else !value.nil?
        end
      end
    end
  end
end
