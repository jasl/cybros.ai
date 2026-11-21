module Nexus
  # The text member of a message's ordered closed part stream. Its sibling
  # is `UploadInputPart`; together they are the whole union, and
  # `InputParts` is the one reader that dispatches between them.
  TextInputPart = Data.define(:type, :text, :thought_signature, :native_origin) do
    def self.from_h(hash)
      new(type: hash.fetch("type"), text: hash.fetch("text"),
        thought_signature: hash["thought_signature"], native_origin: hash["native_origin"])
    end

    def initialize(thought_signature: nil, native_origin: nil, **) = super

    def to_h
      { "type" => type, "text" => text, "thought_signature" => thought_signature, "native_origin" => native_origin }.compact
    end
  end
end
