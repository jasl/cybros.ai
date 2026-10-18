# Member and executor uploads share ingestion; each supplies its own principal.
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
