# @auth [PlatformBearer, BrowserSession]
class API::V1::Agents::ConfigurationsController < API::V1::BaseController
  include API::V1::AgentReading

  # @oas_include
  # @summary Read configurations
  # @tags Platform, configurations
  # @parameter agent_id(path) [!String] Public UUIDv7. format: (uuid)
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  # @response_ref (200) #/components/responses/ApiV1AgentsConfigurationsShow
  def show
    agent = Users::AgentConfigurationSnapshot.read(
      scope: readable_agents.where(public_id: params[:agent_id]))
    render json: API::AgentPresenter.configuration(agent, measured_at: Time.current)
  end
end
