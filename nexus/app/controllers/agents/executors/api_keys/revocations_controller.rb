class Agents::Executors::APIKeys::RevocationsController < Agents::Executors::APIKeys::BaseController
  def create
    AccessTokens::Revoke.call(@api_key)
    redirect_to agent_executor_api_keys_path(@agent), notice: t("agents.api_keys.revoked")
  end
end
