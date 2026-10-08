module AgentRuns
  module Steers
    # Send now inserts a model boundary before the unique waiting mainline.
    # The old head still joins every original task and the inserted mainline,
    # so claims, effects, cancellation and foreground completion stay owned.
    module Advance
      module_function

      def call(agent_run)
        return unless agent_run.steering_inputs.where(delivery_mode: "steer_now").exists?

        live = agent_run.mainline_nodes.where(status: AgentRunTask::LIVE_STATUSES).to_a
        behind = AgentRunEdge.where(from_node_id: live.map(&:id), to_node_id: live.map(&:id)).pluck(:to_node_id)
        heads = live.reject { |node| behind.include?(node.id) }
        return unless heads.one?

        head = heads.sole
        return unless head.status == "queued" && head.remaining_dependencies.positive? &&
          head.continuation_source == Tasks::Compile::ROUND && head.input_value.blank? &&
          head.expansion_parent&.model_task?

        sources = InputComposition.sources_for(head)
        source = sources.find(&:model_task?)
        return unless source&.terminal? && source.selected_model_invocation_id

        results = agent_run.agent_run_tasks.where(node_key: Array(head.result_from_node_keys)).to_a
        pending = (sources + results).reject(&:terminal?).uniq(&:id)
        return if pending.empty?

        calls = RoundReplay.fans_of([source]).fetch(source.id, {}).values
        # Keep call roots for pairing; a pending expanded child waits at the
        # old head and contributes only its root's truthful receipt here.
        material = (sources.reject { |node| node.id == source.id || !node.terminal? } + calls).uniq(&:id)
        reads = material.map { |node| Tasks::Known.of(node) } +
          results.select(&:terminal?).map { |node| Tasks::Known.of(node, result_only: true) }
        tip = Tasks::Tip.new(mainline: Tasks::Known.of(source), waits: [Tasks::Known.of(source)], reads: reads,
          mark: Tasks::Compile::ROUND, detached: false, lifetime: head.lifetime, wake: head.wake)
        key = next_key(agent_run)
        appended = Tasks::Append.call_locked(Tasks::Append::Command.kernel(
          agent_run: agent_run, origin: "kernel", steps: [Tasks::Step.inheriting(head, key: key)],
          tip: tip, head: head.node_key, splice_reads: false
        ))
        raise ArgumentError, "the immediate steer could not be appended: #{appended.errors.inspect}" unless appended.applied?

        consumer = agent_run.agent_run_tasks.find_by!(node_key: key)
        ToolReceipts.record(consumer, calls, pending: pending)
        Tasks::Append::Splice.interpose(agent_run: agent_run, head: head, source: consumer, pending: pending)
      end

      def next_key(agent_run)
        keys = agent_run.agent_run_tasks.pluck(:node_key).to_set
        index = 1
        index += 1 while keys.include?("steer#{index}")
        "steer#{index}"
      end
    end
  end
end
