require "test_helper"
require_relative "../../../test_helpers/conversation_api_test_helper"

class AgentAPI::V1::ReasoningSelectionsTest < ActionDispatch::IntegrationTest
  include ConversationAPITestHelper

  test "InferenceRequest and preview report effective enablement while effort stays independent" do
    selection = { model: "dev/mock-text", reasoning_enabled: false, reasoning_effort: "high" }
    fields = { workload: "text_generation", model: selection, input: "Explain the result" }

    post "#{inference_requests_path}/input_estimate", headers: auth, as: :json,
      params: { input_estimate: fields }
    assert_response :success
    estimated = response.parsed_body.dig("input_estimate", "model")
    assert_equal true, estimated.fetch("reasoning_enabled"), "this model cannot disable reasoning"
    assert_equal "high", estimated.fetch("reasoning_effort")

    post inference_requests_path, headers: auth("reasoning-intent"), as: :json, params: { inference_request: fields }
    assert_response :accepted
    assert_equal estimated, response.parsed_body.dig("inference_request", "model")

    post inference_requests_path, headers: auth("reasoning-intent"), as: :json,
      params: { inference_request: fields.merge(model: selection.merge(reasoning_enabled: true)) }
    assert_response :conflict
    assert_equal "idempotency_envelope_mismatch", response.parsed_body.dig("error", "code"),
      "different caller intent remains a different envelope even when execution agrees"
  end

  test "reasoning disablement is neither an effort alias nor a nontext option" do
    post "#{inference_requests_path}/input_estimate", headers: auth, as: :json,
      params: { input_estimate: { workload: "text_generation", input: "hello",
        model: { model: "dev/mock-text", reasoning_enabled: false, reasoning_effort: "none" } } }
    assert_response :unprocessable_entity
    assert_equal "unsupported_reasoning_effort", response.parsed_body.dig("error", "code")

    post inference_requests_path, headers: auth("embedding-reasoning"), as: :json,
      params: { inference_request: { workload: "embedding", input: "hello",
        model: { model: "dev/mock-embedding", reasoning_enabled: false } } }
    assert_response :unprocessable_entity
    assert_equal "unexpected_reasoning_enabled", response.parsed_body.dig("error", "code")
  end

  test "queued input edits preserve false and the model until another reference is named" do
    conversation = create_conversation!
    post conversation_inputs_path(conversation), headers: auth("thinking-input"), as: :json,
      params: { input: { kind: "direct_reply", text: "hello",
        model: { model: "dev/mock-text", reasoning_enabled: "false", reasoning_effort: "high" } } }
    assert_response :accepted
    input = conversation.conversation_inputs.find_by!(public_id: response.parsed_body.dig("input", "public_id"))
    assert_equal false, input.reasoning_enabled
    assert_equal "high", input.reasoning_effort
    path = "#{conversation_inputs_path(conversation)}/#{input.public_id}"

    patch path, headers: auth, as: :json, params: { input: { model: { reasoning_enabled: nil } } }
    assert_response :success
    assert_equal false, input.reload.reasoning_enabled, "null preserves the queued selection"

    patch path, headers: auth, as: :json, params: { input: { model: { reasoning_enabled: true } } }
    assert_response :success
    assert_equal true, input.reload.reasoning_enabled
    assert_equal ["dev", "mock-text", "high"], [input.provider_id, input.model_ref, input.reasoning_effort]

    patch path, headers: auth, as: :json, params: { input: { model: { model: "dev/mock-priced" } } }
    assert_response :success
    assert_equal "mock-priced", input.reload.model_ref
    assert_nil input.reasoning_enabled, "a different model uses its own enablement default"
    assert_nil input.reasoning_effort, "a different model uses its own effort default"
  end

  test "scheduled job control-only edits retain the reference and changing models resets defaults" do
    conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: users(:agent))
    path = "#{conversation_path(conversation)}/schedules"
    post path, headers: auth("thinking-schedule"), as: :json,
      params: { schedule: { prompt: "Report progress",
        rule: { kind: "once", run_at: (DatabaseClock.now + 1.hour).iso8601(6) },
        model: { model: "dev/mock-text", reasoning_enabled: false, reasoning_effort: "high" } } }
    assert_response :created
    job = response.parsed_body.fetch("schedule")
    assert_equal false, job.dig("model", "reasoning_enabled")
    path = "#{path}/#{job.fetch("public_id")}"

    [true, nil, false].each do |enabled|
      patch path, headers: auth, as: :json,
        params: { schedule: { expected_lock_version: job.fetch("lock_version"),
          model: { reasoning_enabled: enabled } } }
      assert_response :success
      job = response.parsed_body.fetch("schedule")
      assert_equal enabled.nil? ? true : enabled, job.dig("model", "reasoning_enabled")
      assert_equal "dev/mock-text", job.dig("model", "model")
      assert_equal "high", job.dig("model", "reasoning_effort")
    end

    patch path, headers: auth, as: :json,
      params: { schedule: { expected_lock_version: job.fetch("lock_version"),
        model: { model: "dev/mock-priced" } } }
    assert_response :success
    model = response.parsed_body.dig("schedule", "model")
    assert_equal "dev/mock-priced", model.fetch("model")
    assert_nil model.fetch("reasoning_enabled")
    assert_nil model.fetch("reasoning_effort")
  end

  private

    def inference_requests_path = "/agent_api/v1/workspaces/#{@workspace.public_id}/inference_requests"
end
