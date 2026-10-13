module SimpleInference
  class ExecutionProfile
    # One reviewable generation control: an ENUMERATED parameter lists its
    # exact values; a RANGE-TYPED numeric one carries nil allowed_values and
    # is bounded (or deliberately unbounded, e.g. seed) by minimum/maximum.
    # String-family kinds must enumerate — free text is not a contract.
    class GenerationParameter < Data.define(:kind, :default, :minimum, :maximum, :allowed_values)
      # `verbosity` is the Responses wire's `text.verbosity` (alignment
      # 2026-09-16, F21): a string contract enumerating low, medium, high.
      NAMES = %w[
        temperature max_output_tokens top_p top_k min_p seed frequency_penalty presence_penalty
        output_format result_count voice format language dimensions verbosity
      ].freeze
      KINDS = %w[integer number string output_format].freeze
      OUTPUT_FORMAT_VALUES = %w[text json_object json_schema].freeze
      ENUMERATED_KINDS = %w[string output_format].freeze

      def self.from_h(name, hash) = Facts.ingest(self, hash, label: "generation_parameters[#{name}]", name: name)

      def initialize(kind:, default:, minimum:, maximum:, allowed_values:, name: "parameter")
        label = "generation_parameters[#{name}]"
        kind = kind.to_s
        unless KINDS.include?(kind)
          raise SimpleInference::ConfigurationError, "#{label} kind #{kind.inspect} is not reviewed"
        end

        if allowed_values.nil?
          if ENUMERATED_KINDS.include?(kind)
            raise SimpleInference::ConfigurationError, "#{label} #{kind} contracts must enumerate allowed_values"
          end
        elsif !(allowed_values.is_a?(Array) && !allowed_values.empty? && allowed_values.uniq.length == allowed_values.length)
          raise SimpleInference::ConfigurationError, "#{label} allowed_values must be nil or a non-empty unique Array"
        end

        validate_range(label, kind, minimum, maximum)
        (allowed_values || []).each do |value|
          validate_value(label, kind, value, field: "allowed_values")
          if (!minimum.nil? && value < minimum) || (!maximum.nil? && value > maximum)
            raise SimpleInference::ConfigurationError, "#{label} allowed value #{value.inspect} is outside its range"
          end
        end

        unless default.nil?
          validate_value(label, kind, default, field: "default")
          if allowed_values
            unless allowed_values.include?(default)
              raise SimpleInference::ConfigurationError, "#{label} default must be one of allowed_values"
            end
          elsif (!minimum.nil? && default < minimum) || (!maximum.nil? && default > maximum)
            raise SimpleInference::ConfigurationError, "#{label} default #{default.inspect} is outside its range"
          end
        end

        super(
          kind: -kind, default: Facts.immutable(default), minimum: Facts.immutable(minimum),
          maximum: Facts.immutable(maximum),
          allowed_values: allowed_values&.map { |value| Facts.immutable(value) }&.freeze,
        )
      end

      def to_h = super.transform_keys(&:to_s)

      private

      def validate_range(label, kind, minimum, maximum)
        if ENUMERATED_KINDS.include?(kind)
          unless minimum.nil? && maximum.nil?
            raise SimpleInference::ConfigurationError, "#{label} #{kind} bounds must be nil"
          end
          return
        end

        validate_value(label, kind, minimum, field: "minimum") unless minimum.nil?
        validate_value(label, kind, maximum, field: "maximum") unless maximum.nil?
        if !minimum.nil? && !maximum.nil? && minimum > maximum
          raise SimpleInference::ConfigurationError, "#{label} minimum exceeds maximum"
        end
      end

      def validate_value(label, kind, value, field:)
        valid =
          case kind
          when "integer" then value.is_a?(Integer)
          when "number" then Facts.finite_number?(value)
          when "string" then value.is_a?(String) && !value.empty? && value == value.strip
          when "output_format" then value.is_a?(String) && OUTPUT_FORMAT_VALUES.include?(value)
          else raise SimpleInference::ConfigurationError, "#{label} has unhandled kind #{kind.inspect}"
          end
        return if valid

        raise SimpleInference::ConfigurationError, "#{label} #{field} has invalid #{kind} value #{value.inspect}"
      end
    end
  end
end
