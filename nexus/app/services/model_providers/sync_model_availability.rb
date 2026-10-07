module ModelProviders
  # Apply one complete directory observation under the provider's ordinary
  # version fence. The caller supplies only the current composed model refs.
  class SyncModelAvailability < ConfigCommand
    def initialize(model_refs:, unavailable_model_refs:, **base)
      super(**base)
      @model_refs = model_refs
      @unavailable_model_refs = unavailable_model_refs
    end

    private

      def valid_before_transaction?
        super && ModelProviderConfig.valid_model_refs?(@model_refs, provider_id: @provider_id) &&
          ModelProviderConfig.valid_model_refs?(@unavailable_model_refs, provider_id: @provider_id) &&
          (@unavailable_model_refs - @model_refs).empty?
      end

      def mutate(policy)
        return Result.new(outcome: :stale, policy: nil) unless policy.lock_version == @expected_lock_version

        super
      end

      def create_row
        return Result.new(outcome: :stale, policy: nil) unless @expected_lock_version.nil?
        return Result.new(outcome: :noop, policy: nil) if @unavailable_model_refs.empty?

        create_policy(enabled: false, model_overrides: ModelProviderConfig.empty_overrides.merge(
          "unavailable_models" => @unavailable_model_refs.sort
        ))
      end

      def apply_change(policy)
        policy.sync_model_availability(model_refs: @model_refs, unavailable_model_refs: @unavailable_model_refs)
      end
  end
end
