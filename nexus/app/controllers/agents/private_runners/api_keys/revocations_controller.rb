class Agents::PrivateRunners::APIKeys::RevocationsController < Agents::PrivateRunners::APIKeys::BaseController
  def create
    AccessTokens::Revoke.call(@api_key)
    redirect_to agent_private_runner_api_keys_path(@agent, @private_runner), notice: t("agents.api_keys.revoked")
  end
end
