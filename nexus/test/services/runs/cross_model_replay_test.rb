require "test_helper"

class Runs::CrossModelReplayTest < ActiveJob::TestCase
  include InvocationHarness

  ORIGIN_MODEL = "gemini/gemini-3.8-flash".freeze
  TARGET_MODEL = "gemini/review-target".freeze
  SIGNATURE = "origin-model-tool-signature".freeze
  READ_TOOL = {
    "type" => "function",
    "function" => { "name" => "read_file", "parameters" => { "type" => "object" } },
  }.freeze

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
    Accounts::ConfigureCostUnit.call(account: @account, cost_unit: "USD")
    ModelProviders::SetAPIKey.call(account: @account, provider_id: "gemini", api_key: "test-only-key")
    ModelProviders::EnableLane.call(account: @account, provider_id: "gemini", expected_lock_version: nil)

    current = ModelCatalog.current
    target = current.models.fetch(ORIGIN_MODEL).merge("model_id" => "gemini-review-model")
    @catalog = current.with(models: current.models.merge(TARGET_MODEL => target))
    ModelCatalog::CatalogValidation.validate_change(
      @catalog.models, @catalog.selectors, TARGET_MODEL, @catalog.providers
    )
  end

  test "an authored model switch removes foreign signatures already inside the prior request" do
    ModelCatalog.stub(:current, @catalog) do
      run = seed(
        model("read", "model" => selection(ORIGIN_MODEL),
          "prompt" => "Read the file", "tools" => [READ_TOOL]),
        model("review", "model" => selection(TARGET_MODEL),
          "prompt" => "Review the findings", "tools" => [READ_TOOL])
      )
      Runs::Start.call(Runs::Start::Command.new(run: run, acting_user: @human))
      schedule(run)
      apply_via(attempt_for(run, "read"), response([
        { "thought" => true, "text" => "Read the file before answering." },
        { "thoughtSignature" => SIGNATURE,
          "functionCall" => { "id" => "call_read", "name" => "read_file", "args" => { "path" => "file" } } },
      ]))
      Runs::ConvergeTerminalSteps.call
      schedule(run)

      tool = run.tasks.find_by!(node_key: "r1t0")
      assert_equal "dispatched", tool.status
      settled = Runs::Parks::Settle.call(node: tool, trusted: true,
        content: "the file contents", outcome: "completed")
      assert_predicate settled, :applied?
      schedule(run)

      continuation = attempt_for(run, "r1")
      assert_equal [SIGNATURE], wire_parts(continuation).filter_map { |part| part["thoughtSignature"] },
        "the same-model continuation must first seal and replay the origin signature"
      apply_via(continuation, response([{ "text" => "The file has been read." }]))
      Runs::ConvergeTerminalSteps.call
      schedule(run)

      review = run.tasks.find_by!(node_key: "review")
      assert_includes review.input_from_node_keys, "r1",
        "ordinary authoring must splice the next model after the tool continuation"
      attempt = attempt_for(run, "review")
      assert_equal "review-target", attempt.model_invocation.model_ref
      assert_equal "gemini-review-model", DevModelLane.profile_for_invocation(attempt.model_invocation).model_pin
      parts = wire_parts(attempt)
      assert_equal ["call_read"], parts.filter_map { |part| part.dig("functionCall", "id") }
      assert_equal ["call_read"], parts.filter_map { |part| part.dig("functionResponse", "id") }
      assert_empty parts.filter_map { |part| part["thoughtSignature"] },
        "the sealed prefix contains the origin model's signed call, which must not reach another model"
    end
  end

  private

    def selection(model_ref) = { "model" => model_ref, "reasoning_effort" => "low" }

    def schedule(run)
      Runs::ScheduleReady.call(run_id: run.id)
      clear_enqueued_jobs
    end

    def attempt_for(run, key)
      invocation_id = run.tasks.find_by!(node_key: key).selected_model_invocation_id
      admitted = ModelInvocations::AdmitQueuedWork.call.admitted
        .find { |candidate| candidate.invocation.id == invocation_id }
      assert admitted, "the authored model step must be admitted through its declared lane"
      clear_enqueued_jobs
      admitted.attempt
    end

    def wire_parts(attempt)
      built = build(attempt)
      assert_predicate built, :built?, built.refusal.inspect
      JSON.parse(built.request.payload).fetch("contents").flat_map { |message| message.fetch("parts") }
    end

    def response(parts)
      payload = {
        "responseId" => "cross-model-replay-response",
        "candidates" => [{ "content" => { "role" => "model", "parts" => parts }, "finishReason" => "STOP" }],
        "usageMetadata" => { "promptTokenCount" => 2, "candidatesTokenCount" => 3,
                             "thoughtsTokenCount" => 5, "totalTokenCount" => 10 },
      }
      { status: 200, headers: { "content-type" => "text/event-stream" },
        sse: ["data: #{JSON.generate(payload)}\n\n"] }
    end
end
