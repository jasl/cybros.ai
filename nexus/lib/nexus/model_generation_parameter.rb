module Nexus
  ModelGenerationParameter = Data.define(
    :kind, :default, :minimum, :maximum, :allowed_values
  ) do
    def self.from_h(hash)
      kind = hash.fetch("kind").to_sym
      default = hash.fetch("default")
      if kind == :output_format && default
        # Both authored shapes normalize here: a catalog fragment writes the
        # bare type string ("text"), a serialized snapshot round-trips the
        # full mapping.
        default = case default
        when String then OutputFormat.new(type: default, name: nil, schema: nil, strict: nil)
        when Hash then OutputFormat.from_h(default)
        else raise ArgumentError, "output_format default must be a type string or a mapping, got #{default.class}"
        end
      end

      new(
        kind: kind,
        default: default,
        minimum: hash.fetch("minimum"),
        maximum: hash.fetch("maximum"),
        allowed_values: hash.fetch("allowed_values")
      )
    end

    def to_h
      {
        "kind" => kind.to_s,
        "default" => serialized_default,
        "minimum" => minimum,
        "maximum" => maximum,
        "allowed_values" => allowed_values,
      }
    end

    private

      def serialized_default
        case default
        when OutputFormat
          default.to_h
        when String, Integer, Float, true, false, nil
          default
        else
          raise ArgumentError, "unsupported generation default: #{default.class}"
        end
      end
  end
end
