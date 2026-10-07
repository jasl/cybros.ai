module ModelProviders
  class ResetDefinition < ConfigCommand
    private

      def valid_before_transaction?
        return false unless super

        snapshot = ModelCatalog.current
        original = snapshot.providers[@provider_id]
        return true if original.nil?

        catalog = ModelSelection::Resolver.effective_provider_catalog(@account, snapshot, @provider_id)
        ModelCatalog::CatalogValidation.validate_provider_change(
          catalog.models, catalog.selectors, @provider_id, catalog.providers.merge(@provider_id => original)
        )
        true
      rescue ModelCatalog::CompileError
        false
      end

      def apply_change(policy)
        policy.provider_definition = nil
        policy.enabled = false unless ModelCatalog.current.providers.key?(@provider_id)
      end
  end
end
