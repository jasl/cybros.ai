module ContentUploads
  # The one door bytes come in through: the bound is enforced here or
  # nowhere, and the bytes are the only authority on what they are — no
  # filename or declared-type hints reach Marcel.
  class Create
    Result = Data.define(:upload, :refusal) do
      def self.accepted(upload) = new(upload: upload, refusal: nil)
      def self.refused(refusal) = new(upload: nil, refusal: refusal)

      def accepted? = refusal.nil?
    end

    REFUSAL = :content_too_large
    FALLBACK_BASE = "upload".freeze

    def self.call(...) = new(...).call

    # `creator` is a member (the member and session doors) or an executor
    # (the executor plane's captures): whoever it is, its
    # `content_upload_anchor` is the one write that names it — never an
    # `is_a?` branch here.
    def initialize(account:, creator:, file:)
      @account = account
      @creator = creator
      @file = file
    end

    def call
      # BEFORE the second full copy: Rack has already streamed the request to a
      # tempfile, so this refuses without ever handing those bytes to storage.
      return Result.refused(REFUSAL) unless
        Nexus::SizeBounds.bytes_within?(:upload_bound, @file.size)

      content_type = detected_content_type
      # Blob first, row second, no transaction: an interrupted ingest leaves
      # an unattached blob, which `SweepUnattachedBlobsJob` already reclaims.
      blob = ActiveStorage::Blob.create_and_upload!(
        io: rewound, filename: derived_filename(content_type),
        content_type: content_type, identify: false
      )
      Result.accepted(
        @account.content_uploads.create!(**@creator.content_upload_anchor, file: blob)
      )
    end

    private

      def rewound
        @file.tempfile.tap(&:rewind)
      end

      def detected_content_type
        Marcel::MimeType.for(rewound)
      end

      # The extension is part of the wire (OpenAI refuses the same WAV bytes
      # as `.mp3`); the caller's wins when it agrees with the detected type,
      # since a type has several and only the caller knows which it meant.
      def derived_filename(content_type)
        name = ActiveStorage::Filename.new(@file.original_filename.to_s)
        # Ordinary files retain the caller's filename for workspace tools
        # (a .docx container, a .py source file). Its extension is not MIME
        # evidence. Detected media and PDFs need a provider-compatible extension.
        return name.to_s.presence || FALLBACK_BASE unless
          content_type.start_with?("audio/", "image/", "video/") || content_type == "application/pdf"

        base = name.base.presence || FALLBACK_BASE
        known = Marcel::TYPE_EXTS[content_type]
        return "#{base}.#{name.extension}" if known&.include?(name.extension&.downcase)

        first = known&.first
        first ? "#{base}.#{first}" : base
      end
  end
end
