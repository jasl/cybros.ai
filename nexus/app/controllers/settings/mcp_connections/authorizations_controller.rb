class Settings::McpConnections::AuthorizationsController < Settings::McpConnections::BaseController
  rate_limit to: 10, within: 1.minute, by: -> { Current.user.public_id },
    with: -> { redirect_to settings_mcp_connection_path(@connection), alert: t("mcp_connections.authorization_rate_limited") }

  def create
    no_store
    response.headers["Referrer-Policy"] = "no-referrer"
    fields = params.expect(command: [:lock_version])
    result = McpConnections::OAuth::Start.call(connection: @connection,
      expected_lock_version: expected_version(fields),
      redirect_uri: settings_mcp_connection_authorization_callback_url(@connection))
    if result.success?
      redirect_to result.authorization_url, allow_other_host: true, status: :see_other
    else
      redirect_to settings_mcp_connection_path(@connection), alert: t("mcp_connections.errors.#{result.outcome}")
    end
  end
end
