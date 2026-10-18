class API::V1::McpConnectionsController < API::V1::McpConnections::BaseController
  include AgentAPI::KeysetPagination

  skip_before_action :load_connection, only: [:index, :create]

  def index
    page = keyset_page(Current.user.mcp_connections.includes(:owner), columns: { public_id: :uuid })
    render json: {
      mcp_connections: page.records.map { |connection| API::McpConnectionPresenter.full(connection) },
      pagination: { next_after: page.next_after },
    }
  end

  def show
    render json: { mcp_connection: API::McpConnectionPresenter.full(@connection) }
  end

  def create
    connection = Current.user.mcp_connections.build(create_connection_attributes)
    render_connection_result(connection.save_owned, status: :created)
  end

  def update
    fields = connection_update_fields
    render_connection_result(@connection.revise(attributes: connection_update_attributes(fields),
      expected_lock_version: expected_version(fields)))
  end
end
