class Agents::PrivateRunners::BaseController < Agents::BaseController
  before_action :load_private_runner

  private

    def load_private_runner
      @agent = independent_agent
      @private_runner = @agent.private_runners.where(manager: Current.user)
        .find_by!(public_id: params[:private_runner_public_id])
    end
end
