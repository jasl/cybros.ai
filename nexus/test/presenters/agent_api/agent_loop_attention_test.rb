require "test_helper"

class AgentAPI::AgentLoopAttentionTest < ActiveJob::TestCase
  include InvocationHarness
  include LoopLaneTestHelper

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @agent = users(:agent)
    @workspace = workspaces(:shared)
    @attempts = {}
    DevModelLane.ensure_enabled!(@account)
  end

  test "the full read recovers the bounded question keys and overflow carried by the event" do
    agent_loop = seed(model("round1", "tools" => [Nexus::Tools::ASK]))
    start_loop(agent_loop)
    calls = Array.new(33) do |i|
      { id: "question_#{i}", name: "ask", arguments: { prompt: "Question #{i}?" }.to_json }
    end
    apply_via(loop_attempt(agent_loop), sse_success("questions", tool_calls: calls))
    AgentLoops::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    perform_enqueued_jobs(only: [AgentLoops::AskJob, AgentLoops::ScheduleJob]) do
      AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)
    end
    questions = agent_loop.agent_loop_nodes.where(type: AgentLoopNodes::AwaitTask.sti_name)
    assert_equal 33, questions.where(status: "awaiting_input").count
    keys = questions.pluck(:node_key).sort

    full = AgentAPI::AgentLoopPresenter.full(agent_loop.reload)
    assert_equal keys.first(32), full.dig(:attention, :blocked_task_keys)
    assert_equal 1, full.dig(:attention, :blocked_task_overflow)
    # The first ask already announced the reason before the later jobs
    # added their questions. A fresh read projects the current whole set.
    announcement = AgentLoops::Transition.send(:loop_items, agent_loop, announced: true)
      .find { |item| item[:type] == "attention_required" }.fetch(:payload)
    assert_equal announcement, full.fetch(:attention).stringify_keys
    assert_equal({ reason: "awaiting_human" }, AgentAPI::AgentLoopPresenter.basic(agent_loop)[:attention])
  end

  test "the full read names a held approval without confusing it with an ask" do
    declare_tools!(@agent, approval_mode: "ask")
    agent_loop = seed(model("round1", "tools" => [READ_TOOL]), creating_user: @agent, approval_mode: "ask")
    start_loop(agent_loop, actor: @agent)
    finish_step(agent_loop, "round1", sse_success("read", tool_calls: [
      { id: "read_call", name: "read_file", arguments: "{}" },
    ]))
    call = agent_loop.agent_loop_nodes.find_by!(tool_call_id: "read_call")
    assert_equal "needs_approval", call.status

    full = assert_attention_matches_event(agent_loop)
    assert_equal "approval_required", full.dig(:attention, :reason)
    assert_equal [call.node_key], full.dig(:attention, :blocked_task_keys)
    assert_not full.fetch(:attention).key?(:blocked_task_overflow)
  end

  test "the full read preserves the race absorption rule when naming an unresolved failure" do
    agent_loop = seed(
      parallel(model("fast"), [model("slow-head"), model("slow-tail")], until: "any", key: "race"),
      model("after")
    )
    start_loop(agent_loop)
    finish_step(agent_loop, "slow-head", json_response(400, { error: "no" }))
    finish_step(agent_loop, "fast", sse_success("won"))
    finish_step(agent_loop, "after", json_response(400, { error: "no" }))
    assert_equal "join_loser_canceled", loop_node(agent_loop, "slow-tail").error_key
    assert_equal "needs_attention", agent_loop.reload.status

    full = assert_attention_matches_event(agent_loop)
    assert_equal ["after"], full.dig(:attention, :blocked_task_keys),
      "the earlier failed loser is settled by its race, not another adjudication"
  end

  private

    def start_loop(agent_loop, actor: @human)
      started = AgentLoops::Start.call(AgentLoops::Start::Command.new(agent_loop: agent_loop, acting_user: actor))
      assert_predicate started, :accepted?
      schedule_loop!(agent_loop)
    end

    def finish_step(agent_loop, key, behavior)
      ModelInvocations::AdmitQueuedWork.call.admitted.each do |candidate|
        @attempts[candidate.attempt.model_invocation_id] = candidate.attempt
      end
      apply_via(@attempts.fetch(loop_node(agent_loop, key).selected_model_invocation_id), behavior)
      AgentLoops::ConvergeTerminalSteps.call
      schedule_loop!(agent_loop)
    end

    def assert_attention_matches_event(agent_loop)
      agent_loop.reload
      event = agent_loop.conversation_event_items.where(item_type: "attention_required").order(:sequence).last
      assert_not_nil event, "the ordinary execution must actually ask for intervention"
      full = AgentAPI::AgentLoopPresenter.full(agent_loop)
      assert_equal event.payload.slice("reason", "blocked_task_keys", "blocked_task_overflow"),
        full.fetch(:attention).stringify_keys
      full
    end
end
