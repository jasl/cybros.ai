module SimpleInference
  # Byte-truth media-type detection. The detected type comes from magic
  # numbers only — never a caller-asserted content type, filename, or URL.
  # Unknown bytes detect as nil and the caller fails closed.
  module MediaType
    IMAGE_TYPES = %w[image/png image/jpeg image/webp image/gif image/heic image/heif].freeze
    AUDIO_TYPES = %w[audio/wav audio/flac audio/ogg audio/mpeg audio/mp4 audio/webm].freeze
    FILE_TYPES = %w[application/pdf].freeze
    KNOWN_TYPES = (IMAGE_TYPES + AUDIO_TYPES + FILE_TYPES).freeze

    HEIC_BRANDS = %w[heic heix hevc heim heis hevm hevs].freeze
    HEIF_BRANDS = %w[mif1 msf1 heif].freeze
    MP4_AUDIO_BRANDS = ["M4A ", "M4B ", "isom", "iso2", "mp41", "mp42"].freeze

    module_function

    def detect(bytes)
      return nil unless bytes.is_a?(String)
      return nil if bytes.empty?

      head = bytes.byteslice(0, 32).to_s.b

      return "application/pdf" if head.start_with?("%PDF-".b)
      return "image/png" if head.start_with?("\x89PNG\r\n\x1a\n".b)
      return "image/jpeg" if head.start_with?("\xFF\xD8\xFF".b)
      return "image/gif" if head.start_with?("GIF87a".b, "GIF89a".b)
      return "image/webp" if head.start_with?("RIFF".b) && head.byteslice(8, 4) == "WEBP".b
      return "audio/wav" if head.start_with?("RIFF".b) && head.byteslice(8, 4) == "WAVE".b
      return "audio/flac" if head.start_with?("fLaC".b)
      return "audio/ogg" if head.start_with?("OggS".b)
      return "audio/mpeg" if head.start_with?("ID3".b) || mp3_frame_sync?(head)
      return "audio/webm" if head.start_with?("\x1AE\xDF\xA3".b)

      iso_bmff_type(head)
    end

    def audio?(media_type) = AUDIO_TYPES.include?(media_type)

    def mp3_frame_sync?(head)
      first = head.getbyte(0)
      second = head.getbyte(1)
      !first.nil? && !second.nil? && first == 0xFF && second.anybits?(0xE0)
    end

    def iso_bmff_type(head)
      return nil unless head.byteslice(4, 4) == "ftyp".b

      brand = head.byteslice(8, 4).to_s
      return "image/heic" if HEIC_BRANDS.include?(brand.strip)
      return "image/heif" if HEIF_BRANDS.include?(brand.strip)
      return "audio/mp4" if MP4_AUDIO_BRANDS.include?(brand)

      nil
    end
  end
end
