# The one wire shape a replay item takes, on both transports.
# `resource.type` is the unified `one_shot`.
class OneShotEventItem::PublicProjection
  def self.render(item)
    {
      public_id: item.public_id,
      # Published because the merge across both transports needs an ordered value:
      # sequences are OneShot-local, start at 1 and are contiguous, so a follower
      # detects a gap by arithmetic. The cursor stays opaque.
      sequence: item.sequence,
      cursor: OneShotEventItem::ReplayCursor.encode(item.sequence),
      type: item.item_type,
      resource: {
        type: "one_shot",
        public_id: item.one_shot.public_id,
      },
      occurred_at: item.occurred_at.iso8601(3),
      payload: item.payload,
    }
  end
end
