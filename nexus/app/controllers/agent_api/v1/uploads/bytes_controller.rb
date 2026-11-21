# GET /agent_api/v1/uploads/{public_id}/bytes — THE ONE BYTES READ, proxied
# never redirected (a signed blob URL is a global bearer token), through
# the framework's own `ActiveStorage::Streaming` — a `Range` answers 206
# and the slice (THE chunked read, HTTP's own), a whole read carries
# `Accept-Ranges` — the InferenceRequest files door's shape. Scoped by the upload's
# OWN rule (`ContentUpload#readable_by?`): its creator, or a reader of a
# row that NAMES it — a conversation input's or a loop step's attachment, a
# tool result's capture, a sealed request's placed picture, a InferenceRequest's
# input — judged through the funnel that row's own read uses. Absent,
# foreign, fileless and unreadable answer 404 alike: no oracle. The
# conditional GET is `AttachmentRead`'s: the strong ETag of this kind, a
# 304 before streaming.
# @auth [MemberBearer]
class AgentAPI::V1::Uploads::BytesController < AgentAPI::V1::BaseController
  include AgentAPI::V1::Uploads::AttachmentRead

  # @oas_include
  # @summary Read bytes
  # @tags Member, bytes
  # @parameter upload_public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @response_ref (200) #/components/responses/AgentApiV1UploadsBytesShow
  # @response_ref (206) #/components/responses/AgentApiV1UploadsBytesShow
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
    send_upload_bytes
  end
end
