module McpConnectionParameters
  private

    def create_connection_attributes
      attributes = params.expect(mcp_connection: [:name, :account_label, :endpoint_url, :auth_type, :bearer_token, :enabled]).to_h
      attributes["bearer_token"] = nil if attributes["bearer_token"].blank?
      attributes
    end

    def connection_update_fields
      params.expect(mcp_connection: [:lock_version, :name, :account_label, :enabled])
    end

    def connection_update_attributes(fields)
      fields.slice(:name, :account_label, :enabled).to_h
    end
end
