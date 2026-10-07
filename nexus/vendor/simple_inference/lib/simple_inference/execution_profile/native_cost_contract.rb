require "bigdecimal"

module SimpleInference
  class ExecutionProfile
    # How a lane reports its own cost on the wire: the amount field, its
    # unit, the exact-decimal scale to an Account amount, and the bounds
    # that keep the product inside Account storage.
    class NativeCostContract < Data.define(:amount_field, :unit, :scale, :maximum_wire_amount, :maximum_fractional_digits)
      DECIMAL_PATTERN = /\A(?:0|[1-9]\d*)(?:\.\d+)?\z/
      MAX_ACCOUNT_SCALE = 18
      MAX_TEXT_BYTES = 64
      MAX_ACCOUNT_AMOUNT_EXCLUSIVE = BigDecimal("1e20")

      def self.from_h(hash) = hash.nil? ? nil : Facts.ingest(self, hash, label: "native_cost_contract")

      def initialize(amount_field:, unit:, scale:, maximum_wire_amount:, maximum_fractional_digits:)
        amount_field = identity(amount_field, "amount_field")
        unit = identity(unit, "unit")
        scale = decimal(scale, "scale")
        maximum_wire_amount = decimal(maximum_wire_amount, "maximum_wire_amount")
        unless maximum_fractional_digits.is_a?(Integer) && maximum_fractional_digits.between?(0, MAX_ACCOUNT_SCALE)
          raise SimpleInference::ConfigurationError,
                "native_cost_contract maximum_fractional_digits must be an Integer between 0 and #{MAX_ACCOUNT_SCALE}"
        end

        if decimal_scale(maximum_wire_amount) > maximum_fractional_digits
          raise SimpleInference::ConfigurationError,
                "native_cost_contract maximum_wire_amount exceeds its declared fractional-digit bound"
        end
        if decimal_scale(scale) + maximum_fractional_digits > MAX_ACCOUNT_SCALE
          raise SimpleInference::ConfigurationError,
                "native_cost_contract scale cannot produce an Account amount beyond scale #{MAX_ACCOUNT_SCALE}"
        end
        if BigDecimal(maximum_wire_amount) * BigDecimal(scale) >= MAX_ACCOUNT_AMOUNT_EXCLUSIVE
          raise SimpleInference::ConfigurationError,
                "native_cost_contract maximum exceeds the Account amount storage bound"
        end

        super(
          amount_field: -amount_field, unit: -unit, scale: -scale,
          maximum_wire_amount: -maximum_wire_amount, maximum_fractional_digits:,
        )
      end

      def to_h = super.transform_keys(&:to_s)

      private

      def identity(value, field)
        unless value.is_a?(String) && !value.empty? && value == value.strip && value.bytesize <= MAX_TEXT_BYTES
          raise SimpleInference::ConfigurationError,
                "native_cost_contract #{field} must be a non-blank String of at most #{MAX_TEXT_BYTES} bytes"
        end

        value
      end

      def decimal(value, field)
        unless value.is_a?(String) && value.bytesize <= MAX_TEXT_BYTES && value.match?(DECIMAL_PATTERN)
          raise SimpleInference::ConfigurationError,
                "native_cost_contract #{field} must be a bounded exact decimal String"
        end
        if BigDecimal(value) <= 0
          raise SimpleInference::ConfigurationError, "native_cost_contract #{field} must be positive"
        end

        value
      end

      def decimal_scale(value)
        value.include?(".") ? value.length - value.index(".") - 1 : 0
      end
    end
  end
end
