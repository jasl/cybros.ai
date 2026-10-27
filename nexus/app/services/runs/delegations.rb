module Runs
  # A scoped spawn's durable completion is a task on its caller's graph. The
  # child remains a reusable conversation; only its original request is owned.
  module Delegations
    SUFFIX = "-delegation-1".freeze

    module_function

    def key(call_key) = "#{call_key}#{SUFFIX}"

    def for_call(call)
      call.run.tasks.find_by(node_key: key(call.node_key))
    end

    def for_input(input)
      for_dispatch(input.host, input.sender_run_public_id, input.sender_task_key)
    end

    def for_dispatch(child, sender_run_public_id, sender_task_key)
      return if sender_task_key.nil? || !child.hosts_turns?

      source = Run.find_by(public_id: sender_run_public_id)
      call = source&.tasks&.find_by(node_key: sender_task_key)
      node = call && for_call(call)
      return unless node

      target_for(call, node) == child ? node : nil
    end

    def target_for(call, node = for_call(call))
      return call.spawned_conversation if call.spawned_conversation
      return unless node&.delegated_input_public_id

      input = Input.find_by(public_id: node.delegated_input_public_id)
      return input.host if input

      turn = Turn.find_by(input_public_id: node.delegated_input_public_id, forked_from_turn_public_id: nil)
      return turn.conversation if turn

      receipt = TaskResultProjection.call(call)["structured_content"]
      Conversation.find_by(workspace_id: call.run.workspace_id, public_id: receipt["conversation_public_id"]) if receipt
    end

    def original_turn(child, call)
      node = for_call(call)
      return child.turns.find_by(input_public_id: node.delegated_input_public_id, forked_from_turn_public_id: nil) if node&.delegated_input_public_id

      child.turns.find_by(sender_run_public_id: call.run.public_id,
        sender_task_key: call.node_key, forked_from_turn_public_id: nil)
    end

    def original_variant(turn)
      turn&.variants&.find_by(position: 0)
    end

    # The sample that ANSWERS the original request: position zero, or the
    # kernel's own fallback sample of it; never a person's regenerate.
    def answering_variant(turn) = answering_sample(original_variant(turn))

    # The sample that answers `variant`'s request: itself, or — when a
    # provider's classifier declined it, or the provider was overloaded on
    # every attempt, and the answerer's declared fallback asked again —
    # that `fallback` sample.
    def answering_sample(variant)
      return variant unless variant&.model_invocation&.converger_decides?

      variant.turn.variants
        .find_by(source: "fallback", origin_variant_id: variant.id) || variant
    end

    def recovery_candidates(after_id:, limit:)
      Task.where(type: ::Tasks::DelegationTask.sti_name,
        status: %w[queued running canceled skipped])
        .where(id: (after_id + 1)..).order(:id).limit(limit)
    end

    def converge(node:)
      call = node.run.tasks.find_by(node_key: node.node_key.delete_suffix(SUFFIX))
      child = call && target_for(call, node)
      if child
        Converge.call(child: child, call: call)
      elsif !node.terminal? && call
        return false if !call.terminal? && node.delegated_input_public_id.nil?

        node.run.with_lock do
          Settlement.call(node: node, call: call, text: "The delegated conversation was removed.",
            status: "failed", error_key: "delegation_abandoned")
        end
      else
        false
      end
    end

    # The caller holds the source Run while publishing its optional wait and
    # independent completion, so refusal rolls back that whole observation set.
    def prepare(call:, lifetime: "turn", wake: nil)
      existing = for_call(call)
      return existing if existing

      step = Tasks::Step::Delegation.new(key: key(call.node_key), lifetime: lifetime, wake: wake, detached: true)
      result = Tasks::Append.call_locked(Tasks::Append::Command.kernel(
        run: call.run, steps: [step],
        tip: KernelTool.branch_tip(call).with(detached: true, lifetime: lifetime, wake: wake || call.wake), origin: "kernel",
        expansion_parent: call
      ))
      return for_call(call) if result.applied? || result.outcome == :duplicate_task_key

      nil
    end

    # The caller holds the child's Conversation lock, then obtains the source
    # loop before touching an Input, task or body. This order also fences stop.
    def with_owner(input)
      delegation = for_input(input)
      if delegation
        delegation.run.with_lock { yield delegation }
      else
        yield nil
      end
    end

    def owner_stopped?(delegation)
      delegation && (delegation.terminal? || delegation.run.stopped? || !delegation.run.graph_mutable?)
    end

    # Branch cancel already owns the requester Run. Record its one canceled
    # outcome and release the finite wait; target cleanup remains with relay.
    def cancel(node:)
      call = node.run.tasks.find_by!(node_key: node.node_key.delete_suffix(SUFFIX))
      child = target_for(call, node)
      turn = child && original_turn(child, call)
      variant = answering_variant(turn)
      Settlement.call(node: node, call: call, child: child, status: "canceled",
        text: "The request was canceled.", error_key: CancelBranch::REASON,
        execution_identity: { "conversation_public_id" => child&.public_id, "input_public_id" => node.delegated_input_public_id,
          "turn_public_id" => turn&.public_id, "variant_public_id" => variant&.public_id,
          "run_public_id" => variant&.run&.public_id, "status" => "canceled" })
    end

    def launch_failed(call:, detail:)
      delegation = for_call(call)
      return unless delegation

      delegation.run.with_lock do
        Settlement.call(node: delegation, text: detail, status: "failed",
          error_key: "delegation_launch_failed", call: call)
      end
    end

    # A displayed edit or a later regeneration cannot substitute its bytes for
    # the original execution's report. Deletion waits until that report belongs
    # to the caller's task, including when the original is concealed.
    def owed_result?(turn)
      return false if turn.forked_from_turn_public_id || turn.relayed_at
      child = turn.conversation
      if child.schedule_id && child.scheduled_turn_public_id == turn.public_id
        parent = child.parent_conversation
        return parent.present? && !parent.tombstoned? && !parent.workspace.tombstoned?
      end

      delegation = for_dispatch(child, turn.sender_run_public_id, turn.sender_task_key)
      delegation.present? && !delegation.terminal?
    end

    def retained?(run)
      return true if Input.where(sender_run_public_id: run.public_id, source_released_at: nil).exists?
      return true if run.tasks.where(type: ::Tasks::DelegationTask.sti_name, status: %w[queued running]).exists?
      return true if !run.workspace.tombstoned? && ResultDelivery.pending?(run)

      unless run.standalone?
        turn = run.turn
        if owed_result?(turn)
          return true if [original_variant(turn)&.id, answering_variant(turn)&.id].include?(run.variant_id)
        end
      end

      run.tasks.where(type: ::Tasks::DelegationTask.sti_name,
        status: %w[canceled skipped]).any? do |node|
        call_key = node.node_key.delete_suffix(SUFFIX)
        call = run.tasks.find_by(node_key: call_key)
        child = call && target_for(call, node)
        next false unless child && node.delegated_input_public_id
        next true if child.inputs.exists?(public_id: node.delegated_input_public_id)

        variant = original_variant(original_turn(child, call))
        execution = variant&.run || variant&.model_invocation
        execution.present? && !execution.terminal?
      end
    end

    def retained_conversation?(conversation)
      live_completion = "INNER JOIN tasks ON tasks.delegated_input_public_id = %s " \
        "AND tasks.type = 'Tasks::DelegationTask' AND tasks.status IN ('queued', 'running')"
      return true if conversation.inputs.joins(format(live_completion, "inputs.public_id")).exists?
      return true if conversation.turns.where(forked_from_turn_public_id: nil)
        .joins(format(live_completion, "turns.input_public_id")).exists?

      if conversation.schedule_id && conversation.scheduled_turn_public_id
        turn = conversation.turns.find_by(public_id: conversation.scheduled_turn_public_id)
        return true if turn && owed_result?(turn)
      end

      call = conversation.spawn_node
      return false unless call

      delegation = for_call(call)
      delegation.present? && !delegation.terminal?
    end
  end
end
