module AgentLoops
  # Hooks are ordinary foreground tool tasks. The task row is both the
  # invocation and its recovery record; only natural execution boundaries
  # call this owner, so explicit cancellation never asks a hook for consent.
  module LifecycleHooks
    module_function

    def before_start(agent_loop, node)
      return false if agent_loop.lifecycle_hooks.blank? || node.lifecycle_event

      if summary_loop?(agent_loop)
        return false unless agent_loop.lifecycle_hooks["pre_compact"]

        seed = agent_loop.agent_loop_nodes.where(lifecycle_event: nil).order(:id).first
        return pending?(agent_loop, "pre_compact", seed, head: node) if node.id == seed.id
      elsif agent_loop.lifecycle_hooks["turn_start"] && node.round? && node.continuation_source != Tasks::Compile::BRANCH
        seed = agent_loop.agent_loop_nodes.where(type: AgentLoopNodes::ModelTask.sti_name,
          continuation_source: Tasks::Compile::ROUND).order(:id).first
        return true if node.id == seed&.id && pending?(agent_loop, "turn_start", seed, head: node)
      end

      if node.round? && !node.repaired? && resume_compaction(agent_loop, node)
        return true if node.reload.remaining_dependencies.positive?
      end

      if agent_loop.lifecycle_hooks["post_compact"] && node.round? && node.repaired?
        key = node.compaction[AgentLoopNodes::ModelTask::SUMMARY_SOURCE]
        summary = agent_loop.agent_loop_nodes.find_by(node_key: key) if key
        return false if summary && !summary.usable_summary?

        return pending?(agent_loop, "post_compact", node, head: node)
      end
      false
    end

    def before_compact(agent_loop, node, trigger:)
      pending?(agent_loop, "pre_compact", node, head: node,
        context: { "compaction_trigger" => trigger.kind, "overshoot_bytes" => trigger.overshoot&.bytes,
          "overshoot_tokens" => trigger.overshoot&.tokens })
    end

    def resume_compaction(agent_loop, node)
      return false unless agent_loop.lifecycle_hooks["pre_compact"]

      hook = find(agent_loop, "pre_compact", node)
      return false unless hook && (hook.status == "completed" || hook.failure_resolution.present?)

      # The hook task keeps the accepted request while its dependency
      # pauses the round. Manual and provider-overflow requests need not
      # meet another size wall when scheduling resumes.
      input = hook.tool_input
      overshoot = if input["overshoot_tokens"]
        Conversations::Compaction::Overshoot.tokens(input["overshoot_tokens"])
      elsif input["overshoot_bytes"]
        Conversations::Compaction::Overshoot.bytes(input["overshoot_bytes"])
      end
      trigger = Conversations::Compaction::Trigger.new(
        kind: input.fetch("compaction_trigger"), authoring_user: agent_loop.creating_user,
        origin: nil, input_public_id: nil, overshoot: overshoot
      )
      repaired = Conversations::Compaction::Arm.call(agent_loop: agent_loop, node: node, trigger: trigger)
      ScheduleJob.perform_later(agent_loop.id) if repaired
      repaired
    end

    def before_delivery(agent_loop, source)
      return false if agent_loop.lifecycle_hooks.blank? || agent_loop.delivered?
      return pending?(agent_loop, "post_compact", source) if summary_loop?(agent_loop)

      policy = agent_loop.lifecycle_hooks["stop"]
      return false if policy.nil?

      hook = find_or_append(agent_loop, "stop", source, policy: policy)
      return false if hook.failure_resolution.present?
      return true unless hook.status == "completed"

      result = TaskResultProjection.structured_content(TaskResultProjection.entry_payloads(hook.output_body))
      return false unless result.fetch("continue")

      round = continuation_round(agent_loop, source)
      append_continuation(agent_loop, source, round, hook, result.fetch("feedback"))
      true
    end

    # Validate executor-controlled decisions once, at result acceptance.
    # Failure/timeout remains a normal failed task with explicit retry.
    def result_refusal(node, value, is_error:)
      return nil if node.lifecycle_event.nil?
      return :hook_error if is_error

      refusal = Nexus::LifecycleHooks.result_refusal(node.lifecycle_event, value)
      return refusal if refusal
      return nil unless value["continue"]

      agent_loop = node.agent_loop
      source = agent_loop.agent_loop_nodes.find_by!(node_key: node.tool_input.fetch("task_key"))
      return nil unless source.id == agent_loop.deliverable_node_id
      return :hook_requires_model if continuation_round(agent_loop, source).nil?

      policy = agent_loop.lifecycle_hooks.fetch("stop")
      hook_ids = agent_loop.agent_loop_nodes.where(lifecycle_event: "stop").select(:id)
      # A background result may replace a candidate while its Stop check
      # runs. Only decisions consumed into real rounds spend this budget.
      count = agent_loop.agent_loop_nodes.where(type: AgentLoopNodes::ModelTask.sti_name,
        continuation_source: Tasks::Compile::ROUND).joins(:incoming_edges)
        .where(agent_loop_edges: { from_node_id: hook_ids }).distinct.count
      :stop_hook_limit if count >= policy.fetch("max_continuations")
    end

    def pending?(agent_loop, event, source, head: nil, context: {})
      policy = agent_loop.lifecycle_hooks&.fetch(event, nil)
      return false if policy.nil?

      hook = find_or_append(agent_loop, event, source, policy: policy, head: head, context: context)
      hook.status != "completed" && hook.failure_resolution.nil?
    end

    def find(agent_loop, event, source)
      agent_loop.agent_loop_nodes.where(lifecycle_event: event)
        .where("tool_input ->> 'task_key' = ?", source.node_key).first
    end

    def find_or_append(agent_loop, event, source, policy:, head: nil, context: {})
      hook = find(agent_loop, event, source)
      return hook if hook

      step = Tasks::Step::Tool.new(
        name: policy.fetch("tool"), key: free_key(agent_loop, "h"), lifecycle_event: event,
        input: { "event" => event, "task_key" => source.node_key,
          "agent_loop_public_id" => agent_loop.public_id,
          "conversation_public_id" => agent_loop.conversation&.public_id,
          "output_preview" => source.output_preview, "output_size_bytes" => source.output_size_bytes }.merge(context),
        timeout_ms: policy.fetch("timeout_ms"), on_failure: "halt",
        visibility: "collapsed", lifetime: source.lifetime
      )
      appended = Tasks::Append.call_locked(Tasks::Append::Command.kernel(
        agent_loop: agent_loop, steps: [step], origin: "kernel",
        tip: Tasks::Tip.seed(Tasks::Compile::BRANCH, lifetime: source.lifetime, wake: source.wake),
        head: head&.node_key, splice_reads: false
      ))
      raise Tasks::Append::Refused, appended.outcome unless appended.applied?

      ScheduleJob.perform_later(agent_loop.id)
      agent_loop.agent_loop_nodes.find_by!(node_key: step.key)
    end

    def append_continuation(agent_loop, source, round, hook, feedback)
      # Once the append commits, this round is the new deliverable; repeated
      # quiescence observes it as live and cannot consume this decision twice.
      appended = Tasks::Append.call_locked(Tasks::Append::Command.kernel(
        agent_loop: agent_loop,
        steps: [Tasks::Step.inheriting(round, key: free_key(agent_loop, "w"), prompt: feedback)],
        origin: "kernel",
        tip: Tasks::Tip.new(spine: Tasks::Known.of(source), waits: [Tasks::Known.of(hook)], reads: [],
          mark: Tasks::Compile::ROUND, detached: false, lifetime: source.lifetime, wake: source.wake)
      ))
      raise Tasks::Append::Refused, appended.outcome unless appended.applied?

      ScheduleJob.perform_later(agent_loop.id)
    end

    def summary_loop?(agent_loop) = agent_loop.conversation_turn&.compaction_summary? == true
    def continuation_round(agent_loop, source) = source.round? ? source : agent_loop.spine_tail

    def free_key(agent_loop, prefix)
      used = agent_loop.agent_loop_nodes.pluck(:node_key).to_set
      number = 1
      number += 1 while used.include?("#{prefix}#{number}")
      "#{prefix}#{number}"
    end
  end
end
