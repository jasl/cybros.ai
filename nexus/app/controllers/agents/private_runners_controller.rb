class Agents::PrivateRunnersController < Agents::BaseController
  before_action :load_independent_agent

  def index
    @runners_pagy, @private_runners = pagy(:offset,
      @agent.private_runners.where(manager: Current.user).order_by_recency, limit: 10)
  end

  def new
    @private_runner = @agent.build_private_runner(display_name: "")
  end

  def create
    fields = params.expect(private_runner: [:display_name])
    @private_runner = @agent.build_private_runner(display_name: fields[:display_name].to_s)
    if @private_runner.save
      redirect_to agent_private_runner_api_keys_path(@agent, @private_runner), notice: t("agents.private_runners.created")
    else
      render :new, status: :unprocessable_entity
    end
  end

  private

    def load_independent_agent
      @agent = independent_agent
    end
end
