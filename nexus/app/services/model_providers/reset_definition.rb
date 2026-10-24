module ModelProviders
  class ResetDefinition < ConfigCommand
    private

      def valid_before_transaction?
        return false unless super

        snapshot = ModelCatalog.current
        policy = ModelProviderConfig.find_by(account: @account, provider_id: @provider_id)
        snapshot = ModelCatalog::RetainedCatalog.base(snapshot: snapshot, policy: policy)
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
        base = ModelCatalog::RetainedCatalog.base(snapshot: ModelCatalog.current, policy: policy)
        policy.enabled = false unless base.providers.key?(@provider_id)
      end
  end
end
