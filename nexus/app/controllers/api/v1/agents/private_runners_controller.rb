class API::V1::Agents::PrivateRunnersController < API::V1::Agents::BaseController
  def index
    page = keyset_page(@agent.private_runners.where(manager: Current.user).includes(:assignment_agent), columns: { public_id: :uuid })
    render json: { private_runners: page.records.map { |runner| API::PrivateRunnerPresenter.basic(runner) },
      pagination: { next_after: page.next_after } }
  end

  def show
    runner = @agent.private_runners.where(manager: Current.user).find_by!(public_id: params[:id])
    render json: { private_runner: API::PrivateRunnerPresenter.basic(runner) }
  end

  def create
    fields = params.expect(private_runner: [:display_name])
    runner = @agent.build_private_runner(display_name: fields[:display_name].to_s)
    if runner.save
      render json: { private_runner: API::PrivateRunnerPresenter.basic(runner) }, status: :created
    else
      render_error(:validation_failed, runner.errors.full_messages.to_sentence, status: :unprocessable_entity)
    end
  end
end
