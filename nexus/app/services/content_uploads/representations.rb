module ContentUploads
  # THE ONE REPRESENTATION TABLE: three named
  # entries over Active Storage's own `blob.representation` — a variant
  # for an image (`variable?`, image_processing on libvips), a preview
  # for a PDF or a video (`ActiveStorage.previewers`: poppler's `pdftoppm`,
  # ffmpeg — a host without the tool has no previewer, so the blob has no
  # representation of that kind, and the read answers the typed refusal,
  # never a crash). Two entries are the member plane's named reads
  # (`GET /agent_api/v1/uploads/{id}/thumbnail` and `/preview`); the third
  # is the model-facing prepared variant processed once
  # (`ModelRequests::UploadMedia`), bounded by the lane's own
  # `max_dimension` and reached by the assembly, never by a route. Named
  # presets in code only — a client never supplies a transformation.
  #
  # An upload is immutable, so a representation is content-addressed by
  # its source and its bound: Active Storage's variant tracking makes the
  # second read of one kind a lookup, never a second render.
  module Representations
    # The longest edge, in pixels, of each named read.
    THUMBNAIL = 256
    PREVIEW = 1600
    NAMED = { "thumbnail" => THUMBNAIL, "preview" => PREVIEW }.freeze

    module_function

    # Active Storage's own answer, per blob and per host: an image is
    # variable; a PDF or a video is previewable exactly when a previewer
    # accepts it, which is where the tool's presence is decided. Nothing
    # else (a text file, an audio clip) has a representation of any kind.
    def available?(blob) = blob.representable?

    def thumbnail(blob) = processed(blob, THUMBNAIL)

    def preview(blob) = processed(blob, PREVIEW)

    # The assembly's entry: the lane's bound, the same mechanism.
    def prepared(blob, dimension) = processed(blob, dimension)

    # The processed representation bounded by `dimension` on its longest
    # edge — always a `VariantWithRecord`, answering `content_type`,
    # `filename`, `download` and `image.blob` (the tracked record's own
    # attachment: the bounded bytes' blob, what the reads stream with
    # `send_blob_stream`) — rendered on the first call, found on every
    # later one. A variable blob (an image) is its variant outright; for a
    # previewable one (a PDF, a video) Active Storage answers a `Preview`,
    # whose `image` is the page render at its NATURAL size and whose bounded
    # bytes are a tracked variant of that image one level down (`Preview#download` streams that variant) — the table hands back that variant,
    # so every entry has the one shape. A blob with no representation raises
    # `ActiveStorage::UnrepresentableError`: callers ask `available?` first.
    def processed(blob, dimension)
      representation = blob.representation(resize_to_limit: [dimension, dimension]).processed
      return representation if blob.variable?

      representation.image.variant(representation.variation).processed
    end
  end
end
