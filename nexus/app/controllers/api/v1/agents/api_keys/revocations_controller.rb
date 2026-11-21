# @auth [PlatformBearer, BrowserSession]
class API::V1::Agents::APIKeys::RevocationsController < API::V1::Agents::APIKeys::BaseController
  # @oas_include
  # @summary Create revocations
  # @tags Platform, revocations
  # @parameter agent_id(path) [!String] Public UUIDv7. format: (uuid)
  # @parameter api_key_id(path) [!String] Public UUIDv7. format: (uuid)
  # @response_ref (204) #/components/responses/ApiV1AgentsApiKeysRevocationsCreate
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  def create
    AccessTokens::Revoke.call(@api_key)
    head :no_content
  end
end
