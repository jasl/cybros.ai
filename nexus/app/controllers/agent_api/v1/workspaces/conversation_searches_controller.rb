# @auth [MemberBearer]
class AgentAPI::V1::Workspaces::ConversationSearchesController < AgentAPI::V1::Workspaces::BaseController
  include AgentAPI::V1::WorkspaceScoped

  # @oas_include
  # @summary Read conversation searches
  # @tags Member, conversation searches
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
  # @response_ref (200) #/components/responses/AgentApiV1WorkspacesConversationSearchesShow
  def show
    options = ::Conversations::History::Parameters.search(
      params.permit(:query, :archived, :include_auxiliary, :answering_user_public_id, :limit, :after).to_h)
    render json: ::Conversations::History::Search.call(workspace: @workspace, user: acting_user, **options)
  rescue ::Conversations::History::Parameters::Invalid => error
    render_error(:parameter_invalid, error.message, status: :bad_request)
  end
end
