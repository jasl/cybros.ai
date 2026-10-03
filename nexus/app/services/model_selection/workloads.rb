module ModelSelection
  # The provider-neutral acceptance grammar: Selection, Input and
  # Configuration each refuse on their own evidence, and this is where
  # they meet. Nothing may grow a parallel grammar.
  module Workloads
    TOO_MANY_INPUT_TEXTS = :too_many_input_texts

    Normalization = Data.define(:value, :refusal) do
      def self.accepted(value) = new(value: value, refusal: nil)
      def self.refused(refusal) = new(value: nil, refusal: refusal)

      def accepted? = refusal.nil?
    end

    class << self
      include Predicates

      def refusal_for(workload:, submitted:)
        Selection.refusal_for(workload: workload, submitted: submitted)
      end

      def normalize_input(workload:, input:)
        Input.normalize_input(workload: workload, input: input)
      end

      def normalize_configuration(configuration:, capabilities:)
        Configuration.normalize_configuration(
          configuration: configuration, capabilities: capabilities
        )
      end

      # The payload and its uploads are one acceptance contract, derived
      # from the resolved selection; `ModelRequests::Build` reads exactly this shape.
      def normalize_workload_input(selection:, input:, uploads:)
        normalized = normalize_input(workload: selection.workload, input: input)
        return normalized unless normalized.accepted?

        accept_normalized_input(selection: selection, input: normalized.value, uploads: uploads)
      end

      # Accepted input can be composed for another round or model. Its grammar
      # belongs to its writer; the current selection and whole request still bind.
      def accept_normalized_input(selection:, input:, uploads:)
        refusal = Input.role_policy_refusal(selection, input)
        return Normalization.refused(refusal) if refusal
        refusal = Input.input_arity_refusal(selection, input)
        return Normalization.refused(refusal) if refusal
        refusal = Input.upload_policy_refusal(selection, uploads)
        return Normalization.refused(refusal) if refusal
        refusal = Input.upload_placement_refusal(selection.workload, input, uploads)
        return Normalization.refused(refusal) if refusal
        refusal = Input.input_bound_refusal(selection, input, uploads)
        return Normalization.refused(refusal) if refusal
        refusal = Input.input_count_refusal(input)
        return Normalization.refused(refusal) if refusal

        Normalization.accepted(
          Nexus::NormalizedWorkloadInput.new(
            value: input.freeze,
            uploads: uploads.dup.freeze
          )
        )
      end
    end
  end
end
