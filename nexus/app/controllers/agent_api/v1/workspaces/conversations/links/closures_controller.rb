class AgentAPI::V1::Workspaces::Conversations::Links::ClosuresController <
      AgentAPI::V1::Workspaces::Conversations::BaseController
  include AgentAPI::V1::WorkspaceScoped

  def create
    conversation = find_listable_conversation(@workspace)
    return unless authorize_writable(conversation)
    link = ConversationLink.for_conversation(conversation).find_by!(public_id: params.fetch(:link_public_id))
    link.close(acting_user: acting_user)
    render json: { link: ::Conversations::LinkProjection.call(link.reload, conversation: conversation) }
  end
end
