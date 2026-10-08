require "test_helper"

# The replay ask's default is the kernel's, the same on every row: reasoning
# is history, so every seed — a person's turn, the kernel's receipt, a
# regenerated answer and the estimate that models them — replays every
# earlier round's reasoning the target can read. The row states only the
# FORMAT its wire takes back.
class Conversations::ContextAssemblyReplayTest < ActiveSupport::TestCase
  Replay = Conversations::ContextAssembly::Replay

  # A resolved selection's duck: the target is read off it and nothing else.
  Selection = Data.define(:provider_id, :execution_profile, :reasoning, :capabilities)
  Pin = Data.define(:model_pin) do
    def wire_option(_key) = nil
  end
  Reasoning = Data.define(:enabled)
  Capabilities = Data.define(:reasoning_replay)

  def selection(capability)
    Selection.new(provider_id: "p", execution_profile: Pin.new(model_pin: "m-1"),
      reasoning: Reasoning.new(enabled: true), capabilities: Capabilities.new(reasoning_replay: capability))
  end

  test "the default is all on every row, whatever format it replays in" do
    %w[anthropic_thinking responses_reasoning gemini_thought chat_reasoning responses_reasoning_text].each do |format|
      capability = Nexus::ReasoningReplayCapability.from_h("format" => format)

      assert_equal "all", Replay.from_selection(selection(capability)).mode, format
    end
    assert_equal "all", Replay.from_selection(selection(Nexus::ReasoningReplayCapability.default)).mode,
      "an undeclared row"
  end

  test "a caller's named mode is taken for its turn" do
    capability = Nexus::ReasoningReplayCapability.from_h("format" => "anthropic_thinking")

    assert_equal "last_turn", Replay.from_selection(selection(capability), mode: "last_turn").mode
    assert_equal "none", Replay.from_selection(selection(capability), mode: "none").mode
  end

  test "the row's declaration is its format and the vendor's tool-round rule, and survives the snapshot" do
    declared = Nexus::ReasoningReplayCapability.from_h("format" => "chat_reasoning")

    assert_equal "chat_reasoning", declared.format
    assert_equal({ "format" => "chat_reasoning", "required_for_tool_rounds" => false }, declared.to_h)
    assert_equal declared, Nexus::ReasoningReplayCapability.from_h(declared.to_h)
    assert Nexus::ReasoningReplayCapability.from_h("format" => "responses_reasoning_text",
      "required_for_tool_rounds" => true).required_for_tool_rounds
  end
end
