module Nexus
  # A top-level tool-result element of the normalized input list, in the
  # Responses family's neutral shape the protocols lower per wire. Pairing is
  # the composer's law; this type only carries what was paired.
  ToolResultInputItem = Data.define(:type, :payload) do
    def self.from_h(hash)
      new(type: hash.fetch("type"), payload: hash.fetch("payload"))
    end

    def to_h
      { "type" => type, "payload" => payload }
    end
  end
end
