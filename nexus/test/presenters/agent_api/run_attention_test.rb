require "test_helper"

class AgentAPI::RunAttentionTest < ActiveJob::TestCase
  include InvocationHarness
  include RunLaneTestHelper

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @agent = users(:agent)
    @workspace = workspaces(:shared)
    @attempts = {}
    DevModelLane.ensure_enabled!(@account)
  end

  test "the full read recovers the bounded question keys and overflow carried by the event" do
    run = seed(model("round1", "tools" => [Nexus::Tools::ASK]))
    start_loop(run)
    calls = Array.new(33) do |i|
      { id: "question_#{i}", name: "ask", arguments: { prompt: "Question #{i}?" }.to_json }
    end
    apply_via(loop_attempt(run), sse_success("questions", tool_calls: calls))
    Runs::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    perform_enqueued_jobs(only: [Runs::AskJob, Runs::ScheduleJob]) do
      Runs::ScheduleReady.call(run_id: run.id)
    end
    questions = run.tasks.where(type: Tasks::AwaitTask.sti_name)
    assert_equal 33, questions.where(status: "awaiting_input").count
    keys = questions.pluck(:node_key).sort

    full = AgentAPI::RunPresenter.full(run.reload)
    assert_equal keys.first(32), full.dig(:attention, :blocked_task_keys)
    assert_equal 1, full.dig(:attention, :blocked_task_overflow)
    # The first ask already announced the reason before the later jobs
    # added their questions. A fresh read projects the current whole set.
    announcement = Runs::Transition.send(:loop_items, run, announced: true)
      .find { |item| item[:type] == "attention_required" }.fetch(:payload)
    assert_equal announcement, full.fetch(:attention).stringify_keys
    assert_equal({ reason: "awaiting_human" }, AgentAPI::RunPresenter.basic(run)[:attention])
  end

  test "the full read names a held approval without confusing it with an ask" do
    declare_tools!(@agent, approval_mode: "ask")
    run = seed(model("round1", "tools" => [READ_TOOL]), creating_user: @agent, approval_mode: "ask")
    start_loop(run, actor: @agent)
    finish_step(run, "round1", sse_success("read", tool_calls: [
      { id: "read_call", name: "read_file", arguments: "{}" },
    ]))
    call = run.tasks.find_by!(tool_call_id: "read_call")
    assert_equal "needs_approval", call.status

    full = assert_attention_matches_event(run)
    assert_equal "approval_required", full.dig(:attention, :reason)
    assert_equal [call.node_key], full.dig(:attention, :blocked_task_keys)
    assert_not full.fetch(:attention).key?(:blocked_task_overflow)
  end

  test "the full read preserves the race absorption rule when naming an unresolved failure" do
    run = seed(
      parallel(model("fast"), [model("slow-head"), model("slow-tail")], until: "any", key: "race"),
      model("after")
    )
    start_loop(run)
    finish_step(run, "slow-head", json_response(400, { error: "no" }))
    finish_step(run, "fast", sse_success("won"))
    finish_step(run, "after", json_response(400, { error: "no" }))
    assert_equal "join_loser_canceled", loop_node(run, "slow-tail").error_key
    assert_equal "needs_attention", run.reload.status

    full = assert_attention_matches_event(run)
    assert_equal ["after"], full.dig(:attention, :blocked_task_keys),
      "the earlier failed loser is settled by its race, not another adjudication"
  end

  private

    def start_loop(run, actor: @human)
      started = Runs::Start.call(Runs::Start::Command.new(run: run, acting_user: actor))
      assert_predicate started, :accepted?
      schedule_loop!(run)
    end

    def finish_step(run, key, behavior)
      ModelInvocations::AdmitQueuedWork.call.admitted.each do |candidate|
        @attempts[candidate.attempt.model_invocation_id] = candidate.attempt
      end
      apply_via(@attempts.fetch(loop_node(run, key).selected_model_invocation_id), behavior)
      Runs::ConvergeTerminalSteps.call
      schedule_loop!(run)
    end

    def assert_attention_matches_event(run)
      run.reload
      event = run.event_items.where(item_type: "attention_required").order(:sequence).last
      assert_not_nil event, "the ordinary execution must actually ask for intervention"
      full = AgentAPI::RunPresenter.full(run)
      assert_equal event.payload.slice("reason", "blocked_task_keys", "blocked_task_overflow"),
        full.fetch(:attention).stringify_keys
      full
    end
end
