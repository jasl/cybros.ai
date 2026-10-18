module API
  class McpConnectionPresenter < AgentAPI::McpConnectionPresenter
    def self.full(connection)
      basic(connection).merge(
        endpoint_url: connection.endpoint_url,
        auth_type: connection.auth_type,
        credential_configured: connection.credential_configured?,
        authorization_status: connection.authorization_status,
        authorization_expires_at: connection.authorization_expires_at,
        catalog_refreshed_at: connection.catalog_refreshed_at,
        lock_version: connection.lock_version,
      )
    end

    def self.authorization(result)
      {
        connection_public_id: result.connection.public_id,
        authorization_url: result.authorization_url,
        expires_at: result.expires_at,
      }
    end
  end
end
