# @auth [MemberBearer]
class AgentAPI::V1::Workspaces::Conversations::HistoriesController <
      AgentAPI::V1::Workspaces::Conversations::BaseController
  include AgentAPI::V1::WorkspaceScoped

  # @oas_include
  # @summary Read histories
  # @tags Member, histories
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
  # @response_ref (200) #/components/responses/AgentApiV1WorkspacesConversationsHistoriesShow
  def show
    conversation = find_listable_conversation(@workspace)
    options = ::Conversations::History::Parameters.read(params.to_unsafe_h)
    render json: ::Conversations::History::Read.call(conversation: conversation, user: acting_user, **options)
  rescue ::Conversations::History::Parameters::Invalid => error
    render_error(:parameter_invalid, error.message, status: :bad_request)
  end
end
