module AgentLoops
  module TaskTool
    # `task` — one bounded job to a new agent with an empty context. Nexus is
    # its runner: the call's branch is ONE model step through the door
    # compose uses, inheriting the round's surface minus the graph verbs.
    # DETACHED by default: the branch hangs off the call with no head, and
    # its answer reaches the model later by the wake or by mail; with `wait:
    # true` it is spliced under the round's continuation and its last word is
    # this call's paired result at assembly. Every refusal is an error
    # envelope the round reads.
    class Run
      EMPTY_PROMPT = "prompt is empty. Say what the task should do and what to answer with.".freeze
      INVALID_WAIT = KernelTool::INVALID_WAIT
      ROOT_SUFFIX = "-model-1".freeze

      class << self
        def call(...) = new(...).call

        # The branch root's key: the call's namespace names the call, which
        # is the id the model reads back.
        def root_key(call_key) = "#{call_key}#{ROOT_SUFFIX}"
      end

      def initialize(node:)
        @node = node
      end

      def call
        agent_loop = @node.agent_loop
        return :not_running unless @node.status == "running"
        return :not_mutable unless agent_loop.graph_mutable?

        input = @node.tool_input
        # The job may run twice; the root's key is the whole recovery.
        return settle(started_text(input)) if agent_loop.agent_loop_nodes.exists?(node_key: root_key)

        refusal = refusal_for(input)
        return settle(refusal, is_error: true) if refusal

        append(agent_loop, input)
      end

      private

        def root_key = self.class.root_key(@node.node_key)
        def wait?(input) = KernelTool.wait?(input)

        def refusal_for(input)
          return EMPTY_PROMPT if String.try_convert(input["prompt"]).to_s.strip.empty?
          return INVALID_WAIT unless KernelTool.valid_wait?(input)
          return KernelTool::INVALID_LIFETIME unless KernelTool.valid_lifetime?(input)
          return KernelTool::INVALID_WAKE unless KernelTool.valid_wake?(input)

          narrowed = narrow(input)
          BranchTools.not_a_tool("tools", narrowed.refused, round) if narrowed.refused
        end

        # `tools` is generous on shape — one name reads as a list of one —
        # and strict on names: a wrong one is answered with the right ones.
        def narrow(input)
          wanted = input.key?("tools") ? (Array.try_convert(input["tools"]) || [input["tools"]]) : nil
          BranchTools.narrow(round, wanted)
        end

        def round = @round ||= KernelTool.round_of(@node)

        # A detached branch is the step's own `detached` (no reads, `branch`,
        # off the spine) with NO head: the continuation never waits on it.
        # A waited provider call splices the branch under the driver's
        # continuation; a waited call a composed graph made has no such
        # continuation — the step after it is authored — so the branch, one
        # readable leaf, stands in for the call: its readers read the
        # delegate's answer and the steps after it wait on it.
        def append(agent_loop, input)
          step = Tasks::Step.inheriting(round,
            key: root_key, prompt: input["prompt"], tools: narrow(input).definitions,
            model: ConfiguredModel.for(round).model,
            detached: !wait?(input), on_failure: "absorb", lifetime: KernelTool.lifetime(@node, input),
            wake: KernelTool.wake(@node, input))
          waited = wait?(input)
          result = Tasks::Append.call(Tasks::Append::Command.kernel(
            agent_loop: agent_loop, steps: [step], tip: KernelTool.branch_tip(@node),
            origin: "model", expansion_parent: @node,
            head: (KernelTool.continuation_of(@node)&.node_key if waited && @node.tool_call_id),
            replaces: (@node.node_key if waited && @node.tool_call_id.nil?)
          ))
          return settle(started_text(input)) if result.applied?

          detail = result.errors.first&.fetch("code", nil) || result.outcome
          settle("The task was refused: #{detail}.", is_error: true)
        end

        def started_text(input)
          key = @node.node_key
          return "Task #{key} started." if wait?(input)
          if KernelTool.lifetime(@node, input) == "turn"
            return "Task #{key} started in the background. Continue other work while it runs. " \
              "Its <task_result task=\"#{key}\"> reaches you in this turn; consume it and " \
              "incorporate the result before the final answer."
          end

          if @node.agent_loop.standalone?
            return "Task #{key} started in the background. Its <task_result task=\"#{key}\"> " \
              "reaches you in this loop before it completes. Continue other work while it runs."
          end

          if KernelTool.wake(@node, input) == "passive"
            return "Task #{key} started in the background. After the final answer its result is " \
              "recorded in conversation history without starting another turn, even if it finishes sooner."
          end

          "Task #{key} started in the background. Its <task_result task=\"#{key}\"> reaches you " \
            "in a new turn after this reply, even if it finishes before you answer. " \
            "The message is not from the person. Do not poll for it, guess " \
            "its answer, run the same command, or edit its files. Continue other work or end your turn."
        end

        def settle(text, is_error: false)
          text = "#{text}\n#{KernelTool.task_reference(@node)}" unless is_error
          KernelTool.settle(@node, text, is_error: is_error, title: is_error ? "task refused" : "task")
        end
    end
  end
end
