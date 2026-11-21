# Descriptor for a bound attachment under an active executor claim.
# @auth [ExecutorBearer]
class AgentAPI::V1::Executors::AttachmentsController < AgentAPI::V1::Executors::Attachments::BaseController
  # @oas_include
  # @summary Read attachments
  # @tags Executor, attachments
  # @parameter run_public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @parameter task_key(path) [!String] Resource selector.
  # @parameter upload_public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @parameter_ref #/components/parameters/ClaimToken
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  # @response_ref (200) #/components/responses/AgentApiV1ExecutorsAttachmentsShow
  def show
    render json: { upload: AgentAPI::UploadPresenter.full(attachment(params.fetch(:upload_public_id))) }
  end
end
