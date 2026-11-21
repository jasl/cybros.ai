# @auth [PlatformBearer, BrowserSession]
class API::V1::Agents::ConnectionRevocationsController < API::V1::Agents::BaseController
  # @oas_include
  # @summary Create connection revocations
  # @tags Platform, connection revocations
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
  # @response_ref (200) #/components/responses/ApiV1AgentsConnectionRevocationsCreate
  def create
    outcome = @agent.revoke_connection
    RealtimeConnections::Disconnect.user_authority(@agent)
    render_agent_result(outcome)
  end
end
