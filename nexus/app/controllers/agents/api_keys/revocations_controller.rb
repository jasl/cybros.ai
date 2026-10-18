class Agents::APIKeys::RevocationsController < Agents::APIKeys::BaseController
  def create
    AccessTokens::Revoke.call(@api_key)
    redirect_to agent_api_keys_path(@agent), notice: t("agents.api_keys.revoked")
  end
end
