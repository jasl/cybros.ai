module ContentBodies
  # The shared composer of a person's message with file attachments:
  # words then attachments in the order given, as ONE `{role, parts}` entry
  # in the InferenceRequest's own grammar — the same shape `CoerceTextMessages`
  # reads — plus the rows the body will bind for liveness through the
  # keyless join, and the words the writer hands `Replace` as
  # `readable_text` (`""` for a file with no words). Both input doors
  # (a conversation's, a standalone loop's) and the loop's model step
  # compose through here, so the three agree byte for byte.
  #
  # Resolution is creator-scoped (`ContentUploads::ResolveReferences`),
  # whole or nothing, and PINS the rows for the caller's transaction so the
  # orphan reaper cannot take one between the read and the join. Assembly
  # places supported images and PDFs natively and indexes unsupported PDFs
  # and other files; an executor reads those files through its claim's
  # attachment resources.
  class AttachedMessage
    Result = Data.define(:entries, :uploads, :readable_text, :refusal) do
      def self.refused(refusal) = new(entries: nil, uploads: nil, readable_text: nil, refusal: refusal)

      def accepted? = refusal.nil?
    end

    WORKLOAD = "text_generation".freeze
    # `attachments` rides beside `text`, never beside raw `entries`: the raw
    # grammar places its own parts.
    WITH_ENTRIES = :attachments_with_entries

    class << self
      # Classifies bound image rows from their byte-derived MIME type.
      # Round pairing uses the same predicate alongside its PDF check,
      # never the link's own `mimeType`, which is stored verbatim.
      def image?(upload)
        modality = upload.content_type.to_s.split("/").first
        ModelSelection::Workloads::Input::WORKLOAD_UPLOAD_MODALITIES.fetch(WORKLOAD).include?(modality)
      end

      # `text` (nil or blank = no words) and the canonical upload ids, in the
      # order they will occur.
      def compose(account:, creating_user:, text:, attachments:)
        new(account:, creating_user:).compose(text, attachments)
      end

      # Already-resolved rows, including a queued body's existing bindings.
      # Rebuilding the words does not re-author the files they retain.
      def from_uploads(text:, uploads:)
        if uploads.empty?
          entries = text.to_s.empty? ? [] : [{ "text" => text }]
          return Result.new(entries: entries, uploads: [], readable_text: nil, refusal: nil)
        end

        words = text.to_s
        parts = words.empty? ? [] : [{ "type" => Nexus::InputParts::TEXT, "text" => words }]
        parts += uploads.map { |upload| { "type" => Nexus::InputParts::UPLOAD, "upload_public_id" => upload.public_id } }
        Result.new(entries: [{ "role" => "user", "parts" => parts }],
          uploads: uploads, readable_text: words, refusal: nil)
      end

      # A raw entries list carrying `upload` parts binds what it placed
      # (`Input.placed_upload_public_ids`'s rule over the hashes): the
      # entries stand as written, the projection stays the writer's nil.
      def placed(account:, creating_user:, entries:)
        new(account:, creating_user:).placed(entries)
      end

      # The distinct upload ids a hash-shaped entries list places, in
      # first-occurrence order; the door reads them before it decides.
      def placed_ids(entries)
        Array(entries).flat_map do |entry|
          Array(Hash.try_convert(entry)&.fetch("parts", nil)).filter_map do |part|
            part = Hash.try_convert(part)
            part["upload_public_id"] if part && part["type"] == Nexus::InputParts::UPLOAD
          end
        end.uniq
      end

      # True for the door's own text shape — nothing, or one `{"text"}`
      # entry — the shape `attachments` may ride beside.
      def text_shaped?(entries)
        entries = Array(entries)
        entries.empty? || (entries.length == 1 && entries.sole.keys == ["text"])
      end
    end

    def initialize(account:, creating_user:)
      @account = account
      @creating_user = creating_user
    end

    def compose(text, attachments)
      ids = Array(attachments)
      return self.class.from_uploads(text: text, uploads: []) if ids.empty?

      resolved = resolve(ids)
      return resolved unless resolved.accepted?

      self.class.from_uploads(text: text, uploads: resolved.uploads)
    end

    def placed(entries)
      ids = self.class.placed_ids(entries)
      return Result.new(entries: entries, uploads: [], readable_text: nil, refusal: nil) if ids.empty?

      resolved = resolve(ids.map { |id| ContentUpload.canonical_public_id(id) })
      return resolved unless resolved.accepted?

      Result.new(entries: entries, uploads: resolved.uploads, readable_text: nil, refusal: nil)
    end

    private

      def resolve(ids)
        resolved = ContentUploads::ResolveReferences.call(
          account: @account, creator: @creating_user, public_ids: ids, lock: true
        )
        return Result.refused(resolved.refusal) unless resolved.accepted?
        Result.new(entries: nil, uploads: resolved.uploads, readable_text: nil, refusal: nil)
      end
  end
end
