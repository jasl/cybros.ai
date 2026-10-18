class API::V1::Agents::ConfigurationsController < API::V1::BaseController
  include API::V1::AgentReading

  def show
    agent = Users::AgentConfigurationSnapshot.read(
      scope: readable_agents.where(public_id: params[:agent_id]))
    render json: API::AgentPresenter.configuration(agent, measured_at: Time.current)
  end
end
