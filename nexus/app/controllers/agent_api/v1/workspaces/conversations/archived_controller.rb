# The recycle bin's own view — the working list's shape, opposite archived filter.
class AgentAPI::V1::Workspaces::Conversations::ArchivedController <
      AgentAPI::V1::Workspaces::Conversations::BaseController
  include AgentAPI::ConversationListing
  include AgentAPI::V1::WorkspaceScoped

  def index
    scope = Conversation.visible_to(acting_user, workspace: @workspace)
      .archived.where(parent_conversation_id: nil)
      .includes(:active_turn, :answering_user)
    render_conversation_list(scope)
  end
end
