# The creator's cancel as a named POST command: idempotent and total —
# cancelling terminal work returns the standing state. Whoever may create
# work in a workspace may stop it.
class AgentAPI::V1::Workspaces::InferenceRequests::CancellationsController <
      AgentAPI::V1::Workspaces::BaseController
  include AgentAPI::V1::WorkspaceScoped

  def create
    inference_request = InferenceRequest.where(workspace_id: @workspace.id).listable
      .find_by!(public_id: params.fetch(:inference_request_public_id))
    return unless authorize_writable(@workspace)

    InferenceRequests::Cancel.call(inference_request: inference_request)

    render json: { inference_request: AgentAPI::InferenceRequestPresenter.full(inference_request.reload) }
  end
end
