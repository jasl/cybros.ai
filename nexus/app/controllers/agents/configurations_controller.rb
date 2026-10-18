class Agents::ConfigurationsController < Agents::BaseController
  def show
    @agent = Users::AgentConfigurationSnapshot.read(
      scope: Current.user.stewarded_agents.where(public_id: params[:agent_public_id]))
    @declaration = API::AgentPresenter.configuration(@agent, measured_at: Time.current)
  end
end
