class API::V1::Agents::APIKeys::RevocationsController < API::V1::Agents::APIKeys::BaseController
  def create
    AccessTokens::Revoke.call(@api_key)
    head :no_content
  end
end
