module ModelCatalog
  # Current deployment facts win over their saved fallback. Explicit operator
  # replacements and tombstones are applied afterward by the ordinary overlay.
  module RetainedCatalog
    Result = Data.define(:providers, :models, :model_definitions)

    def self.base(snapshot:, policy:)
      return snapshot if policy.nil?

      result = apply(providers: snapshot.providers, models: snapshot.models,
        model_definitions: snapshot.model_definitions, policy: policy)
      snapshot.with(providers: result.providers, models: result.models, model_definitions: result.model_definitions,
        authored_models: result.models.except(*snapshot.models.keys).merge(snapshot.authored_models))
    end

    def self.apply(providers:, models:, model_definitions:, policy:, logger: Rails.logger)
      original = Result.new(providers: providers, models: models, model_definitions: model_definitions)
      return original unless ModelProviderConfig.valid_document_shape?(policy.model_overrides, provider_id: policy.provider_id)

      saved = policy.retained_catalog
      return original if saved.empty?

      if !providers.key?(policy.provider_id) && saved.key?("provider")
        declaration = Nexus::ProviderDefinition.normalize(saved.fetch("provider"), provider_id: policy.provider_id)
        providers = providers.merge(policy.provider_id => declaration)
      end
      definitions = ModelDefinition.normalize_definitions(saved.fetch("model_definitions", {}).except(*model_definitions.keys)).merge(model_definitions)
      retained = saved.fetch("models", {}).except(*models.keys).to_h do |ref, entry|
        [ref, ModelDefinition.normalize(entry, model_ref: ref)]
      end
      retained.each do |ref, entry|
        CatalogValidation.validate_change({ ref => entry }, {}, ref, providers)
      end
      Result.new(providers: ModelCatalog.deep_freeze(providers),
        models: retained.empty? ? models : ModelCatalog.deep_freeze(retained.merge(models)),
        model_definitions: ModelCatalog.deep_freeze(definitions))
    rescue Nexus::ProviderDefinition::Invalid, CompileError
      logger.warn("event=model_catalog_retention_ignored account_public_id=#{policy.account.public_id} " \
        "provider_id=#{policy.provider_id} reason=invalid_definition")
      original
    end
  end
end
