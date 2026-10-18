require_relative "media_type"

module SimpleInference
  # The one media ingress value: raw bytes and their normalized media type.
  #
  # Paths, URLs, data URIs, provider file handles, and caller-asserted types
  # that disagree with the bytes are all loud typed rejections. The public
  # raw-byte boundary detects the type once. Internal callers that
  # already own normalized storage bytes construct the value directly and the
  # protocol layers trust it.
  class MediaInput
    CARRIER_PREFIXES = ["data:", "http://", "https://", "/", "./", "../", "~/"].freeze

    attr_reader :media_type, :byte_size, :source

    def self.from_bytes(bytes, declared_media_type: nil)
      bytes = String.try_convert(bytes)
      if bytes.nil?
        raise SimpleInference::ValidationError,
              "media input must be raw bytes"
      end

      if carrier_string?(bytes)
        raise SimpleInference::ValidationError,
              "media input must be raw bytes, not a path, URL, or data URI " \
              "(got #{bytes.byteslice(0, 32).inspect}...)"
      end

      if bytes.empty?
        raise SimpleInference::ValidationError, "media input bytes are empty"
      end

      detected = MediaType.detect(bytes)
      if detected.nil?
        raise SimpleInference::ValidationError,
              "media input bytes match no supported media type (byte-truth detection found nothing)"
      end

      if declared_media_type && declared_media_type != detected
        raise SimpleInference::ValidationError,
              "declared media type #{declared_media_type.inspect} does not match the bytes " \
              "(detected #{detected.inspect}); byte truth wins and mismatches are rejected"
      end

      new(bytes: bytes, media_type: detected)
    end

    def self.carrier_string?(value)
      head = value.byteslice(0, 512).to_s
      return false unless head.dup.force_encoding(Encoding::UTF_8).valid_encoding?

      CARRIER_PREFIXES.any? { |prefix| head.start_with?(prefix) }
    end

    def initialize(media_type:, bytes: nil, source: nil, byte_size: nil)
      @held = bytes
      @source = source
      @media_type = -media_type
      @byte_size = byte_size || bytes.bytesize

      freeze
    end

    def streamed? = !@source.nil?

    # LOUDLY, NEVER SILENTLY. The lanes that inline media base64-encode these
    # bytes into a JSON body, so they genuinely need them all at once — and a
    # streamed input handed to one of them is an authoring mistake, not a case
    # to paper over by quietly materializing what streaming exists to avoid.
    def bytes
      return @held unless streamed?

      raise SimpleInference::ValidationError,
            "this media input is streamed (#{@byte_size} bytes); read it through #source, or " \
            "build it with from_bytes if the lane must hold it whole"
    end
  end
end
