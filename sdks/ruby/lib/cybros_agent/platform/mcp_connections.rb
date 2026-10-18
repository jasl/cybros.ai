module CybrosAgent
  module Platform
    McpConnection = Data.define(:public_id, :name, :account_label, :endpoint_url, :auth_type,
      :enabled, :available, :credential_configured, :authorization_status, :authorization_expires_at,
      :tools, :catalog_refreshed_at, :lock_version)
    McpAuthorization = Data.define(:connection_public_id, :authorization_url, :expires_at)

    # Human-owned service accounts. Secrets are write-only; changing the service
    # or external account means creating another connection with another identity.
    class McpConnections
      include Api::WorkspaceProjections
      include Api::Fields

      PATH = "/api/v1/mcp_connections".freeze
      SHAPES = {
        McpConnection => { public_id: :string, name: :string, account_label: :nullable_string,
          endpoint_url: :string, auth_type: :string, enabled: :boolean, available: :boolean, credential_configured: :boolean,
          authorization_status: :string, authorization_expires_at: :nullable_string,
          tools: :json_array, catalog_refreshed_at: :nullable_string, lock_version: :integer },
        McpAuthorization => { connection_public_id: :string, authorization_url: :string, expires_at: :string },
      }.freeze

      def initialize(dispatch:)
        @dispatch = dispatch
      end

      def list(after: nil, limit: nil, order: nil)
        page(McpConnection, @dispatch.call(PATH, params: query(after:, limit:, order:)), "mcp_connections")
      end

      def fetch(public_id)
        shape(McpConnection, @dispatch.call(path(public_id)), "mcp_connection")
      end

      def create(name:, endpoint_url:, auth_type:, account_label: omitted_field, bearer_token: omitted_field, enabled: omitted_field)
        body = fields(name:, endpoint_url:, auth_type:, account_label:, bearer_token:, enabled:)
        shape(McpConnection, @dispatch.call(PATH, method: :post, body: { "mcp_connection" => body }, success: [201]), "mcp_connection")
      end

      def update(public_id, lock_version:, name: omitted_field, account_label: omitted_field, enabled: omitted_field)
        body = fields(lock_version:, name:, account_label:, enabled:)
        shape(McpConnection, @dispatch.call(path(public_id), method: :patch, body: { "mcp_connection" => body }), "mcp_connection")
      end

      def refresh_catalog(public_id, lock_version:)
        command(public_id, "catalog_refresh", :post, "command", { "lock_version" => lock_version })
      end

      def start_authorization(public_id, lock_version:)
        shape(McpAuthorization, @dispatch.call("#{path(public_id)}/authorization", method: :post,
          body: { "command" => { "lock_version" => lock_version } }), "authorization")
      end

      def rotate_credential(public_id, lock_version:, bearer_token:)
        command(public_id, "credential", :put, "credential", { "lock_version" => lock_version, "bearer_token" => bearer_token })
      end

      def clear_credential(public_id, lock_version:)
        command(public_id, "credential", :delete, "command", { "lock_version" => lock_version })
      end

      private

        def path(public_id)
          "#{PATH}/#{path_segment(public_id, "public_id")}"
        end

        def command(public_id, resource, method, root, body)
          shape(McpConnection, @dispatch.call("#{path(public_id)}/#{resource}", method: method, body: { root => body }), "mcp_connection")
        end
    end
  end
end
