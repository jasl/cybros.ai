# @auth [MemberBearer]
class AgentAPI::V1::Workspaces::InferenceRequests::InputEstimatesController <
  AgentAPI::V1::Workspaces::BaseController
  include AgentAPI::V1::WorkspaceScoped
  include AgentAPI::InferenceRequestInputParameters

  # @oas_include
  # @summary Create input estimates
  # @tags Member, input estimates
  # @parameter workspace_public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @request_body_ref #/components/requestBodies/AgentApiV1WorkspacesInferenceRequestsInputEstimatesCreate
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  # @response_ref (200) #/components/responses/AgentApiV1WorkspacesInferenceRequestsInputEstimatesCreate
  def create
    fields = estimate_fields
    result = InferenceRequests::InputEstimate.call(
      command: InferenceRequests::InputEstimate::Command.new(
        workspace: @workspace,
        creating_user: acting_user,
        workload: fields[:workload],
        submitted: submitted_inference_request_selection(fields),
        configuration: plain_inference_request_configuration(fields),
        model_selection: fields[:model_selection]&.to_h, fallback_models: fields[:fallback_models],
        input: raw_inference_request_input(:input_estimate),
        upload_public_ids: Array(fields[:upload_public_ids])
      ),
      port: ModelSelection::Resolver.new
    )

    if result.estimated?
      render json: {
        input_estimate: AgentAPI::InferenceRequestInputEstimatePresenter.full(result.estimate),
      }
    else
      render_error(result.refusal.to_s, "Refused: #{result.refusal}", status: :unprocessable_entity)
    end
  end

  private

    def estimate_fields
      params.expect(input_estimate: [
        :workload,
        { model: %i[model reasoning_effort reasoning_enabled], configuration: {}, upload_public_ids: [], model_selection: {}, fallback_models: [] },
      ])
    end
end
