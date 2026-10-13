# The prefix identifies the hosted event plane, not an individual host.
# Clients keep the opaque cursor with its conversation or loop identity.
class ConversationEventItem::ReplayCursor
  PREFIX = "cvei".freeze
  MalformedCursor = Nexus::ReplayCursor::MalformedCursor
  CODEC = Nexus::ReplayCursor.new(prefix: PREFIX)

  def self.encode(sequence) = CODEC.encode(sequence)
  def self.decode(value) = CODEC.decode(value)
end
