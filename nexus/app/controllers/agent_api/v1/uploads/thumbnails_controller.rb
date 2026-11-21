# GET /agent_api/v1/uploads/{public_id}/thumbnail — THE THUMBNAIL READ:
# the upload's representation bounded at
# `ContentUploads::Representations::THUMBNAIL` on its longest edge, whole,
# inline, under the same rule as `bytes` and the same conditional GET; a
# blob with no thumbnail (a text file; a PDF on a host without poppler)
# answers `404 representation_unavailable`. Named in code, never by the
# client: there is no `?preset=`.
# @auth [MemberBearer]
class AgentAPI::V1::Uploads::ThumbnailsController < AgentAPI::V1::BaseController
  include AgentAPI::V1::Uploads::AttachmentRead

  # THE READ'S OWN BUDGET, below the family's ordinary budget: the FIRST read of a
  # preset is a whole render through vips, poppler or ffmpeg on an input
  # of up to `upload_bound` (100 MB) — a transcode, not a row read — and
  # Active Storage's variant tracking makes only the later reads a lookup.
  # 30 a minute per caller is one render every two seconds: a UI painting
  # a page of thumbnails stays well inside it (a second visit is 304s), a
  # caller cycling fresh uploads through the renderers is bounded at half
  # a render per second.
  self.caller_rate_limit = 30

  # @oas_include
  # @summary Read thumbnails
  # @tags Member, thumbnails
  # @parameter upload_public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @response_ref (200) #/components/responses/AgentApiV1UploadsThumbnailsShow
  # @response_ref (304) #/components/responses/Empty
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
    send_representation("thumbnail")
  end
end
