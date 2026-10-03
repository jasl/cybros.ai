require "test_helper"

# THE SETTLE MACHINE AS A LIBRARY (`Rho::Cli::TurnFollow`): the follow lifted out of `rho run` and shared
# with the ACP surface, driven against scripted daemons whose streams are
# the script. Each verdict of the vocabulary, the frame order the
# callbacks see, the park handed over and the follow going on, the turn
# filter, the row settle, the socket's deadline. `run`'s own suite pins
# the lines it prints over this machine, unchanged.
class CliTurnFollowTest < Minitest::Test
  include RhoTest::CliHarness

  # One frame of the daemon's stream, as `LoopStream` writes it.
  def frame(type, payload) = "event: #{type}\ndata: #{JSON.generate(payload)}\n\n"

  SNAPSHOT = { "public_id" => "c-9", "host_type" => "conversation", "status" => "running", "loop" => "al-9",
               "turn" => "t-9", "complete" => false, "text" => "Hel",
               "tasks" => [{ "task_key" => "r1", "kind" => "model_task", "lifetime" => "conversation", "wake" => "auto", "status" => "running" }] }.freeze
  CLOSED = { "reason" => "turn_settled" }.freeze
  DENIED = { "task" => { "key" => "r1c1", "kind" => "tool_task", "lifetime" => "conversation", "wake" => "auto", "status" => "denied" } }.freeze

  def completed_stream
    frame("snapshot", SNAPSHOT) +
      frame("text_delta", "text" => "lo") +
      frame("task_status", "task_key" => "r1", "kind" => "model_task", "lifetime" => "conversation", "wake" => "auto", "status" => "completed") +
      frame("turn_status", "status" => "completed", "loop_status" => "completed", "turn_public_id" => "t-9",
        "agent_loop_public_id" => "al-9") +
      frame("closed", CLOSED)
  end

  # A machine over a scripted daemon whose `/loops/follow` is `stream`;
  # every frame it sees is kept in order, and the loop it learns too.
  def machine(stream, routes: {}, seen: nil, **options)
    announce(endpoint: recording_routed_endpoint(seen, {
      "GET /loops/follow?public_id=c-9" => [[200, stream]],
    }.merge(routes)))
    @frames = []
    @learned = []
    Rho::Cli::TurnFollow.new(core: core, conversation: "c-9",
      on_frame: ->(type, payload) { @frames << [type, payload] }, on_loop: ->(id) { @learned << id }, **options)
  end

  def types = @frames.map(&:first)

  # ---- the vocabulary ----

  # Every word the machine can answer is one `run` prices: the exit table
  # and the vocabulary are the same set.
  def test_the_verdicts_are_the_words_run_prices
    assert_equal Rho::Cli::Run::EXIT.keys.sort, Rho::Cli::TurnFollow::VERDICTS.sort
    assert_equal Rho::Cli::Run::SUBTYPE.keys.sort, Rho::Cli::TurnFollow::VERDICTS.sort
  end

  # ---- the turn's word ----

  # COMPLETED: the word is remembered and the stream read to its end —
  # `on_frame` saw every frame, `closed` included, each before the machine
  # moved on it; the ids as the first frame carried them; the loop
  # announced once.
  def test_a_completed_turn_is_read_to_the_streams_end
    follow = machine(completed_stream)

    assert_equal :completed, follow.follow
    assert_equal :completed, follow.verdict
    assert_equal %w[snapshot text_delta task_status turn_status closed], types
    assert_equal SNAPSHOT, @frames.first.last
    assert_equal({ "reason" => "turn_settled" }, @frames.last.last)
    assert_equal %w[t-9 al-9 completed completed], [follow.turn, follow.loop, follow.status, follow.loop_status]
    assert_equal ["al-9"], @learned
    assert_nil follow.failure
    assert_nil follow.attention
    assert_nil follow.reason
    assert_nil follow.settled_row, "a stream that settled read no row"
    assert_equal [], follow.decided
  end

  def test_a_canceled_turn_answers_canceled
    stream = frame("snapshot", SNAPSHOT) +
             frame("turn_status", "status" => "canceled", "loop_status" => "canceled") +
             frame("closed", CLOSED)
    follow = machine(stream)

    assert_equal :canceled, follow.follow
    assert_equal "canceled", follow.status
    assert_nil follow.failure
  end

  # FAILED on a TERMINAL loop is over for good: `failed`, and the failure's
  # two kernel fields as the frame carried them.
  def test_a_failed_turn_on_a_terminal_loop_answers_failed_with_the_failure
    stream = frame("snapshot", SNAPSHOT) +
             frame("turn_status", "status" => "failed", "loop_status" => "canceled",
               "failure_reason" => "provider_http_error", "failure_reason_key" => "provider.http_error") +
             frame("closed", CLOSED)
    follow = machine(stream)

    assert_equal :failed, follow.follow
    assert_equal Rho::Cli::TurnFollow::Failure.new(reason: "provider_http_error", key: "provider.http_error"), follow.failure
    assert_equal %w[snapshot turn_status closed], types, "a terminal word is remembered, the stream read to its end"
  end

  # FAILED on a LIVE loop is a HOLD: the stream never closes
  # on one, so the verdict is the frame's — the follow leaves the stream
  # the moment the word lands, the frame already handed to `on_frame`.
  def test_a_failed_turn_on_a_live_loop_is_a_hold_that_leaves_the_stream
    stream = frame("snapshot", SNAPSHOT) +
             frame("turn_status", "status" => "failed", "loop_status" => "needs_attention",
               "failure_reason" => "provider_http_error") +
             frame("text_delta", "text" => "never read")
    follow = machine(stream)

    assert_equal :hold, follow.follow
    assert_equal %w[snapshot turn_status], types
    assert_equal Rho::Cli::TurnFollow::Failure.new(reason: "provider_http_error", key: nil), follow.failure
    assert_equal "needs_attention", follow.loop_status
  end

  # ---- the ask and the park ----

  # THE MODEL'S ASK (`awaiting_human`): the follow ends with its payload —
  # `[reason, keys]` — nothing decided, `on_park` never asked.
  def test_the_models_ask_ends_the_follow_with_its_payload
    stream = frame("snapshot", SNAPSHOT) +
             frame("attention_required", "reason" => "awaiting_human", "blocked_task_keys" => ["r2c1"])
    parks = []
    follow = machine(stream, on_park: ->(loop, keys) { parks << [loop, keys] })

    assert_equal :ask, follow.follow
    assert_equal ["awaiting_human", ["r2c1"]], follow.attention
    assert_equal %w[snapshot attention_required], types
    assert_empty parks
    assert_nil follow.reason
  end

  # A HOLD'S ATTENTION IS NOT AN ASK: a halted loop rests `needs_attention`
  # with its failure key as the reason, and on a conversation host that
  # `attention_required` can land BEFORE the turn's own `failed` word. The
  # frame moves nothing — `on_park` never asked, no `:ask` — and the word
  # that follows settles the hold; the same on a re-join's snapshot.
  def test_a_holds_attention_before_the_turns_failed_word_moves_nothing_and_the_word_is_the_hold
    stream = frame("snapshot", SNAPSHOT) +
             frame("turn_status", "loop_status" => "needs_attention", "attention_reason" => "halt_failure",
               "agent_loop_public_id" => "al-9", "turn_public_id" => "t-9") +
             frame("attention_required", "reason" => "halt_failure", "blocked_task_keys" => ["r1"]) +
             frame("turn_status", "status" => "failed", "loop_status" => "needs_attention",
               "failure_reason" => "the model call failed", "failure_reason_key" => "halt_failure",
               "turn_public_id" => "t-9", "agent_loop_public_id" => "al-9") +
             frame("text_delta", "text" => "never read")
    parks = []
    follow = machine(stream, on_park: ->(loop, keys) { parks << [loop, keys] })

    assert_equal :hold, follow.follow
    assert_equal %w[snapshot turn_status attention_required turn_status], types
    assert_empty parks
    assert_equal ["halt_failure", ["r1"]], follow.attention
    assert_equal Rho::Cli::TurnFollow::Failure.new(reason: "the model call failed", key: "halt_failure"), follow.failure

    snapshot = SNAPSHOT.merge("status" => "failed", "loop_status" => "needs_attention", "complete" => true,
      "attention" => { "reason" => "halt_failure", "blocked_task_keys" => ["r1"] })
    rejoined = machine(frame("snapshot", snapshot) + frame("text_delta", "text" => "never read"))

    assert_equal :hold, rejoined.follow
    assert_equal %w[snapshot], types
  end

  # The ask the snapshot carries on a (re-)join ends the follow the same way.
  def test_the_ask_on_the_snapshot_ends_the_follow_too
    snapshot = SNAPSHOT.merge("attention" => { "reason" => "awaiting_human", "blocked_task_keys" => ["r2c1"] })
    follow = machine(frame("snapshot", snapshot) + frame("text_delta", "text" => "never read"))

    assert_equal :ask, follow.follow
    assert_equal ["awaiting_human", ["r2c1"]], follow.attention
    assert_equal %w[snapshot], types
  end

  # THE PARK (`approval_required` with keys) goes to `on_park` with the
  # loop and the keys, and the follow GOES ON to the turn's word; the keys
  # are remembered as decided.
  def test_a_park_goes_to_on_park_and_the_follow_continues
    stream = frame("snapshot", SNAPSHOT) +
             frame("attention_required", "reason" => "approval_required", "blocked_task_keys" => %w[r1c1 r1c2]) +
             frame("turn_status", "status" => "completed", "loop_status" => "completed") +
             frame("closed", CLOSED)
    parks = []
    follow = machine(stream, on_park: ->(loop, keys) { parks << [loop, keys] })

    assert_equal :completed, follow.follow
    assert_equal [["al-9", %w[r1c1 r1c2]]], parks
    assert_equal %w[r1c1 r1c2], follow.decided
    assert_equal %w[snapshot attention_required turn_status closed], types
    assert_equal ["approval_required", %w[r1c1 r1c2]], follow.attention, "the last park, for the record"
  end

  # A park re-sent for keys already handed over has nothing left to
  # decide: `keyless`, and `on_park` is not asked twice for one key.
  def test_a_park_already_decided_is_keyless
    stream = frame("snapshot", SNAPSHOT) +
             frame("attention_required", "reason" => "approval_required", "blocked_task_keys" => ["r1c1"]) +
             frame("attention_required", "reason" => "approval_required", "blocked_task_keys" => ["r1c1"]) +
             frame("turn_status", "status" => "completed", "loop_status" => "completed")
    parks = []
    follow = machine(stream, on_park: ->(_loop, keys) { parks << keys })

    assert_equal :keyless, follow.follow
    assert_equal [["r1c1"]], parks
    assert_equal ["approval_required", []], follow.attention
  end

  # WITHOUT `on_park` a park with keys needs a person like the ask does:
  # `ask`, with the park as the payload — a surface that decides nothing
  # reads `attention.first` to tell the two apart.
  def test_a_park_without_on_park_ends_the_follow_as_ask
    stream = frame("snapshot", SNAPSHOT) +
             frame("attention_required", "reason" => "approval_required", "blocked_task_keys" => ["r1c1"])
    follow = machine(stream)

    assert_equal :ask, follow.follow
    assert_equal ["approval_required", ["r1c1"]], follow.attention
    assert_equal [], follow.decided
  end

  # A park with NO key, or one before the loop is known, is a park nobody
  # can decide: `keyless`, the reason named for the second.
  def test_a_keyless_park_and_a_park_before_the_loop_is_known_are_keyless
    stream = frame("snapshot", SNAPSHOT) +
             frame("attention_required", "reason" => "approval_required", "blocked_task_keys" => [])
    parks = []
    follow = machine(stream, on_park: ->(loop, keys) { parks << [loop, keys] })
    assert_equal :keyless, follow.follow
    assert_nil follow.reason
    assert_empty parks

    pending = { "public_id" => "c-9", "host_type" => "conversation", "tasks" => [] }
    stream = frame("snapshot", pending) +
             frame("attention_required", "reason" => "approval_required", "blocked_task_keys" => ["r1c1"])
    follow = machine(stream, on_park: ->(loop, keys) { parks << [loop, keys] })
    assert_equal :keyless, follow.follow
    assert_equal Rho::Cli::TurnFollow::LOOP_UNKNOWN, follow.reason
    assert_nil follow.loop
    assert_empty parks
  end

  # A decision the daemon refuses (`on_park` raising the sentence) is a
  # call nobody here can decide: `keyless`, the sentence as the reason —
  # `run`'s refused deny, through the same door.
  def test_a_refused_park_decision_is_keyless_with_the_sentence
    stream = frame("snapshot", SNAPSHOT) +
             frame("attention_required", "reason" => "approval_required", "blocked_task_keys" => %w[r1c1 r1c2])
    follow = machine(stream, on_park: ->(_loop, _keys) { raise Rho::Error, "r1c1 is already decided" })

    assert_equal :keyless, follow.follow
    assert_equal "r1c1 is already decided", follow.reason
    assert_equal [], follow.decided, "a refused park hands nothing over"
  end

  # `run`'s deny through the machine: `on_park` is where the core's `deny`
  # is called, one per key, and the follow continues to the word.
  def test_run_style_denies_ride_on_park_and_reach_the_daemon
    stream = frame("snapshot", SNAPSHOT) +
             frame("attention_required", "reason" => "approval_required", "blocked_task_keys" => %w[r1c1 r1c2]) +
             frame("turn_status", "status" => "completed", "loop_status" => "completed") +
             frame("closed", CLOSED)
    seen = []
    follow = machine(stream, seen: seen, routes: { "POST /loops/deny" => [[200, DENIED]] },
      on_park: ->(loop, keys) { keys.each { |key| core.deny(loop, key, reason: "nobody here") } })

    assert_equal :completed, follow.follow
    denies = seen.grep(%r{\APOST /loops/deny }).map { |request| JSON.parse(request.partition("\r\n\r\n").last) }
    assert_equal [{ "public_id" => "al-9", "task_key" => "r1c1", "reason" => "nobody here" },
                  { "public_id" => "al-9", "task_key" => "r1c2", "reason" => "nobody here" }], denies
  end

  # ---- the filter ----

  # A word about ANOTHER turn moves nothing (the between-turn summary's
  # loop, a late settle of a turn left behind): with `turn:` named, a
  # hold-shaped `failed` on t-8 is ignored and t-9's `completed` settles.
  def test_a_frame_for_another_turn_moves_nothing
    stream = frame("snapshot", SNAPSHOT.merge("turn" => nil, "loop" => nil)) +
             frame("turn_status", "status" => "failed", "loop_status" => "needs_attention", "turn_public_id" => "t-8",
               "agent_loop_public_id" => "al-8", "failure_reason" => "provider_http_error") +
             frame("turn_status", "status" => "completed", "loop_status" => "completed", "turn_public_id" => "t-9",
               "agent_loop_public_id" => "al-9") +
             frame("closed", CLOSED)
    follow = machine(stream, turn: "t-9")

    assert_equal :completed, follow.follow
    assert_equal "t-9", follow.turn
    assert_nil follow.failure
    assert_equal %w[snapshot turn_status closed], types, "the other turn's frame cannot render or trigger an approval"
    assert_equal "al-9", follow.loop
  end

  # The loop named at construction (the open's 201, a re-join) is not
  # announced again; one learned from a later frame (a `pending` open) is,
  # once, and the turn with it.
  def test_the_loop_is_announced_once_and_only_when_learned
    follow = machine(completed_stream, turn: "t-9", loop: "al-9")
    assert_equal :completed, follow.follow
    assert_empty @learned

    pending = { "public_id" => "c-9", "host_type" => "conversation", "tasks" => [] }
    stream = frame("snapshot", pending) +
             frame("turn_status", "status" => "running", "turn_public_id" => "t-9", "agent_loop_public_id" => "al-9") +
             frame("turn_status", "status" => "completed", "loop_status" => "completed", "turn_public_id" => "t-9",
               "agent_loop_public_id" => "al-9") +
             frame("closed", CLOSED)
    follow = machine(stream)
    assert_equal :completed, follow.follow
    assert_equal ["al-9"], @learned
    assert_equal %w[t-9 al-9], [follow.turn, follow.loop]
  end

  # ---- the stream that ends without a word ----

  # THE ROW SETTLES IT: a `closed` (or a bare end) before the turn's word
  # reads `Core#loop_row`; a completed row completes, a holding row holds,
  # and the row is kept for the reader.
  def test_a_stream_that_ends_without_a_word_settles_on_the_row
    stream = frame("snapshot", SNAPSHOT) + frame("closed", CLOSED)
    completed = SNAPSHOT.merge("status" => "completed", "loop_status" => "completed", "complete" => true)
    follow = machine(stream, routes: { "GET /loops" => [[200, { "loops" => [completed] }]] })
    assert_equal :completed, follow.follow
    assert_equal completed, follow.settled_row
    assert_equal %w[snapshot closed], types

    holding = SNAPSHOT.merge("status" => "failed", "loop_status" => "needs_attention", "failure_reason" => "provider_http_error")
    follow = machine(stream, routes: { "GET /loops" => [[200, { "loops" => [holding] }]] })
    assert_equal :hold, follow.follow
    assert_equal holding, follow.settled_row
    assert_equal "provider_http_error", follow.failure.reason

    bare = frame("snapshot", SNAPSHOT)
    follow = machine(bare, routes: { "GET /loops" => [[200, { "loops" => [completed] }]] })
    assert_equal :completed, follow.follow, "a stream that just ends settles on the row the same way"
  end

  # A row that says nothing terminal is a failure to read the end, named;
  # a row the daemon refuses to read is its sentence. Both `refused`.
  def test_a_row_that_settles_nothing_is_refused_and_named
    stream = frame("snapshot", SNAPSHOT) + frame("closed", CLOSED)
    follow = machine(stream, routes: { "GET /loops" => [[200, { "loops" => [SNAPSHOT] }]] })
    assert_equal :refused, follow.follow
    assert_equal Rho::Cli::TurnFollow::STREAM_ENDED, follow.reason
    assert_equal SNAPSHOT, follow.settled_row

    follow = machine(stream, routes: { "GET /loops" => [[200, { "loops" => [] }]] })
    assert_equal :refused, follow.follow
    assert_equal "this daemon is not following c-9", follow.reason
    assert_nil follow.settled_row
  end

  def test_an_ended_host_is_unavailable_without_claiming_the_turn_was_canceled
    seen = []
    stream = frame("snapshot", SNAPSHOT) + frame("turn_status", "status" => "running") +
             frame("closed", "reason" => "host_ended")
    follow = machine(stream, seen: seen)

    assert_equal :refused, follow.follow
    assert_equal "this daemon stopped following the host; it may be unavailable", follow.reason
    assert_equal "running", follow.status
    assert_nil follow.settled_row
    refute seen.any? { |request| request.start_with?("GET /loops ") }
  end

  # ---- the daemon's refusal, the deadline ----

  # A daemon that refuses the follow itself: `refused`, the sentence.
  def test_a_refused_follow_is_refused_with_the_sentence
    follow = machine("", routes: {
      "GET /loops/follow?public_id=c-9" => [[404, { "error" => { "message" => "c-9 is not followed" } }]],
    })

    assert_equal :refused, follow.follow
    assert_equal "c-9 is not followed", follow.reason
    assert_empty @frames
  end

  # THE DEADLINE IS THE SOCKET'S: a daemon that sends
  # nothing cannot outlive `deadline:` — `timeout`, within the budget and
  # a socket's slack, never the heartbeat's twenty seconds.
  def test_a_silent_daemon_under_the_deadline_answers_timeout_within_the_budget
    announce(endpoint: serve do |client, request|
      if request.lines.first.to_s.start_with?("GET /healthz")
        answer(client, 200, "status" => "ok", "version" => Rho::VERSION,
          "control_version" => Rho::Daemon::ANNOUNCEMENT_VERSION)
      else
        client.write("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n")
        client.write(frame("snapshot", SNAPSHOT))
        IO.select([client], nil, nil, 4)
      end
    end)
    frames = []
    follow = Rho::Cli::TurnFollow.new(core: core, conversation: "c-9", deadline: 1,
      on_frame: ->(type, _payload) { frames << type })

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    verdict = follow.follow
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_equal :timeout, verdict
    assert_operator elapsed, :<, 3, "a 1 s deadline returns in well under the heartbeat (took #{elapsed.round(2)} s)"
    assert_equal %w[snapshot], frames
    assert_equal %w[t-9 al-9], [follow.turn, follow.loop], "what the snapshot taught stays readable"
  end
end
