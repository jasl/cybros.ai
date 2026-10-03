require "test_helper"

class Executors::SourceStopTest < ActiveJob::TestCase
  include InvocationHarness
  include LoopLaneTestHelper

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @agent = users(:agent)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
  end

  test "a committed stop refuses a fresh claim before the scheduler drains the loop" do
    agent_loop = dispatched_loop
    row = agent_loop.agent_loop_nodes.find_by!(node_key: "read")
    AgentLoops::Stop.mark_now(agent_loop)
    assert_equal "running", agent_loop.reload.status
    assert_equal "dispatched", row.reload.status

    assert_equal :task_not_claimable, claim(agent_loop, row).outcome
    assert_nil row.reload.claimed_at
    assert_nil row.claim_token
  end

  test "a stopped ancestor refuses a derived tool claim before recovery reaches its owner" do
    source, derived, row = dispatched_derived_loop
    AgentLoops::Stop.mark_now(source)
    assert_not_predicate derived.reload, :stopped?
    assert_equal "running", derived.status
    assert_equal :task_not_claimable, claim(derived, row, executor: TaskExecutor.address_for(@agent)).outcome
    assert_nil row.reload.claimed_at
  end

  test "a graceful self stop keeps an already dispatched conversation tool claimable" do
    _source, derived, row = dispatched_derived_loop
    assert_predicate AgentLoops::Stop.call(AgentLoops::Stop::Command.new(
      agent_loop: derived, acting_user: @human, force: false)), :accepted?
    schedule_loop!(derived)
    assert_equal "canceling", derived.reload.status

    assert_predicate claim(derived, row, executor: TaskExecutor.address_for(@agent)), :accepted?
    assert row.reload.claimed_at
    assert_equal "dispatched", row.status
  end

  test "a later source cut does not rewrite an already granted claim" do
    agent_loop = dispatched_loop
    row = agent_loop.agent_loop_nodes.find_by!(node_key: "read")
    granted = claim(agent_loop, row)
    assert_predicate granted, :accepted?
    token = granted.value.claim_token
    claimed_at = granted.value.claimed_at

    AgentLoops::Stop.mark_now(agent_loop)
    assert_equal :task_not_claimable, claim(agent_loop, row).outcome
    assert_equal token, row.reload.claim_token
    assert_equal claimed_at, row.claimed_at
    assert_equal "dispatched", row.status, "the existing cancellation drain owns already granted work"
  end

  test "a completed source stop immediately cancels and nudges its claimed descendant without a sweep" do
    source, derived, row = dispatched_derived_loop
    executor = TaskExecutor.address_for(@agent)
    assert_predicate claim(derived, row, executor: executor), :accepted?
    clear_enqueued_jobs
    broadcasts = []

    ActionCable.server.stub(:broadcast, ->(stream, payload) { broadcasts << [stream, payload] }) do
      perform_enqueued_jobs(only: [AgentLoops::ScheduleJob, AgentLoops::Spawn::RelayJob]) do
        assert_predicate AgentLoops::Stop.call(AgentLoops::Stop::Command.forced(
          agent_loop: source, acting_user: @human)), :accepted?
      end
    end

    assert_equal "completed", source.reload.status
    assert_equal "canceled", row.reload.status
    assert_equal "canceled", derived.reload.status
    assert_predicate derived, :stopped?
    assert_includes broadcasts, [Nexus::RealtimeStreams.executor_inbox(executor.public_id),
      { event: { type: Executors::Nudge::WORK_CANCELED,
        agent_loop_public_id: derived.public_id, task_key: row.node_key } }]
    assert_no_enqueued_jobs(only: AgentLoops::ScheduleSweepJob)

    host = source.conversation
    Conversations::Turns::Converge.call(agent_loop_id: derived.id, conversation_id: host.id)
    post_input!(host, acting_user: @human, text: "continue after stopping background work",
      kind: "direct_reply", provider_id: "dev", model_ref: "mock-text")
    result = Conversations::Inputs::ApplyNext.call(conversation_id: host.id)
    assert_predicate result, :accepted?
    assert_not AgentLoops::SourceWork.stopped_variant_source?(result.value.active_variant)
  end

  private

    def dispatched_derived_loop
      declare_tools!(@agent)
      host = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
      source = create_loop_backed_turn(conversation: host, acting_user: @human,
        turn_status: "completed", variant_status: "completed", loop_status: "completed").agent_loop
      source.update!(delivered_at: Time.current, completed_at: Time.current)
      host.update!(active_turn: nil)
      accepted = Conversations::Inputs::Create.call(Conversations::Inputs::Create::Command.kernel(
        host: host, acting_user: @human, entries: [{ "text" => "background result" }],
        origin: "task_result", sender_conversation_public_id: host.public_id,
        agent_loop_public_id: source.public_id, task_key: "background", kind: "direct_reply",
        provider_id: "dev", model_ref: "mock-text"))
      assert_predicate accepted, :accepted?
      applied = Conversations::Inputs::ApplyNext.call(conversation_id: host.id)
      assert_predicate applied, :accepted?
      derived = applied.value.active_variant.agent_loop
      schedule_loop!(derived)
      run_loop_round!(derived, sse_success("reading", tool_calls: [
        { id: "call_read", name: "read_file", arguments: "{}" },
      ]))
      row = derived.agent_loop_nodes.find_by!(tool_call_id: "call_read")
      assert_equal "dispatched", row.status
      [source, derived, row]
    end

    def dispatched_loop
      agent_loop = seed(tool("read", "read_file", "input" => { "path" => "notes.md" }))
      assert_predicate AgentLoops::Start.call(AgentLoops::Start::Command.new(
        agent_loop: agent_loop, acting_user: @human)), :accepted?
      schedule_loop!(agent_loop)
      agent_loop
    end

    def claim(agent_loop, row, executor: suite_runner)
      Executors::Claim.call(Executors::Claim::Command.new(
        agent_loop: agent_loop, task_key: row.node_key, executor: executor))
    end
end
