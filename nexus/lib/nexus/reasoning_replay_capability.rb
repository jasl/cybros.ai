module Nexus
  # What reasoning shape a model's wire accepts back: the format selects the
  # native serializer family, "none" disables replay. How much is replayed
  # is the kernel's rule, the same on every row
  # (`Conversations::ContextAssembly::Replay::DEFAULT_MODE`).
  # `required_for_tool_rounds` is the vendor's refusal of a tool round sent
  # back without its reasoning (DeepSeek with tools, Kimi K3): such a model
  # cannot take over a history of tool rounds another model produced.
  class ReasoningReplayCapability < Data.define(:format, :required_for_tool_rounds)
    # Each is one wire family's own field: Anthropic's thinking blocks, the
    # Responses reasoning items, Gemini's thought parts, the chat assistant
    # message's reasoning field, DeepSeek's plain-text reasoning item.
    NATIVE_FORMATS = %w[
      anthropic_thinking responses_reasoning gemini_thought chat_reasoning responses_reasoning_text
    ].freeze
    FORMATS = (NATIVE_FORMATS + %w[none]).freeze
    # A row that states no format replays nothing: there is no portable
    # form of another model's reasoning, only each wire's own field.
    DEFAULT_FORMAT = "none"

    def self.default = new(format: DEFAULT_FORMAT)

    # The catalog's declaration, or nothing: the default is what an
    # undeclared model effectively is.
    def self.from_h(hash)
      declared = hash.to_h
      new(format: declared.fetch("format", DEFAULT_FORMAT),
        required_for_tool_rounds: declared.fetch("required_for_tool_rounds", false) == true)
    end

    def initialize(required_for_tool_rounds: false, **) = super

    def none? = format == "none"

    def to_h = super.transform_keys(&:to_s)
  end
end
