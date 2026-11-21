# @auth [PlatformBearer, BrowserSession]
class API::V1::McpConnectionsController < API::V1::McpConnections::BaseController
  include AgentAPI::KeysetPagination

  skip_before_action :load_connection, only: [:index, :create]

  # @oas_include
  # @summary List mcp connections
  # @tags Platform, mcp connections
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  # @response_ref (200) #/components/responses/ApiV1McpConnectionsIndex
  def index
    page = keyset_page(Current.user.mcp_connections.includes(:owner), columns: { public_id: :uuid })
    render json: {
      mcp_connections: page.records.map { |connection| API::McpConnectionPresenter.full(connection) },
      pagination: { next_after: page.next_after },
    }
  end

  # @oas_include
  # @summary Read mcp connections
  # @tags Platform, mcp connections
  # @parameter id(path) [!String] Public UUIDv7. format: (uuid)
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  # @response_ref (200) #/components/responses/ApiV1McpConnectionsShow
  def show
    render json: { mcp_connection: API::McpConnectionPresenter.full(@connection) }
  end

  # @oas_include
  # @summary Create mcp connections
  # @tags Platform, mcp connections
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  # @response_ref (201) #/components/responses/ApiV1McpConnectionsCreate
  def create
    connection = Current.user.mcp_connections.build(create_connection_attributes)
    render_connection_result(connection.save_owned, status: :created)
  end

  # @oas_include
  # @summary Update mcp connections
  # @tags Platform, mcp connections
  # @parameter id(path) [!String] Public UUIDv7. format: (uuid)
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  # @response_ref (200) #/components/responses/ApiV1McpConnectionsUpdate
  def update
    fields = connection_update_fields
    render_connection_result(@connection.revise(attributes: connection_update_attributes(fields),
      expected_lock_version: expected_version(fields)))
  end
end
