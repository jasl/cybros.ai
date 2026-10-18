module Nexus
  # One attachment occurrence in a message's part stream: a durable ContentUpload
  # reference and nothing else, at possibly several positions. It declares no modality
  # — this part says where, storage truth says what.
  UploadInputPart = Data.define(:type, :upload_public_id) do
    def self.from_h(hash)
      new(type: hash.fetch("type"), upload_public_id: hash.fetch("upload_public_id"))
    end

    def to_h
      { "type" => type, "upload_public_id" => upload_public_id }
    end
  end
end
