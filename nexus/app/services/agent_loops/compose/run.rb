module AgentLoops
  module Compose
    # Nexus is this tool's runner: take the parked task, evaluate the script in a job
    # (never under the loop lock), settle it. Every failure is an error envelope the
    # next round reads — the refusal is how the model learns. The WHEN word is `wait`
    # on the call: by default the subgraph is DETACHED — appended from a detached
    # branch tip with no head, so nothing is spliced under the continuation and each
    # tip is a receipt — and `wait: true` splices it under the continuation.
    class Run
      DETACHED_MANIFEST = "They run in the background: each result reaches you in a new turn after this reply, " \
                          "even if it finishes sooner. The message is not from the person.".freeze
      WAITED_MANIFEST = "Their results reach you in the next round.".freeze
      # How much of a prompt the receipt quotes to point at its step.
      RECEIPT_PROMPT_CHARS = 60

      def self.call(...) = new(...).call

      def initialize(node:)
        @node = node
      end

      def call
        agent_loop = @node.agent_loop
        return :not_running unless @node.status == "running"
        return :not_mutable unless agent_loop.graph_mutable?

        # Normalized at the boundary and trusted after it: the evaluator
        # refuses an empty script by name, and anything else the model
        # put in that field reaches it as the source it claimed to be.
        input = @node.tool_input
        return refuse(KernelTool::INVALID_WAIT) unless KernelTool.valid_wait?(input)
        return refuse(KernelTool::INVALID_LIFETIME) unless KernelTool.valid_lifetime?(input)
        return refuse(KernelTool::INVALID_WAKE) unless KernelTool.valid_wake?(input)

        # Only a provider call has the driver's continuation to wait: a
        # call a composed graph made is followed by an authored step, so its
        # subgraph runs as background work whatever `wait` said, and its
        # results come back through the one delivery set.
        @wait = KernelTool.wait?(input) && !@node.tool_call_id.nil?
        @lifetime = KernelTool.lifetime(@node, input)
        @wake = KernelTool.wake(@node, input)
        execute(agent_loop, input["script"].to_s,
          Hash.try_convert(input["params"]) || {})
      end

      private

        def execute(agent_loop, script, params)
          built = Nexus::Compose::Evaluator.call(
            script: script, params: params, tool_names: BranchTools.names(KernelTool.round_of(@node))
          )
          return refuse(built.refusal, built.detail) unless built.built?

          lowered = Lower.call(built: built, node: @node, lifetime: @lifetime, wake: @wake)
          return refuse(lowered.refusal, lowered.detail) unless lowered.lowered?

          append(agent_loop, built, lowered)
        end

        # The job may run twice and the script is pure, so a second run
        # rebuilds the same keys; finding them is the whole recovery.
        def append(agent_loop, built, lowered)
          existing = agent_loop.agent_loop_nodes.where(node_key: lowered.keys).pluck(:node_key)
          return settle(manifest(lowered.keys, built)) if existing.any?

          result = Tasks::Append.call(Tasks::Append::Command.kernel(
            agent_loop: agent_loop, steps: lowered.steps,
            tip: KernelTool.branch_tip(@node).with(detached: @node.detached? || !@wait, lifetime: @lifetime, wake: @wake),
            origin: "model",
            expansion_parent: @node,
            head: (KernelTool.continuation_of(@node)&.node_key if @wait)
          ))
          return settle(manifest(lowered.keys, built)) if result.applied?

          settle(refusal_text(result, built), is_error: true)
        end

        # The compiler speaks positions and the model wrote lines, so the
        # refusal is translated (Lower.explain); a door-level one has no position.
        def refusal_text(result, built)
          errors = Lower.explain(result.errors, built)
          errors = [{ "code" => result.outcome.to_s }] if errors.empty?
          "The composed graph was refused:\n#{JSON.pretty_generate(errors)}"
        end

        def manifest(keys, built)
          delivery = if @wait
            WAITED_MANIFEST
          elsif @lifetime == "turn"
            "They run in the background. Continue other work; their results must be consumed " \
              "and incorporated in this turn before the final answer."
          elsif @node.agent_loop.standalone?
            "They run in the background: each result reaches you in this loop before it completes."
          elsif @wake == "passive"
            "They run in the background. After the final answer results are recorded in conversation " \
              "history without starting another turn, even if they finish sooner."
          else
            DETACHED_MANIFEST
          end
          ["Composed #{keys.length} #{"task".pluralize(keys.length)}: #{keys.join(", ")}.",
           *prompt_only(built.steps, built.lines), delivery].join("\n")
        end

        # THE STEPS THAT START FROM THEIR PROMPT ALONE — each model step that
        # names no `results` — by the author's own coordinates: the script
        # line that placed it and the start of its prompt, never a generated
        # key the author would have to count to. A compile-time fact, so a
        # hand-off the author forgot is visible where it was written.
        def prompt_only(steps, lines)
          steps.zip(lines).flat_map do |step, line|
            model = step["model"]
            if step.key?("parallel")
              step["parallel"].zip(line.fetch("members")).flat_map do |member, placed|
                sequence = Array.try_convert(member)
                sequence ? prompt_only(sequence, placed) : prompt_only([member], [placed])
              end
            elsif model && Array(model["results"]).empty?
              ["Line #{line} g.model(#{JSON.generate(prompt_head(model["prompt"]))}) starts from its prompt alone."]
            else
              []
            end
          end
        end

        def prompt_head(prompt)
          text = prompt.to_s.squish
          text.length > RECEIPT_PROMPT_CHARS ? "#{text.first(RECEIPT_PROMPT_CHARS).rstrip}…" : text
        end

        def refuse(code, detail = nil)
          settle([code, detail].compact.join(": "), is_error: true)
        end

        def settle(text, is_error: false)
          text = "#{text}\n#{KernelTool.task_reference(@node)}" unless is_error
          KernelTool.settle(@node, text, is_error: is_error, title: is_error ? "compose refused" : "compose")
        end
    end
  end
end
