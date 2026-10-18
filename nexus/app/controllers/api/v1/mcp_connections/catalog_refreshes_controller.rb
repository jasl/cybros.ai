class API::V1::McpConnections::CatalogRefreshesController < API::V1::McpConnections::BaseController
  rate_limit to: 10, within: 1.minute, by: -> { Current.user.public_id },
    with: -> { render_rate_limited(retry_after: 60) }

  def create
    fields = params.expect(command: [:lock_version])
    render_connection_result(McpConnections::RefreshCatalog.call(connection: @connection,
      expected_lock_version: expected_version(fields)))
  end
end
