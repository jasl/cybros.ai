module CybrosAgent
  module Api
    # A staged upload, as the server describes it back.
    #
    # `content_type` and `filename` are the SERVER'S, not the caller's: the
    # bytes decide the type, and the extension follows that decision. A caller
    # who staged `clip.mp3` and reads back `clip.wav` has been told something
    # true about their own file.
    Upload = Data.define(:public_id, :filename, :content_type, :byte_size, :created_at)

    # WHAT AN ATTACHMENT READ ANSWERS: the status the
    # server chose (200 whole, 206 a `Range`'s slice, 304 unchanged) and
    # the strong `etag` it carried — the validator a later read hands back
    # as `etag:`. The bytes are in the caller's IO; on `unchanged?` nothing
    # was written to it.
    AttachmentRead = Data.define(:status, :etag) do
      def unchanged? = status == 304
    end

    module UploadProjections
      include Parsing

      SHAPES = {
        Upload => {
          public_id: :string, filename: :string, content_type: :string, byte_size: :integer, created_at: :string,
        },
      }.freeze
    end
  end
end
