require "test_helper"
require_relative "../../../test_helpers/compaction_test_helper"

class Conversations::Compaction::CostLimitTest < ActiveJob::TestCase
  include CompactionTestHelper

  test "a cost refused mid-turn summary holds its original round and retries the same summary" do
    run = loop_at_the_wall
    schedule!(run)
    schedule!(run)
    summary = node(run, "k1")
    assert_equal "absorb", summary.on_failure
    refuse_cost!(run, summary)

    assert_equal ["needs_attention", "halt_failure"], run.reload.values_at(:status, :attention_reason)
    assert_equal ["queued", 1], node(run, "round2").values_at(:status, :remaining_dependencies)
    assert_equal "k1", node(run, "round2").compaction.fetch("summary_source")
    assert_equal Conversation::COST_LIMIT_REACHED, summary.reload.error_key
    assert_nil node(run, "round2").selected_model_invocation_id

    assert_predicate retry_summary(run, summary), :accepted?
    schedule!(run)
    settle!(run, "k1", "THE REPAIRED SUMMARY")
    schedule!(run)
    assert_equal "running", node(run, "round2").status
    assert_includes round_request_entries(node(run, "round2")).to_json, "THE REPAIRED SUMMARY"
    settle!(run, "round2", "done")
    schedule!(run)
    assert_equal "completed", run.reload.status
    assert_equal 1, run.tasks.where("node_key LIKE 'k%'").count
    assert_equal 0, node(run, "round1").execution_generation
  end

  test "a cost refused between-turn summary keeps the queued input pending until retry succeeds" do
    build_history!
    ask_greedily!
    assert_equal 0, drain!
    head = @conversation.inputs.sole
    turn = summary_turn
    run = summary_loop
    schedule_loop!(run)
    summary = run.tasks.sole
    refuse_cost!(run, summary)
    Conversations::Turns::Converge.call

    assert_equal "failed", turn.reload.status
    assert_equal "halt_failure", run.reload.turn_shape.failure_reason_key
    assert_equal Conversation::COST_LIMIT_REACHED, Runs::Transition.newest_blocking_error_key(run)
    assert_equal 0, drain!
    assert_equal "pending", head.reload.state
    assert_nil head.blocked_reason
    assert_equal ["run_held"], @conversation.event_items.where(item_type: "input_blocked")
      .map { |item| item.payload.fetch("blocked_reason") }.uniq
    assert_equal 0, @conversation.model_invocations.count
    assert_equal 1, @conversation.turns.where(kind: "compaction_summary").count

    assert_predicate retry_summary(run, summary), :accepted?
    schedule_loop!(run)
    run_loop_round!(run, sse_success("THE REPAIRED SUMMARY"))
    Conversations::Turns::Converge.call
    assert_equal "completed", turn.reload.status
    assert_equal 1, drain!
    assert_not Input.exists?(head.id)
    assert_equal 1, @conversation.turns.where(kind: "compaction_summary").count
    assert_includes @conversation.turns.order(:position).last.active_variant
      .model_invocation.content_bodies.find_by!(role: "request").effective_text, "THE REPAIRED SUMMARY"
  end

  test "retry reopens the same held summary turn while its model is still working" do
    build_history!(turns: 2)
    requested = Conversations::Compaction::Request.call(Conversations::Compaction::Request::Command.new(
      conversation: @conversation, acting_user: @human, model: "dev/mock-text"
    ))
    assert_predicate requested, :accepted?
    turn = summary_turn
    variant_id = turn.active_variant_id
    run = summary_loop
    schedule_loop!(run)
    summary = run.tasks.sole
    refuse_cost!(run, summary)
    Conversations::Turns::Converge.call
    assert_equal "failed", turn.reload.status

    assert_predicate retry_summary(run, summary), :accepted?
    schedule_loop!(run)
    Conversations::Turns::Converge.call
    assert_equal "running", turn.reload.status
    assert_equal variant_id, turn.active_variant_id
    assert_equal turn.id, @conversation.reload.active_turn_id

    run_loop_round!(run, sse_success("THE RETRIED SUMMARY"))
    Conversations::Turns::Converge.call
    assert_equal "completed", turn.reload.status
    assert_equal variant_id, turn.active_variant_id
    assert_equal 1, turn.variants.count
    assert_nil @conversation.reload.active_turn_id
  end

  %w[empty failed].each do |result|
    test "a fast #{result} summary retry wakes the input waiting behind its cost hold" do
      build_history!
      ask_greedily!
      assert_equal 0, drain!
      head = @conversation.inputs.sole
      turn = summary_turn
      run = summary_loop
      schedule_loop!(run)
      summary = run.tasks.sole
      refuse_cost!(run, summary)
      Conversations::Turns::Converge.call
      assert_equal "failed", turn.reload.status
      assert_equal 0, drain!
      assert_nil head.deliver_at
      clear_enqueued_jobs
      assert_no_enqueued_jobs(only: Conversations::Inputs::DrainJob) do
        Conversations::Turns::Converge.call
      end

      assert_predicate retry_summary(run, summary), :accepted?
      schedule_loop!(run)
      response = result == "empty" ? responses_output([]) : json_response(400, { "error" => "bad" })
      run_loop_round!(run, response)
      assert_equal(result == "empty" ? "completed" : "needs_attention", run.reload.status)
      assert_not summary.reload.usable_summary?
      assert_equal "failed", turn.reload.status, "the retry completed before the reopen job ran"

      perform_enqueued_jobs(only: Conversations::Inputs::DrainJob) do
        Conversations::Turns::Converge.call
      end

      assert_equal "blocked", head.reload.state
      assert_equal "estimated_input_exceeds_model_limit", head.blocked_reason
      assert_equal 1, @conversation.turns.where(kind: "compaction_summary").count
      assert_equal 1, summary.reload.execution_generation

      accept!(text: "wait behind the blocked input")
      clear_enqueued_jobs
      sequence = @conversation.event_items.maximum(:sequence)
      assert_no_enqueued_jobs(only: Conversations::Inputs::DrainJob) do
        Conversations::Turns::Converge.call
      end
      assert_equal sequence, @conversation.event_items.maximum(:sequence)
    end
  end

  private

    def refuse_cost!(run, summary)
      invocation = ModelInvocation.find(summary.selected_model_invocation_id)
      invocation.with_lock { invocation.terminalize(status: "failed", reason_key: Conversation::COST_LIMIT_REACHED) }
      Runs::ConvergeTerminalSteps.call
      schedule!(run)
    end

    def retry_summary(run, summary)
      Runs::Tasks::Retry.call(Runs::Tasks::Retry::Command.new(
        run: run, task_key: summary.node_key, acting_user: @human
      ))
    end
end
