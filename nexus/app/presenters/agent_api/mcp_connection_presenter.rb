module AgentAPI
  class McpConnectionPresenter
    def self.basic(connection)
      {
        public_id: connection.public_id,
        name: connection.name,
        account_label: connection.account_label,
        enabled: connection.enabled?,
        available: connection.enabled? && connection.owner.active? && connection.credential_configured?,
        tools: connection.tools_catalog,
      }
    end
  end
end
