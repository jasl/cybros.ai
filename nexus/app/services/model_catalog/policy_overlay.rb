module ModelCatalog
  # Applies one database policy document to the file base: user-authored
  # overlay data, never provider facts. An inapplicable operation is
  # ignored with a warning, and an entry pays only for what it changes.
  module PolicyOverlay
    LOG_IDENTITY_LIMIT = 256
    Result = Data.define(:models, :hidden_models)

    class << self
      def apply(providers:, models:, selectors:, policy:, account_unit:, logger: Rails.logger)
        unless providers.key?(policy.provider_id)
          warn_ignored(logger, policy, reason: :provider_not_present)
          return Result.new(models: models, hidden_models: [])
        end

        document = policy.model_overrides
        unless ModelProviderPolicy.valid_document_shape?(document, provider_id: policy.provider_id)
          warn_ignored(logger, policy, reason: :invalid_document)
          return Result.new(models: models, hidden_models: [])
        end
        entries = document.fetch("entries")

        # Each operation folds the mapping forward instead of mutating one:
        # an entry that does not apply hands its input straight back, so an
        # inert document costs no copy at all.
        composed = entries.reduce(models) do |effective, (model_ref, operation)|
          apply_operation(
            effective, policy, model_ref, operation, providers: providers,
            selectors: selectors, account_unit: account_unit, logger: logger
          )
        end
        Result.new(
          models: composed.equal?(models) ? models : deep_freeze(composed),
          hidden_models: document.fetch("hidden_models", []).freeze
        )
      end

      private

      def apply_operation(effective, policy, model_ref, operation, providers:, selectors:, account_unit:, logger:)
        unless ModelProviderPolicy.provider_lane_ref?(policy.provider_id, model_ref)
          warn_ignored(logger, policy, model_ref: model_ref, reason: :outside_provider_lane)
          return effective
        end
        valid_operation = case operation
        when Hash then (operation.keys - ModelProviderPolicy::ENTRY_KEYS).empty?
        else false
        end
        unless valid_operation
          warn_ignored(logger, policy, model_ref: model_ref, reason: :invalid_operation)
          return effective
        end

        case operation["op"]
        when "upsert"
          apply_upsert(
            effective, policy, model_ref, operation, providers: providers,
            selectors: selectors, account_unit: account_unit, logger: logger
          )
        when "remove"
          apply_remove(effective, policy, model_ref, operation, providers: providers, selectors: selectors, logger: logger)
        else
          warn_ignored(logger, policy, model_ref: model_ref, reason: :invalid_operation)
          effective
        end
      end

      def apply_upsert(effective, policy, model_ref, operation, providers:, selectors:, account_unit:, logger:)
        model = operation["model"]
        # Unknown operation keys were already refused by the caller; the
        # composed validation below refuses a non-mapping model itself.
        unless operation.key?("model")
          warn_ignored(logger, policy, model_ref: model_ref, reason: :invalid_operation)
          return effective
        end

        # A shallow merge, so only the rewritten model is copied.
        candidate = effective.merge(model_ref => model.deep_dup)
        validate_change(candidate, selectors, model_ref, providers)

        candidate
      rescue CompileError
        warn_ignored(logger, policy, model_ref: model_ref, reason: :invalid_model)
        effective
      end

      def apply_remove(effective, policy, model_ref, operation, providers:, selectors:, logger:)
        unless closed_keys?(operation, ["op"])
          warn_ignored(logger, policy, model_ref: model_ref, reason: :invalid_operation)
          return effective
        end
        unless effective.key?(model_ref)
          warn_ignored(logger, policy, model_ref: model_ref, reason: :model_not_present)
          return effective
        end

        candidate = effective.except(model_ref)
        validate_change(candidate, selectors, model_ref, providers)
        candidate
      rescue CompileError
        warn_ignored(logger, policy, model_ref: model_ref, reason: :invalid_composition)
        effective
      end

      def validate_change(models, selectors, model_ref, providers)
        CatalogValidation.validate_change(models, selectors, model_ref, providers)
      end

      def warn_ignored(logger, policy, model_ref: nil, reason:)
        logger.warn(
          "event=model_catalog_policy_overlay_ignored account_public_id=#{policy.account.public_id} " \
          "provider_id=#{bounded_identity(policy.provider_id)} policy_version=#{policy.lock_version} " \
          "model_ref=#{bounded_identity(model_ref)} reason=#{reason}"
        )
        nil
      end

      def bounded_identity(value)
        return nil if value.nil?

        value.to_s.first(LOG_IDENTITY_LIMIT)
      end

      def closed_keys?(mapping, expected)
        (mapping.keys - expected).empty? && (expected - mapping.keys).empty?
      end

      def deep_freeze(value) = ModelCatalog.deep_freeze(value)
    end
  end
end
