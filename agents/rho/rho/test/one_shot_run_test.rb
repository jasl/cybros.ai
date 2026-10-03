require "test_helper"

# What following a run TEACHES a daemon: deltas provide a preview, while the
# terminal item wakes an authoritative resource read rather than carrying the
# result itself.
class OneShotRunTest < Minitest::Test
  Event = Data.define(:sequence, :cursor, :public_id, :type, :payload)
  Page = Data.define(:items, :next_after, :watermark)
  Usage = CybrosAgent::Api::OneShotUsage
  FileResult = CybrosAgent::Api::OneShotFile
  ErrorResult = CybrosAgent::Api::OneShotError
  Result = CybrosAgent::Api::OneShotResult
  OneShot = Data.define(:result) do
    def output_text = result&.output_text
  end

  def event(sequence, type, payload)
    Event.new(sequence: sequence, cursor: "c#{sequence}", public_id: "e#{sequence}",
              type: type, payload: payload)
  end

  # Yields scripted events, exactly as the socket adapter does — typed items,
  # not the wire's frame.
  class Socket
    def initialize(events, ending: nil)
      @events = events
      @ending = ending
    end

    def each(&block)
      @events.each(&block)
      raise @ending if @ending
    end

    def unsubscribe = nil
  end

  class Realtime
    def rebind = true
    def close = nil
  end

  # Stands in for OneShotsContext. `asked` records the narrowing each
  # subscription was opened with, in order, because "which stream did it
  # subscribe to" is the property under test as much as what arrived on it.
  class Lane
    attr_reader :asked

    attr_reader :fetches

    def initialize(pages, sockets: nil, terminal:)
      @pages = pages
      @sockets = sockets
      @terminal = terminal
      @asked = []
      @fetches = []
    end

    def realtime_opener(_public_id, _client, items: nil)
      @asked << items
      sockets = @sockets
      -> { sockets.shift || Socket.new([]) }
    end

    def fetch(public_id)
      @fetches << public_id
      if @fetch_error
        error = @fetch_error
        @fetch_error = nil
        raise error
      end
      @terminal
    end

    def fail_next_fetch(error) = @fetch_error = error

    def feed(_public_id, realtime: nil, items: nil)
      pages = @pages
      opener = realtime && realtime_opener(nil, realtime, items: items)
      CybrosAgent::KernelFeed.new(
        replay: ->(_cursor) { pages.shift || Page.new(items: [], next_after: nil, watermark: 0) },
        subscribe: opener
      )
    end

    Page = OneShotRunTest::Page
  end

  # Returns the run; the lane it was built on is reachable as `@lane` for the
  # tests that assert which subscription was opened.
  def run_for(pages, sockets: nil, terminal: one_shot,
              sleeper: ->(_seconds) { }, **options)
    @lane = Lane.new(pages, sockets: sockets, terminal: terminal)
    @realtime = sockets && Realtime.new
    Rho::OneShotRun.new(
      one_shots: @lane, public_id: "os-1",
      realtime: @realtime, sleeper: sleeper, **options
    )
  end

  def one_shot(status: "completed", output_text: nil, usage: nil, timing: nil,
               error: nil, reasoning: nil, output_files: nil, finish_quality: nil)
    OneShot.new(result: Result.new(
      status: status, finish_quality: finish_quality, output_text: output_text,
      usage: usage, timing: timing, error: error, reasoning: reasoning,
      output_files: output_files
    ))
  end

  def test_the_answer_is_assembled_from_the_deltas_and_closed_by_the_result
    run = run_for([
      Page.new(items: [
        event(1, "run_status", { "status" => "running" }),
        event(2, "text_delta", { "text" => "Mock: " }),
        event(3, "text_delta", { "text" => "say hi" }),
        event(4, "result", {}),
      ], next_after: "c4", watermark: 4),
    ], terminal: one_shot(output_text: "Mock: say hi"))

    snapshot = run.follow.snapshot
    assert_equal "Mock: say hi", snapshot.text
    assert_equal "completed", snapshot.status
    assert_equal 4, snapshot.sequence
    assert snapshot.complete
  end

  # A ROLLBACK MEANS THE TEXT BEFORE IT NEVER HAPPENED. When a transient
  # failure makes Nexus retry, the output the dead attempt had already streamed
  # is thrown away and a `rollback` item says so — "reset and replay", in the
  # published words. A follower that ignores it keeps the discarded half and
  # concatenates the retry's answer onto it, which is not a missing feature but
  # a wrong answer the caller has no way to detect.
  def test_a_rollback_discards_the_output_the_retry_threw_away
    run = run_for([
      Page.new(items: [
        event(1, "run_status", { "status" => "running" }),
        event(2, "text_delta", { "text" => "Mock: the wrong " }),
        event(3, "text_delta", { "text" => "half" }),
        event(4, "rollback", {}),
        event(5, "text_delta", { "text" => "Mock: say hi" }),
        event(6, "result", {}),
      ], next_after: "c6", watermark: 6),
    ], terminal: one_shot(output_text: "Mock: say hi"))

    snapshot = run.follow.snapshot
    assert_equal "Mock: say hi", snapshot.text,
      "the discarded attempt's output must not survive into the answer"
    assert_equal "completed", snapshot.status
    assert_equal 6, snapshot.sequence
  end

  # And a rollback with nothing before it is not a special case — Nexus only
  # emits one when something public already streamed, but a follower that
  # resets an empty buffer is correct either way.
  def test_a_rollback_before_any_delta_leaves_an_empty_answer
    run = run_for([
      Page.new(items: [
        event(1, "rollback", {}),
        event(2, "text_delta", { "text" => "Mock: say hi" }),
        event(3, "result", {}),
      ], next_after: "c3", watermark: 3),
    ], terminal: one_shot(output_text: "Mock: say hi"))

    assert_equal "Mock: say hi", run.follow.snapshot.text
  end

  # The event is only a wake. The authoritative GET supplies every typed
  # result member, including metadata that never belongs in the event payload.
  def test_the_terminal_wake_fetches_and_serializes_the_authoritative_result
    usage = Usage.new(
      usage_record_public_id: "ur-1", input_tokens: 5, cache_read_tokens: nil,
      uncached_input_tokens: 5, cache_creation_tokens: nil, cache_hit_rate: nil,
      output_tokens: 7, reasoning_tokens: nil, total_tokens: 12,
      cost_amount: "0.01", cost_unit: "USD", cost_complete: true
    )
    terminal = one_shot(
      output_text: "authoritative",
      usage: usage,
      output_files: [FileResult.new(index: 0, filename: "f", content_type: "image/png", byte_size: 128)]
    )
    run = run_for([
      Page.new(items: [event(1, "result", { "result" => { "ignored" => true } })],
               next_after: "c1", watermark: 1),
    ], terminal: terminal)

    snapshot = run.follow.snapshot
    assert_equal "authoritative", snapshot.text
    assert_equal 12, snapshot.result.dig(:usage, :total_tokens)
    assert_equal "image/png", snapshot.result.dig(:output_files, 0, :content_type)
    assert_equal snapshot.result, snapshot.to_h.fetch(:result)
    assert_equal "completed", snapshot.status
    assert_equal ["os-1"], @lane.fetches
  end

  def test_a_lifecycle_only_terminal_wake_keeps_live_false_and_carries_the_error
    terminal = one_shot(
      status: "failed",
      error: ErrorResult.new(code: "provider_error", attempt_budget_spent: true)
    )
    run = run_for(
      [
        Page.new(items: [], next_after: nil, watermark: 0),
        Page.new(items: [], next_after: nil, watermark: 0),
      ],
      sockets: [Socket.new([event(1, "result", {})])],
      terminal: terminal,
      live: false
    )

    snapshot = run.follow.snapshot

    refute snapshot.live
    assert_equal ["lifecycle"], @lane.asked
    assert_equal "", snapshot.text
    assert_equal(
      { code: "provider_error", attempt_budget_spent: true },
      snapshot.result.fetch(:error)
    )
  end

  def test_a_transient_terminal_fetch_replays_the_uncommitted_wake
    terminal = Page.new(items: [event(1, "result", {})], next_after: "c1", watermark: 1)
    run = run_for([terminal, terminal], terminal: one_shot(output_text: "done"))
    @lane.fail_next_fetch(CybrosAgent::Api::ServerError.new("briefly unavailable"))

    snapshot = run.follow.snapshot

    assert snapshot.complete
    assert_equal "done", snapshot.text
    assert_equal %w[os-1 os-1], @lane.fetches
    assert_equal 1, snapshot.sequence,
      "the terminal cursor advances only after the authoritative GET succeeds"
  end

  def test_a_throttled_terminal_fetch_honors_retry_after_before_replay
    terminal = Page.new(items: [event(1, "result", {})], next_after: "c1", watermark: 1)
    slept = []
    run = run_for(
      [terminal, terminal],
      terminal: one_shot(output_text: "done"),
      sleeper: ->(seconds) { slept << seconds }
    )
    @lane.fail_next_fetch(CybrosAgent::Api::RateLimited.new(retry_after: 7))

    snapshot = run.follow.snapshot

    assert snapshot.complete
    assert_equal [7], slept
    assert_equal %w[os-1 os-1], @lane.fetches
    assert_equal 1, snapshot.sequence
  end

  # And it is nil while the run is still open, so a caller cannot mistake an
  # unfinished run for one that produced nothing.
  def test_a_run_still_open_carries_no_result
    run = run_for([
      Page.new(items: [event(1, "text_delta", { "text" => "part" })],
               next_after: "c1", watermark: 1),
    ], sockets: nil)

    assert_nil run.send(:snapshot).result
  end

  # THE ALGORITHM THE OWNER ASKED FOR, and it is the SDK's ordinary barrier
  # rather than a resume path written here.
  #
  # A run nobody is reading still LISTENS — to the lifecycle narrowing, which
  # carries where the run got to and none of what it is producing. When
  # attention arrives it upgrades to the full stream, and the upgrade replays
  # what landed while nobody was reading before going live. Both halves arrive
  # exactly once, which is the whole property.
  def test_a_run_nobody_reads_listens_for_lifecycle_then_upgrades_on_attention
    run = run_for([
      Page.new(items: [event(1, "text_delta", { "text" => "landed " })],
               next_after: "c1", watermark: 1),
      # The gap after the lifecycle subscribe.
      Page.new(items: [], next_after: nil, watermark: 1),
      # What landed durably while only lifecycle was being listened to, drained
      # as the gap after the full subscribe. The sequences are CONTIGUOUS on
      # purpose: a socket event that jumps ahead of the durable window is a
      # gap, and the pump re-drains rather than delivering it.
      Page.new(items: [event(3, "text_delta", { "text" => "while away " })],
               next_after: "c3", watermark: 3),
    ], sockets: [
      Socket.new([event(2, "run_status", { "status" => "running" })]),
      Socket.new([
        event(4, "text_delta", { "text" => "and live" }),
        event(5, "result", {}),
      ]),
    ], terminal: one_shot(output_text: "landed while away and live"), live: false)

    # Attention arrives on the lifecycle item, which is the only thing this
    # follower is receiving until it does.
    def run.apply(event)
      super
      attach_socket if event.type == "run_status"
    end

    snapshot = run.follow.snapshot

    assert_equal %w[lifecycle], @lane.asked.first(1),
      "a run nobody reads subscribes to the narrowing, not the whole stream"
    assert_nil @lane.asked.last, "and the upgrade opens the full one"
    assert run.snapshot.live
    assert_equal "landed while away and live", snapshot.text,
      "what landed while nobody read it is replayed, then live delivery continues it"
    assert snapshot.complete
  end

  # And letting go is the reverse: the full stream closes, the position stays,
  # and what is left is the lifecycle listener — so the run still reports when
  # it finishes, without shipping output nobody is reading.
  def test_detaching_leaves_a_lifecycle_listener
    run = run_for([
      Page.new(items: [], next_after: nil, watermark: 0),
      # The gap between the frozen head and the confirmed subscription.
      Page.new(items: [], next_after: nil, watermark: 0),
      # Drained by the durable pass that follows the detach.
      Page.new(items: [
        event(2, "text_delta", { "text" => "after" }),
        event(3, "result", {}),
      ], next_after: "c3", watermark: 3),
    ], sockets: [
      Socket.new([event(1, "text_delta", { "text" => "live " })]),
      Socket.new([]),
    ], terminal: one_shot(output_text: "live after"))

    # Attention leaves at the first delivered item, which is the only moment a
    # detach can be told apart from a stop.
    def run.apply(event)
      super
      detach_socket if event.sequence == 1
    end

    snapshot = run.follow.snapshot
    refute snapshot.live
    assert_equal [nil, "lifecycle"], @lane.asked,
      "the full stream gave way to the narrowing rather than to nothing"
    assert_equal "live after", snapshot.text,
      "the position carried across, so nothing was re-delivered and nothing lost"
    assert snapshot.complete
  end

  # A follower stops at the terminal item rather than draining forever, which
  # is what lets its fiber end instead of being killed.
  def test_following_ends_at_the_terminal_item_without_asking_again
    pages = [
      Page.new(items: [event(1, "result", {})],
               next_after: "c1", watermark: 1),
    ]
    run = run_for(pages, terminal: one_shot(status: "failed"))
    run.follow

    assert_empty pages, "the first page closed the stream"
    assert_equal "failed", run.snapshot.status
  end

  # An item type this daemon predates advances the position and means nothing.
  # A follower that raised on one would go dark the day Nexus learns a type.
  def test_an_unknown_item_type_is_carried_rather_than_refused
    run = run_for([
      Page.new(items: [
        event(1, "reasoning_delta", { "text" => "thinking" }),
        event(2, "something_new", { "whatever" => true }),
        event(3, "result", {}),
      ], next_after: "c3", watermark: 3),
    ])

    snapshot = run.follow.snapshot
    assert_equal "", snapshot.text, "only text deltas are the answer"
    assert_equal 3, snapshot.sequence, "but everything advanced the position"
    assert snapshot.complete
  end

  # A LOST SHARED CONNECTION ENDS THE SUBSCRIPTION, NOT THE RUN. Stopping would
  # cost the caller the answer so far, its position, and any way to resume
  # without re-delivering.
  def test_a_lost_shared_connection_keeps_following_on_a_new_subscription
    run = run_for(
      Array.new(4) { Page.new(items: [], next_after: nil, watermark: 0) },
      sockets: [
        Socket.new(
          [event(1, "text_delta", { "text" => "Mock: " })],
          ending: CybrosAgent::Realtime::ConnectionLostError
        ),
        Socket.new([
          event(2, "text_delta", { "text" => "say hi" }),
          event(3, "result", {}),
        ]),
      ],
      terminal: one_shot(output_text: "Mock: say hi")
    )
    snapshot = run.follow.snapshot
    assert_equal "Mock: say hi", snapshot.text,
      "the run kept its position and its answer across the rebind"
    assert snapshot.complete
  end

  def test_a_stopped_run_stops_draining
    pages = [
      Page.new(items: [event(1, "text_delta", { "text" => "partial" })], next_after: "c1", watermark: 9),
    ]
    run = run_for(pages)
    run.stop
    run.follow

    assert_equal "", run.snapshot.text, "a run stopped before it starts reads nothing"
    refute run.snapshot.complete
  end
end
