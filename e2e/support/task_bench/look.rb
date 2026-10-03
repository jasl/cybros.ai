require "json"

module E2E
  module TaskBench
    # THE IN-VIVO LOOK: whether a round of a recorded run only looked. No fixture exists for a
    # historical round, so a look is read by this rule, not by `ReadClass`: a round is a look when it
    # holds a call and every call is `read`, `ls`, `find` or `grep`, or a `bash` whose command — its
    # one `2>/dev/null` stripped, then split into stages on `;`, `&&`, `||` and `|` — opens each stage
    # with one of `ReadClass`'s admitted commands (its `admit`) or `pwd` or `tail`, which read by
    # effect. A second quieted stderr, any other redirect, a command substitution or a backquote is no
    # look, so `cat bin/fetch 2>/dev/null; ls bin 2>/dev/null` is a door. `ReadClass` refuses `;`
    # outright, which would read a model's `cat claims.md; ls -R lib; pwd` as its door.
    #
    # One rule for both readers of a recorded run's door: the door screen's register
    # (`Screen::DoorReader`) and the evals lane's `door_kind` (`Evals::Predicates`), so a kind the lane
    # records means what the register's kinds mean. A round is its calls, each `{name, input}`.
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
