require "test_helper"

# THE HELD ROW'S CLOCK CAN FIRE. A tool call parked for its approver rests on the ask's 24 h clock —
# `MAX_HOLD`, never the tool's run clock, which starts at dispatch — and expires `timed_out
# approval_expired` under the row's own `on_failure` when nobody decides: never `uncertain` (nothing
# was dispatched, nothing was claimed). The clock is one derivation in three places (Ruby, the
# sweep's SQL twin, the index predicate); this file pins the Ruby half under `travel_to` and drives
# the sweep with a back-dated clock, because the sweep reads the DATABASE clock
# (`DatabaseClock.now`), which `travel_to` does not move.
class AgentLoops::ApprovalHoldTest < ActiveJob::TestCase
  include InvocationHarness

  MAX_HOLD = AgentLoopNodes::AwaitTask::MAX_HOLD

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @agent = users(:agent)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
  end

  def node(agent_loop, key) = agent_loop.agent_loop_nodes.find_by!(node_key: key)

  def schedule!(agent_loop)
    AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)
    clear_enqueued_jobs
  end

  # A model round under `ask` calling `read_file` once: the fan member
  # parks for its approver, the continuation waits on it.
  def park!(creating_user: @agent)
    agent_loop = seed(model("round1", "tools" => [LoopLaneTestHelper::READ_TOOL]),
      creating_user: creating_user, approval_mode: "ask")
    AgentLoops::Start.call(AgentLoops::Start::Command.new(agent_loop: agent_loop, acting_user: creating_user))
    clear_enqueued_jobs
    schedule!(agent_loop)
    round = node(agent_loop, "round1")
    admitted = ModelInvocations::AdmitQueuedWork.call.admitted.find do |candidate|
      candidate.attempt.model_invocation_id == round.selected_model_invocation_id
    end
    clear_enqueued_jobs
    apply_via(admitted.attempt, sse_success("reading", tool_calls: [
      { id: "call_read", name: "read_file", arguments: "{}" },
    ]))
    AgentLoops::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    schedule!(agent_loop)
    call = agent_loop.agent_loop_nodes.find_by!(tool_call_id: "call_read")
    assert_equal "needs_approval", call.status
    [agent_loop, call]
  end

  def settle_timeout(call) = AgentLoops::Parks::Settle.call(node: call.reload, timeout: true)

  test "Human shutdown withdraws a paused approval addressee without ending the approval" do
    assert_equal :changed, @agent.change_steward(to: @human)
    agent_loop, call = park!
    address = TaskExecutor.address_for(@agent)
    epoch = address.credential_epoch
    armed = call.await_started_at
    assert_predicate AgentLoops::Pause.call(AgentLoops::Pause::Command.graceful(
      agent_loop: agent_loop, acting_user: @agent
    )), :accepted?
    assert_equal :removed, @human.remove
    assert_equal :restored, @human.restore
    TaskExecutor.converge
    assert_equal epoch, address.reload.credential_epoch

    pass = AgentLoops::Parks::TimeoutSweep.call
    assert_equal [0, 1], pass.counts.values_at(:expired, :revoked)
    assert_equal ["needs_approval", nil, nil, armed],
      call.reload.values_at(:status, :addressed_executor_id, :error_key, :await_started_at)
    assert_equal "paused", agent_loop.reload.status
    item = agent_loop.conversation_event_items.where(item_type: "task_readdressed").sole
    assert_equal AgentLoops::Parks::Revoke::APPROVAL_DETAIL, item.payload.fetch("detail")
    TaskExecutor.converge
    assert_equal epoch + 1, address.reload.credential_epoch
    assert_not_predicate address, :shutdown_pending?
  end

  test "the deadline is await_started_at + MAX_HOLD exactly, whatever the tool's run clock" do
    _agent_loop, call = park!
    assert_equal call.await_started_at + MAX_HOLD, call.deadline_at
    AgentLoopNode.where(id: call.id).update_all(timeout_ms: 1_000)
    assert_equal call.await_started_at + MAX_HOLD, call.reload.deadline_at, "a run clock of 1 s does not shorten the hold"
    assert_not call.deadline_passed?
  end

  test "under travel_to the hold stands at 24 h minus a second and expires at 24 h plus a second, absorbed by its policy" do
    agent_loop, call = park!
    armed = call.await_started_at
    assert_equal "absorb", call.on_failure, "a fan member absorbs"

    travel_to(armed + MAX_HOLD - 1.second) do
      assert_not call.reload.deadline_passed?
      assert_equal :idle, settle_timeout(call).outcome, "the sweep's recheck refuses to expire it early"
      assert_equal "needs_approval", call.reload.status
      assert_equal 0, AgentLoops::Parks::TimeoutSweep.call[:expired]
    end

    travel_to(armed + MAX_HOLD + 1.second) do
      assert_predicate call.reload, :deadline_passed?
      assert_predicate settle_timeout(call), :applied?
    end

    call.reload
    assert_equal %w[timed_out approval_expired], call.values_at(:status, :error_key)
    assert_nil call.error_detail
    assert_nil call.approval_origin, "nobody decided: no fact"
    assert_nil call.approval_decided_at
    assert_nil call.claimed_at
    assert_not_nil call.completed_at
    assert_equal :resolved, AgentLoops::Graph.settlement_of(call), "absorb resolves; the model learns nobody answered"
    assert_includes AgentLoops::RoundReplay::Pairing.output_for(call), "Nobody approved this tool call before it expired.",
      "the sentence the next round reads"
    schedule!(agent_loop)
    assert_equal "running", node(agent_loop, "r1").status, "the continuation is released, not stranded"
    assert_nil agent_loop.reload.attention_reason, "the announcement clears with the row"
    assert_equal "running", agent_loop.status
  end

  test "the sweep expires a held row by the SQL twin, to approval_expired and never uncertain" do
    _agent_loop, call = park!
    # A non-replayable profile would make a CLAIMED expiry `uncertain`; a
    # held row was never claimed, so the word is the hold's own.
    AgentLoopNode.where(id: call.id).update_all(effect_profile: nil, timeout_ms: 1_000)
    assert_not call.reload.replayable?

    AgentLoopNode.where(id: call.id).update_all(await_started_at: (MAX_HOLD - 1.minute).ago)
    assert_equal 0, AgentLoops::Parks::TimeoutSweep.call[:expired], "23 h 59 m: still the approver's"
    assert_equal "needs_approval", call.reload.status

    AgentLoopNode.where(id: call.id).update_all(await_started_at: (MAX_HOLD + 1.second).ago)
    assert_equal 1, AgentLoops::Parks::TimeoutSweep.call[:expired]
    assert_equal %w[timed_out approval_expired], call.reload.values_at(:status, :error_key)
  end

  test "a person's settle on a held row is task_not_running: the timeout path is the only door" do
    _agent_loop, call = park!
    refused = AgentLoops::Parks::Settle.call(node: call, trusted: true, content: "done", outcome: "completed")
    assert_equal :task_not_running, refused.outcome
    assert_equal "needs_approval", call.reload.status
  end

  test "a claim on a held row is not_claimable_kind for its addressee, not_addressed_here for the runner" do
    agent_loop, call = park!
    claim = ->(executor) {
      Executors::Claim.call(Executors::Claim::Command.new(
        agent_loop: agent_loop, task_key: call.node_key, executor: executor
      )).outcome
    }
    assert_equal :not_claimable_kind, claim.call(TaskExecutor.address_for(@agent))
    assert_equal :not_addressed_here, claim.call(suite_runner)
    assert_nil call.reload.claimed_at
  end

  test "a paused loop's held clock stands still, and resume shifts it by the pause" do
    agent_loop, call = park!
    armed = call.await_started_at
    paused = AgentLoops::Pause.call(AgentLoops::Pause::Command.graceful(agent_loop: agent_loop, acting_user: @agent))
    assert_predicate paused, :accepted?, paused.outcome.inspect
    assert_equal "paused", agent_loop.reload.status

    travel_to(armed + MAX_HOLD + 1.hour) do
      assert_not call.reload.deadline_passed?, "the virtual clock stands at paused_at"
      assert_equal :idle, settle_timeout(call).outcome
      assert_equal "needs_approval", call.reload.status

      resumed = AgentLoops::Resume.call(AgentLoops::Resume::Command.new(agent_loop: agent_loop, acting_user: @agent))
      assert_predicate resumed, :accepted?, resumed.outcome.inspect
      call.reload
      assert_operator call.await_started_at, :>, armed + MAX_HOLD, "the debt is repaid: the clock moved by the pause"
      assert_not call.deadline_passed?
      assert_equal "needs_approval", call.status
    end
  end

  test "a held row that expires during a graceful drain settles idle: the stop took it first" do
    agent_loop, call = park!
    stopped = AgentLoops::Stop.call(AgentLoops::Stop::Command.new(agent_loop: agent_loop, acting_user: @agent, force: false))
    assert_predicate stopped, :accepted?, stopped.outcome.inspect
    assert_equal %w[canceled loop_canceled], call.reload.values_at(:status, :error_key)

    AgentLoopNode.where(id: call.id).update_all(await_started_at: (MAX_HOLD + 1.second).ago)
    assert_equal 0, AgentLoops::Parks::TimeoutSweep.call[:expired], "a canceled row is off the frontier"
    assert_equal :idle, settle_timeout(call).outcome
  end
end
