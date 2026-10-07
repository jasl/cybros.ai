# The prefix identifies the InferenceRequest event plane, not an individual InferenceRequest.
# Clients keep the opaque cursor with its resource identity.
class InferenceRequestEventItem::ReplayCursor
  PREFIX = "osei".freeze
  MalformedCursor = Nexus::ReplayCursor::MalformedCursor
  CODEC = Nexus::ReplayCursor.new(prefix: PREFIX)

  def self.encode(sequence) = CODEC.encode(sequence)
  def self.decode(value) = CODEC.decode(value)
end
