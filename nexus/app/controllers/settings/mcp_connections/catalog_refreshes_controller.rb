class Settings::McpConnections::CatalogRefreshesController < Settings::McpConnections::BaseController
  rate_limit to: 10, within: 1.minute, by: -> { Current.user.public_id },
    with: -> { redirect_to settings_mcp_connection_path(@connection), alert: t("mcp_connections.rate_limited") }

  def create
    fields = params.expect(command: [:lock_version])
    result = McpConnections::RefreshCatalog.call(connection: @connection,
      expected_lock_version: expected_version(fields))
    if result.success?
      redirect_to settings_mcp_connection_path(@connection), notice: t("mcp_connections.refreshed")
    else
      redirect_to settings_mcp_connection_path(@connection), alert: t("mcp_connections.errors.#{result.outcome}")
    end
  end
end
