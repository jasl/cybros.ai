module SimpleInference
  module Decisions
    Probability = Data.define(:value, :probability, :label) do
      def initialize(value:, probability:, label: nil) = super
      def to_h = super.transform_keys(&:to_s).compact
    end

    Answer = Data.define(:name, :type, :probability, :choice, :score, :confidence, :probabilities) do
      def initialize(name:, type:, probability: nil, choice: nil, score: nil, confidence: nil, probabilities: nil)
        super
      end

      def to_h
        super.transform_keys(&:to_s).merge("probabilities" => probabilities&.map(&:to_h)).compact
      end
    end

    Result = Data.define(:answers, :usage, :provider_response, :provider_format)
  end
end
