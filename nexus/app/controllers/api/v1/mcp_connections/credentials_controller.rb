# @auth [PlatformBearer, BrowserSession]
class API::V1::McpConnections::CredentialsController < API::V1::McpConnections::BaseController
  # @oas_include
  # @summary Update credentials
  # @tags Platform, credentials
  # @parameter mcp_connection_id(path) [!String] Public UUIDv7. format: (uuid)
  # @request_body_ref #/components/requestBodies/ApiV1McpConnectionsCredentialsUpdate
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  # @response_ref (200) #/components/responses/ApiV1McpConnectionsCredentialsUpdate
  def update
    fields = params.expect(credential: [:lock_version, :bearer_token])
    render_connection_result(@connection.set_credential(bearer_token: fields.fetch(:bearer_token).to_s,
      expected_lock_version: expected_version(fields)))
  end

  # @oas_include
  # @summary Destroy credentials
  # @tags Platform, credentials
  # @parameter mcp_connection_id(path) [!String] Public UUIDv7. format: (uuid)
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  # @response_ref (200) #/components/responses/ApiV1McpConnectionsCredentialsDestroy
  def destroy
    fields = params.expect(command: [:lock_version])
    render_connection_result(@connection.set_credential(bearer_token: nil,
      expected_lock_version: expected_version(fields)))
  end
end
