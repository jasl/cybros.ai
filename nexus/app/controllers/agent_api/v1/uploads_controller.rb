# POST /agent_api/v1/uploads and GET.../:public_id — authorization, bounded
# streaming and orphan cleanup, nothing more. No idempotency key (a repeat
# POST is a second upload). The ingest is `UploadIngest`'s, shared with the
# session door and the executor plane's captures; the descriptor read is
# creator-scoped; the BYTES read is `Uploads::BytesController`'s, by the
# upload's own rule.
# @auth [MemberBearer]
class AgentAPI::V1::UploadsController < AgentAPI::V1::BaseController
  include UploadIngest

  serves_plane :member

  # @oas_include
  # @request_body_ref #/components/requestBodies/AgentApiV1UploadsCreate
  # @summary Create uploads
  # @tags Member, uploads
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  # @response_ref (201) #/components/responses/AgentApiV1UploadsCreate
  def create
    ingest_upload(account: acting_user.account, creator: acting_user)
  end

  # @oas_include
  # @summary Read uploads
  # @tags Member, uploads
  # @parameter public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  # @response_ref (200) #/components/responses/AgentApiV1UploadsShow
  def show
    render_upload(staged.find_by!(public_id: params.fetch(:public_id)))
  end

  private

    # CREATOR-SCOPED, exactly as binding is. A read that could see another
    # member's upload would be a boundary the bind path does not have.
    def staged
      acting_user.account.content_uploads.where(creating_user: acting_user).with_attached_file
    end

    def acting_user
      current_credential.user
    end

    def render_upload(upload, status: :ok)
      render json: { upload: AgentAPI::UploadPresenter.full(upload) }, status: status
    end
end
