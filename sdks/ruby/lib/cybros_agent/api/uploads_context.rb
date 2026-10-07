module CybrosAgent
  module Api
    # THE STAGING BODY the two ingest contexts share: one
    # multipart part on whichever door the context names (`ingest_path`).
    module UploadStaging
      include UploadProjections

      # The server decides the stored type from the bytes, so the part declares
      # the neutral one. A guess here would be a claim the server is right to
      # ignore, and the caller would read back a different answer than they
      # sent.
      NEUTRAL_MEDIA = "application/octet-stream".freeze

      # THE PART SHAPE THE ENCODER READS FIRST, and the only one that is safe
      # for every source. httpx's part builder takes an object answering
      # `read`/`filename`/`content_type` as-is; a Hash whose `:body` is an IO
      # WITHOUT a `path` falls through to `StringIO.new(value.to_s)`, which
      # uploads the object's inspect string instead of its bytes. A File
      # happens to have a path and survives that; a StringIO does not. Naming
      # the three members leaves nothing to happen to be true.
      Part = Data.define(:io, :filename, :byte_size) do
        def read(*args) = io.read(*args)
        def content_type = NEUTRAL_MEDIA
        # The encoder sums every part's `size` to declare Content-Length
        # before it reads a byte, which is what lets the body stream instead
        # of being measured by building it.
        def size = byte_size
      end

      # Takes a path and owns the handle it opens, so a caller cannot leak one
      # by forgetting.
      def create(path)
        File.open(path, "rb") { |io| create_io(io, filename: File.basename(path)) }
      end

      # For bytes a caller already holds. The IO is theirs to close — that is
      # the ordinary Ruby division of who opened what. Uploading begins at the
      # IO's current position, so Content-Length names exactly the remaining
      # bytes rather than the original whole stream.
      def create_io(io, filename:)
        remaining = [io.size - io.pos, 0].max
        part = Part.new(io: io, filename: filename, byte_size: remaining)
        answer = @dispatch.call(
          ingest_path,
          method: :post,
          form: { upload: { file: part } },
          success: 201
        )
        shape(Upload, answer, "upload")
      end
    end

    # Staging binary input for a later InferenceRequest to name (Agent API v1
    # `/uploads`). One upload, one request, and the bytes are streamed rather
    # than read into memory: what reaches the transport is something to read
    # FROM, and httpx's multipart encoder pulls it in chunks.
    #
    # An upload belongs to the (Account, creator) pair the credential resolves
    # to, which is the same scope a InferenceRequest binds from. There is no list and no
    # delete: staged bytes nothing names are reclaimed on their own.
    class UploadsContext
      include UploadStaging

      PATH = "/agent_api/v1/uploads".freeze

      def initialize(dispatch:)
        @dispatch = dispatch
      end

      def fetch(public_id)
        shape(Upload, @dispatch.call("#{PATH}/#{public_id}"), "upload")
      end

      # THE ONE BYTES READ: the upload's bytes streamed INTO
      # `io` — any upload this credential may read: its own staged rows, an
      # attachment of a conversation it reads, a capture a result it reads
      # names. A `range` (`"bytes=0-1023"`) asks for the slice and the
      # server answers 206 — HTTP's own chunked read, no second
      # vocabulary. Answers an `AttachmentRead` (the status and the strong
      # ETag); the bytes are in the IO. An `etag:` from an earlier read
      # makes it conditional: the upload is immutable, so a
      # matching tag is `unchanged?` (304) with nothing written — a typed
      # answer, never an exception.
      def bytes(public_id, io, range: nil, etag: nil)
        headers = {}
        headers["Range"] = range unless range.nil?
        attachment_read("#{PATH}/#{public_id}/bytes", io, success: range.nil? ? 200 : 206, etag: etag, headers: headers)
      end

      # THE TWO NAMED REPRESENTATION READS: a picture of the upload
      # for a UI — the thumbnail bounded at 256 px on its longest edge, the
      # preview at 1600 — presets the server names; whole, no `range:`.
      # The same rule and the same conditional read as `bytes`; an upload
      # with no representation of that kind (a text file, a PDF on a host
      # without poppler) is `NotFound` with the code
      # `representation_unavailable`, and nothing is written.
      def thumbnail(public_id, io, etag: nil)
        attachment_read("#{PATH}/#{public_id}/thumbnail", io, success: 200, etag: etag)
      end

      def preview(public_id, io, etag: nil)
        attachment_read("#{PATH}/#{public_id}/preview", io, success: 200, etag: etag)
      end

      private

        def ingest_path = PATH

        # `If-None-Match` is sent only with a tag, and the 304 is accepted
        # only then: a server answering 304 to an unconditional read is
        # malformed, as a 200 to a `Range` read is.
        def attachment_read(path, io, success:, etag:, headers: {})
          headers = headers.merge("If-None-Match" => etag) unless etag.nil?
          accepted = etag.nil? ? success : [success, 304]
          response = @dispatch.download(path, headers: headers, sink: io, success: accepted)
          AttachmentRead.new(status: response.status, etag: response.etag)
        end
    end

    # THE EXECUTOR PLANE'S CAPTURES: a runner stages a file it
    # wants a client to fetch — a screenshot, a file's bytes — as ITS OWN,
    # then names it with a `resource_link` block in its commit
    # (`ResourceLink#to_h`). No `fetch` and no bytes read: nothing on this
    # plane reads a capture back; the member plane serves it to a reader of
    # the result that names it.
    class ExecutorUploadsContext
      include UploadStaging

      PATH = "/agent_api/v1/executor/uploads".freeze

      def initialize(dispatch:)
        @dispatch = dispatch
      end

      private

        def ingest_path = PATH
    end
  end
end
