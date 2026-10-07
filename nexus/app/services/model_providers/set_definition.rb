module ModelProviders
  class SetDefinition < ConfigCommand
    def initialize(definition:, **base)
      super(**base)
      @definition = definition
    end

    private

      def valid_before_transaction?
        return false unless super

        @definition = Nexus::ProviderDefinition.normalize(@definition, provider_id: @provider_id)
        catalog = ModelSelection::Resolver.effective_provider_catalog(@account, ModelCatalog.current, @provider_id)
        ModelCatalog::CatalogValidation.validate_provider_change(
          catalog.models, catalog.selectors, @provider_id, catalog.providers.merge(@provider_id => @definition)
        )
        true
      rescue Nexus::ProviderDefinition::Invalid, ModelCatalog::CompileError
        false
      end

      def create_row
        create_policy(enabled: false, provider_definition: @definition)
      end

      def apply_change(policy)
        policy.provider_definition = @definition
      end
  end
end
