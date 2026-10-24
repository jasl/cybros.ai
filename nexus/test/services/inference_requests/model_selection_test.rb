require "test_helper"

class InferenceRequests::ModelSelectionTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
    @workspace = workspaces(:shared)
    @creator = users(:agent)
    DevModelLane.ensure_enabled!(@account)
    @port = DevModelLane.port
  end

  test "explicit selection equal to the configured model and its ordered list remain captured" do
    @creator.update!(default_model: "dev/mock-text", fallback_models: ["dev/mock-unmetered"])
    intent = { "source" => "explicit", "model" => "dev/mock-text", "constraint" => "route", "alternatives" => [] }
    result = create(model_selection: intent, fallback_models: [])
    assert_predicate result, :created?
    request = InferenceRequest.find_by!(public_id: result.accepted.fetch("inference_request_public_id"))
    @creator.update!(default_model: "dev/mock-priced", fallback_models: ["dev/mock-priced"])

    assert_equal intent, request.reload.model_selection.as_json
    assert_equal [], request.fallback_models
    detail = AgentAPI::InferenceRequestPresenter.full(request)
    assert_equal intent, detail.fetch(:model_selection).stringify_keys
    assert_equal [], detail.fetch(:fallback_models)
    refute AgentAPI::InferenceRequestPresenter.basic(request).key?(:model_selection)
  end

  test "unavailable initial routes are skipped before creating an invocation and preview selects the same route" do
    options = { submitted: Nexus::SubmittedModelSelection.new(model: "missing/text", reasoning_effort: nil),
                fallback_models: ["missing/second", "dev/mock-text"] }
    counts = [InferenceRequest.count, ModelInvocation.count, ModelInvocationAttempt.count]
    command = InferenceRequests::InputEstimate::Command.new(**attributes.merge(options).except(:billing_subject, :idempotency_key))
    estimate = InferenceRequests::InputEstimate.call(command: command, port: @port)
    assert_predicate estimate, :estimated?, estimate.refusal.inspect
    assert_equal "mock-text", estimate.estimate.selection.model_ref
    assert_equal counts, [InferenceRequest.count, ModelInvocation.count, ModelInvocationAttempt.count]

    result = create(**options)
    assert_predicate result, :created?, result.refusal.inspect
    request = InferenceRequest.find_by!(public_id: result.accepted.fetch("inference_request_public_id"))
    assert_equal "missing/text", request.model_selection.model
    assert_equal "mock-text", request.model_invocation.model_ref
    assert_equal counts[1] + 1, ModelInvocation.count
    assert_equal counts[2], ModelInvocationAttempt.count
    event = request.inference_request_event_items.find_by!(item_type: "run_status")
    assert_equal %w[missing/text missing/second], event.payload.fetch("model_skips").map { |skip| skip.fetch("model") }
    assert_equal "dev/mock-text", event.payload.dig("model_change", "to")
  end

  test "an overflowing fallback is skipped and the later candidate seals the accepted input" do
    options = { submitted: Nexus::SubmittedModelSelection.new(model: "missing/text", reasoning_effort: nil),
                fallback_models: %w[dev/mock-text dev/mock-windowless] }
    overflow = ModelRequests::TokenCount::Result.counted(1_000_000, exact: true)
    ModelRequests::TokenCount.stub(:count, overflow) do
      result = create(**options)
      assert_predicate result, :created?, result.refusal.inspect
      request = InferenceRequest.find_by!(public_id: result.accepted.fetch("inference_request_public_id"))
      assert_equal "mock-windowless", request.model_invocation.model_ref
      body = request.model_invocation.content_bodies.find_by!(role: "request")
      assert_predicate body, :sealed?
      assert_equal attributes.fetch(:input).sole, JSON.parse(body.effective_text)
      event = request.inference_request_event_items.find_by!(item_type: "run_status")
      assert_equal %w[unknown_provider estimated_input_exceeds_model_limit],
        event.payload.fetch("model_skips").map { |skip| skip.fetch("reason") }
    end
  end

  test "selection intent and ordered candidates participate in create idempotency" do
    key = SecureRandom.uuid
    intent = { "source" => "explicit", "model" => "dev/mock-text", "constraint" => "route", "alternatives" => [] }
    assert_predicate create(idempotency_key: key, model_selection: intent, fallback_models: []), :created?
    assert_predicate create(idempotency_key: key, model_selection: intent, fallback_models: []), :replayed?
    assert_equal :idempotency_mismatch,
      create(idempotency_key: key, model_selection: intent.merge("constraint" => "any"), fallback_models: []).outcome
    assert_equal :idempotency_mismatch,
      create(idempotency_key: key, model_selection: intent, fallback_models: ["dev/mock-priced"]).outcome
  end

  private

    def attributes
      { workspace: @workspace, creating_user: @creator, workload: "text_generation",
        submitted: DevModelLane.submission_for("text_generation"), configuration: {},
        input: [{ "role" => "user", "parts" => [{ "type" => "text", "text" => "Question" }] }],
        upload_public_ids: [], billing_subject: nil, idempotency_key: SecureRandom.uuid }
    end

    def create(**overrides)
      command = InferenceRequests::Create::Command.new(**attributes.merge(overrides))
      InferenceRequests::Create.call(command: command, port: @port)
    end
end
