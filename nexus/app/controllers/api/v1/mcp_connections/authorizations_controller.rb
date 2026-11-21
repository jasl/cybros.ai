# @auth [PlatformBearer, BrowserSession]
class API::V1::McpConnections::AuthorizationsController < API::V1::McpConnections::BaseController
  rate_limit to: 10, within: 1.minute, by: -> { Current.user.public_id },
    with: -> { render_rate_limited(retry_after: 60) }

  # @oas_include
  # @summary Create authorizations
  # @tags Platform, authorizations
  # @parameter mcp_connection_id(path) [!String] Public UUIDv7. format: (uuid)
  # @request_body_ref #/components/requestBodies/ApiV1McpConnectionsAuthorizationsCreate
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  # @response_ref (200) #/components/responses/ApiV1McpConnectionsAuthorizationsCreate
  def create
    no_store
    fields = params.expect(command: [:lock_version])
    result = McpConnections::OAuth::Start.call(connection: @connection,
      expected_lock_version: expected_version(fields),
      redirect_uri: settings_mcp_connection_authorization_callback_url(@connection))
    if result.success?
      render json: { authorization: API::McpConnectionPresenter.authorization(result) }
    else
      render_refusal(result.outcome)
    end
  end
end
