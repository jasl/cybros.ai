require "support/host_follower_harness"

class HostFollowerTranscriptTest < Minitest::Test
  include RhoTest::HostFollowerHarness

  # THE DELTAS ARE ON THE HOST'S OTHER FEED. Everything below
  # drives `follow_transcript`, which is the pump that reads it; the
  # events feed carries none of this and never did.
  def transcript_run(*items, ending: StopIteration, pages: nil, **options)
    run_for(pages || [page(run_event(1, "running"))],
            transcript_sockets: [Socket.new(items, ending: ending)], **options)
  end

  def test_deltas_join_into_the_preview_and_reach_a_listener
    fanned = []
    run = transcript_run(delta_item("half an "), delta_item("answer"))
    run.listen { |frame| fanned << [frame.type, frame.payload] }

    assert_raises(StopIteration) { run.follow_transcript }
    assert_equal "half an answer", run.snapshot.text
    assert_equal 14, run.snapshot.text_length
    assert_equal [["text_delta", { "text" => "half an " }],
                  ["text_delta", { "text" => "answer" }]], fanned
  end

  def test_stream_reset_discards_the_streamed_half
    run = transcript_run(
      delta_item("half an ans"), transcript_item("stream_reset", reason: "retry"),
      delta_item("the answer")
    )

    assert_raises(StopIteration) { run.follow_transcript }
    assert_equal "the answer", run.snapshot.text
  end

  # The preview must not become a transcript: a run that runs for an hour
  # would otherwise make the daemon's footprint a function of its duration.
  # What is COUNTED is unbounded, which is what keeps the settle exact.
  def test_text_is_bounded_and_the_count_is_not
    deltas = Array.new(40) { delta_item("x" * 4096) }
    run = transcript_run(*deltas)

    assert_raises(StopIteration) { run.follow_transcript }
    assert_equal Rho::HostFollower::TEXT_BOUND, run.snapshot.text.bytesize
    assert_equal 40 * 4096, run.snapshot.text_length
  end

  # A NEW ANSWER IS A NEW KEY, not a round ending: `round_result` on the
  # events feed races the settle on the transcript one, and clearing there
  # made "print only the remainder" print the whole reply a second time.
  def test_a_new_rounds_key_starts_the_preview_over
    run = transcript_run(delta_item("round one", task_key: "r1"),
                         delta_item("round two", task_key: "r2"),
                         pages: [page(
                           event(1, "round_result", { "task_key" => "round-1", "status" => "completed" }),
                           run_event(2, "completed")
                         )])

    assert_raises(StopIteration) { run.follow_transcript }
    assert_equal "round two", run.snapshot.text

    run.follow
    assert_equal %w[round-1], run.snapshot.tasks.map(&:task_key)
    assert_equal "round two", run.snapshot.text, "a round ending does not drop what a person is reading"
  end

  # REPLACE-ON-SETTLE IS THE TURN'S. The settled row carries the whole
  # sealed body, so only what was not streamed is fanned on.
  def test_a_settled_turn_fans_only_the_unprinted_remainder
    fanned = []
    run = transcript_run(delta_item("the ans", turn: "t-1"),
                         settled_turn_item("the answer"),
                         host: CONVERSATION, turn: "t-1")
    run.listen { |frame| fanned << [frame.type, frame.payload] }

    assert_raises(StopIteration) { run.follow_transcript }
    assert_equal [["text_delta", { "text" => "the ans" }],
                  ["text_delta", { "text" => "wer" }]], fanned
    assert_equal "the answer", run.snapshot.text
  end

  def test_a_settled_turn_that_does_not_continue_the_stream_resets_first
    fanned = []
    run = transcript_run(delta_item("a wrong start", turn: "t-1"),
                         settled_turn_item("something else"),
                         host: CONVERSATION, turn: "t-1")
    run.listen { |frame| fanned << [frame.type, frame.payload] }

    assert_raises(StopIteration) { run.follow_transcript }
    assert_equal ["text_delta", "stream_reset", "text_delta"], fanned.map(&:first)
    assert_equal({ "text" => "something else" }, fanned.last.last)
  end

  # THE TWO FEEDS END INDEPENDENTLY. The EVENTS feed's
  # terminal says where the turn got to; the settle a person READS lands on
  # the transcript one, and it can be milliseconds behind. A reader that
  # ended on the first alone printed nothing at all while `rho watch`
  # printed the whole reply, which is exactly what the live lane saw.
  def test_the_events_terminal_does_not_mean_the_text_has_settled
    run = transcript_run(delta_item("the ans", turn: "t-1"), settled_turn_item("the answer"),
                         host: CONVERSATION, turn: "t-1",
                         pages: [page(settle_event(1, "completed"))],
                         sockets: [Socket.new([])], sleeper: ->(_s) { raise StopIteration })

    assert_raises(StopIteration) { run.follow }
    assert run.turn_settled?, "the events feed said the turn is over"
    refute run.transcript_settled?, "and what it said has not arrived yet"

    assert_raises(StopIteration) { run.follow_transcript }
    assert run.transcript_settled?, "the settle landed, so there is nothing left to print"
    assert_equal "the answer", run.snapshot.text
  end

  # THE SETTLE IS NOT OVER UNTIL ITS LAST FRAME IS OUT. A
  # reader ends on `transcript_settled?`, and the settle fans up to TWO
  # frames — a `stream_reset` and then the replacement text. Recording the
  # settle before those frames told the reader it was done while the whole
  # replacement was still unsent, which is the same silence the step set out
  # to remove, one path over.
  def test_a_replaced_settle_reads_settled_only_after_its_replacement_is_fanned
    seen = []
    run = transcript_run(delta_item("a wrong start", turn: "t-1"),
                         settled_turn_item("something else"),
                         host: CONVERSATION, turn: "t-1")
    run.listen { |frame| seen << [frame.type, run.transcript_settled?] }

    assert_raises(StopIteration) { run.follow_transcript }
    assert_equal [["text_delta", false], ["stream_reset", false], ["text_delta", true]], seen
  end

  # NOTHING WILL DELIVER ONE, so nothing waits for one: a run host's feed
  # carries settled rounds and no turn at all — only a conversation
  # publishes one — and a follower with streaming off opens no second feed.
  def test_a_host_with_no_turn_settle_coming_is_settled_at_once
    assert transcript_run(delta_item("said")).transcript_settled?, "a run host has no turn item"

    quiet = run_for([page(run_event(1, "completed"))], host: CONVERSATION, turn: "t-1",
                    transcript_sockets: [Socket.new([])], stream: false)
    assert quiet.transcript_settled?, "streaming off means there is no second half to wait for"
  end

  # A settled ROUND carries a truncated `text_preview`; replacing a full
  # accumulator with it would silently shorten what a person is reading.
  def test_a_settled_round_moves_nothing
    run = transcript_run(delta_item("the whole answer"),
                         transcript_item("round", task_key: "r1",
                                         round: { "text_preview" => "the who…" }))

    assert_raises(StopIteration) { run.follow_transcript }
    assert_equal "the whole answer", run.snapshot.text
  end

  # …AND IS RELAYED WHOLE: a settled `round` or `call` reaches
  # every listener as a frame of its own type carrying the item as the
  # follower saw it — `rho transcript --follow` folds it on the far side
  # of the SSE — while the text stays what the deltas built.
  def test_a_settled_round_or_call_is_relayed_as_a_frame_of_its_type
    fanned = []
    round = { "task_key" => "r2", "mainline" => true, "status" => "completed", "text_preview" => "the who…",
              "calls" => { "count" => 1, "items" => [{ "task_key" => "r2t0", "name" => "read_file", "status" => "completed" }] },
              "branches" => [] }
    call = round.dig("calls", "items", 0)
    run = transcript_run(delta_item("the whole answer"),
                         transcript_item("call", run_id: "al-1", task_key: "r2t0", call: call),
                         transcript_item("round", run_id: "al-1", task_key: "r2", round: round))
    run.listen { |frame| fanned << [frame.type, frame.payload] }

    assert_raises(StopIteration) { run.follow_transcript }
    assert_equal "the whole answer", run.snapshot.text
    assert_equal [
      ["text_delta", { "text" => "the whole answer" }],
      ["call", { "type" => "call", "run_public_id" => "al-1", "task_key" => "r2t0", "payload" => { "call" => call } }],
      ["round", { "type" => "round", "run_public_id" => "al-1", "task_key" => "r2", "payload" => { "round" => round } }],
    ], fanned
  end

  # A DELTA MAY NOT CREATE A ROW: an item naming a turn this follower is
  # not on is dropped, and it does not move the turn either.
  def test_a_delta_for_another_turn_is_dropped
    run = transcript_run(delta_item("not ours", turn: "t-other"),
                         delta_item("ours", turn: "t-1"),
                         host: CONVERSATION, turn: "t-1")

    assert_raises(StopIteration) { run.follow_transcript }
    assert_equal "ours", run.snapshot.text
    assert_equal "t-1", run.snapshot.turn
  end

  # A reopened tail may have dropped frames, so nothing held is known to
  # be a prefix of anything — and whoever was reading is told.
  def test_a_lost_subscription_reopens_with_the_accumulator_empty
    fanned = []
    run = run_for([page(run_event(1, "running"))], transcript_sockets: [
      Socket.new([delta_item("half ")], ending: CybrosAgent::Realtime::ConnectionLostError.new),
      Socket.new([delta_item("all of it")], ending: StopIteration),
    ])
    run.listen { |frame| fanned << [frame.type, frame.payload] }

    assert_raises(StopIteration) { run.follow_transcript }
    assert_equal "all of it", run.snapshot.text
    assert_equal ["text_delta", "stream_reset", "text_delta"], fanned.map(&:first)
  end

  def test_a_follower_with_streaming_off_never_opens_the_transcript_feed
    run = run_for([page(run_event(1, "completed"))],
                  transcript_sockets: [Socket.new([delta_item("unheard")])],
                  stream: false, sleeper: ->(_s) { raise StopIteration })

    assert_raises(StopIteration) { run.follow_transcript }
    assert_empty @context.asked_transcript
    assert_equal "", run.snapshot.text
    assert_nil run.snapshot.text_length
  end

  # The transcript pump is not the events pump: it advances no position
  # and it never spends a gate fetch.
  def test_the_transcript_pump_touches_neither_the_position_nor_the_gate
    looked = 0
    gate = Object.new
    gate.define_singleton_method(:run_public_id) { nil }
    gate.define_singleton_method(:worth_a_look?) { |_tasks| looked += 1 }
    gate.define_singleton_method(:to_h) { {} }
    gate.define_singleton_method(:cancel!) { nil }
    run = transcript_run(delta_item("said"), gate: gate, spawner: ->(&block) { block.call })

    assert_raises(StopIteration) { run.follow_transcript }
    assert_equal 0, run.snapshot.sequence
    assert_equal 0, looked
  end

  # A LOGICAL SUBSCRIPTION NOBODY READS is a server-side buffer that fills
  # until it overflows, so the watcher leaving ends it — asked from inside
  # the drain, which is the only moment the handle is live.
  def test_detaching_ends_the_transcript_subscription
    socket = Socket.new([delta_item("said")], ending: StopIteration)
    run = run_for([page(run_event(1, "running"))], sockets: [Socket.new([]), Socket.new([])],
                  transcript_sockets: [socket])
    run.listen { |_frame| run.detach_socket }

    assert_raises(StopIteration) { run.follow_transcript }
    assert_equal 1, socket.unsubscribed
  end

  def test_stopping_ends_the_transcript_subscription
    socket = Socket.new([delta_item("said")], ending: StopIteration)
    run = run_for([page(run_event(1, "running"))], sockets: [Socket.new([])],
                  transcript_sockets: [socket])
    run.listen { |_frame| run.stop }

    assert_raises(StopIteration) { run.follow_transcript }
    assert_equal 1, socket.unsubscribed
  end
end
