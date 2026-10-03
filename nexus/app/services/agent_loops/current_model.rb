module AgentLoops
  # A loop's current main-line selection lives on its spine tail. The variant
  # keeps the initial choice; neither a
  # parallel branch nor an older invocation changes the current selection.
  module CurrentModel
    module_function

    def for(agent_loop, nodes: nil)
      agent_loop.spine_tail(nodes: nodes) || agent_loop.conversation_turn_variant
    end

    def for_variant(variant)
      agent_loop = variant.agent_loop if variant.source == "agent_loop"
      agent_loop ? self.for(agent_loop) : variant
    end

    # A page already has its variants. Return each loop's tail, or nil when
    # it has no model spine, so the page can use that variant's initial choice.
    def for_loops(loops)
      nodes = AgentLoopNodes::ModelTask.where(agent_loop_id: loops.map(&:id))
        .where("continuation_source IS DISTINCT FROM ?", AgentLoopNodes::ModelTask::BRANCH)
        .select(:id, :type, :agent_loop_id, :node_key, :continuation_source,
          :input_from_node_keys, :provider_id, :model_ref, :reasoning_effort)
        .group_by(&:agent_loop_id)
      loops.to_h { |agent_loop| [agent_loop.id, agent_loop.spine_tail(nodes: nodes.fetch(agent_loop.id, []))] }
    end
  end
end
