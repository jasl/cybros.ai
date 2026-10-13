# THE ONE INGEST BODY behind three doors: the session door (`/uploads`),
# the member plane's (`/agent_api/v1/uploads`) and the executor plane's
# captures (`/agent_api/v1/executor/uploads`) differ in the plane and the
# creator alone — each supplies its principal and nothing else. One part
# `upload[file]`, the bytes decide the type (`ContentUploads::Create`),
# `upload_bound` at the door, `201` with the staged descriptor, `413`
# over the bound. No lock rung: the row is created, never locked.
module UploadIngest
  extend ActiveSupport::Concern

  private

    def ingest_upload(account:, creator:)
      fields = params.expect(upload: [:file])
      # Asked by conversion, not inspection: `IO.try_convert` answers `to_io` or
      # nil, so the boundary turns an unknown into a known without a class probe.
      raise APIErrors::ParameterInvalid, :file if IO.try_convert(fields[:file]).nil?

      result = ContentUploads::Create.call(account: account, creator: creator, file: fields[:file])
      if result.accepted?
        render json: { upload: AgentAPI::UploadPresenter.full(result.upload) }, status: :created
      else
        render_error(result.refusal, "The upload exceeds its size bound", status: :content_too_large)
      end
    end
end
