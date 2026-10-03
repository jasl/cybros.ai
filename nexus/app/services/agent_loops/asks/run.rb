module AgentLoops
  module Asks
    # `ask` — one question to the person: one await through the door compose
    # uses, spliced under the round's continuation, tokenless so it answers
    # to write standing and announces `awaiting_human`; `halt` on expiry (the
    # kernel-await rule). The answer reaches the model as `<answer task="…">`
    # in the continuation's request.
    class Run
      EMPTY_PROMPT = "prompt is empty.".freeze
      FIELDS = %w[prompt options multi].freeze
      OPTIONS_INVALID = "options must be a list of strings.".freeze
      MULTI_INVALID = "multi must be true or false.".freeze
      # One park's ceiling: the await's effective deadline is clamped there anyway.
      TIMEOUT_MS = AgentLoopNodes::AwaitTask::MAX_HOLD_MS
      KEY_SUFFIX = "-ask-1".freeze

      class << self
        def call(...) = new(...).call
        def await_key(call_key) = "#{call_key}#{KEY_SUFFIX}"
      end

      def initialize(node:)
        @node = node
      end

      def call
        agent_loop = @node.agent_loop
        return :not_running unless @node.status == "running"
        return :not_mutable unless agent_loop.graph_mutable?
        return settle(asked_text) if agent_loop.agent_loop_nodes.exists?(node_key: await_key)

        input = @node.tool_input
        refusal = refusal_for(input)
        return settle(refusal, is_error: true) if refusal

        append(agent_loop, input)
      end

      private

        def await_key = self.class.await_key(@node.node_key)

        # ONE field name on every surface: an extra key is named with the
        # repair, so `question` is answered with `prompt`; the choices are
        # `options` (strings) and `multi` (a boolean), refused by sentence.
        def refusal_for(input)
          stray = input.keys.find { |name| !FIELDS.include?(name) }
          return "#{stray} is not a parameter; the fields are prompt, options and multi." if stray
          return EMPTY_PROMPT if String.try_convert(input["prompt"]).to_s.strip.empty?
          return OPTIONS_INVALID unless input["options"].nil? || Array.try_convert(input["options"])&.all?(String)

          MULTI_INVALID unless [nil, true, false].include?(input["multi"])
        end

        def append(agent_loop, input)
          step = Tasks::Step::Ask.new(key: await_key, prompt: input["prompt"], timeout_ms: TIMEOUT_MS,
            options: input["options"], multi: input["multi"])
          # Provider calls keep their paired acknowledgement in the model fan;
          # graph-authored calls hand every consumer to the answer itself.
          result = Tasks::Append.call(Tasks::Append::Command.kernel(
            agent_loop: agent_loop, steps: [step], tip: KernelTool.branch_tip(@node),
            origin: "kernel", expansion_parent: @node,
            head: (KernelTool.continuation_of(@node)&.node_key if @node.tool_call_id),
            replaces: (@node.node_key unless @node.tool_call_id)
          ))
          return settle(asked_text) if result.applied?

          detail = result.errors.first&.fetch("code", nil) || result.outcome
          settle("The question was refused: #{detail}.", is_error: true)
        end

        def asked_text = "Asked. The answer is in your next message as <answer task=\"#{@node.node_key}\">."

        def settle(text, is_error: false)
          KernelTool.settle(@node, text, is_error: is_error, title: is_error ? "ask refused" : "ask")
        end
    end
  end
end
