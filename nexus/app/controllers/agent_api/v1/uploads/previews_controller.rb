# GET /agent_api/v1/uploads/{public_id}/preview — THE PREVIEW READ: the
# upload's representation bounded at
# `ContentUploads::Representations::PREVIEW` on its longest edge — a
# screen-sized picture of an image, a PDF's first page, a video's frame —
# whole, inline, under the same rule as `bytes` and the same conditional
# GET; a blob with no preview answers `404 representation_unavailable`.
class AgentAPI::V1::Uploads::PreviewsController < AgentAPI::V1::BaseController
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

  def show
    send_representation("preview")
  end
end
