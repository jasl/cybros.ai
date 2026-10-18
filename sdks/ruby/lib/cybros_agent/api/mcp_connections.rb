module CybrosAgent
  module Api
    McpConnection = Data.define(:public_id, :name, :account_label, :enabled, :available, :tools)

    # The selected Agent's current human steward owns this saved directory.
    # Reading a connection never performs remote discovery or reveals credentials.
    class McpConnections
      include WorkspaceProjections
      include Fields

      PATH = "/agent_api/v1/mcp_connections".freeze
      SHAPES = {
        McpConnection => { public_id: :string, name: :string, account_label: :nullable_string,
          enabled: :boolean, available: :boolean, tools: :json_array },
      }.freeze

      def initialize(dispatch:)
        @dispatch = dispatch
      end

      def list(after: nil, limit: nil, order: nil, agent_public_id: nil)
        page(McpConnection, @dispatch.call(PATH, params: query(after:, limit:, order:, agent_public_id:)), "mcp_connections")
      end

      def fetch(public_id, agent_public_id: nil)
        shape(McpConnection, @dispatch.call("#{PATH}/#{path_segment(public_id, "public_id")}", params: query(agent_public_id:)), "mcp_connection")
      end
    end
  end
end
