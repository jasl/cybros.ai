class AgentAPI::V1::McpConnectionsController < AgentAPI::V1::BaseController
  serves_plane :member
  include AgentAPI::KeysetPagination
  include AgentAPI::V1::Profiles::NamedAgents

  before_action :require_agent

  def index
    page = keyset_page(authorized_connections, columns: { public_id: :uuid })
    render json: {
      mcp_connections: page.records.map { |connection| AgentAPI::McpConnectionPresenter.basic(connection) },
      pagination: { next_after: page.next_after },
    }
  end

  def show
    connection = authorized_connections.find_by!(public_id: params[:id])
    render json: { mcp_connection: AgentAPI::McpConnectionPresenter.basic(connection) }
  end

  private

    def authorized_connections
      McpConnection.for_agent(selected_agent).includes(:owner)
    end
end
