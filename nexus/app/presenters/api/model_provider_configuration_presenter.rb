module API
  # Administrator authoring projection: retain removals so inheritance can be restored.
  class ModelProviderConfigurationPresenter
    def self.one(account:, provider_id:, snapshot: ModelCatalog.current)
      catalog = ModelSelection::Resolver.effective_provider_catalog(account, snapshot, provider_id)
      definition = catalog.providers[provider_id]
      policy = catalog.policies[provider_id]
      raise ActiveRecord::RecordNotFound if definition.nil? && policy.nil?

      snapshot = ModelCatalog::RetainedCatalog.base(snapshot: snapshot, policy: policy)
      entries = policy&.override_entries || {}
      refs = (snapshot.models.keys | entries.keys).select { |ref| ModelProviderConfig.provider_lane_ref?(provider_id, ref) }
      source = if definition.nil?
        "removed"
      elsif policy&.provider_definition
        snapshot.providers.key?(provider_id) ? "override" : "custom"
      else
        "catalog"
      end
      {
        definition: definition,
        source: source,
        model_definitions: snapshot.model_definitions,
        models: refs.sort.map { |ref|
          entry = entries[ref]
          model = if entry&.fetch("op", nil) == "upsert"
            authoring_definition(entry.fetch("model"), ref)
          else
            snapshot.authored_models[ref]
          end
          {
            model: ref,
            definition: model,
            source: entry ? (snapshot.models.key?(ref) ? "override" : "custom") : "catalog",
            removed: entry&.fetch("op", nil) == "remove",
          }
        },
      }
    end

    def self.authoring_definition(model, ref)
      ModelCatalog::ModelDefinition.authoring_shape(model, model_ref: ref)
    rescue ModelCatalog::CompileError
      # Inert internal overrides remain readable so one malformed entry cannot
      # prevent an administrator from viewing and repairing the provider.
      model
    end
    private_class_method :authoring_definition
  end
end
