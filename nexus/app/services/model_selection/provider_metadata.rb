module ModelSelection
  # Lane metadata reads provider facts and operation names, never model payloads.
  # The count describes configured refs; model discovery owns semantic availability.
  module ProviderMetadata
    Catalog = Data.define(:providers, :policies, :model_counts)
    OPERATIONS = <<~SQL.squish.freeze
      COALESCE((SELECT jsonb_object_agg(key, value ->> 'op')
        FROM jsonb_each(CASE WHEN jsonb_typeof(model_overrides -> 'entries') = 'object'
          THEN model_overrides -> 'entries' ELSE '{}'::jsonb END)), '{}'::jsonb) AS model_operations
    SQL

    def self.read(account:, snapshot:, provider_id: nil)
      scope = ModelProviderPolicy.where(account: account)
      scope = scope.where(provider_id: provider_id) if provider_id
      policies = scope.select(:provider_id, :enabled, :lock_version, :provider_definition, Arel.sql(OPERATIONS)).index_by(&:provider_id)
      providers = provider_id ? snapshot.providers.slice(provider_id) : snapshot.providers
      refs = snapshot.models.keys.group_by { |ref| Nexus::ModelRef.parse(ref).provider_id }
      counts = refs.transform_values(&:length)
      policies.each_value do |policy|
        providers = apply_definition(providers, policy, account)
        configured = Set.new(refs.fetch(policy.provider_id, []))
        policy[:model_operations].each do |ref, op|
          next unless ModelProviderPolicy.provider_lane_ref?(policy.provider_id, ref)

          case op
          when "upsert" then configured.add(ref)
          when "remove" then configured.delete(ref)
          else nil
          end
        end
        counts[policy.provider_id] = configured.length
      end
      Catalog.new(providers: providers, policies: policies, model_counts: counts)
    end

    def self.apply_definition(providers, policy, account)
      return providers if policy.provider_definition.nil?

      definition = Nexus::ProviderDefinition.normalize(policy.provider_definition, provider_id: policy.provider_id)
      ModelCatalog::CatalogValidation.validate_provider_definition(policy.provider_id, definition)
      providers.merge(policy.provider_id => definition)
    rescue Nexus::ProviderDefinition::Invalid, ModelCatalog::CompileError
      Rails.logger.warn("event=model_catalog_provider_overlay_ignored account_public_id=#{account.public_id} " \
        "provider_id=#{policy.provider_id} policy_version=#{policy.lock_version} reason=invalid_definition")
      providers
    end
    private_class_method :apply_definition
  end
end
