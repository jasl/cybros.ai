module ModelProviders
  # Refresh on configuration writes and installation preparation, never on a read.
  # Resolved file models survive removal of their shared inheritance definition.
  class RetainCatalog < ConfigCommand
    def self.capture(policy, snapshot: nil)
      snapshot ||= ModelCatalog.current
      provider_id = policy.provider_id
      models = snapshot.models.select { |ref, _| ModelProviderConfig.provider_lane_ref?(provider_id, ref) }
      authored = snapshot.authored_models.slice(*models.keys).values
      authored += policy.override_entries.values.filter_map { |entry| entry["model"] if entry["op"] == "upsert" }
      names = authored.filter_map { |entry| entry["inherit"] }.uniq
      policy.retain_catalog(provider: snapshot.providers[provider_id], models: models,
        model_definitions: snapshot.model_definitions.slice(*names))
    rescue ModelCatalog::Unavailable
      # Internal inert-document edits remain available without a booted catalog.
      # No new deployment facts can be captured; existing saved facts remain.
      nil
    end

    private

      def apply_change(policy)
        self.class.capture(policy, snapshot: ModelCatalog.current)
      end
  end
end
