module Rho
  class MemoryReview
    # The source conversation owns the single unfinished submission. Its
    # keys and accepted IDs recover the same side and the same model input.
    Submission = Data.define(:idempotency_key, :input_idempotency_key, :prepared_at, :input,
      :review_conversation_public_id, :input_public_id) do
      def self.from_h(value) = new(**value.to_h.transform_keys(&:to_sym))
      def to_h = super.transform_keys(&:to_s)
    end

    Source = Data.define(:conversation_public_id, :review_conversation_public_id, :idempotency_key) do
      def self.from_h(value) = new(**value.to_h.transform_keys(&:to_sym))
      def to_h = super.transform_keys(&:to_s)
    end

    State = Data.define(:conversation_public_id, :enabled, :path, :document_public_id, :model,
      :after_position, :pending, :last_run_public_id, :last_review_conversation_public_id, :outcome) do
      def self.empty(conversation_public_id)
        new(conversation_public_id: conversation_public_id, enabled: false, path: nil, document_public_id: nil,
          model: nil, after_position: -1, pending: nil, last_run_public_id: nil,
          last_review_conversation_public_id: nil, outcome: nil)
      end

      def self.from_h(value)
        fields = value.to_h.transform_keys(&:to_sym)
        fields[:pending] = Submission.from_h(fields[:pending]) if fields[:pending]
        new(**fields)
      end

      def to_h = super.transform_keys(&:to_s).merge("pending" => pending&.to_h)
    end
  end
end
