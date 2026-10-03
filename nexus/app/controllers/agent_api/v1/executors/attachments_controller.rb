# Descriptor for a bound input attachment under an active executor claim.
class AgentAPI::V1::Executors::AttachmentsController < AgentAPI::V1::Executors::Attachments::BaseController
  def show
    render json: { upload: AgentAPI::UploadPresenter.full(attachment(params.fetch(:upload_public_id))) }
  end
end
