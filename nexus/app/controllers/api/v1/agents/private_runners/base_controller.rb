class API::V1::Agents::PrivateRunners::BaseController < API::V1::Agents::BaseController
  before_action :load_private_runner

  private

    def load_private_runner
      @private_runner = @agent.private_runners.where(manager: Current.user)
        .find_by!(public_id: params[:private_runner_id])
    end
end
