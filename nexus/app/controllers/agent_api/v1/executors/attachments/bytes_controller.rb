# @auth [ExecutorBearer]
class AgentAPI::V1::Executors::Attachments::BytesController < AgentAPI::V1::Executors::Attachments::BaseController
  include ActiveStorage::Streaming

  # @oas_include
  # @summary Read bytes
  # @tags Executor, bytes
  # @parameter attachment_upload_public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @parameter run_public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @parameter task_key(path) [!String] Resource selector.
  # @parameter_ref #/components/parameters/ClaimToken
  # @response_ref (200) #/components/responses/AgentApiV1ExecutorsAttachmentsBytesShow
  # @response_ref (206) #/components/responses/AgentApiV1ExecutorsAttachmentsBytesShow
  # @response_ref (304) #/components/responses/Empty
  # @response_ref (416) #/components/responses/RangeError
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
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
