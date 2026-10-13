require "test_helper"
require_relative "../../../test_helpers/conversation_api_test_helper"

class AgentAPI::V1::ConversationInputPromptBoundsTest < ActionDispatch::IntegrationTest
  include ConversationAPITestHelper

  test "a long inline prompt accepted by PATCH can also be created and exactly replayed" do
    assert_long_create_and_replay(inline: [{ role: "developer", text: long_prompt }])
  end

  test "long raw instructions accepted by PATCH can also be created and exactly replayed" do
    assert_long_create_and_replay(context_mode: "raw", instructions: long_prompt)
  end

  test "a long body within the storage wall can be created and exactly replayed" do
    assert_long_create_and_replay(text: long_prompt)
  end

  test "a receipt containing raw instructions and text is not another request body" do
    assert_long_create_and_replay(context_mode: "raw", instructions: "i" * 600.kilobytes,
      text: "t" * 600.kilobytes)
  end

  test "declared variable values can carry a long prompt through create and replay" do
    agent = users(:agent)
    outcome = Users::DeclareConfiguration.call(user: agent,
      tool_definitions: [], approval_mode: nil, approval_rules: nil, prompt_mechanism: "assembly",
      prompt_template: {
        "blocks" => [
          { "type" => "inline", "role" => "system", "text" => "{{scene}}" },
          { "type" => "history" }, { "type" => "input" },
        ],
        "variables" => { "scene" => "a short default" },
      },
      compaction_policy: nil
    )
    assert_equal :declared, outcome.outcome, outcome.user.errors.full_messages.join(", ")
    conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: agent)
    assert_long_create_and_replay(conversation: conversation, variables: { scene: long_prompt })
  end

  test "PATCH preserves a long inline prompt through materialization" do
    conversation, input = queued_reply
    patch input_path(conversation, input), headers: auth, as: :json,
      params: { input: { inline: [{ role: "developer", text: long_prompt }] } }
    assert_response :success

    invocation = materialize(conversation)
    body = invocation.content_bodies.find_by!(role: "request")
    entry = body.content_body_entries.includes(:content_fragment).first
    assert_equal long_prompt, entry.content_fragment.payload.dig("parts", 0, "text")
  end

  test "PATCH preserves long raw instructions through materialization" do
    conversation, input = queued_reply(context_mode: "raw")
    patch input_path(conversation, input), headers: auth, as: :json,
      params: { input: { instructions: long_prompt } }
    assert_response :success

    invocation = materialize(conversation)
    assert_equal long_prompt, invocation.request_options.fetch("instructions")
  end

  test "an inline prompt over the storage wall blocks durably and remains editable" do
    conversation, input = queued_reply
    patch input_path(conversation, input), headers: auth, as: :json,
      params: { input: { inline: [{ role: "developer", text: "x" * (2 * Nexus::SizeBounds.fetch(:snapshot_bound)) }] } }
    assert_response :success

    result = Conversations::Inputs::ApplyNext.call(conversation_id: conversation.id)
    assert_equal :input_blocked, result.outcome
    get conversation_inputs_path(conversation), headers: auth
    assert_response :success
    blocked = response.parsed_body.fetch("inputs").sole
    assert_equal "blocked", blocked.fetch("state")
    assert_equal "content_too_large", blocked.fetch("blocked_reason")

    patch input_path(conversation, input), headers: auth, as: :json,
      params: { input: { inline: [{ role: "developer", text: "short enough" }] } }
    assert_response :success
    assert_equal "pending", response.parsed_body.dig("input", "state")
    materialize(conversation)
  end

  test "a submitted body over the storage wall writes neither input nor receipt" do
    conversation = create_conversation!
    assert_no_difference ["ConversationInput.count", "ConversationCommandReceipt.count", "ContentBody.count"] do
      post conversation_inputs_path(conversation), headers: auth("oversize"), as: :json,
        params: { input: reply_fields(text: "x" * Nexus::SizeBounds.fetch(:snapshot_bound)) }
    end
    assert_response :content_too_large
    assert_equal "content_too_large", response.parsed_body.dig("error", "code")
  end

  private

    def long_prompt = "x" * 128.kilobytes

    def input_path(conversation, input)
      "#{conversation_inputs_path(conversation)}/#{input.fetch("public_id")}"
    end

    def reply_fields(**attributes)
      { kind: "direct_reply", text: "Question", model: { model: DevModelLane::WINDOWLESS_TEXT_MODEL } }
        .merge(attributes)
    end

    def queued_reply(**attributes)
      conversation = create_conversation!
      post conversation_inputs_path(conversation), headers: auth("short"), as: :json,
        params: { input: reply_fields(**attributes) }
      assert_response :accepted
      [conversation, response.parsed_body.fetch("input")]
    end

    def materialize(conversation)
      result = Conversations::Inputs::ApplyNext.call(conversation_id: conversation.id)
      assert_predicate result, :accepted?, result.outcome.to_s
      assert_empty conversation.conversation_inputs
      result.value.active_variant.model_invocation
    end

    def assert_long_create_and_replay(conversation: create_conversation!, **attributes)
      params = { input: reply_fields(**attributes) }
      post conversation_inputs_path(conversation), headers: auth("long"), as: :json, params: params
      assert_response :accepted
      accepted = response.parsed_body
      materialize(conversation)

      assert_no_difference ["ConversationInput.count", "ModelInvocation.count"] do
        post conversation_inputs_path(conversation), headers: auth("long"), as: :json, params: params
      end
      assert_response :accepted
      assert_equal accepted, response.parsed_body, "the receipt replays the original acceptance after its input was consumed"
    end
end
