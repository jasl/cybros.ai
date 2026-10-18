class Agents::Executors::APIKeys::BaseController < Agents::Executors::BaseController
  before_action :load_api_key

  private

    def load_api_key
      @agent = independent_agent
      @api_key = @agent.executor_api_keys.find_by!(public_id: params[:api_key_id])
    end
end
