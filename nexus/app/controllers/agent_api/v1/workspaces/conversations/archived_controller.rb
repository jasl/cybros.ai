# The recycle bin's own view — the working list's shape, opposite archived filter.
class AgentAPI::V1::Workspaces::Conversations::ArchivedController <
      AgentAPI::V1::Workspaces::Conversations::BaseController
  include AgentAPI::V1::WorkspaceScoped

  def index
    scope = Conversation.visible_to(acting_user, workspace: @workspace)
      .archived.where(parent_conversation_id: nil)
      .includes(:active_turn, :answering_user)
    page = keyset_page(scope, columns: { public_id: :uuid })

    render json: {
      conversations: page.records.map { |c| AgentAPI::ConversationPresenter.basic(c) },
      pagination: { next_after: page.next_after },
    }
  end
end
