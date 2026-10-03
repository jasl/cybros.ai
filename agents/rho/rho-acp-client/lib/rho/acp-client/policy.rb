require "rho"
require "rho/acp"

module Rho
  module AcpClient
    # THE PERMISSION RELAY — THE FLOOR, NEVER A PROXY. The parent call was judged whole at
    # the kernel's stage; approving `delegate_agent` approves what the
    # agent does, as approving `bash` approves the script. Inside the turn
    # each `session/request_permission` is answered here, locally: (1) the
    # request's `toolCall` merged onto the tracked `tool_call` (an id-only
    # request is judged by what its `tool_call` said); (2) THE FLOOR —
    # `Rho::Extensions::Guard.refusal` over a synthesized call: `execute`
    # → `("bash", {"command"})`, `edit|delete|move` → `("write", {"path"})`
    # per location — the nine regexes and the incubation floor over
    # `Rho.protected_roots`, one list, no second matcher; a sentence → the
    # first `reject_once` option, else `cancelled`; (3) THE ROW'S POLICY —
    # `allow` → the first `allow_once` (never `allow_always`: a grant is a
    # person's act; the child re-asks, rho re-judges), `reject` →
    # `reject_once`, no option of the kind → `cancelled`; (4) a request the
    # floor cannot read (no command, no path) is the policy's.
    module Policy
      Kind = Rho::Acp::Methods::ToolKind
      OptionKind = Rho::Acp::Methods::PermissionOptionKind
      Outcome = Rho::Acp::Methods::PermissionOutcome
      EXECUTE_KINDS = [Kind::EXECUTE].freeze
      PATH_KINDS = [Kind::EDIT, Kind::DELETE, Kind::MOVE].freeze

      # `outcome` is the JSON-RPC result; `decision` allow|reject; `by`
      # floor|policy; `kind` the tool call's; `reason` the floor's sentence.
      Decision = Data.define(:outcome, :decision, :by, :kind, :reason)

      module_function

      def decide(params, tracked:, row:, home:, guard: Rho::Extensions::Guard)
        call = merged(params, tracked)
        options = Array(params["options"]).select { |option| option.is_a?(Hash) }
        reason = synthesized(call).filter_map { |name, arguments| guard.refusal(name, arguments, home) }.first
        if reason
          Decision.new(outcome: outcome(options, OptionKind::REJECT_ONCE), decision: "reject", by: "floor",
            kind: call["kind"], reason: reason)
        elsif row.allow?
          Decision.new(outcome: outcome(options, OptionKind::ALLOW_ONCE), decision: "allow", by: "policy",
            kind: call["kind"], reason: nil)
        else
          Decision.new(outcome: outcome(options, OptionKind::REJECT_ONCE), decision: "reject", by: "policy",
            kind: call["kind"], reason: nil)
        end
      end

      # The tracked tool_call under the request's own fields.
      def merged(params, tracked)
        request = Hash.try_convert(params["toolCall"]) || {}
        known = Hash.try_convert(tracked[request["toolCallId"]]) || {}
        known.merge(request.compact)
      end

      # The calls the floor reads: `[name, arguments]` pairs, none for a
      # request it cannot read.
      def synthesized(call)
        kind = call["kind"]
        if EXECUTE_KINDS.include?(kind)
          command = command_text(call)
          command.nil? ? [] : [["bash", { "command" => command }]]
        elsif PATH_KINDS.include?(kind)
          paths(call).map { |path| ["write", { "path" => path }] }
        else
          []
        end
      end

      def command_text(call)
        raw = Hash.try_convert(call["rawInput"]) || {}
        command = raw["command"]
        command = command.map(&:to_s).join(" ") if command.is_a?(Array)
        command = call["title"] unless command.is_a?(String) && !command.empty?
        command.is_a?(String) && !command.empty? ? command : nil
      end

      def paths(call)
        raw = Hash.try_convert(call["rawInput"]) || {}
        located = Array(call["locations"]).filter_map { |location| location["path"] if location.is_a?(Hash) }
        [*located, raw["path"]].select { |path| path.is_a?(String) && !path.empty? }.uniq
      end

      # The first option of the kind, selected; none → the spec's cancelled.
      def outcome(options, kind)
        option = options.find { |candidate| candidate["kind"] == kind }
        return { "outcome" => { "outcome" => Outcome::CANCELLED } } if option.nil?

        { "outcome" => { "outcome" => Outcome::SELECTED, "optionId" => option["optionId"] } }
      end
    end
  end
end
