require "test_helper"
require_relative "../support/conversation_fixtures"

class ApiReasoningSelectionTest < Minitest::Test
  include CybrosAgentTest::ConversationFixtures

  def test_input_and_preview_keep_enabled_separate_from_effort
    chat([[202, {}, contract.fetch("valid_input_fixture")]]).inputs.create(
      idempotency_key: "reasoning-input", kind: "direct_reply", text: "Answer",
      model: "dev/text", reasoning_enabled: false, reasoning_effort: "low"
    )
    assert_equal({ "model" => "dev/text", "reasoning_effort" => "low", "reasoning_enabled" => false },
      request.fetch(:body).dig("input", "model"))

    chat([[200, {}, contract.fetch("valid_estimate_fixture")]]).estimate_input(
      model: "dev/text", reasoning_enabled: false, prompt: "Answer"
    )
    assert_equal({ "model" => "dev/text", "reasoning_enabled" => false },
      request.fetch(:body).dig("context_estimate", "model"))
  end

  def test_input_updates_can_toggle_reasoning_without_resubmitting_the_model
    [false, true, nil].each do |enabled|
      chat([[200, {}, contract.fetch("valid_input_fixture")]]).inputs.update(
        "input-1", expected_lock_version: 2, reasoning_enabled: enabled
      )
      assert_equal({ "reasoning_enabled" => enabled }, request.fetch(:body).dig("input", "model"))
    end

    chat([[200, {}, contract.fetch("valid_input_fixture")]]).inputs.update("input-1", text: "Updated")
    refute request.fetch(:body).fetch("input").key?("model")
  end

  def test_regeneration_keeps_a_false_override_without_a_new_model
    fixture = contract.fetch("valid_regeneration_fixture")
    fixture.fetch("variant").fetch("model")["reasoning_enabled"] = false
    result = chat([[202, {}, fixture]]).turns.regenerate(
      TURN_ID, idempotency_key: "reasoning-regeneration", reasoning_enabled: false
    )

    assert_equal({ "model" => { "reasoning_enabled" => false } }, request.fetch(:body).fetch("regeneration"))
    assert_equal false, result.variant.model.reasoning_enabled
  end

  def test_inference_request_create_and_estimate_report_effective_enabled
    fixtures = CybrosAgentTest::ContractFixtures.pack("inference_requests.json")
    queued = fixtures.fetch("valid_queued_fixture")
    queued.fetch("inference_request").fetch("model")["reasoning_enabled"] = true
    result = workspace([[202, {}, queued]]).inference_requests.create(
      workload: "text_generation", model: "dev/text", input: "Answer",
      reasoning_enabled: false, idempotency_key: "reasoning-one-shot"
    )
    assert_equal false, request.fetch(:body).dig("inference_request", "model", "reasoning_enabled")
    assert_equal true, result.model.reasoning_enabled,
      "the response describes the effective selection when the lane cannot disable reasoning"

    estimate = fixtures.fetch("valid_input_estimate_fixture")
    estimate.fetch("input_estimate").fetch("model")["reasoning_enabled"] = false
    result = workspace([[200, {}, estimate]]).inference_requests.estimate_input(
      workload: "text_generation", model: "dev/text", input: "Answer", reasoning_enabled: false
    )
    assert_equal false, request.fetch(:body).dig("input_estimate", "model", "reasoning_enabled")
    assert_equal false, result.model.reasoning_enabled
  end

  def test_schedules_keep_false_on_creation_and_control_only_update
    fixture = CybrosAgentTest::ContractFixtures.pack("schedules.json").fetch("valid_fixture")
    fixture.fetch("schedule").fetch("model")["reasoning_enabled"] = false
    job = chat([[201, {}, fixture]]).schedules.create(
      prompt: "Report", rule: fixture.dig("schedule", "rule"), idempotency_key: "reasoning-job",
      model: "dev/text", reasoning_enabled: false
    )
    assert_equal false, request.fetch(:body).dig("schedule", "model", "reasoning_enabled")
    assert_equal false, job.schedule.model.reasoning_enabled

    chat([[200, {}, fixture]]).schedules.update("job-1", expected_lock_version: 2, reasoning_enabled: false)
    assert_equal({ "reasoning_enabled" => false }, request.fetch(:body).dig("schedule", "model"))
  end

  def test_compaction_and_task_retry_keep_control_only_overrides
    turn = { "public_id" => "turn-1", "position" => 1, "kind" => "compaction_summary", "status" => "running" }
    chat([[202, {}, { "turn" => turn }]]).compact(reasoning_enabled: false)
    assert_equal({ "compaction" => { "reasoning_enabled" => false } }, request.fetch(:body))

    fixture = CybrosAgentTest::ContractFixtures.pack("runs.json").fetch("valid_task_detail_fixture")
    workspace([[200, {}, fixture]]).run("run-1").tasks_context("round-1").retry(reasoning_enabled: false)
    assert_equal({ "model" => { "reasoning_enabled" => false } }, request.fetch(:body))
  end

  def test_step_and_operation_defaults_preserve_the_same_selection
    selection = { "model" => "dev/text", "reasoning_enabled" => false, "reasoning_effort" => "low" }
    step = CybrosAgent::Steps::Model.new(prompt: "Answer", model: selection)
    tool = CybrosAgent::Steps::Tool.new(name: "code", model_defaults: { "model" => selection })

    assert_equal selection, step.to_h.dig("model", "model")
    assert_equal selection, tool.to_h.dig("tool", "model_defaults", "model")
  end
end
