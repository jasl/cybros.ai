require "json"
require "digest"

module Nexus
  # One canonical serialization behind every structured-payload byte measurement: keys
  # codepoint-sorted, no insignificant whitespace, raw UTF-8, so insertion order never changes a size
  # verdict. Exponent floats are refused: jsonb may expand them.
  module CanonicalJson
    # A value JSON can spell but this substrate cannot carry; callers rescue
    # the parent into their own typed rejection, the leaves name the limit.
    class UnsupportedValue < ArgumentError; end
    class UnsupportedNumber < UnsupportedValue; end
    class UnsupportedText < UnsupportedValue; end
    # Depth is a substrate limit like the others: a raw `JSON::NestingError`
    # escaping here would be a 500 out of the boundary that answers "can this be stored".
    class UnsupportedDepth < UnsupportedValue; end

    # PostgreSQL text and jsonb cannot store U+0000; refusing it here beats the
    # INSERT aborting an enclosing transaction, and wire JSON produces it legitimately.
    UNSTORABLE_CODEPOINT = "\u0000".freeze
    UNSTORABLE_CODEPOINT_REFUSAL = "a string carrying U+0000 cannot be stored: remove it before submitting".freeze

    class << self
      def encode(value)
        JSON.generate(normalize(value))
      rescue JSON::NestingError => error
        raise UnsupportedDepth, "structure is nested too deeply to store: #{error.message}"
      end

      def bytesize(value)
        encode(value).bytesize
      end

      def digest(value)
        Digest::SHA256.hexdigest(encode(value))
      end

      def normalize(value)
        canonicalize(value)
      end

      # Whether the row store can hold `value`: a number or text the encoder
      # refuses — U+0000 among the text — answers false, so the step compiler
      # makes it a typed refusal rather than an INSERT-time 500.
      def storable?(value) = storage_refusal(value).nil?

      # Why the row store cannot hold `value`, in the encoder's own words, or
      # nil when it can — for a caller that hands the reason to whoever sent
      # the value. The check on the encoded bytes also refuses the six
      # characters `\u0000` written as text, which jsonb holds: an
      # over-refusal kept as it stands, and worded as the codepoint's.
      def storage_refusal(value)
        UNSTORABLE_CODEPOINT_REFUSAL if encode(value).include?("\\u0000")
      rescue UnsupportedNumber, UnsupportedText => error
        error.message
      end

      private

        # JSON-legal and still unstorable: U+0000, and invalid UTF-8 (which the
        # generator refuses outside this family). One exception kind for both.
        def storable_text(value)
          if value.include?(UNSTORABLE_CODEPOINT)
            raise UnsupportedText, UNSTORABLE_CODEPOINT_REFUSAL
          end
          unless value.valid_encoding?
            raise UnsupportedText, "a string that is not valid UTF-8 cannot be stored"
          end

          value
        end

        def canonicalize(value)
          case value
          when Hash
            canonicalize_object(value)
          when Array
            value.map { |element| canonicalize(element) }
          when String
            storable_text(value)
          when Integer, true, false, nil
            value
          when Float
            unless value.finite?
              raise UnsupportedNumber, "not a supported JSON number: encode it as a string"
            end

            if value.zero?
              value = 0.0
            end

            token = JSON.generate(value)
            if token.match?(/[eE]/)
              raise UnsupportedNumber,
                "exponent-form JSON numbers are unsupported: encode the value as a string"
            end

            value
          else
            raise UnsupportedValue, "not a JSON value: #{value.class}"
          end
        end

        # A key is stored text too: jsonb rejects U+0000 wherever it appears.
        def canonicalize_object(object)
          object.each_key do |key|
            unless key.is_a?(String)
              raise UnsupportedValue, "JSON object keys must be Strings: #{key.class}"
            end

            storable_text(key)
          end

          object.sort_by { |key, _element| key }
            .to_h { |key, element| [key, canonicalize(element)] }
        end
    end
  end
end
