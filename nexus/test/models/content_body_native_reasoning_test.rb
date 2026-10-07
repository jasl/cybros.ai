require "test_helper"

class ContentBodyNativeReasoningTest < ActiveSupport::TestCase
  setup do
    @inference_request = InferenceRequest.create!(
      account: accounts(:cybros), workspace: workspaces(:shared), creating_user: users(:member),
      workload: "text_generation"
    )
  end

  test "a native reasoning item is recognized beside ordinary messages" do
    body = body_with([
      { "role" => "user", "parts" => [{ "type" => "text", "text" => "Question" }] },
      { "type" => "reasoning_item", "encrypted_content" => "opaque" },
    ])

    assert_predicate body, :native_reasoning?
  end

  test "a native reasoning part is recognized inside a message" do
    body = body_with([{ "role" => "assistant", "parts" => [
      { "type" => "text", "text" => "Answer" },
      { "type" => "reasoning", "text" => "Thought", "signature" => "signed" },
    ] }])

    assert_predicate body, :native_reasoning?
  end

  test "portable think text and other opaque content are not native reasoning" do
    body = body_with([
      { "text" => "<think>Thought</think>" },
      { "role" => "assistant", "parts" => [{ "type" => "text", "text" => "<think>Thought</think>" }] },
      { "metadata" => { "type" => "reasoning_item" } },
    ])

    assert_not_predicate body, :native_reasoning?
  end

  test "an empty body has no native reasoning" do
    assert_not_predicate body_with([]), :native_reasoning?
  end

  private

    def body_with(entries)
      ContentBodies::Replace.call(owner: @inference_request, role: "input", entries: entries).body
    end
end
