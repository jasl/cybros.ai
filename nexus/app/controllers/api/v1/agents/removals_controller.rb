class API::V1::Agents::RemovalsController < API::V1::Agents::BaseController
  def create
    outcome = @agent.remove
    RealtimeConnections::Disconnect.user_authority(@agent) if outcome == :removed
    render_agent_result(outcome)
  end
end
