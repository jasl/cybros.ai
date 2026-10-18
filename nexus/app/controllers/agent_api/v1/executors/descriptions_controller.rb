# GET /agent_api/v1/executor — the executor plane's self-description: the
# process proves its transport credential and learns which delivery address it
# is without a member-plane call. The credential names the address. The member
# plane's discovery of executors OTHERS may address is the plural
# `AgentAPI::V1::ExecutorsController`.
class AgentAPI::V1::Executors::DescriptionsController < AgentAPI::V1::Executors::BaseController
  def show
    render json: AgentAPI::ExecutorPresenter.description(
      current_executor, measured_at: Time.current, live_server_ids: NexusServer.live_ids
    )
  end
end
