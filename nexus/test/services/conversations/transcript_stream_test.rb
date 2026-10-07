require "test_helper"

# ⚑T4/⚑T6 — ONE TRANSCRIPT STREAM OVER THE HOST: deltas while a reply or a round runs, the settled
# snapshot when a turn or a task terminalizes, and nothing durable anywhere. THREE HOSTS OF ONE
# STREAM: a direct reply on its conversation, a loop-backed round on its conversation through the
# seam, a standalone round on the loop's own channel. Until the stream was hosted, a loop-backed
# round's deltas went to a loop address no channel would serve — they existed and landed nowhere.
class Conversations::TranscriptStreamTest < ActiveJob::TestCase
  include InvocationHarness
  include RunLaneTestHelper

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @agent = users(:agent)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
    # Answered by the agent: the engine of every reply head here is the agent's.
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
    @published = []
  end

  def capture_stream
    ActionCable.server.stub(:broadcast, ->(stream, payload) {
      @published << [stream.to_s, payload]
    }) { yield }
  end

  def transcript_events
    @published.select { |stream, _| stream.end_with?(":transcript") }
      .map { |_, payload| payload.fetch(:event) }
  end

  def transcript_streams
    @published.select { |stream, _| stream.end_with?(":transcript") }.map(&:first).uniq
  end

  def conversation_stream = "agent_api:v1:conversation:#{@conversation.public_id}:transcript"
  def loop_stream(agent_run) = "agent_api:v1:run:#{agent_run.public_id}:transcript"

  def text_delta(delta) = SimpleInference::Responses::Events::TextDelta.new(delta: delta)

  def sink_on(attempt) = ConversationEvents::StreamSink.new(attempt: attempt, flush_interval_ms: 0)

  # --- a direct reply: the conversation is the host -----------------------

  def accept!(kind: "message", text: "hello", **overrides)
    result = Conversations::Inputs::Create.call(Conversations::Inputs::Create::Command.new(**{
      host: @conversation, acting_user: @human, kind: kind, role: "user",
      entries: [{ "text" => text }], visible_in_context: true, delivery_mode: "queue",
      context_mode: nil, context_options: nil, expected_context_revision: nil,
      expected_tail_turn_public_id: nil, provider_id: nil, model_ref: nil,
      reasoning_effort: nil, request_options: nil,
    }.merge(overrides)))
    assert_predicate result, :accepted?
    result.value
  end

  def ask!(text: "what is up")
    accept!(kind: "direct_reply", text: text, provider_id: "dev", model_ref: "mock-text")
    Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)
    @conversation.reload.conversation_turns.order(:position).last
  end

  def reply_attempt
    admitted = ModelInvocations::AdmitQueuedWork.call.admitted.find do |candidate|
      candidate.attempt.model_invocation.conversation_id == @conversation.id
    end
    raise "reply not admitted" if admitted.nil?

    clear_enqueued_jobs
    admitted.attempt
  end

  def sink = sink_on(reply_attempt)

  test "a reply narrates its text, its reasoning, and the calls it is making" do
    turn = ask!
    invocation = @conversation.model_invocations.sole
    live = sink

    capture_stream do
      live.on_event(invocation, text_delta("he"))
      live.on_event(invocation, SimpleInference::Responses::Events::ReasoningDelta.new(
        delta: "why", kind: "summary"
      ))
      live.on_event(invocation, SimpleInference::Responses::Events::ToolCallDelta.new(
        call_id: "c1", item_id: "i1", name: "search", delta: '{"q":'
      ))
      live.on_stream_settled(invocation)
    end

    assert_equal %w[text_delta reasoning_delta tool_call_started tool_call_arguments_delta],
      transcript_events.map { |event| event.fetch(:type) }
    assert_equal "he", transcript_events.first.fetch(:text)
    assert_equal "summary", transcript_events.second.fetch(:kind)
    assert_equal "search", transcript_events.third.fetch(:name)

    assert transcript_events.all? { |event| event.fetch(:turn_public_id) == turn.public_id },
      "every item names the turn it belongs to"
    assert transcript_events.all? { |event|
      event.fetch(:variant_public_id) == turn.active_variant.public_id
    }, "and the sample within it — a regeneration is a different sample of the same turn"
    refute transcript_events.any? { |event| event.key?(:run_public_id) },
      "the loop correlation keys are ADDITIVE: absent for a direct reply"
  end

  test "the feed publishes on its own stream, and writes nothing durable" do
    ask!
    invocation = @conversation.model_invocations.sole
    live = sink

    before = ConversationEventItem.count
    capture_stream do
      live.on_event(invocation, text_delta("hi"))
      live.on_stream_settled(invocation)
    end

    stream, = @published.sole
    assert_equal conversation_stream, stream
    assert_equal before, ConversationEventItem.count,
      "a delta is not a replay item — the events feed stays replayable"
  end

  test "a retry tells a follower to discard what it accumulated" do
    ask!
    invocation = @conversation.model_invocations.sole
    live = sink

    capture_stream do
      live.on_event(invocation, text_delta("half an ans"))
      live.on_stream_settled(invocation)
      live.on_retry(invocation)
      live.on_event(invocation, text_delta("the real answer"))
      live.on_stream_settled(invocation)
    end

    assert_equal %w[text_delta stream_reset text_delta],
      transcript_events.map { |event| event.fetch(:type) }
    assert_equal "retry", transcript_events.second.fetch(:reason)
  end

  test "an attempt that streamed nothing public emits no reset marker" do
    ask!
    invocation = @conversation.model_invocations.sole
    live = sink

    capture_stream { live.on_retry(invocation) }
    assert_empty transcript_events
  end

  # A declined answer is discarded from storage, so what it streamed is
  # withdrawn from every live follower: the reset names why, and a refusal
  # that streamed nothing public says nothing.
  test "a refusal tells a follower to discard what it accumulated, naming why" do
    ask!
    invocation = @conversation.model_invocations.sole
    attempt = reply_attempt
    live = sink_on(attempt)

    capture_stream do
      live.on_event(invocation, text_delta("Sure, here is"))
      live.on_refused(invocation)
    end
    assert_equal %w[text_delta stream_reset], transcript_events.map { |event| event.fetch(:type) }
    assert_equal "refused", transcript_events.second.fetch(:reason)

    @published.clear
    quiet = sink_on(attempt)
    capture_stream { quiet.on_refused(invocation) }
    assert_empty transcript_events
  end

  # A failed attempt nothing retries — a budget spent mid-stream, a terminal error — holds none of
  # what it streamed, so a follower is told to discard it before any switch re-asks elsewhere. The
  # sink answers for its own invocation only.
  test "a failed attempt tells a follower to discard what it accumulated, and another's is not its word" do
    ask!
    invocation = @conversation.model_invocations.sole
    attempt = reply_attempt
    live = sink_on(attempt)
    other = ModelInvocation.create!(
      conversation: @conversation, creating_user: @human, internal_creation_key: "conversation_reply:other",
      provider_id: "dev", model_ref: "mock-text", request_options: {}, admission_deadline_seconds: 60
    )

    capture_stream do
      live.on_event(invocation, text_delta("Sure, here is"))
      live.on_failed(other)
    end
    assert_equal %w[text_delta], transcript_events.map { |event| event.fetch(:type) }, "someone else's failure"

    @published.clear
    capture_stream { live.on_failed(invocation) }
    assert_equal [["stream_reset", "failed"]], transcript_events.map { |event| event.values_at(:type, :reason) }
    assert_equal [conversation_stream], transcript_streams
  end

  test "a hidden turn is off the feed exactly as it is off every read" do
    turn = ask!
    turn.update!(visibility: "hidden")
    invocation = @conversation.model_invocations.sole
    live = sink

    capture_stream { live.on_event(invocation, text_delta("secret")); live.on_stream_settled(invocation) }
    assert_empty transcript_events,
      "streaming text no REST read serves would be unreconcilable"
  end

  test "the settled turn rides the same feed, under the same turn id" do
    turn = ask!
    apply_via(reply_attempt, sse_success("the answer"))

    capture_stream { Conversations::Turns::Converge.call }

    settled = transcript_events.sole
    assert_equal "turn", settled.fetch(:type)
    assert_equal turn.public_id, settled.fetch(:turn_public_id),
      "one routing key for both kinds of item on this feed"
    assert_equal turn.active_variant.public_id, settled[:variant_public_id]
    assert_not settled.key?(:run_public_id), "a direct reply has no loop"
    snapshot = settled.fetch(:turn)
    assert_equal turn.public_id, snapshot.fetch(:public_id)
    assert_equal "completed", snapshot.fetch(:status)
    assert_includes snapshot.dig(:active_variant, :content), "Mock: the answer",
      "completion replaces the accumulator, and completion wins"
  end

  test "the settled snapshot is the row a paginated read would have served" do
    turn = ask!
    apply_via(reply_attempt, sse_success("the answer"))
    Conversations::Turns::Converge.call

    entries = @conversation.reload.timeline.entries(surface: :timeline)
    page = AgentAPI::ConversationPresenter.turn_entries(entries).last
    assert_equal page, AgentAPI::ConversationPresenter.turn_snapshot(turn.reload),
      "one projection, two transports — never two shapes of one turn"
  end

  # --- a loop-backed round: the conversation is the host, through the seam --

  # The real chain: a tool-bearing agent's reply head materializes a loop
  # born running, and the scheduler mints round one.
  def run_backed_turn!
    declare_tools!(@agent)
    turn, agent_run = materialize_loop_reply!(@conversation, agent: @agent)
    schedule_loop!(agent_run)
    [turn, agent_run]
  end

  def assert_loop_keys(events, agent_run:, turn:, task_key:)
    assert events.all? { |event| event.fetch(:run_public_id) == agent_run.public_id },
      "every item names the loop behind the turn"
    assert events.all? { |event| event.fetch(:task_key) == task_key },
      "and the task within it, which is how a client upserts it"
    assert events.all? { |event| event.fetch(:turn_public_id) == turn.public_id },
      "and the turn the seam hangs the loop on"
    assert events.all? { |event| event.fetch(:variant_public_id) == turn.active_variant.public_id },
      "and the sample within it"
  end

  test "a loop-backed round streams on the CONVERSATION's transcript with the loop keys through the seam" do
    turn, agent_run = run_backed_turn!
    attempt = loop_attempt(agent_run)
    invocation = attempt.model_invocation
    live = sink_on(attempt)

    before = ConversationEventItem.count
    capture_stream do
      live.on_event(invocation, text_delta("he"))
      live.on_event(invocation, SimpleInference::Responses::Events::ReasoningDelta.new(
        delta: "thinking", kind: "reasoning_text"
      ))
      live.on_event(invocation, SimpleInference::Responses::Events::ToolCallDelta.new(
        item_id: "i1", call_id: "c1", name: "read_file", delta: "{\"pa"
      ))
      live.on_event(invocation, SimpleInference::Responses::Events::ToolCallDelta.new(
        item_id: "i1", call_id: "c1", name: "read_file", delta: "th\":1}"
      ))
      live.on_stream_settled(invocation)
    end

    assert_equal %w[text_delta reasoning_delta tool_call_started
                    tool_call_arguments_delta tool_call_arguments_delta],
      transcript_events.map { |event| event.fetch(:type) }
    assert_equal [conversation_stream], transcript_streams,
      "the loop-backed round's stream is its HOST's — never the loop's own address, " \
        "which no channel serves for a loop-backed loop"
    assert_loop_keys(transcript_events, agent_run: agent_run, turn: turn, task_key: "r1")
    assert_equal before, ConversationEventItem.count, "a delta is not a replay item"
  end

  test "a retry on a loop-backed round tells the follower to discard, on the conversation's stream" do
    _turn, agent_run = run_backed_turn!
    attempt = loop_attempt(agent_run)
    invocation = attempt.model_invocation
    live = sink_on(attempt)

    capture_stream do
      live.on_event(invocation, text_delta("a"))
      live.on_retry(invocation)
    end

    assert_equal %w[text_delta stream_reset], transcript_events.map { |event| event.fetch(:type) }
    assert_equal [conversation_stream], transcript_streams
  end

  test "a failed loop-backed round tells the follower to discard, on the conversation's stream" do
    _turn, agent_run = run_backed_turn!
    attempt = loop_attempt(agent_run)
    invocation = attempt.model_invocation
    live = sink_on(attempt)

    capture_stream do
      live.on_event(invocation, text_delta("a"))
      live.on_failed(invocation)
    end

    assert_equal [["text_delta", nil], ["stream_reset", "failed"]],
      transcript_events.map { |event| event.values_at(:type, :reason) }
    assert_equal [conversation_stream], transcript_streams
  end

  test "the settled round, then the settled turn, ride the conversation's transcript" do
    turn, agent_run = run_backed_turn!

    capture_stream { run_loop_round!(agent_run, sse_success("the answer")) }

    round = transcript_events.find { |event| event.fetch(:type) == "round" }
    refute_nil round, "completion is authoritative, so it rides the feed"
    assert_equal [conversation_stream], transcript_streams
    assert_loop_keys([round], agent_run: agent_run, turn: turn, task_key: "r1")
    from_rest = AgentRuns::Transcript.call(agent_run: agent_run)
      .rounds.find { |row| row.fetch(:task_key) == "r1" }
    assert_equal from_rest, round.fetch(:round),
      "the same row under the same key, on the host a reader can actually subscribe to"
    assert round.dig(:round, :mainline), "the settled row is the thread's row: the mark, the calls and the branches ride"
    assert_equal %i[calls branches], round.fetch(:round).keys.last(2)

    @published.clear
    capture_stream { Conversations::Turns::Converge.call }

    settled = transcript_events.sole
    assert_equal "turn", settled.fetch(:type)
    assert_equal turn.public_id, settled.fetch(:turn_public_id)
    assert_equal agent_run.public_id, settled[:run_public_id]
    assert_equal agent_run.conversation_turn_variant.public_id, settled[:variant_public_id]
    snapshot = settled.fetch(:turn)
    assert_equal "completed", snapshot.fetch(:status)
    assert_equal agent_run.public_id, snapshot.dig(:active_variant, :run_public_id)
    assert_equal ["r1"], snapshot.dig(:active_variant, :rounds).map { |row| row.fetch(:task_key) },
      "the turn's snapshot carries the loop's rounds as the presenter renders them"
  end

  test "a call's settlement rides the conversation's transcript under its own task key" do
    turn, agent_run = run_backed_turn!
    run_loop_round!(agent_run, sse_success("reading", tool_calls: [
      { id: "c1", name: "read_file", arguments: { "path" => "x" }.to_json },
    ]))
    # The fan is keyed by the round it feeds: r1's call is r2's `t0`.
    call = loop_node(agent_run, "r2t0")

    capture_stream do
      AgentRuns::Transition.node(call, status: "completed", completed_at: Time.current)
    end

    settled = transcript_events.sole
    assert_equal "call", settled.fetch(:type)
    assert_equal [conversation_stream], transcript_streams
    assert_loop_keys([settled], agent_run: agent_run, turn: turn, task_key: "r2t0")
    assert_equal AgentRuns::Transcript.call_snapshot(call.reload), settled.fetch(:call)
  end

  test "a hidden TURN silences the loop's deltas and its snapshots" do
    turn, agent_run = run_backed_turn!
    turn.update!(visibility: "hidden")
    attempt = loop_attempt(agent_run)
    invocation = attempt.model_invocation
    live = sink_on(attempt)

    capture_stream do
      live.on_event(invocation, text_delta("secret"))
      live.on_stream_settled(invocation)
      apply_via(attempt, sse_success("the answer"))
      AgentRuns::ConvergeTerminalSteps.call
    end

    assert_empty transcript_events,
      "the hidden gate reads the TURN on a conversation host: a round no read serves streams nothing"
  end

  test "a hidden TASK is off the conversation's transcript too" do
    _turn, agent_run = run_backed_turn!
    # Authored once, read-only after: the fixture writes the column.
    AgentRunTask.where(id: loop_node(agent_run, "r1").id).update_all(transcript_visibility: "hidden")
    attempt = loop_attempt(agent_run)
    invocation = attempt.model_invocation
    live = sink_on(attempt)

    capture_stream do
      live.on_event(invocation, text_delta("secret"))
      live.on_stream_settled(invocation)
      apply_via(attempt, sse_success("the answer"))
      AgentRuns::ConvergeTerminalSteps.call
    end

    assert_empty transcript_events, "the task's own gate holds on both hosts"
  end

  # --- a standalone round: the loop is its own host ------------------------

  def start!(agent_run)
    AgentRuns::Start.call(AgentRuns::Start::Command.new(
      agent_run: agent_run, acting_user: @human
    ))
    clear_enqueued_jobs
    AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
    clear_enqueued_jobs
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

  def standalone_events
    @published.select { |stream, _| stream.start_with?("agent_api:v1:run:") }
      .map { |_, payload| payload.fetch(:event) }
  end

  test "a standalone round streams on the loop's own transcript, keyed by loop and task" do
    agent_run = seed(model("ask"))
    start!(agent_run)
    attempt = attempt_for(agent_run, "ask")
    invocation = attempt.model_invocation
    live = sink_on(attempt)

    before = agent_run.conversation_event_items.count
    capture_stream do
      live.on_event(invocation, text_delta("he"))
      live.on_event(invocation, SimpleInference::Responses::Events::ReasoningDelta.new(
        delta: "thinking", kind: "reasoning_text"
      ))
      live.on_event(invocation, SimpleInference::Responses::Events::ToolCallDelta.new(
        item_id: "i1", call_id: "c1", name: "read_file", delta: "{\"pa"
      ))
      live.on_event(invocation, SimpleInference::Responses::Events::ToolCallDelta.new(
        item_id: "i1", call_id: "c1", name: "read_file", delta: "th\":1}"
      ))
      live.on_stream_settled(invocation)
    end

    assert_equal %w[text_delta reasoning_delta tool_call_started
                    tool_call_arguments_delta tool_call_arguments_delta],
      standalone_events.map { |event| event.fetch(:type) },
      "a call ANNOUNCES itself on its first fragment, so a collapsed row " \
        "can name its target before the arguments finish"
    assert_equal [loop_stream(agent_run)], transcript_streams,
      "a standalone loop is its own host: the channel's spelling, byte for byte"
    assert standalone_events.all? { |event| event.fetch(:run_public_id) == agent_run.public_id }
    assert standalone_events.all? { |event| event.fetch(:task_key) == "ask" },
      "every item is keyed by the task, which is how a client upserts it"
    assert_equal "c1", standalone_events.last.fetch(:call_id)
    refute standalone_events.any? { |event| event.key?(:turn_public_id) || event.key?(:variant_public_id) },
      "on a loop host the turn keys are the absent ones"
    assert_equal before, agent_run.conversation_event_items.count,
      "a saturated transport must not be able to truncate a transcript, " \
        "which is only true when the deltas were never the record"
  end

  test "a retry on a standalone round tells followers to DISCARD what they accumulated" do
    agent_run = seed(model("ask"))
    start!(agent_run)
    attempt = attempt_for(agent_run, "ask")
    invocation = attempt.model_invocation
    live = sink_on(attempt)

    capture_stream { live.on_retry(invocation) }
    assert_equal [], standalone_events, "an attempt that streamed nothing public says nothing"

    capture_stream do
      live.on_event(invocation, text_delta("a"))
      live.on_retry(invocation)
    end
    assert_equal %w[text_delta stream_reset], standalone_events.map { |event| event.fetch(:type) },
      "otherwise a follower would splice two attempts into one answer"
  end

  test "a settled standalone task publishes the SAME row the paginated read would serve" do
    agent_run = seed(model("ask"))
    start!(agent_run)

    capture_stream do
      apply_via(attempt_for(agent_run, "ask"), sse_success("the answer"))
      AgentRuns::ConvergeTerminalSteps.call
    end

    snapshot = standalone_events.find { |event| event.fetch(:type) == "round" }
    refute_nil snapshot, "completion is authoritative, so it rides the feed"
    assert_equal [loop_stream(agent_run)], transcript_streams
    assert_equal agent_run.public_id, snapshot.fetch(:run_public_id)
    assert_equal "ask", snapshot.fetch(:task_key)
    refute snapshot.key?(:turn_public_id), "no turn row, no turn key"
    from_rest = AgentRuns::Transcript.call(agent_run: agent_run)
      .rounds.find { |row| row.fetch(:task_key) == "ask" }
    assert_equal from_rest, snapshot.fetch(:round),
      "the same row under the same key - that is what makes 'completion " \
        "replaces the accumulator' an event rather than a rule every " \
        "client re-implements against a separate read"
  end

  test "plumbing never reaches the standalone feed — snapshots OR deltas" do
    agent_run = seed(model("quiet", "visibility" => "hidden"))
    start!(agent_run)
    attempt = attempt_for(agent_run, "quiet")
    invocation = attempt.model_invocation
    live = sink_on(attempt)

    # The DELTA half owes the same gate: streaming a hidden round's text
    # would put a conversation on the feed that no reader can reconcile,
    # because the window omits that task entirely.
    capture_stream do
      live.on_event(invocation, text_delta("secret"))
      live.on_stream_settled(invocation)
      AgentRuns::Transition.node(loop_node(agent_run, "quiet"),
        status: "completed", completed_at: Time.current)
    end
    assert_equal [], transcript_events, "a hidden task is not conversation substance"
  end
end
