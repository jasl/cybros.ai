require "json"

module E2E
  module TaskBench
    # A read-only scout round may inspect files before choosing a task. Compound shell stages
    # must all be readers; substitutions and redirects make the round an action instead.
    module Look
      READ_TOOLS = %w[read ls find grep].freeze
      COMMANDS = %w[cat ls wc head sed grep find pwd tail].freeze
      QUIET = "2>/dev/null".freeze
      STAGES = /;|&&|\|\||\|/
      # A redirect left once the one quieted stderr is stripped, a command substitution, a backquote.
      UNREAD = /[<>`]|\$\(/

      module_function

      def look?(round) = round.any? && round.all? { |call| look_call?(call) }

      def look_call?(call)
        name = call.fetch("name")
        READ_TOOLS.include?(name) || (name == "bash" && look_command?(call.dig("input", "command").to_s))
      end

      def look_command?(command)
        quiet = command.sub(QUIET, "")
        stages = quiet.split(STAGES).map(&:strip)
        !quiet.match?(UNREAD) && stages.any? && stages.all? { |stage| COMMANDS.include?(stage.split.first) }
      end

      # A round's calls in the wire shape a message's calls arrive in: the name and the arguments as
      # JSON text — what `TaskBench::Objectives.door` kinds.
      def calls(round)
        round.each_with_index.map do |call, index|
          { "id" => "call_#{index + 1}", "name" => call.fetch("name"), "arguments" => JSON.generate(call.fetch("input")) }
        end
      end
    end
  end
end
