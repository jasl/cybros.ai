module API
  # Administrator authoring projection: retain removals so inheritance can be restored.
  class ModelProviderConfigurationPresenter
    def self.one(account:, provider_id:, snapshot: ModelCatalog.current)
      catalog = ModelSelection::Resolver.effective_provider_catalog(account, snapshot, provider_id)
      definition = catalog.providers[provider_id]
      policy = catalog.policies[provider_id]
      raise ActiveRecord::RecordNotFound if definition.nil? && policy.nil?

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
        models: refs.sort.map { |ref|
          entry = entries[ref]
          {
            model: ref,
            definition: entry&.fetch("op", nil) == "upsert" ? entry.fetch("model") : snapshot.models[ref],
            source: entry ? (snapshot.models.key?(ref) ? "override" : "custom") : "catalog",
            removed: entry&.fetch("op", nil) == "remove",
          }
        },
      }
    end
  end
end
