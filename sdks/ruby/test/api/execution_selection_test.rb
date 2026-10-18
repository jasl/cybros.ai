require "test_helper"
require_relative "../support/conversation_fixtures"

class ApiExecutionSelectionTest < Minitest::Test
  include CybrosAgentTest::ConversationFixtures

  DECLARATION = {
    "default_model" => "dev/text",
    "system_prompt" => { "content" => "Review the supplied task." },
    "fallback_models" => ["other/text", "backup/text"],
  }.freeze
  INTENT = { "source" => "explicit", "model" => "dev/text", "constraint" => "model", "alternatives" => [] }.freeze

  def test_a_child_preview_can_leave_its_model_with_the_conversation
    chat([[200, {}, contract.fetch("valid_estimate_fixture")]]).estimate_input(prompt: "Continue", render: true)

    assert_equal({}, request.dig(:body, "context_estimate", "model"))
    refute request.fetch(:body).fetch("context_estimate").key?("agent_configuration")
  end

  def test_conversation_detail_identifies_owned_execution_defaults_without_returning_the_catalog
    [true, false].each do |present|
      body = Marshal.load(Marshal.dump(contract.fetch("valid_fixture")))
      body.fetch("conversation")["agent_configuration_present"] = present
      conversation = chat([[200, {}, body]]).fetch

      assert_equal present, conversation.agent_configuration_present
      assert_equal present, conversation.to_h.fetch(:agent_configuration_present)
    end
  end

  def test_input_preview_and_regeneration_carry_configuration_separately_from_identity
    options = { agent_configuration: DECLARATION, model_selection: INTENT, fallback_models: [] }
    chat([[202, {}, contract.fetch("valid_input_fixture")]]).inputs.create(
      idempotency_key: "preset-input", kind: "direct_reply", text: "Review", model: "dev/text",
      to: "@review-bot", **options
    )
    fields = request.fetch(:body).fetch("input")
    assert_equal "@review-bot", fields.fetch("answering_user_public_id")
    assert_execution_selection(fields)

    chat([[200, {}, contract.fetch("valid_input_fixture")]]).inputs.update("input-1", **options)
    assert_execution_selection(request.fetch(:body).fetch("input"))

    chat([[200, {}, contract.fetch("valid_estimate_fixture")]]).estimate_input(model: "dev/text", **options)
    assert_execution_selection(request.fetch(:body).fetch("context_estimate"))

    chat([[202, {}, contract.fetch("valid_regeneration_fixture")]]).turns.regenerate(
      TURN_ID, idempotency_key: "preset-regeneration", **options
    )
    assert_execution_selection(request.fetch(:body).fetch("regeneration"))
  end

  def test_one_shot_capture_preserves_the_order_and_an_explicit_empty_list
    fixtures = CybrosAgentTest::ContractFixtures.pack("inference_requests.json")
    workspace([[202, {}, fixtures.fetch("valid_queued_fixture")]]).inference_requests.create(
      workload: "text_generation", model: "dev/text", input: "Review", idempotency_key: "one-shot-selection",
      model_selection: INTENT, fallback_models: ["other/text", "backup/text"]
    )
    fields = request.fetch(:body).fetch("inference_request")
    assert_equal INTENT, fields.fetch("model_selection")
    assert_equal ["other/text", "backup/text"], fields.fetch("fallback_models")

    workspace([[200, {}, fixtures.fetch("valid_input_estimate_fixture")]]).inference_requests.estimate_input(
      workload: "text_generation", model: "dev/text", input: "Review", model_selection: INTENT, fallback_models: []
    )
    fields = request.fetch(:body).fetch("input_estimate")
    assert_equal INTENT, fields.fetch("model_selection")
    assert_empty fields.fetch("fallback_models")
  end

  def test_detail_reads_keep_captured_intent_separate_from_the_actual_model_and_preserve_empty_lists
    runs = CybrosAgentTest::ContractFixtures.pack("runs.json")
    full = runs.fetch("valid_run_backed_fixture")
    full = full.merge("run" => full.fetch("run").merge("model_selection" => INTENT, "fallback_models" => ["other/text", "backup/text"]))
    run = workspace([[200, {}, full]]).run("run-1").fetch
    assert_equal INTENT, run.model_selection
    assert_equal ["other/text", "backup/text"], run.fallback_models
    assert_predicate run.model_selection, :frozen?
    assert_predicate run.fallback_models, :frozen?

    task_fixture = runs.fetch("valid_task_detail_fixture")
    task = workspace([[200, {}, task_fixture]]).run("run-1").task("work")
    assert_equal task_fixture.dig("task", "model_selection"), task.model_selection
    assert_empty task.fallback_models

    variants_fixture = contract.fetch("valid_variants_fixture")
    variants = chat([[200, {}, variants_fixture]]).turns.variants(TURN_ID)
    variants.items.zip(variants_fixture.fetch("variants")).each do |variant, raw|
      assert_equal raw["model_selection"], variant.model_selection
      assert_equal raw["fallback_models"], variant.fallback_models
    end

    inference_fixture = CybrosAgentTest::ContractFixtures.pack("inference_requests.json").fetch("valid_fixture")
    inference = workspace([[200, {}, inference_fixture]]).inference_requests.fetch("ir-1")
    assert_equal inference_fixture.dig("inference_request", "model_selection"), inference.model_selection
    assert_empty inference.fallback_models
  end

  private

    def assert_execution_selection(fields)
      assert_equal DECLARATION, fields.fetch("agent_configuration")
      assert_equal INTENT, fields.fetch("model_selection")
      assert_empty fields.fetch("fallback_models"), "disable differs from omission or inheritance"
      refute fields.key?("configuration"), "generation parameters are a separate field"
    end
end
