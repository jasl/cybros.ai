module Nexus
  EffectiveGenerationConfig = Data.define(:values) do
    # The inverse of `serialized_value`, which emits a Hash only for an
    # OutputFormat; reading back by shape keeps the codec symmetric under any
    # catalog spelling (`output_format` may carry a plain string).
    def self.from_h(hash)
      values = hash.to_h do |name, value|
        normalized = case value
        when Hash then OutputFormat.from_h(value)
        else value
        end
        [name.to_sym, normalized]
      end

      new(values: values.freeze)
    end

    def fetch(...) = values.fetch(...)

    def to_h
      values.to_h do |name, value|
        [name.to_s, serialized_value(value)]
      end
    end

    # The provider-neutral projection: each value knows its own wire shape and
    # the names stay semantic; `ModelRequests::WireLowering` owns the provider spelling.
    def request_options
      values.to_h { |name, value| [name, request_value(value)] }
    end

    private

      def serialized_value(value)
        case value
        when OutputFormat
          value.to_h
        when String, Integer, Float, true, false, nil
          value
        else
          raise ArgumentError, "unsupported generation value: #{value.class}"
        end
      end

      def request_value(value)
        case value
        when OutputFormat
          value.request_options
        when String, Integer, Float, true, false, nil
          value
        else
          raise ArgumentError, "unsupported request value: #{value.class}"
        end
      end
  end
end
