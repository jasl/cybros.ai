module ModelProviders
  # Interactive authoring validates the final model and its selector references.
  # Internal inert-document writes retain their forward-compatible storage contract.
  class ModelDefinitionCommand < PolicyCommand
    def initialize(model_ref:, validate_definition: false, **base)
      super(**base)
      @model_ref = model_ref
      @validate_definition = validate_definition
    end

    private

      def valid_before_transaction?
        return false unless super && ModelProviderPolicy.provider_lane_ref?(@provider_id, @model_ref)
        return true unless @validate_definition
        return false unless Nexus::ModelRef.parse(@model_ref).complete?

        snapshot = ModelCatalog.current
        catalog = ModelSelection::Resolver.effective_provider_catalog(@account, snapshot, @provider_id)
        return false unless catalog.providers.key?(@provider_id)

        ModelCatalog::CatalogValidation.validate_change(
          changed_models(catalog.models, snapshot), catalog.selectors, @model_ref, catalog.providers
        )
        true
      rescue ModelCatalog::CompileError
        false
      end
  end
end
