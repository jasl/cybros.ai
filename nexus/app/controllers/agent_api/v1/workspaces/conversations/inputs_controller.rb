# The conversation's door: the one inputs body over the listable conversation.
class AgentAPI::V1::Workspaces::Conversations::InputsController <
      AgentAPI::V1::Workspaces::InputsController
  include AgentAPI::V1::WorkspaceScoped

  private

    def host = find_listable_conversation(@workspace)
end
