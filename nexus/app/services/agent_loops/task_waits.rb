module AgentLoops
  # A finite observation of existing work. The wait owns no execution: expiry,
  # cancellation and repeated observation never stop or relaunch its target.
  module TaskWaits
    module_function

    def target(agent_loop:, task_key:, loop_public_id: nil)
      source = if loop_public_id.nil? || loop_public_id == agent_loop.public_id
        agent_loop
      elsif !agent_loop.standalone?
        AgentLoop.listable.joins(conversation_turn_variant: :conversation_turn)
          .where(conversation_turns: { conversation_id: agent_loop.conversation.id })
          .find_by(public_id: loop_public_id)
      end
      source&.agent_loop_nodes&.find_by(node_key: task_key)
    end

    # Append is the boundary that resolves the caller's optional loop selector.
    # Weak public references keep historical collection independent of a wait.
    def bind(agent_loop:, attributes:, expansion_parent: nil)
      return attributes unless attributes["awaited_task_key"]

      observed = target(agent_loop: agent_loop, task_key: attributes.fetch("awaited_task_key"),
        loop_public_id: attributes["awaited_agent_loop_public_id"])
      raise Tasks::Append::Refused, :wait_target_not_found if observed.nil?
      if expansion_parent && (observed.id == expansion_parent.id ||
          ExpansionOwnership.descendants(observed).any? { |node| node.id == expansion_parent.id })
        raise Tasks::Append::Refused, :wait_cycle
      end

      attributes.merge("awaited_agent_loop_public_id" => observed.agent_loop.public_id)
    end

    # Called under the waiting loop's lock by its ordinary scheduler. Reading
    # another execution acquires no second loop lock and never mutates it.
    def reconcile(agent_loop)
      agent_loop.agent_loop_nodes.where(status: "dispatched").where.not(awaited_task_key: nil)
        .each { |node| settle(node) }
    end

    def settle(node)
      observed = target(agent_loop: node.agent_loop, task_key: node.awaited_task_key,
        loop_public_id: node.awaited_agent_loop_public_id)
      result = observed ? Observe.call(observed) : Observe.missing
      return false if result.nil?

      settled = Parks::Settle.call(node: node, trusted: true, outcome: "completed",
        content: result.text, structured_content: result.data, is_error: result.error,
        title: "wait")
      if !settled.moved? && !node.terminal?
        FailNode.call(agent_loop: node.agent_loop, node: node, error_key: "wait_result_unstorable",
          error_detail: settled.outcome.to_s, worklist: [])
      end
      true
    end

    # Settlement hints only accelerate the existing schedule sweep. The index
    # contains live observers, so ordinary tasks with no observers add no jobs.
    def wake_observers(agent_loop)
      ids = AgentLoopNode.where(awaited_agent_loop_public_id: agent_loop.public_id,
        status: "dispatched").where.not(awaited_task_key: nil).distinct.pluck(:agent_loop_id)
      ids.each { |id| ScheduleJob.perform_later(id) }
    end
  end
end
