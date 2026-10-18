class AgentAPI::V1::Executors::Attachments::BytesController < AgentAPI::V1::Executors::Attachments::BaseController
  include ActiveStorage::Streaming

  def show
    blob = attachment(params.fetch(:attachment_upload_public_id)).file.blob
    if request.headers["Range"].present?
      send_blob_byte_range_data blob, request.headers["Range"], disposition: "attachment"
    else
      response.headers["Accept-Ranges"] = "bytes"
      response.headers["Content-Length"] = blob.byte_size.to_s
      send_blob_stream blob, disposition: "attachment"
    end
  end
end
