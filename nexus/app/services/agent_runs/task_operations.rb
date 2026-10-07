module AgentRuns
  # Accepted operations keep child work behind the executing tool's final
  # result unless an explicit background operation releases that work.
  module TaskOperations
    module_function

    def attached_children(node)
      descendants = ExpansionOwnership.descendants(node)
      owners = ExpansionOwnership.operation_owners(node.agent_run, descendants.map(&:node_key))
      descendants.select { |child| owners.fetch(child.node_key, []).include?(node.node_key) }
    end

    # Failure closes attached work. Released work retains its ordinary
    # lifetime, delivery and source Stop ownership.
    def cancel_attached_locked(node)
      CancelBranch.cancel_locked(agent_run: node.agent_run, targets: attached_children(node))
    end
  end
end
