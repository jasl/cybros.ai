module Nexus
  # The text member of a message's ordered closed part stream. Its sibling
  # is `UploadInputPart`; together they are the whole union, and
  # `InputParts` is the one reader that dispatches between them.
  TextInputPart = Data.define(:type, :text) do
    def self.from_h(hash)
      new(type: hash.fetch("type"), text: hash.fetch("text"))
    end

    def to_h
      { "type" => type, "text" => text }
    end
  end
end
