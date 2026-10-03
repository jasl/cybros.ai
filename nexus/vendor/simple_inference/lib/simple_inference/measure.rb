module SimpleInference
  # Canonical pre-IO measurers (frozen conservative metrics).
  #
  # `characters` is the Unicode scalar-value count. The token-conservative
  # proxy is the UTF-8 byte count: byte-level BPE consumes at least one byte
  # per token, so bytes bound tokens from above — scalar counts do NOT (one
  # emoji is one scalar but may be several tokens). Enforcing a token bound
  # therefore measures bytes, never scalars.
  module Measure
    module_function

    def unicode_scalar_count(text)
      ensure_valid_utf8(text)
      text.each_char.count
    end

    def utf8_byte_count(text)
      ensure_valid_utf8(text)
      text.bytesize
    end

    # The zero-IO preflight: passing at the cap and rejecting cap + 1 is the
    # deterministic half of every bound's evidence pair.
    def ensure_within(value:, cap:, bound_id:, unit:)
      return value if value <= cap

      raise SimpleInference::BoundExceededError,
            "#{bound_id}: #{value} #{unit} exceeds the selectable cap of #{cap} #{unit}"
    end

    def ensure_valid_utf8(text)
      unless text.is_a?(String)
        raise SimpleInference::ValidationError, "expected a String to measure (got #{text.class})"
      end

      encoded = text.encoding == Encoding::UTF_8 ? text : text.encode(Encoding::UTF_8)
      return if encoded.valid_encoding?

      raise SimpleInference::ValidationError, "text is not valid UTF-8"
    rescue Encoding::UndefinedConversionError, Encoding::InvalidByteSequenceError
      raise SimpleInference::ValidationError, "text is not valid UTF-8"
    end
  end
end
