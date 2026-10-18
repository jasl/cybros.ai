module Nexus
  # Prefix-parameterized replay-cursor codec: an opaque urlsafe token over the
  # durable sequence. The bytes are a public contract — a client that stores
  # cursors across deploys depends on them decoding forever.
  class ReplayCursor
    MalformedCursor = Class.new(StandardError)

    def initialize(prefix:)
      @prefix = prefix
    end

    def encode(sequence)
      Base64.urlsafe_encode64("#{@prefix}:#{sequence}", padding: false)
    end

    # Blank decodes to 0 — the start of the stream, not an error.
    def decode(value)
      return 0 if value.blank?

      decoded = Base64.urlsafe_decode64(value.to_s)
      prefix, sequence = decoded.split(":", 2)
      raise MalformedCursor unless prefix == @prefix

      integer = Integer(sequence.to_s, 10, exception: false)
      raise MalformedCursor if integer.nil? || integer.negative?

      integer
    rescue ArgumentError
      raise MalformedCursor
    end
  end
end
