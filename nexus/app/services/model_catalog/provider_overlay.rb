module ModelCatalog
  # Provider and model facts compose as one lane: validation sees replacements too.
  module ProviderOverlay
    Result = Data.define(:providers, :models, :hidden_models, :unavailable_models)

    class << self
      def apply(providers:, models:, selectors:, policy:, account_unit:, logger: Rails.logger)
        compose(providers: providers, models: models, selectors: selectors, policy: policy,
          account_unit: account_unit, logger: logger)
      rescue Nexus::ProviderDefinition::Invalid, ModelCatalog::CompileError
        logger.warn("event=model_catalog_provider_overlay_ignored account_public_id=#{policy.account.public_id} " \
          "provider_id=#{policy.provider_id} policy_version=#{policy.lock_version} reason=invalid_definition")
        model_overlay(providers, models, selectors, policy, account_unit, logger)
      end

      # Malformed historical documents remain inert; authoring separately preserves
      # currently effective models so changing a protocol cannot silently retire one.
      def compose(providers:, models:, selectors:, policy:, account_unit:, logger: Rails.logger)
        return model_overlay(providers, models, selectors, policy, account_unit, logger) if policy.provider_definition.nil?

        definition = Nexus::ProviderDefinition.normalize(policy.provider_definition, provider_id: policy.provider_id)
        candidate = providers.merge(policy.provider_id => definition)
        result = model_overlay(candidate, models, selectors, policy, account_unit, logger)
        CatalogValidation.validate_provider_change(result.models, selectors, policy.provider_id, candidate)
        Result.new(providers: ModelCatalog.deep_freeze(candidate), models: result.models,
          hidden_models: result.hidden_models, unavailable_models: result.unavailable_models)
      end

      private

        def model_overlay(providers, models, selectors, policy, account_unit, logger)
          result = ModelOverlay.apply(providers: providers, models: models, selectors: selectors,
            policy: policy, account_unit: account_unit, logger: logger)
          Result.new(providers: providers, models: result.models,
            hidden_models: result.hidden_models, unavailable_models: result.unavailable_models)
        end
    end
  end
end
