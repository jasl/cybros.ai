require "bigdecimal"

module SimpleInference
  class ExecutionProfile
    # The validators every profile fact shares: closed vocabularies, identity
    # strings, finite numbers, and the one ingestion seam that turns a
    # keyword Ruby does not know into the gem's ConfigurationError.
    module Facts
      module_function

      # `hash` is the catalog's declaration (or an already-built value); an
      # unknown or missing keyword is a configuration error named by `label`.
      def ingest(klass, hash, label:, **context)
        klass.new(**hash.to_h.transform_keys(&:to_sym), **context)
      rescue ArgumentError => e
        raise SimpleInference::ConfigurationError, "#{label} #{e.message}"
      end

      def identity(value, field:)
        text = value.to_s
        if text.empty? || text != text.strip
          raise SimpleInference::ConfigurationError,
                "#{field} must be a non-blank String without surrounding whitespace"
        end

        -text
      end

      def member(value, vocabulary, field:)
        text = value.to_s
        unless vocabulary.include?(text)
          raise SimpleInference::ConfigurationError,
                "#{field} #{value.inspect} is not in the closed vocabulary (#{vocabulary.join(", ")})"
        end

        -text
      end

      def closed_list(values, vocabulary, field:)
        unless values.is_a?(Array)
          raise SimpleInference::ConfigurationError, "#{field} must be an Array"
        end

        normalized = values.map(&:to_s)
        unknown = normalized - vocabulary
        unless unknown.empty?
          raise SimpleInference::ConfigurationError,
                "#{field} contains unknown value(s): #{unknown.join(", ")} (known: #{vocabulary.join(", ")})"
        end

        if normalized.uniq.length != normalized.length
          raise SimpleInference::ConfigurationError, "#{field} contains duplicate values"
        end

        normalized.map { |entry| -entry }.freeze
      end

      def identity_list(values, field:)
        unless values.is_a?(Array)
          raise SimpleInference::ConfigurationError, "#{field} must be an Array"
        end

        normalized = values.map do |value|
          unless value.is_a?(String) && !value.empty? && value == value.strip
            raise SimpleInference::ConfigurationError,
                  "#{field} values must be non-blank Strings without surrounding whitespace"
          end

          -value
        end
        if normalized.uniq.length != normalized.length
          raise SimpleInference::ConfigurationError, "#{field} contains duplicate values"
        end

        normalized.freeze
      end

      def positive_integer(value, field:)
        return value if value.is_a?(Integer) && value.positive?

        raise SimpleInference::ConfigurationError, "#{field} must be a positive Integer (got #{value.inspect})"
      end

      # A real number: Integer, Rational or Float, finite.
      def finite_number?(value)
        value.is_a?(Numeric) && !value.is_a?(Complex) && value.finite?
      end

      def immutable(value)
        value.is_a?(String) ? -value : value
      end
    end
  end
end
