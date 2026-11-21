# The creator's cancel as a named POST command: idempotent and total —
# cancelling terminal work returns the standing state. Whoever may create
# work in a workspace may stop it.
# @auth [MemberBearer]
class AgentAPI::V1::Workspaces::InferenceRequests::CancellationsController <
      AgentAPI::V1::Workspaces::BaseController
  include AgentAPI::V1::WorkspaceScoped

  # @oas_include
  # @summary Create cancellations
  # @tags Member, cancellations
  # @parameter inference_request_public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @parameter workspace_public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @request_body_ref #/components/requestBodies/AgentApiV1WorkspacesInferenceRequestsCancellationsCreate
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  # @response_ref (200) #/components/responses/AgentApiV1WorkspacesInferenceRequestsCancellationsCreate
  def create
    inference_request = InferenceRequest.where(workspace_id: @workspace.id).listable
      .find_by!(public_id: params.fetch(:inference_request_public_id))
    return unless authorize_writable(@workspace)

    InferenceRequests::Cancel.call(inference_request: inference_request)

    render json: { inference_request: AgentAPI::InferenceRequestPresenter.full(inference_request.reload) }
  end
end
