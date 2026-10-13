# The one wire shape a replay item takes, on both transports and both
# hosts. Sequences are host-local, start at 1 and are contiguous (the cursor
# row's lock allocates ranges); the cursor stays opaque.
class ConversationEventItem::PublicProjection
  def self.render(item)
    {
      public_id: item.public_id,
      sequence: item.sequence,
      cursor: ConversationEventItem::ReplayCursor.encode(item.sequence),
      type: item.item_type,
      resource: {
        type: Nexus::RealtimeStreams.resource_type(item.host),
        public_id: item.host.public_id,
      },
      occurred_at: item.occurred_at.iso8601(3),
      payload: item.payload,
    }
  end
end
