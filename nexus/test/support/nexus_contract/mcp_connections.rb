module Nexus
  module Contract
    class << self
      private

        def mcp_connections
          owner = Data.define(:active?).new(active?: true)
          tool = { "name" => "search", "description" => "Search documents", "input_schema" => { "type" => "object" } }
          connection = Data.define(:public_id, :name, :account_label, :owner, :endpoint_url,
            :auth_type, :authorization_status, :authorization_expires_at,
            :tools_catalog, :catalog_refreshed_at, :lock_version) do
            def enabled? = true
            def credential_configured? = true
          end.new(public_id: "01900000-0000-7000-8000-000000000091", name: "Work", account_label: "Company account",
            owner: owner, endpoint_url: "https://tools.example/mcp", auth_type: "bearer",
            authorization_status: "not_applicable", authorization_expires_at: nil,
            tools_catalog: [tool], catalog_refreshed_at: nil, lock_version: 3)
          oauth_connection = connection.with(auth_type: "oauth", authorization_status: "authorized",
            authorization_expires_at: Time.utc(2026, 10, 15, 12))
          authorization = Data.define(:connection, :authorization_url, :expires_at).new(
            connection: oauth_connection, authorization_url: "https://tools.example/authorize?state=fixture-state",
            expires_at: Time.utc(2026, 10, 15, 11, 10))
          node = CONTRACT_NODE_TYPE.new(id: 1, node_key: "mcp-search", task_kind: "tool_task", status: "needs_approval",
            on_failure: "halt", transcript_visibility: "visible", created_at: Time.utc(2026, 10, 14),
            tool_name: "search", tool_alias: "work_search", tool_input: { "query" => "invoice" },
            mcp_connection_public_id: connection.public_id, mcp_connection: connection,
            effect_profile: McpConnection::EFFECT_PROFILE)
          {
            "member_fixture" => { "mcp_connection" => AgentAPI::McpConnectionPresenter.basic(connection) },
            "owner_fixture" => { "mcp_connection" => API::McpConnectionPresenter.full(connection) },
            "oauth_owner_fixture" => { "mcp_connection" => API::McpConnectionPresenter.full(oauth_connection) },
            "unknown_authorization_status_fixture" => {
              "mcp_connection" => API::McpConnectionPresenter.full(oauth_connection.with(authorization_status: "future_status")),
            },
            "authorization_fixture" => { "authorization" => API::McpConnectionPresenter.authorization(authorization) },
            "approval_fixture" => detail_of(node),
          }
        end
    end
  end
end
