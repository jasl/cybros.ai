require "test_helper"

class Conversations::Compaction::LastUsageTest < ActiveJob::TestCase
  include InvocationHarness
  include RunLaneTestHelper

  setup do
    @human = users(:member)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(accounts(:cybros))
  end

  test "usage from the replayed prefix still arms compaction after an unstarted model fails" do
    agent_run = loop_after_unstarted_failure(input_tokens: 9_000)

    report = loop_node(agent_run, "report")
    assert_equal "queued", report.status, "the full prefix waits for compaction"
    assert_nil report.selected_model_invocation_id
    assert_not_nil report.compaction.fetch("summary_source")
    item = agent_run.conversation_event_items.find_by!(item_type: "context_compacted")
    assert_equal "usage", item.payload.fetch("trigger")
  end

  test "truncation compares usage and the appended tail against the same recovered prefix" do
    agent_run = loop_after_unstarted_failure(input_tokens: 5_000, prompt: "Investigate the patch. " * 300)
    plan = loop_node(agent_run, "plan")
    report = loop_node(agent_run, "report")

    assert_equal "running", report.status
    prefix = round_request_entries(plan)
    assert_equal prefix, round_request_entries(report).take(prefix.length)
    record = Conversations::Compaction::LastUsage.for_round(report)
    assert_equal 5_000, record&.input_tokens

    run_loop_round!(agent_run, sse_success("The review could not run", usage: {
      "input_tokens" => 4_000, "output_tokens" => 3,
    }))

    result = agent_run.conversation_event_items.where(item_type: "round_result")
      .order(:sequence).last
    assert_equal "report", result.payload.fetch("task_key")
    assert_equal true, result.payload["input_truncation_suspected"]
    assert_empty agent_run.conversation_event_items.where(item_type: "context_compacted")
  end

  private

    def loop_after_unstarted_failure(input_tokens:, prompt: "Investigate the patch")
      agent_run = seed(
        model("plan", "prompt" => prompt),
        model("review", "prompt" => "Review the patch", "model" => { "model" => "dev/no-such-model" },
          "on_failure" => "absorb"),
        model("report", "prompt" => "Report the review outcome")
      )
      started = AgentRuns::Start.call(AgentRuns::Start::Command.new(
        agent_run: agent_run, acting_user: @human
      ))
      assert_predicate started, :accepted?
      schedule_loop!(agent_run)
      run_loop_round!(agent_run, sse_success("The patch changes the parser", usage: {
        "input_tokens" => input_tokens, "output_tokens" => 3,
      }))

      review = loop_node(agent_run, "review")
      assert_equal %w[failed unknown_model], review.values_at(:status, :error_key)
      assert_nil review.selected_model_invocation_id
      agent_run
    end
end
