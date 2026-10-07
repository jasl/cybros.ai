# The one wire shape a replay item takes, on both transports.
# `resource.type` is the unified `inference_request`.
class InferenceRequestEventItem::PublicProjection
  def self.render(item)
    {
      public_id: item.public_id,
      # Published because the merge across both transports needs an ordered value:
      # sequences are InferenceRequest-local, start at 1 and are contiguous, so a follower
      # detects a gap by arithmetic. The cursor stays opaque.
      sequence: item.sequence,
      cursor: InferenceRequestEventItem::ReplayCursor.encode(item.sequence),
      type: item.item_type,
      resource: {
        type: "inference_request",
        public_id: item.inference_request.public_id,
      },
      occurred_at: item.occurred_at.iso8601(3),
      payload: item.payload,
    }
  end
end
