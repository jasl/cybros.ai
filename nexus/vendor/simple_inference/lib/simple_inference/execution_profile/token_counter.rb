module SimpleInference
  class ExecutionProfile
    # The lane's token counter, declared as DATA exactly like
    # `native_cost_contract`: this gem measures scalars and bytes and owns no
    # tokenizer, so it states which counter a lane needs and the consumer
    # implements it. `tiktoken`/`huggingface` are EXACT counters; `anchored`
    # tokenizes with an encoding we can run and multiplies by a declared
    # safety factor — a measured confidence, never a bound. Each kind names
    # exactly the one locator it needs.
    class TokenCounter < Data.define(:kind, :encoding, :tokenizer_id, :safety_factor)
      KINDS = %w[tiktoken huggingface anchored].freeze
      # Exact-decimal text, like the native-cost scale beside it.
      SAFETY_FACTOR_PATTERN = /\A[1-9]\d*(?:\.\d+)?\z/

      def self.from_h(hash) = hash.nil? ? nil : Facts.ingest(self, hash, label: "token_counter")

      def initialize(kind:, encoding: nil, tokenizer_id: nil, safety_factor: nil)
        kind = kind.to_s
        unless KINDS.include?(kind)
          raise SimpleInference::ConfigurationError, "token_counter kind #{kind.inspect} is not reviewed"
        end

        required, forbidden = kind == "huggingface" ? %w[tokenizer_id encoding] : %w[encoding tokenizer_id]
        locators = { "encoding" => encoding, "tokenizer_id" => tokenizer_id }
        locator = locators.fetch(required)
        unless locator.is_a?(String) && !locator.strip.empty?
          raise SimpleInference::ConfigurationError, "token_counter kind #{kind} requires a nonblank #{required}"
        end
        unless locators.fetch(forbidden).nil?
          raise SimpleInference::ConfigurationError, "token_counter kind #{kind} cannot carry #{forbidden}"
        end

        if kind == "anchored"
          unless safety_factor.is_a?(String) && safety_factor.match?(SAFETY_FACTOR_PATTERN)
            raise SimpleInference::ConfigurationError,
                  "token_counter kind anchored requires an exact-decimal safety_factor >= 1"
          end
        elsif !safety_factor.nil?
          raise SimpleInference::ConfigurationError, "token_counter kind #{kind} cannot carry safety_factor"
        end

        super(
          kind: -kind, encoding: Facts.immutable(encoding), tokenizer_id: Facts.immutable(tokenizer_id),
          safety_factor: Facts.immutable(safety_factor),
        )
      end

      def anchored? = kind == "anchored"

      def to_h = super.transform_keys(&:to_s).compact
    end
  end
end
