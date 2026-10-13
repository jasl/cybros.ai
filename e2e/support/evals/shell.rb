require "strscan"

module E2E
  module Evals
    # THE SHELL'S SPLIT, one reading of a bash command line for every reader that asks (`QueuePass`,
    # `Coverage`): words at blanks, commands at the control operators — neither inside quotes, an
    # escape, parentheses (`$( … )`, `<( … )`, `$(( … ))`, a subshell) or backquotes; a `#` that
    # opens a word comments out its line; a subshell group standing alone is read as the commands
    # inside it. Words keep their quotes and substitutions: what the shell expands of one is read
    # off it here (`glob?`, `brace?`), what it names is the reader's.
    module Shell
      # A simple command's words, quotes and substitutions kept, and the control operator after it.
      Simple = Data.define(:words, :ender) do
        def piped? = ender == "|"
        # Its words past the ones that open a compound command (`do`, `then`, …).
        def own = words.drop_while { |word| RESERVED.include?(word) }
      end

      OPERATOR = /&&|\|\||;;|[;&|\n]/
      QUOTED = /'[^']*'|"(?:\\.|[^"\\])*"|\\./m
      RESERVED = %w[do then else elif if ! { time].freeze
      # A `$( … )`, a process substitution `<( … )` or `>( … )`, nested parentheses and all, or a
      # backquoted command.
      SUBSTITUTION = /[$<>](?<paren>\((?:[^()]|\g<paren>)*\))|`(?<tick>[^`]*)`/
      PARAMETER = /\$\{[^}]*\}/
      GROUP = /\A\((?!\().*\)\z/m
      # A brace expansion: `{a,b}` or `{1..3}`.
      BRACE = /\{[^{}]*(?:,|\.\.)[^{}]*\}/
      # The line count `head`/`tail` keeps as spelled: `-n1`, `-n 1`, `-1`, `--lines=1`.
      LINES = /(?:\A| )(?:-n ?|--lines[= ]|-)(\d+)(?: |\z)/
      KEEPERS = %w[head tail].freeze

      module_function

      def simples(text)
        scanner = StringScanner.new(text)
        commands = []
        words = []
        word = +""
        depth = 0
        tick = false
        until scanner.eos?
          open = depth.positive? || tick
          if !open && word.empty? && scanner.skip(/#[^\n]*/)
            next
          elsif !open && (operator = scanner.scan(OPERATOR))
            commands.concat(finished(word.empty? ? words : words + [word], operator))
            words = []
            word = +""
          elsif !open && scanner.skip(/[ \t]+/)
            words << word unless word.empty?
            word = +""
          elsif (quoted = scanner.scan(QUOTED))
            word << quoted
          else
            char = scanner.getch
            depth += 1 if char == "("
            depth -= 1 if char == ")" && depth.positive?
            tick = !tick if char == "`"
            word << char
          end
        end
        commands.concat(finished(word.empty? ? words : words + [word], nil))
      end

      def finished(words, ender)
        if words.empty?
          []
        elsif words.size == 1 && words.first.match?(GROUP)
          inside = simples(words.first[1...-1])
          inside.empty? ? [] : [*inside[0...-1], inside.last.with(ender: ender)]
        else
          [Simple.new(words: words, ender: ender)]
        end
      end

      # The commands a pipe joins, in order.
      def pipelines(commands) = commands.slice_when { |before, _after| !before.piped? }.to_a

      # The command text of each substitution in a word, in order; a nested one stays inside the
      # text of the one around it.
      def substitutions(word) = word.scan(SUBSTITUTION).map { |paren, tick| paren ? paren[1...-1] : tick }

      # A word as the shell reads its path: quotes and escapes gone.
      def unquoted(word) = word.delete(%q('"\\))

      # What the shell expands of a word itself: its substitutions, parameters and quotes stripped —
      # a `*` inside `$(ls queue/* | head -n1)` is that command's, never the word's.
      def expanded(word) = word.gsub(SUBSTITUTION, "").gsub(QUOTED, "").gsub(PARAMETER, "")

      # A glob the shell expands: `*`, `?` or `[` in the word itself.
      def glob?(word) = expanded(word).match?(/[*?\[]/)

      def brace?(word) = expanded(word).match?(BRACE)

      # THE ONE-LINE PICK: a command whose last pipeline keeps one line at some stage (`ls queue |
      # sort | head -n1`, `… | tail -1`) prints one line, whatever its first stage listed.
      def one_line?(text)
        pipelines(simples(text)).last.to_a.any? do |command|
          name, *args = command.own
          KEEPERS.include?(File.basename(name.to_s)) && args.join(" ")[LINES, 1] == "1"
        end
      end
    end
  end
end
