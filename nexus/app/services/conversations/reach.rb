module Conversations
  # The execution's address scope only narrows ordinary member visibility.
  # A child starts its own subtree; no scope points back at an older root.
  module Reach
    module_function

    def of(node)
      node.run.conversation_reach
    end

    def visible(conversation:, workspace:, user:, reach:)
      scope = Conversation.visible_to(user, workspace: workspace)
      return scope if reach == "workspace"
      return scope.none if conversation.nil?

      scope.merge(SubagentTree.members(conversation))
    end
  end
end
