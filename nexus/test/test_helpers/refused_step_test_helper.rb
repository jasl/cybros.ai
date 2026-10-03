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
    include LoopLaneTestHelper
  end

  private

    # A standalone loop whose round one composes a review and a summary
    # that reads it, both on the dev lane, the review with a retry it must
    # not spend. `creating_user` answers it, so its profile's fallback is
    # the one a refusal reads.
    def composed_loop(creating_user: @human)
      agent_loop = seed(model("round1", "tools" => [Nexus::Compose::DEFINITION], "retry" => 1),
        creating_user: creating_user)
      start_loop(agent_loop)
      run_step!(agent_loop, "round1", sse_success("composing", tool_calls: [
        { id: "compose_call", name: "compose", arguments: {
          script: <<~JS,
            const review = g.model({ prompt: "Review the patch", key: "review" });
            g.model({ prompt: "Summarize the review", key: "summary", results: [review] });
          JS
          wait: true,
        }.to_json },
      ]))
      AgentLoops::ComposeJob.perform_now(node(agent_loop, "r1t0").id)
      schedule(agent_loop)
      assert_equal "running", node(agent_loop, "r1t0-review").status
      agent_loop
    end

    def start_loop(agent_loop)
      result = AgentLoops::Start.call(AgentLoops::Start::Command.new(agent_loop: agent_loop, acting_user: @human))
      assert_predicate result, :accepted?
      schedule(agent_loop)
    end

    def refuse!(agent_loop, key, category: "cyber")
      refused = anthropic_result(
        "content" => [], "stop_reason" => "refusal",
        "stop_details" => { "type" => "refusal", "category" => category, "explanation" => EXPLANATION }
      )
      run_provider_step!(agent_loop, key, refused, adapter_profile: "anthropic_messages")
    end

    def anthropic_result(body)
      SimpleInference::Protocols::AnthropicMessages.new(
        base_url: "https://api.anthropic.com", api_key: "secret",
        adapter: InvocationHarness::FakeAdapter.new(json_response(200, {
          "id" => "msg_1", "usage" => { "input_tokens" => 2, "output_tokens" => 1 },
        }.merge(body)))
      ).create(model: "claude-opus-5-5", input: "Hello", max_output_tokens: 4096)
    end

    def run_step!(agent_loop, key, behaviour)
      apply_via(step_attempt(agent_loop, key), behaviour)
      converge(agent_loop)
    end

    def run_provider_step!(agent_loop, key, provider_result, adapter_profile:)
      apply_provider_result(step_attempt(agent_loop, key), provider_result, adapter_profile: adapter_profile)
      converge(agent_loop)
    end

    def converge(agent_loop)
      AgentLoops::ConvergeTerminalSteps.call
      clear_enqueued_jobs
      schedule(agent_loop)
    end

    def step_attempt(agent_loop, key)
      ModelInvocations::AdmitQueuedWork.call.admitted.each do |candidate|
        @attempts[candidate.attempt.model_invocation_id] = candidate.attempt
      end
      clear_enqueued_jobs
      @attempts.fetch(node(agent_loop, key).selected_model_invocation_id)
    end

    def schedule(agent_loop)
      AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)
      clear_enqueued_jobs
    end

    def node(agent_loop, key) = agent_loop.agent_loop_nodes.find_by!(node_key: key)

    # The node's own invocations, one per generation it ran, oldest first.
    def step_invocations(node)
      ModelInvocation.where(agent_loop_id: node.agent_loop_id)
        .where("internal_creation_key LIKE ?", "agent_loop_step:#{node.id}:%").order(:id)
    end

    # The loop's narration of one kind, oldest first, without the loop id
    # every item carries.
    def feed(agent_loop, item_type)
      agent_loop.conversation_event_items.where(item_type: item_type).order(:sequence)
        .map { |item| item.payload.except("agent_loop_public_id") }
    end
end
