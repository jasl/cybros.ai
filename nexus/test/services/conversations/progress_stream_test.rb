require "test_helper"
require_relative "../../test_helpers/agent_membership_test_helper"

# THE KERNEL'S OWN FRAMES: three words on the host's `progress` feed for facts no row or settled
# item carries at their instant — `round_started` when an attempt is dialled, `step_started` when a
# tool row is dispatched, run or held, `step_claimed` when an executor takes it. Decided eagerly at
# the transition, published after commit, never a row; the transcript's own Source supplies the keys
# and the hidden gate.
class Conversations::ProgressStreamTest < ActiveJob::TestCase
  include AgentMembershipTestHelper
  include InvocationHarness
  include RunLaneTestHelper

  AT = /\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z\z/
  FAN = 60
  # What the keys cost a pass beyond the dispatch's own statements:
  # NOTHING. `ScheduleReady` holds one locked loop per pass whose rows it
  # dispatches; each row reaches its loop through the inverse association,
  # and the loop object has already resolved its host and its seam for the
  # dispatch itself — so sixty frames' keys are sixty reads of one cache.
  KEY_QUERIES_PER_PASS = 0

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @agent = users(:agent)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
    @published = []
  end

  def tool(key, **over) = super(key, "read_file", "input" => { "path" => key }, **over)

  def capture_stream
    ActionCable.server.stub(:broadcast, ->(stream, payload) { @published << [stream.to_s, payload] }) { yield }
  end

  def frames = @published.select { |stream, _| stream.end_with?(":progress") }.map { |_, payload| payload.fetch(:frame) }
  def frame_streams = @published.select { |stream, _| stream.end_with?(":progress") }.map(&:first).uniq
  def loop_stream(agent_run) = "agent_api:v1:run:#{agent_run.public_id}:progress"
  def conversation_stream = "agent_api:v1:conversation:#{@conversation.public_id}:progress"

  def start!(agent_run)
    AgentRuns::Start.call(AgentRuns::Start::Command.new(agent_run: agent_run, acting_user: @human))
    clear_enqueued_jobs
    AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
    clear_enqueued_jobs
    agent_run
  end

  def claim!(agent_run, key)
    result = Executors::Claim.call(Executors::Claim::Command.new(
      agent_run: agent_run, task_key: key, executor: suite_runner
    ))
    assert_predicate result, :accepted?, result.outcome.inspect
    result
  end

  # The real attempt the admission plane mints, not a hand-built row.
  def attempt_for(agent_run, key)
    @admitted ||= {}
    ModelInvocations::AdmitQueuedWork.call.admitted.each do |candidate|
      @admitted[candidate.attempt.model_invocation_id] = candidate.attempt
    end
    clear_enqueued_jobs
    @admitted.fetch(loop_node(agent_run, key).selected_model_invocation_id)
  end

  # The whole sequence both hosts run, with the sink both hosts build (C18).
  def run_attempt!(attempt, behaviour = sse_success("hi"))
    fake_dispatch(behaviour) do
      ModelInvocations::ExecuteAttempt.call(
        attempt: attempt, host: "solid_queue",
        stream_sink: ModelInvocations::StreamSink.for(attempt: attempt, host: "solid_queue")
      )
    end
    clear_enqueued_jobs
  end

  def run_backed_turn!
    declare_tools!(@agent)
    turn, agent_run = materialize_loop_reply!(@conversation, agent: @agent)
    schedule_loop!(agent_run)
    [turn, agent_run]
  end

  # Every statement but the schema's and the transaction's own.
  def count_queries
    count = 0
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_, _, _, _, payload|
      count += 1 unless %w[SCHEMA TRANSACTION].include?(payload[:name])
    end
    yield
    count
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  def row_counts = [AgentRunTask.count, ConversationEventItem.count, ContentBody.count, AgentRunEdge.count]

  # --- step_started ---------------------------------------------------------

  test "a tool row dispatched through the stage narrates step_started twice with its name, held then dispatched" do
    agent_run = seed(tool("alpha"))

    capture_stream { start!(agent_run) }

    assert_equal [loop_stream(agent_run)], frame_streams, "a standalone loop's frames ride its own channel"
    assert_equal [%w[step_started alpha read_file needs_approval], %w[step_started alpha read_file dispatched]],
      frames.map { |frame| frame.values_at("type", "task_key", "tool_name", "status") },
      "the park and the release are both news; under bypass the stage still crosses"
    frames.each do |frame|
      assert_equal %w[type run_public_id task_key tool_name status at], frame.keys
      assert_equal agent_run.public_id, frame.fetch("run_public_id")
      assert_match AT, frame.fetch("at"), "milliseconds on the wire"
    end
    assert @published.select { |_, payload| payload.key?(:frame) }.all? { |_, payload| payload.keys == [:frame] },
      "the envelope is {frame}, never {event}"
  end

  test "a round's own transitions and a call's settle narrate no frame — the settled snapshot is the end" do
    agent_run = seed(tool("alpha"))
    start!(agent_run)
    call = loop_node(agent_run, "alpha")

    capture_stream { AgentRuns::Transition.node(call, status: "completed", completed_at: Time.current) }
    assert_empty frames, "a terminal is the transcript's `call` snapshot, never a frame"

    round_loop = seed(model("plan"))
    capture_stream { start!(round_loop) }
    assert_empty frames, "a round going `running` is `task_status`; its frame is the attempt's dial"
  end

  # --- step_claimed ---------------------------------------------------------

  test "a claim narrates step_claimed with the claimant and no status word" do
    agent_run = start!(seed(tool("alpha")))

    capture_stream { claim!(agent_run, "alpha") }

    frame = frames.sole
    assert_equal %w[type run_public_id task_key tool_name executor_public_id at], frame.keys
    assert_equal ["step_claimed", "alpha", "read_file", suite_runner.public_id],
      frame.values_at("type", "task_key", "tool_name", "executor_public_id")
    assert_match AT, frame.fetch("at")
  end

  # --- round_started --------------------------------------------------------

  test "an attempt dialled narrates round_started with the mark, the attempt, the model and the sealed bytes" do
    agent_run = start!(seed(model("plan")))
    attempt = attempt_for(agent_run, "plan")

    capture_stream { run_attempt!(attempt) }

    frame = frames.sole
    assert_equal [loop_stream(agent_run)], frame_streams
    assert_equal %w[type run_public_id task_key mainline attempt model request_bytes at], frame.keys
    assert_equal ["round_started", agent_run.public_id, "plan", true, 1, "dev/mock-text"],
      frame.values_at("type", "run_public_id", "task_key", "mainline", "attempt", "model")
    bytes = loop_node(agent_run, "plan").sealed_request_bytes
    assert_kind_of Integer, bytes
    assert_operator bytes, :>, 0
    assert_equal bytes, frame.fetch("request_bytes"), "the size the request was sealed with — the task read's number"
    assert_match AT, frame.fetch("at")
    first_frame = @published.index { |stream, _| stream.end_with?(":progress") }
    first_delta = @published.index { |stream, _| stream.end_with?(":transcript") }
    assert_operator first_frame, :<, first_delta, "dialled before the first byte: the frame precedes every delta"
  end

  test "a branch round's frame carries mainline false" do
    agent_run = seed(model("plan"))
    AgentRunTask.where(id: loop_node(agent_run, "plan").id)
      .update_all(continuation_source: AgentRuns::Tasks::Compile::BRANCH)
    start!(agent_run)

    capture_stream { run_attempt!(attempt_for(agent_run, "plan")) }

    assert_equal false, frames.sole.fetch("mainline")
  end

  test "a loop-backed round's frames ride the CONVERSATION's progress feed with the turn keys through the seam" do
    turn, agent_run = run_backed_turn!

    capture_stream do
      run_attempt!(loop_attempt(agent_run), sse_success("reading", tool_calls: [
        { id: "c1", name: "read_file", arguments: { "path" => "x" }.to_json },
      ]))
      AgentRuns::ConvergeTerminalSteps.call
      clear_enqueued_jobs
      schedule_loop!(agent_run)
    end

    assert_equal [conversation_stream], frame_streams, "a loop-backed loop has no channel of its own"
    assert_equal [%w[round_started r1], %w[step_started r2t0], %w[step_started r2t0]],
      frames.map { |frame| frame.values_at("type", "task_key") },
      "the round dialled, then r1's call — keyed by the round that READS it — held and dispatched"
    frames.each do |frame|
      assert_equal turn.public_id, frame.fetch("turn_public_id")
      assert_equal turn.active_variant.public_id, frame.fetch("variant_public_id")
      assert_equal agent_run.public_id, frame.fetch("run_public_id")
    end
  end

  test "a direct reply narrates no frame" do
    result = Conversations::Inputs::Create.call(Conversations::Inputs::Create::Command.new(
      host: @conversation, acting_user: @human, kind: "direct_reply", role: "user",
      entries: [{ "text" => "hello" }], visible_in_context: true, delivery_mode: "queue",
      context_mode: nil, context_options: nil, expected_context_revision: nil,
      expected_tail_turn_public_id: nil, provider_id: "dev", model_ref: "mock-text",
      reasoning_effort: nil, request_options: nil
    ))
    assert_predicate result, :accepted?
    Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)
    admitted = ModelInvocations::AdmitQueuedWork.call.admitted.find do |candidate|
      candidate.attempt.model_invocation.conversation_id == @conversation.id
    end
    refute_nil admitted, "the reply was never admitted"
    clear_enqueued_jobs

    capture_stream { run_attempt!(admitted.attempt) }

    assert_empty frames, "no task key, no frame: the reply's deltas and its settled turn are the whole story"
    refute_empty @published.select { |stream, _| stream.end_with?(":transcript") }, "the reply still streamed"
  end

  # --- the hidden gate ------------------------------------------------------

  test "a hidden step reaches the feed exactly as it reaches the transcript: not at all" do
    quiet_call = seed(tool("quiet", "visibility" => "hidden"))
    quiet_round = seed(model("quiet", "visibility" => "hidden"))

    capture_stream do
      start!(quiet_call)
      claim!(quiet_call, "quiet")
      start!(quiet_round)
      run_attempt!(attempt_for(quiet_round, "quiet"))
    end

    assert_empty frames, "the dispatch, the claim and the dial of a hidden row all narrate nothing"
  end

  test "a hidden TURN silences its loop's frames on the conversation host" do
    turn, agent_run = run_backed_turn!
    turn.update!(visibility: "hidden")

    capture_stream do
      run_attempt!(loop_attempt(agent_run), sse_success("reading", tool_calls: [
        { id: "c1", name: "read_file", arguments: { "path" => "x" }.to_json },
      ]))
      AgentRuns::ConvergeTerminalSteps.call
      clear_enqueued_jobs
      schedule_loop!(agent_run)
    end

    assert_empty frames, "the gate reads the TURN on a conversation host, for the dial and the dispatch alike"
    assert_equal "dispatched", loop_node(agent_run, "r2t0").status, "the work still ran"
  end

  # --- decided eagerly, published late ------------------------------------

  test "two saves of one row in one transaction publish two frames, each carrying its own save's decision" do
    agent_run = seed(tool("alpha"))
    call = loop_node(agent_run, "alpha")

    capture_stream do
      AgentRun.transaction do
        AgentRuns::Transition.node(call, status: "needs_approval", await_started_at: Time.current)
        AgentRuns::Transition.node(call, status: "dispatched", started_at: Time.current)
        assert_empty frames, "nothing is published before the commit"
      end
    end

    assert_equal %w[needs_approval dispatched], frames.map { |frame| frame.fetch("status") },
      "a closure reading saved_changes at commit would have said `dispatched` twice"
  end

  test "a rolled-back transition publishes nothing" do
    agent_run = seed(tool("alpha"))
    call = loop_node(agent_run, "alpha")

    capture_stream do
      AgentRun.transaction do
        AgentRuns::Transition.node(call, status: "needs_approval", await_started_at: Time.current)
        raise ActiveRecord::Rollback
      end
    end

    assert_empty frames
    assert_equal "queued", call.reload.status
  end

  # --- the cost of the keys, and nothing stored ---------------------------

  # The kernel's own fan: a round whose model answered sixty calls
  # (`ExpandRound`, bounded at KERNEL_MAX_DEPENDENCIES_PER_TASK — the
  # authored door stops at 32), queued by the converge, dispatched by ONE
  # `ScheduleReady` pass under one locked loop.
  def wide_round!(agent_run)
    start!(agent_run)
    apply_via(attempt_for(agent_run, "plan"), sse_success("fan", tool_calls: FAN.times.map { |index|
      { id: "c#{index}", name: "read_file", arguments: { "path" => "f#{index}" }.to_json }
    }))
    AgentRuns::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    assert_equal FAN, agent_run.agent_run_tasks.where(status: "queued", type: AgentRunTasks::ToolTask.sti_name).count
    agent_run
  end

  test "a sixty-wide fan dispatched in one pass narrates every row and costs no per-row statement, writing no row" do
    silent = wide_round!(seed(model("plan", "tools" => [RunLaneTestHelper::READ_TOOL])))
    narrated = wide_round!(seed(model("plan", "tools" => [RunLaneTestHelper::READ_TOOL])))

    silent_rows = row_counts
    without = Conversations::ProgressStream.stub(:transition, nil) do
      count_queries { AgentRuns::ScheduleReady.call(agent_run_id: silent.id) }
    end
    silent_delta = row_counts.zip(silent_rows).map { |after, before| after - before }
    clear_enqueued_jobs

    narrated_rows = row_counts
    with = nil
    capture_stream { with = count_queries { AgentRuns::ScheduleReady.call(agent_run_id: narrated.id) } }
    narrated_delta = row_counts.zip(narrated_rows).map { |after, before| after - before }

    dispatched = frames.select { |frame| frame.fetch("status") == "dispatched" }
    assert_equal FAN, dispatched.length, "every row of the fan narrated its dispatch"
    assert_equal FAN.times.map { |index| "r1t#{index}" }.sort, dispatched.map { |frame| frame.fetch("task_key") }.sort,
      "keyed by the round that reads them"
    assert_equal FAN * 2, frames.length, "held then dispatched, per row"
    assert_equal without + KEY_QUERIES_PER_PASS, with,
      "the keys resolve through the loop object's association cache: #{with - without} statements for #{FAN} rows"
    assert_equal silent_delta, narrated_delta, "a frame writes no row: the primary tables move by the dispatch alone"
  end
end
