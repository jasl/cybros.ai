# @auth [PlatformBearer, BrowserSession]
class API::V1::Agents::RestorationsController < API::V1::Agents::BaseController
  # @oas_include
  # @summary Create restorations
  # @tags Platform, restorations
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
  # @response_ref (200) #/components/responses/ApiV1AgentsRestorationsCreate
  def create
    render_agent_result(@agent.restore)
  end
end
