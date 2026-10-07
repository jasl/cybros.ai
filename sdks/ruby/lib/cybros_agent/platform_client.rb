module CybrosAgent
  # The Human Platform plane. Nexus checks the current role for every admin
  # command; this client keeps its resource surface separate from agent work.
  class PlatformClient < Api::BaseClient
    def session
      Platform::SessionContext.new(dispatch: dispatch)
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

    def model_providers
      Platform::ModelProviders.new(dispatch: dispatch)
    end
  end
end
