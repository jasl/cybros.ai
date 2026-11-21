# The caller's retained acceptance, read before an application repeats any
# preparatory work. Reading it neither validates a new request nor runs work.
# @auth [MemberBearer]
class AgentAPI::V1::Workspaces::Conversations::RegenerationReceiptsController <
      AgentAPI::V1::Workspaces::Conversations::BaseController
  include AgentAPI::V1::WorkspaceScoped

  # @oas_include
  # @summary Read regeneration receipts
  # @tags Member, regeneration receipts
  # @parameter conversation_public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @parameter workspace_public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  # @response_ref (200) #/components/responses/AgentApiV1WorkspacesConversationsRegenerationReceiptsShow
  def show
    conversation = find_listable_conversation(@workspace)
    receipt = ConversationCommandReceipt.unexpired.find_by!(
      host: conversation, acting_user: acting_user, operation: "regeneration",
      idempotency_key: params.require(:idempotency_key).to_s
    )
    render json: receipt.response_body
  end
end
