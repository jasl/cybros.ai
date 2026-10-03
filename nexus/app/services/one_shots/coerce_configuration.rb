module OneShots
  # The one seam between wire JSON and the generation-parameter grammar,
  # which judges symbol-keyed hashes so a request body cannot forge its
  # shape. `schema` stays opaque String-keyed JSON. Coerces, never decides.
  class CoerceConfiguration
    OPAQUE = "schema".freeze

    class << self
      def call(configuration)
        symbolized(configuration) { |name, value| [name, coerce_value(name, value)] }
      end

      private

        def coerce_value(name, value)
          return value if name.to_s == OPAQUE

          attributes = Hash.try_convert(value)
          return value if attributes.nil?

          # One level deeper is where an output format's own members live; its
          # `schema` stops the recursion by the rule above.
          symbolized(attributes) { |member, element| [member, coerce_value(member, element)] }
        end

        # Parameter names are normalized once at this wire seam. JSON object
        # keys are strings; `to_s` also keeps direct domain callers on the
        # same path without a second String-or-Symbol type question.
        def symbolized(value)
          attributes = Hash.try_convert(value)
          return value if attributes.nil?

          attributes.to_h { |key, element| yield(key.to_s.to_sym, element) }
        end
    end
  end
end
