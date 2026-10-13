module Nexus
  # The one place the ordered closed part stream is read back from its durable
  # form, dispatching on the part's own `type` so nothing downstream asks what
  # a part is.
  module InputParts
    TEXT = "text".freeze
    UPLOAD = "upload".freeze
    REASONING = "reasoning".freeze

    def self.from_h(hash)
      case hash["type"]
      when TEXT then TextInputPart.from_h(hash)
      when UPLOAD then UploadInputPart.from_h(hash)
      when REASONING then ReasoningInputPart.from_h(hash)
      else raise ArgumentError, "unknown input part type: #{hash["type"].inspect}"
      end
    end
  end
end
