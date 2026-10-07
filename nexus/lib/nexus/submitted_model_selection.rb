module Nexus
  class SubmittedModelSelection < Data.define(:model, :reasoning_effort, :reasoning_enabled)
    MODEL_SELECTOR_PREFIX = "model_selector:".freeze

    def self.from_h(hash) = new(**hash.transform_keys(&:to_sym))

    def initialize(reasoning_enabled: nil, **) = super

    def model_selector
      return unless model.start_with?(MODEL_SELECTOR_PREFIX)

      model.delete_prefix(MODEL_SELECTOR_PREFIX)
    end

    def to_h = super.transform_keys(&:to_s)
  end
end
