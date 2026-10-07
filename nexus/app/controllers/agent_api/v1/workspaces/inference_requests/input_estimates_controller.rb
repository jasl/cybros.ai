class AgentAPI::V1::Workspaces::InferenceRequests::InputEstimatesController <
  AgentAPI::V1::Workspaces::BaseController
  include AgentAPI::V1::WorkspaceScoped
  include AgentAPI::InferenceRequestInputParameters

  def create
    fields = estimate_fields
    result = InferenceRequests::InputEstimate.call(
      command: InferenceRequests::InputEstimate::Command.new(
        workspace: @workspace,
        creating_user: acting_user,
        workload: fields[:workload],
        submitted: submitted_inference_request_selection(fields),
        configuration: plain_inference_request_configuration(fields),
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
        { model: %i[model reasoning_effort reasoning_enabled], configuration: {}, upload_public_ids: [] },
      ])
    end
end
