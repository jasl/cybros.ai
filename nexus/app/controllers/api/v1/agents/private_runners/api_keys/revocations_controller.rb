class API::V1::Agents::PrivateRunners::APIKeys::RevocationsController < API::V1::Agents::PrivateRunners::APIKeys::BaseController
  def create
    AccessTokens::Revoke.call(@api_key)
    head :no_content
  end
end
