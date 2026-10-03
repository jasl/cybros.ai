module Nexus
  # A top-level tool-call element of the normalized input list, in the
  # Responses family's neutral shape every protocol lowers natively;
  # kernel-authored when a continuation replays the round that made the calls.
  ToolCallInputItem = Data.define(:type, :payload, :native_origin) do
    def initialize(native_origin: nil, **) = super

    def self.from_h(hash)
      new(type: hash.fetch("type"), payload: hash.fetch("payload"), native_origin: hash["native_origin"])
    end

    def to_h
      { "type" => type, "payload" => payload, "native_origin" => native_origin }.compact
    end

    # Native arguments stay verbatim; the pairing identity is the kernel's
    # normalized one, including calls for which the provider supplied no id.
    def with_native_payload(native_payload, origin:)
      native = native_payload.merge("functionCall" =>
        native_payload.fetch("functionCall").merge("id" => payload.fetch("call_id")))
      with(payload: payload.merge("provider_payload" => native), native_origin: origin)
    end
  end
end
