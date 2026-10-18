class API::V1::Agents::ConnectionRevocationsController < API::V1::Agents::BaseController
  def create
    outcome = @agent.revoke_connection
    RealtimeConnections::Disconnect.user_authority(@agent)
    render_agent_result(outcome)
  end
end
