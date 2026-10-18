class API::V1::Agents::RestorationsController < API::V1::Agents::BaseController
  def create
    render_agent_result(@agent.restore)
  end
end
