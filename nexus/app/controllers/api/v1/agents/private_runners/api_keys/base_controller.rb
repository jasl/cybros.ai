class API::V1::Agents::PrivateRunners::APIKeys::BaseController < API::V1::Agents::PrivateRunners::BaseController
  before_action :load_api_key

  private

    def load_api_key
      @api_key = @private_runner.api_keys.find_by!(public_id: params[:api_key_id])
    end
end
