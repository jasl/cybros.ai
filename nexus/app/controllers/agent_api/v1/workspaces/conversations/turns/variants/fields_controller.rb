# @auth [MemberBearer]
class AgentAPI::V1::Workspaces::Conversations::Turns::Variants::FieldsController <
      AgentAPI::V1::Workspaces::Conversations::BaseController
  include AgentAPI::V1::WorkspaceScoped

  # @oas_include
  # @summary Read fields
  # @tags Member, fields
  # @parameter conversation_public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @parameter field(path) [!String] Resource selector.
  # @parameter turn_public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @parameter variant_public_id(path) [!String] Public UUIDv7. format: (uuid)
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
  # @response_ref (200) #/components/responses/AgentApiV1WorkspacesConversationsTurnsVariantsFieldsShow
  def show
    conversation = find_listable_conversation(@workspace)
    options = ::Conversations::History::Parameters.field(params.permit(:field, :location, :after).to_h)
    result = ::Conversations::Reader.new(conversation, user: acting_user).field(
      turn_public_id: params.fetch(:turn_public_id), variant_public_id: params.fetch(:variant_public_id), **options)
    render json: result
  rescue ::Conversations::History::Parameters::Invalid => error
    render_error(:parameter_invalid, error.message, status: :bad_request)
  end
end
