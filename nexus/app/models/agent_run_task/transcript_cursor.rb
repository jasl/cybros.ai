class AgentRunTask
  # The transcript window's cursor. Opaque by construction — it wraps an
  # internal ordinal that must never render as a field (the cardinal
  # rule), and a client only ever echoes it back.
  class TranscriptCursor
    PREFIX = "altr".freeze
    MalformedCursor = Nexus::ReplayCursor::MalformedCursor
    CODEC = Nexus::ReplayCursor.new(prefix: PREFIX)

    def self.encode(position) = CODEC.encode(position)
    def self.decode(value) = CODEC.decode(value)
  end
end
