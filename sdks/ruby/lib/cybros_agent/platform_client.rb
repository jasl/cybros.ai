module CybrosAgent
  # The Human Platform plane. Nexus checks the current role for every admin
  # command; this client keeps its resource surface separate from agent work.
  class PlatformClient < Api::BaseClient
    include Api::WorkspaceProjections

    def session
      Platform::SessionContext.new(dispatch: dispatch)
    end

    def agents
      Platform::Agents.new(dispatch: dispatch)
    end

    def runners
      Platform::ManagedRunners.new(dispatch: dispatch)
    end

    def budgets(user_public_id)
      Platform::Budgets.new(dispatch: dispatch,
        path: "/api/v1/admin/users/#{path_segment(user_public_id, "user_public_id")}/budgets")
    end

    def model_usage
      Platform::ModelUsage.new(dispatch: dispatch)
    end

    def deployment
      Platform::Deployment.new(dispatch: dispatch)
    end

    def profile
      Platform::ProfileContext.new(dispatch: dispatch)
    end

    def persona
      Platform::PersonaContext.new(dispatch: dispatch)
    end

    def cost_unit
      Platform::CostUnitContext.new(dispatch: dispatch)
    end

    def retention
      Platform::RetentionContext.new(dispatch: dispatch)
    end

    def models
      Platform::ModelCatalog.new(dispatch: dispatch)
    end

    def mcp_connections
      Platform::McpConnections.new(dispatch: dispatch)
    end

    def model_providers
      Platform::ModelProviders.new(dispatch: dispatch)
    end
  end
end
