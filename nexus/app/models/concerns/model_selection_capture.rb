module ModelSelectionCapture
  extend ActiveSupport::Concern

  included do
    attribute :model_selection, ModelSelectionIntent.to_type
    validates :model_selection, store_model: true, allow_nil: true
    validates :model_selection_document, bounded_json: { bound: :envelope_bound }, allow_nil: true
    validates :fallback_models, bounded_json: { bound: :envelope_bound, shape: Array }, model_references: true, allow_nil: true
  end

  private

    def model_selection_document = model_selection&.as_json
end
