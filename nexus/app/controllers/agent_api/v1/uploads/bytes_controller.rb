# GET /agent_api/v1/uploads/{public_id}/bytes — THE ONE BYTES READ, proxied
# never redirected (a signed blob URL is a global bearer token), through
# the framework's own `ActiveStorage::Streaming` — a `Range` answers 206
# and the slice (THE chunked read, HTTP's own), a whole read carries
# `Accept-Ranges` — the OneShot files door's shape. Scoped by the upload's
# OWN rule (`ContentUpload#readable_by?`): its creator, or a reader of a
# row that NAMES it — a conversation input's or a loop step's attachment, a
# tool result's capture, a sealed request's placed picture, a OneShot's
# input — judged through the funnel that row's own read uses. Absent,
# foreign, fileless and unreadable answer 404 alike: no oracle. The
# conditional GET is `AttachmentRead`'s: the strong ETag of this kind, a
# 304 before streaming.
class AgentAPI::V1::Uploads::BytesController < AgentAPI::V1::BaseController
  include AgentAPI::V1::Uploads::AttachmentRead

  def show
    blob = readable_upload.file.blob
    return if answered_fresh?(blob, "bytes")

    if request.headers["Range"].present?
      send_blob_byte_range_data blob, request.headers["Range"], disposition: "attachment"
    else
      response.headers["Accept-Ranges"] = "bytes"
      response.headers["Content-Length"] = blob.byte_size.to_s
      send_blob_stream blob, disposition: "attachment"
    end
  end
end
