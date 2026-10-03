class AgentAPI::V1::Workspaces::OneShots::InputEstimatesController <
  AgentAPI::V1::Workspaces::BaseController
  include AgentAPI::V1::WorkspaceScoped
  include AgentAPI::OneShotInputParameters

  def create
    fields = estimate_fields
    result = OneShots::InputEstimate.call(
      command: OneShots::InputEstimate::Command.new(
        workspace: @workspace,
        creating_user: acting_user,
        workload: fields[:workload],
        submitted: submitted_one_shot_selection(fields),
        configuration: plain_one_shot_configuration(fields),
        input: raw_one_shot_input(:input_estimate),
        upload_public_ids: Array(fields[:upload_public_ids])
      ),
      port: ModelSelection::Resolver.new
    )

    if result.estimated?
      render json: {
        input_estimate: AgentAPI::OneShotInputEstimatePresenter.full(result.estimate),
      }
    else
      render_error(result.refusal.to_s, "Refused: #{result.refusal}", status: :unprocessable_entity)
    end
  end

  private

    def estimate_fields
      params.expect(input_estimate: [
        :workload,
        { model: %i[model reasoning_effort], configuration: {}, upload_public_ids: [] },
      ])
    end
end
