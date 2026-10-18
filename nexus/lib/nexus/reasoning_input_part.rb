module Nexus
  # A replayed-reasoning member of a message's part stream: the neutral shape
  # the protocols lower natively (anthropic thinking/redacted_thinking, gemini
  # thought), or the chat message's reasoning field, which the request build
  # lifts onto the message (CHAT_FIELDS). Raw mode may carry them too — a
  # forged signature is the provider's 400.
  ReasoningInputPart = Data.define(:type, :payload, :native_origin) do
    def self.from_h(hash)
      new(type: hash.fetch("type"), payload: hash.fetch("payload"), native_origin: hash["native_origin"])
    end

    def initialize(native_origin: nil, **) = super

    def to_h
      { "type" => type, "payload" => payload, "native_origin" => native_origin }.compact
    end
  end

  # The chat wire's reasoning payload types, each the name of the assistant
  # message field it lands on, and the payload member that field carries: the
  # broker's detail blocks verbatim, else the reasoning text.
  ReasoningInputPart::CHAT_FIELDS = { "reasoning_details" => "blocks", "reasoning_content" => "text" }.freeze
  # Every payload type a reasoning part may carry: the in-message blocks and
  # the chat fields — a closed set, so a typo'd shape refuses at acceptance.
  ReasoningInputPart::PAYLOAD_TYPES =
    (%w[thinking redacted_thinking thought] + ReasoningInputPart::CHAT_FIELDS.keys).freeze
end
