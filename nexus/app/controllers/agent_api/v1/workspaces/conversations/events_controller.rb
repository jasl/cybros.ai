# The conversation's feed: the one events body over the listable conversation.
class AgentAPI::V1::Workspaces::Conversations::EventsController <
      AgentAPI::V1::Workspaces::EventsController
  include AgentAPI::V1::WorkspaceScoped

  private

    def host = find_listable_conversation(@workspace)
end
