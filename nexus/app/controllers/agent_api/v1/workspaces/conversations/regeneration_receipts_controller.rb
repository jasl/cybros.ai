# The caller's retained acceptance, read before an application repeats any
# preparatory work. Reading it neither validates a new request nor runs work.
class AgentAPI::V1::Workspaces::Conversations::RegenerationReceiptsController <
      AgentAPI::V1::Workspaces::Conversations::BaseController
  include AgentAPI::V1::WorkspaceScoped

  def show
    conversation = find_listable_conversation(@workspace)
    receipt = ConversationCommandReceipt.unexpired.find_by!(
      host: conversation, acting_user: acting_user, operation: "regeneration",
      idempotency_key: params.require(:idempotency_key).to_s
    )
    render json: receipt.response_body
  end
end
