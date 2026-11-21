# @auth [PlatformBearer, BrowserSession]
class API::V1::McpConnections::CatalogRefreshesController < API::V1::McpConnections::BaseController
  rate_limit to: 10, within: 1.minute, by: -> { Current.user.public_id },
    with: -> { render_rate_limited(retry_after: 60) }

  # @oas_include
  # @summary Create catalog refreshes
  # @tags Platform, catalog refreshes
  # @parameter mcp_connection_id(path) [!String] Public UUIDv7. format: (uuid)
  # @request_body_ref #/components/requestBodies/ApiV1McpConnectionsCatalogRefreshesCreate
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  # @response_ref (200) #/components/responses/ApiV1McpConnectionsCatalogRefreshesCreate
  def create
    fields = params.expect(command: [:lock_version])
    render_connection_result(McpConnections::RefreshCatalog.call(connection: @connection,
      expected_lock_version: expected_version(fields)))
  end
end
