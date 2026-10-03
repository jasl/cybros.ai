require "test_helper"

class Nexus::ModelRequestInputTest < ActiveSupport::TestCase
  test "text segments preserve strings and message text in order" do
    message = Nexus::TextInputMessage.new(
      role: "user",
      parts: [Nexus::TextInputPart.new(type: Nexus::InputParts::TEXT, text: "message")]
    )

    assert_equal %w[plain message], request_input(["plain", message]).text_segments
    assert_empty request_input(nil).text_segments
  end

  # Replayed reasoning the wire reads as text is text the request carries:
  # DeepSeek's plain-text item, the chat field's text and its text blocks.
  # Opaque material (an encrypted blob) is the provider's to count.
  test "replayed reasoning counts the text the wire reads" do
    item = Nexus::ReasoningInputItem.new(type: "reasoning_item",
      payload: { "type" => "reasoning", "content" => [{ "type" => "reasoning_text", "text" => "plain thought" }] })
    content = Nexus::ReasoningInputPart.new(type: Nexus::InputParts::REASONING,
      payload: { "type" => "reasoning_content", "text" => "chat thought" })
    details = Nexus::ReasoningInputPart.new(type: Nexus::InputParts::REASONING,
      payload: { "type" => "reasoning_details", "blocks" => [
        { "type" => "reasoning.text", "text" => "block thought" }, { "type" => "reasoning.encrypted", "data" => "opaque" },
      ] })
    message = Nexus::TextInputMessage.new(role: "assistant", parts: [content, details])

    assert_equal ["plain thought", "chat thought", "block thought"], request_input([item, message]).text_segments
  end

  test "unknown top-level and array member shapes fail loudly" do
    error = assert_raises(ArgumentError) { request_input(Object.new).text_segments }
    assert_includes error.message, "unhandled model request input"

    error = assert_raises(ArgumentError) { request_input([Object.new]).text_segments }
    assert_includes error.message, "unhandled model request input element"
  end

  test "the normalized-input helper and request value share one segmentation" do
    message = Nexus::TextInputMessage.new(
      role: "user",
      parts: [Nexus::TextInputPart.new(type: Nexus::InputParts::TEXT, text: "message")]
    )

    assert_equal %w[plain message], Nexus::ModelRequestInput.text_segments(["plain", message])
  end

  private

    def request_input(input)
      Nexus::ModelRequestInput.new(
        profile_id: "test", adapter_profile: "test", protocol_route: "test",
        workload: "test", wire_model: "test", input: input,
        generation_config: nil, reasoning_effort: nil, stream: false
      )
    end
end
