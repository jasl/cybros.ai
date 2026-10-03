module ModelRequests
  # The one crossing from storage truth to provider preparation.
  # Preparation is an Active Storage representation, which shares and
  # caches the prepared variant — the third entry of the one
  # representation table (`ContentUploads::Representations.prepared`),
  # bounded by the lane's own `max_dimension` and reached here, never by
  # a route.
  module UploadMedia
    # The bytes could not be turned into something this lane accepts. A
    # preparation failure discovered after acceptance terminalizes the work
    # with typed evidence and never silently drops the media.
    class Unpreparable < StandardError; end

    class << self
      # Each distinct upload is prepared once. `streamed:` is the lane's
      # question: a multipart lane streams its part, every other lane holds
      # the bytes whole, and handing one a stream is a loud refusal.
      def by_public_id(uploads, input_media:, streamed: false)
        uploads.uniq(&:public_id).to_h do |upload|
          [upload.public_id, prepare(upload, input_media, streamed: streamed)]
        end
      end

      def prepare(upload, input_media, streamed: false)
        facts = facts_for(upload, input_media)
        dimension = facts.max_dimension
        # A resize has to decode the whole image to produce one, so a resized
        # lane holds bytes whatever the wire is.
        return resized(upload, facts, dimension) unless dimension.nil?
        return streamed_from(upload) if streamed

        pass_through(upload)
      end

      private

        # The first allowlist that claims this upload's type. Agrees with
        # acceptance because every shipped profile declares one input modality;
        # two overlapping ones would fail closed here rather than differ silently.
        def facts_for(upload, input_media)
          _modality, facts = input_media.find do |_name, declared|
            declared.mime_allowlist.include?(upload.content_type)
          end
          return facts if facts

          raise Unpreparable,
            "upload #{upload.public_id} is #{upload.content_type}, which this lane's input media " \
            "declares no allowlist for"
        end

        def pass_through(upload)
          media_input(upload.file.download, upload.content_type)
        end

        # Read from storage as written to the socket, never whole.
        # Constructed, not sniffed: the media type is Active Storage's.
        # `download` with a block streams; `open` would stage a tempfile.
        def streamed_from(upload)
          blob = upload.file.blob
          SimpleInference::MediaInput.new(
            source: ->(&chunk) { blob.download(&chunk) },
            byte_size: blob.byte_size,
            media_type: upload.content_type
          )
        end

        # The representation's OWN type and bytes, never the source's — the
        # re-encode is what the lane is handed, and labelling it with the
        # upload's type would be a lie about the wire.
        def resized(upload, facts, dimension)
          representation = processed(upload, dimension)
          unless facts.mime_allowlist.include?(representation.content_type)
            raise Unpreparable,
              "preparing #{upload.public_id} produced #{representation.content_type}, which this lane does " \
              "not accept"
          end

          media_input(representation.download, representation.content_type)
        end

        # Broad on purpose, narrow in reach: three libraries raise their own
        # families (`Vips::Error` may not even be defined), every one means
        # "could not be prepared", and the guarded expression is one call.
        # A blob with no representation of any kind (`representable?` false:
        # a type no variant and no previewer takes) keeps Active Storage's
        # own word, as a vanished file does.
        def processed(upload, dimension)
          ContentUploads::Representations.prepared(upload.file.blob, dimension)
        rescue ActiveStorage::UnrepresentableError, ActiveStorage::FileNotFoundError
          raise
        rescue StandardError => error
          raise Unpreparable,
            "preparing #{upload.public_id} failed: #{error.class}: #{error.message}"
        end

        def media_input(bytes, media_type)
          SimpleInference::MediaInput.new(bytes: bytes, media_type: media_type)
        end
    end
  end
end
