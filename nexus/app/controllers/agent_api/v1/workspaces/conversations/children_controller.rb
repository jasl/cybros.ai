# The follower listing: subagent conversations surface HERE, through
# their parent — never in the top-level lists.
class AgentAPI::V1::Workspaces::Conversations::ChildrenController <
      AgentAPI::V1::Workspaces::Conversations::BaseController
  include AgentAPI::ConversationListing
  include AgentAPI::V1::WorkspaceScoped

  def index
    conversation = find_listable_conversation(@workspace)
    scope = Conversation.visible_to(acting_user, workspace: @workspace)
      .where(parent_conversation_id: conversation.id)
      .includes(:active_turn, :answering_user, :spawn_node)
    render_conversation_list(scope)
  end
end
