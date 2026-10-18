require "test_helpers/invocation_result_test_helper"

# A loop step a provider DECLINED, driven through the real chain: the loop
# lane mints and admits the step, the harness applies the provider's answer
# — the Anthropic shape by default, the lane whose refusal names its
# category — and the converger and the scheduler settle what follows.
# Includers carry `@agent`, `@workspace` and `@attempts = {}`.
module RefusedStepTestHelper
  extend ActiveSupport::Concern

  EXPLANATION = "The request asked for an exploit.".freeze

  included do
    include InvocationResultTestHelper
    include RunLaneTestHelper
  end

  private

    # A bounded branch and its selected-result reader exercise provider
    # refusal handling independently of any graph-authoring language.
    def composed_loop(creating_user: @human)
      run = seed(model("round1"), parallel([
        model("r1t0-review", "prompt" => "Review the patch", "on_failure" => "absorb"),
        model("r1t0-summary", "prompt" => "Summarize the review", "results" => ["r1t0-review"]),
      ]), model("final"), creating_user: creating_user)
      start_loop(run)
      run_step!(run, "round1", sse_success("review planned"))
      assert_equal "running", node(run, "r1t0-review").status
      run
    end

    def start_loop(run)
      result = Runs::Start.call(Runs::Start::Command.new(run: run, acting_user: @human))
      assert_predicate result, :accepted?
      schedule(run)
    end

    def refuse!(run, key, category: "cyber")
      refused = anthropic_result(
        "content" => [], "stop_reason" => "refusal",
        "stop_details" => { "type" => "refusal", "category" => category, "explanation" => EXPLANATION }
      )
      run_provider_step!(run, key, refused, adapter_profile: "anthropic_messages")
    end

    def anthropic_result(body)
      SimpleInference::Protocols::AnthropicMessages.new(
        base_url: "https://api.anthropic.com", api_key: "secret",
        adapter: InvocationHarness::FakeAdapter.new(json_response(200, {
          "id" => "msg_1", "usage" => { "input_tokens" => 2, "output_tokens" => 1 },
        }.merge(body)))
      ).create(model: "claude-opus-5-5", input: "Hello", max_output_tokens: 4096)
    end

    def run_step!(run, key, behaviour)
      apply_via(step_attempt(run, key), behaviour)
      converge(run)
    end

    def run_provider_step!(run, key, provider_result, adapter_profile:)
      apply_provider_result(step_attempt(run, key), provider_result, adapter_profile: adapter_profile)
      converge(run)
    end

    def converge(run)
      Runs::ConvergeTerminalSteps.call
      clear_enqueued_jobs
      schedule(run)
    end

    def step_attempt(run, key)
      ModelInvocations::AdmitQueuedWork.call.admitted.each do |candidate|
        @attempts[candidate.attempt.model_invocation_id] = candidate.attempt
      end
      clear_enqueued_jobs
      @attempts.fetch(node(run, key).selected_model_invocation_id)
    end

    def schedule(run)
      Runs::ScheduleReady.call(run_id: run.id)
      clear_enqueued_jobs
    end

    def node(run, key) = run.tasks.find_by!(node_key: key)

    # The node's own invocations, one per generation it ran, oldest first.
    def step_invocations(node)
      ModelInvocation.where(run_id: node.run_id)
        .where("internal_creation_key LIKE ?", "task:#{node.id}:%").order(:id)
    end

    # The loop's narration of one kind, oldest first, without the loop id
    # every item carries.
    def feed(run, item_type)
      run.event_items.where(item_type: item_type).order(:sequence)
        .map { |item| item.payload.except("run_public_id") }
    end
end
