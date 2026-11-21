# @auth [MemberBearer]
class AgentAPI::V1::McpConnectionsController < AgentAPI::V1::BaseController
  serves_plane :member
  include AgentAPI::KeysetPagination
  include AgentAPI::V1::Profiles::NamedAgents

  before_action :require_agent

  # @oas_include
  # @summary List mcp connections
  # @tags Member, mcp connections
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  # @response_ref (200) #/components/responses/AgentApiV1McpConnectionsIndex
  def index
    page = keyset_page(authorized_connections, columns: { public_id: :uuid })
    render json: {
      mcp_connections: page.records.map { |connection| AgentAPI::McpConnectionPresenter.basic(connection) },
      pagination: { next_after: page.next_after },
    }
  end

  # @oas_include
  # @summary Read mcp connections
  # @tags Member, mcp connections
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
  # @response_ref (200) #/components/responses/AgentApiV1McpConnectionsShow
  def show
    connection = authorized_connections.find_by!(public_id: params[:id])
    render json: { mcp_connection: AgentAPI::McpConnectionPresenter.basic(connection) }
  end

  private

    def authorized_connections
      McpConnection.for_agent(selected_agent).includes(:owner)
    end
end
