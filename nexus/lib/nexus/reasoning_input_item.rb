module Nexus
  # A top-level replayed-reasoning element of the normalized input list (the
  # Responses shape): a role-less item placed before the assistant message it
  # produced. The payload is the wire item the protocol passes through verbatim.
  ReasoningInputItem = Data.define(:type, :payload, :native_origin) do
    def self.from_h(hash)
      new(type: hash.fetch("type"), payload: hash.fetch("payload"), native_origin: hash["native_origin"])
    end

    def initialize(native_origin: nil, **) = super

    def to_h
      { "type" => type, "payload" => payload, "native_origin" => native_origin }.compact
    end
  end
end
