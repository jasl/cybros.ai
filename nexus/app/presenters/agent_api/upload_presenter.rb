module AgentAPI
  # `content_type` is the model's normalized spelling so a caller reads the
  # vocabulary the catalog's `input_modalities` speak; `filename` rides because
  # the provider reads its extension — `clip.mp3` back as `clip.wav` is a truth about the bytes.
  module UploadPresenter
    module_function

    def full(upload)
      {
        public_id: upload.public_id,
        filename: upload.filename.to_s,
        content_type: upload.content_type,
        byte_size: upload.byte_size,
        created_at: upload.created_at.utc,
      }
    end
  end
end
