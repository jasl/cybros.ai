require "test_helper"
require "test_helpers/refused_step_test_helper"
require "test_helpers/gemini_finish_test_helper"

class AgentRuns::FinishErrorTest < ActiveJob::TestCase
  include RefusedStepTestHelper
  include GeminiFinishTestHelper

  setup do
    @agent = users(:agent)
    @workspace = workspaces(:shared)
    @attempts = {}
    declare_tools!(@agent, default_model: "dev/mock-text", fallback_model: "dev/mock-unmetered")
  end

  test "an abnormal finish fails a branch without retry fallback or partial tool expansion" do
    agent_run = composed_loop(creating_user: @agent)
    run_provider_step!(agent_run, "r1t0-review", gemini_error_result("MALFORMED_FUNCTION_CALL"), adapter_profile: "gemini_generate_content")
    review = node(agent_run, "r1t0-review")
    assert_equal ["failed", "provider_error", 0, 0], review.values_at(:status, :error_key, :auto_retries_used, :execution_generation)
    assert_equal({ "finish_quality" => "error" }, review.output_summary)
    assert_equal 1, step_invocations(review).count
    assert_nil review.output_body
    assert_not agent_run.agent_run_tasks.where(tool_call_id: "call_unusable").exists?
    texts = round_request_entries(node(agent_run, "r1t0-summary")).to_json
    assert_includes texts, "provider_error"
    assert_not_includes texts, "unfinished answer"
    assert_not_includes texts, "unfinished thought"
    assert_not_includes texts, "call_unusable"
    round = feed(agent_run, "round_result").find { |payload| payload["task_key"] == review.node_key }
    assert_equal ["failed", "error", "provider_error"], round.values_at("status", "finish_quality", "error_key")
  end

  test "a canceling loop preserves cancellation instead of retrying an errored generation" do
    agent_run = composed_loop(creating_user: @agent)
    AgentRuns::Stop.call(AgentRuns::Stop::Command.new(agent_run: agent_run, acting_user: @human, force: false))
    run_provider_step!(agent_run, "r1t0-review", gemini_error_result("OTHER"), adapter_profile: "gemini_generate_content")
    assert_equal "canceled", node(agent_run, "r1t0-review").status
    assert_equal 1, step_invocations(node(agent_run, "r1t0-review")).count
  end
end
