module ModelProviders
  # Visibility is independent of replacement definitions and file inheritance.
  class SetModelVisibility < ConfigCommand
    def initialize(model_ref:, visible:, **base)
      super(**base)
      @model_ref = model_ref.to_s
      @visible = visible
    end

    private

      def valid_before_transaction?
        super && [true, false].include?(@visible) &&
          Nexus::ModelRef.parse(@model_ref).complete? &&
          ModelProviderConfig.provider_lane_ref?(@provider_id, @model_ref)
      end

      def create_row
        overrides = ModelProviderConfig.empty_overrides
        overrides["hidden_models"] = [@model_ref] unless @visible
        create_policy(enabled: false, model_overrides: overrides)
      end

      def apply_change(policy)
        policy.set_model_visibility(@model_ref, visible: @visible)
      end
  end
end
