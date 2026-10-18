module ModelProviders
  # A retained unavailable mark hides the model without replacing its definition
  # or the administrator's independent visibility choice.
  class SetModelAvailability < ConfigCommand
    def initialize(model_ref:, available:, **base)
      super(**base)
      @model_ref = model_ref.to_s
      @available = available
    end

    private

      def valid_before_transaction?
        super && [true, false].include?(@available) &&
          Nexus::ModelRef.parse(@model_ref).complete? &&
          ModelProviderConfig.provider_lane_ref?(@provider_id, @model_ref)
      end

      def apply_change(policy)
        policy.set_model_availability(@model_ref, available: @available)
      end
  end
end
