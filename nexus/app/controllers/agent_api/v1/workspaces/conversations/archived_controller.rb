# The recycle bin's own view — the working list's shape, opposite archived filter.
class AgentAPI::V1::Workspaces::Conversations::ArchivedController <
      AgentAPI::V1::Workspaces::Conversations::BaseController
  include AgentAPI::ConversationListing
  include AgentAPI::V1::WorkspaceScoped

  def index
    scope = Conversation.visible_to(acting_user, workspace: @workspace)
      .archived.lifecycle_roots
      .includes(:active_turn, :answering_user, :workspace)
    render_conversation_list(filter_conversation_answerer(scope))
  end
end
