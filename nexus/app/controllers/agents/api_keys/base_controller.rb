class Agents::APIKeys::BaseController < Agents::BaseController
  before_action :load_api_key

  private

    def load_api_key
      @agent = independent_agent
      @api_key = @agent.api_keys.find_by!(public_id: params[:api_key_id])
    end
end
