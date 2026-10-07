module SimpleInference
  class ExecutionProfile
    # The registry row is the single home for every pre-IO input cap; the
    # protocol reads its cap at construction and keeps only the enforcement.
    # `input_characters` is the Unicode-scalar bound (the Create Speech
    # API's 4,096-character cap); `embedding_dimensions` enumerates the
    # selectable dimensions.
    class LocalSafetyLimits < Data.define(
      :input_tokens, :output_tokens, :input_bytes, :input_characters, :audio_duration_seconds,
      :result_count, :embedding_dimensions, :combined_input_output_tokens
    )
      def self.from_h(hash) = Facts.ingest(self, hash, label: "local_safety_limits")

      def initialize(**limits)
        limits.each do |key, value|
          next if value.nil?

          if key == :embedding_dimensions
            unless value.is_a?(Array) && !value.empty? && value.uniq.length == value.length &&
                value.all? { |dimension| dimension.is_a?(Integer) && dimension.positive? }
              raise SimpleInference::ConfigurationError,
                    "local_safety_limits[embedding_dimensions] must be unique positive Integers"
            end
          elsif !(value.is_a?(Integer) && value.positive?)
            raise SimpleInference::ConfigurationError, "local_safety_limits[#{key}] must be a positive Integer"
          end
        end

        super(**self.class.members.to_h { |member| [member, nil] }, **limits.transform_values { |value| value.is_a?(Array) ? value.dup.freeze : value })
      end

      def [](key) = public_send(key)

      def to_h = super.transform_keys(&:to_s).compact
    end
  end
end
