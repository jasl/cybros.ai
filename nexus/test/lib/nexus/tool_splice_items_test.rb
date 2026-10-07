require "test_helper"

# the tool splice vocabulary: role-less function_call / function_call_output items travel the whole
# substrate (normalize gate → stored entries → read-back → wire lowering) so InputComposition can
# author them and every protocol stitches them natively.
class Nexus::ToolSpliceItemsTest < ActiveSupport::TestCase
  CALL = Nexus::ToolCallInputItem.new(
    type: "tool_call_item",
    payload: { "type" => "function_call", "call_id" => "call_1",
               "name" => "read_file", "arguments" => "{\"path\":\"a.rb\"}" }
  )
  RESULT = Nexus::ToolResultInputItem.new(
    type: "tool_result_item",
    payload: { "type" => "function_call_output", "call_id" => "call_1",
               "output" => "contents of a.rb" }
  )

  def messages
    [
      Nexus::TextInputMessage.new(
        role: "user",
        parts: [Nexus::TextInputPart.new(type: Nexus::InputParts::TEXT, text: "read it")]
      ),
      CALL, RESULT,
    ]
  end

  test "entries round-trip the splice pair by type" do
    entries = Nexus::InputEntries.for(messages)
    restored = Nexus::InputEntries.from(entries: entries, workload: "text_generation")

    assert_equal messages, restored,
      "a stored continuation request reads back element-identical"
    refute CALL.to_h.key?("native_origin"), "neutral calls need no native replay provenance"
  end

  test "normalization and storage preserve a native call's replay origin" do
    call = CALL.with(native_origin: { "provider_id" => "gemini", "model_id" => "gemini-3.8-flash",
                                     "api_format" => "gemini_generate_content" })
    normalized = ModelSelection::Workloads::Input.send(:normalize_text_element, call)
    entries = Nexus::InputEntries.for([normalized])
    restored = Nexus::InputEntries.from(entries: entries, workload: "text_generation")

    assert_equal call, restored.sole,
      "the wire gate still knows the origin after another round inherits the sealed prefix"
  end

  test "the normalize gate accepts the pair and refuses a mislabeled one" do
    mislabeled = Nexus::ToolCallInputItem.new(
      type: "tool_call_item", payload: { "type" => "function_call_output" }
    )
    assert_nil ModelSelection::Workloads::Input.send(:normalize_text_element, mislabeled),
      "a mislabeled splice item is a composition bug surfaced at the gate"
    normalized = ModelSelection::Workloads::Input.send(:normalize_text_element, CALL)
    assert_equal "function_call", normalized.payload.fetch("type")
  end

  test "token counting reads name+arguments and the output text" do
    segments = Nexus::ModelRequestInput.text_segments([CALL, RESULT])
    assert_equal ["read_file", "{\"path\":\"a.rb\"}", "contents of a.rb"], segments
  end

  test "the anthropic protocol stitches the pair into tool_use and tool_result blocks" do
    protocol = SimpleInference::Protocols::AnthropicMessages.allocate
    stitched = []
    [CALL.payload, RESULT.payload].each do |entry|
      protocol.send(:append_entry, stitched, entry)
    end

    tool_use = stitched.first.fetch(:content).sole
    assert_equal "tool_use", tool_use.fetch(:type).to_s
    assert_equal "read_file", tool_use.fetch(:name),
      "the call's NAME survives the stitch (the K0 axis, input side)"
    tool_result = stitched.last.fetch(:content).sole
    assert_equal "call_1", tool_result.fetch(:tool_use_id)
  end
end
