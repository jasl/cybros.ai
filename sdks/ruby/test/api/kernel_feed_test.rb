require "test_helper"

# The pump that makes "follow this run" correct rather than hopeful.
#
# Every case here is a property the barrier exists to hold. The doubles are
# deliberately dumb — a page is a page and a subscription is an array — so
# that what is being tested is the pump's control flow and nothing else.
class KernelFeedTest < Minitest::Test
  Page = Data.define(:items, :next_after, :watermark)
  Event = Data.define(:sequence, :cursor, :public_id)

  def event(sequence) = Event.new(sequence: sequence, cursor: "c#{sequence}", public_id: "e#{sequence}")

  # Serves pre-baked pages in order and records what cursor each call asked
  # for, so a test can assert the pump resumed where it said it would.
  class Replay
    attr_reader :asked

    def initialize(pages)
      @pages = pages
      @asked = []
    end

    def call(cursor)
      @asked << cursor
      @pages.shift || Page.new(items: [], next_after: nil, watermark: 0)
    end
  end

  # Yields scripted EVENTS — the same typed items the replay page yields, and
  # not the wire's `{"event" => …}` frame. The adapter that opens a socket is
  # what turns one into the other, and a double that skipped that step would
  # be modelling a shape nothing produces. It did, and the pump crashed on the
  # first real frame it ever saw.
  class Subscription
    attr_reader :unsubscribed

    def initialize(frames, ending: nil)
      @frames = frames
      @ending = ending
      @unsubscribed = 0
    end

    def each(&block)
      @frames.each(&block)
      raise @ending if @ending
    end

    def unsubscribe = @unsubscribed += 1
  end

  def page(sequences, watermark:)
    Page.new(items: sequences.map { event(_1) }, next_after: nil, watermark: watermark)
  end

  def feed(replay, **options)
    CybrosAgent::KernelFeed.new(replay: replay, sleeper: ->(_seconds) { }, **options)
  end

  # ATTACHING LATE IS THE SAME BARRIER, NOT A RESUME PATH. A consumer that
  # follows many resources wants a socket only for the one someone is looking
  # at — so a run followed over REST while it was out of focus must, on
  # attaching, get what already landed and then continue from where it
  # stopped. The pump does that by re-entering: drain to a frozen head,
  # subscribe, drain the gap, go live.
  def test_a_socket_attached_late_replays_what_landed_then_goes_live
    replay = Replay.new([
      Page.new(items: [event(1), event(2)], next_after: "c2", watermark: 2),
      # The gap between the frozen head and the confirmed subscription.
      Page.new(items: [event(3)], next_after: "c3", watermark: 3),
    ])
    pump = feed(replay)

    assert_equal [1, 2], collect(pump), "a REST follower with no socket still sees everything"

    assert pump.attach(-> { Subscription.new([event(4)]) })
    assert_equal [3, 4], collect(pump),
      "the gap drain runs before live delivery, because subscribing replays no backlog"
    assert_equal [nil, "c2", "c3"], replay.asked,
      "and every read resumed from the position the last one reached"
  end

  # A PAGE WITHOUT A WATERMARK ENDS THE DRAIN WHERE THE PAGE ENDS. Not every
  # replay reader publishes a committed head (a fake, an older door); the
  # drain must still deliver what the page carries and stop, never compare
  # its position with nothing — that comparison raised inside the reactor
  # and was printed as a warning no test failed on.
  def test_a_page_without_a_watermark_is_drained_once_and_raises_nothing
    replay = Replay.new([
      Page.new(items: [event(1), event(2)], next_after: "c2", watermark: nil),
      Page.new(items: [event(3)], next_after: "c3", watermark: nil),
    ])
    pump = feed(replay)

    assert_silent { assert_equal [1, 2], collect(pump), "one pass over the watermark-less page, then stop" }
    assert_equal [3], collect(pump), "the next pass resumes from the position the last one reached"
    assert_equal [nil, "c2"], replay.asked
  end

  # DETACHING ENDS THE SOCKET, NOT THE FOLLOWING. What is left is the REST
  # follower this class starts as, holding the position it reached — which is
  # what makes losing focus cost nothing.
  def test_detaching_leaves_a_rest_follower_that_keeps_its_position
    subscription = Subscription.new([event(2)])
    replay = Replay.new([
      Page.new(items: [event(1)], next_after: "c1", watermark: 1),
      Page.new(items: [], next_after: nil, watermark: 1),
      Page.new(items: [event(3)], next_after: "c3", watermark: 3),
    ])
    pump = feed(replay, subscribe: -> { subscription })

    seen = []
    pump.each do |item|
      seen << item.sequence
      pump.detach if item.sequence == 2
    end

    assert_equal [1, 2], seen
    assert_operator subscription.unsubscribed, :>=, 1,
      "the socket is closed rather than left open — twice here, because detach ends the " \
      "subscription through rebind's door and the pump's ensure closes it again, which is " \
      "the shape rebind already has and why unsubscribe is idempotent"
    assert_equal [3], collect(pump), "and the next pass is an ordinary durable drain"
  end

  def test_attach_and_detach_answer_whether_they_changed_anything
    pump = feed(Replay.new([]))

    assert pump.attach(-> { Subscription.new([]) })
    refute pump.attach(-> { Subscription.new([]) }), "already attached"
    assert pump.detach
    refute pump.detach, "nothing to detach"
    refute pump.attach(nil), "nil is not a subscription"
  end

  # Opening a socket is network IO and may still be in flight when attention
  # moves elsewhere. A late opener from the old attachment must be disposed,
  # never installed over the replacement attachment.
  def test_detach_and_attach_supersede_an_in_flight_opener
    opener_started = Queue.new
    release_opener = Queue.new
    old_subscription = Subscription.new([])
    new_subscription = Subscription.new([event(1)])
    replay = Replay.new([
      page([], watermark: 0),
      page([], watermark: 0),
    ])
    old_opener = lambda do
      opener_started << true
      release_opener.pop
      old_subscription
    end
    pump = feed(replay, subscribe: old_opener)
    seen = []
    follower = Thread.new { pump.each { |item| seen << item.sequence } }

    opener_started.pop
    assert pump.detach
    assert pump.attach(-> { new_subscription })
    release_opener << true

    assert follower.join(2), "the replacement subscription should finish the pump"
    assert_equal [1], seen
    assert_equal 1, old_subscription.unsubscribed,
      "the superseded opener is closed immediately instead of becoming live"
    assert_equal 1, new_subscription.unsubscribed
  ensure
    release_opener << true if follower&.alive?
    pump&.stop
    follower&.join(1)
  end

  # Stop may land while the network opener is still outside the feed's mutex.
  # Once stopping wins, the late subscription is disposed rather than
  # installed, and no live item can cross the stopped boundary.
  def test_stop_supersedes_an_in_flight_opener
    opener_started = Queue.new
    release_opener = Queue.new
    subscription = Subscription.new([event(1)])
    replay = Replay.new([page([], watermark: 0)])
    opener = lambda do
      opener_started << true
      release_opener.pop
      subscription
    end
    pump = feed(replay, subscribe: opener)
    seen = []
    follower = Thread.new { pump.each { |item| seen << item.sequence } }

    opener_started.pop
    pump.stop
    release_opener << true

    assert follower.join(2), "the stopped pump must discard a late opener"
    assert_empty seen
    assert_equal 1, subscription.unsubscribed
  ensure
    release_opener << true if follower&.alive?
    pump&.stop
    follower&.join(1)
  end

  # A NARROWED SUBSCRIPTION DOES NOT NARROW WHAT THIS PUMP DELIVERS, and the
  # server's `items: "lifecycle"` is the case that makes it visible. That
  # narrowing puts a SUBSET of one sequence space on the socket while the replay
  # window still serves the whole of it — so a live item arriving more than one
  # sequence past the position is a gap by the only rule this pump has, and the
  # re-drain hands the consumer the very deltas it did not subscribe to.
  #
  # That is correct, not a leak: the durable window is the authority and the
  # drain is what makes the answer complete. What the narrowing buys is a socket
  # that stays silent and a client that stops polling — measured here so the
  # benefit is not restated as something it is not.
  def test_a_narrowed_socket_still_delivers_the_whole_stream_through_the_drain
    drains = 0
    pages = [
      page([1], watermark: 1),
      page([], watermark: 1),
      page([2, 3, 4, 5], watermark: 5),
    ]
    replay = ->(_cursor) do
      drains += 1
      pages.shift || Page.new(items: [], next_after: nil, watermark: 5)
    end
    # The socket carries only the terminal item, four sequences past the head.
    pump = feed(replay, subscribe: -> { Subscription.new([event(5)]) })

    assert_equal [1, 2, 3, 4, 5], collect(pump),
      "everything arrives, in order, exactly once — through the window, not the socket"
    assert_equal 3, drains,
      "and the last of those drains is the gap rule closing what the socket skipped"
  end

  def collect(feed)
    seen = []
    feed.each { |item| seen << item.sequence }
    seen
  end

  # A REPLAY-ONLY FEED IS A FIRST-CLASS FEED. It needs no socket, which is
  # both a supported way to use the API and what makes every case below
  # testable without one.
  def test_a_feed_with_no_subscription_drains_once_and_returns
    replay = Replay.new([page([1, 2], watermark: 3), page([3], watermark: 3)])

    assert_equal [1, 2, 3], collect(feed(replay))
    assert_equal [nil, "c2"], replay.asked, "each page resumes from the last item applied"
  end

  # THE HEAD IS FROZEN AT THE FIRST PAGE. A stream that keeps producing
  # reports a higher head on every page; a drain that chased it would never
  # end. This is the case the predecessor got wrong — it drained "until a page
  # comes back empty", which on a live stream is a moving target.
  def test_the_drain_stops_at_the_head_it_froze_not_the_one_that_moved
    replay = Replay.new([
      page([1, 2], watermark: 3),
      page([3], watermark: 9),   # the stream grew while we were reading
      page([4, 5], watermark: 9),
    ])

    assert_equal [1, 2, 3], collect(feed(replay)),
      "whatever arrived after the drain started belongs to the next drain"
  end

  # An empty page cannot move the position, so continuing would spin forever.
  # The predecessor could reach exactly this state and did run.
  def test_a_short_stream_that_never_reaches_its_head_still_terminates
    replay = Replay.new([page([1], watermark: 7)])

    assert_equal [1], collect(feed(replay))
  end

  def test_the_position_advances_only_after_the_consumer_returns
    replay = Replay.new([page([1, 2], watermark: 2)])
    pump = feed(replay)

    assert_raises(RuntimeError) do
      pump.each { |item| raise "consumer failed" if item.sequence == 2 }
    end
    assert_equal 1, pump.position.sequence, "the failed event stays eligible for replay"
    assert_equal "c1", pump.position.cursor
  end

  def test_a_transient_shaped_consumer_failure_reaches_the_consumer
    pump = feed(Replay.new([page([1], watermark: 1)]))
    refusal = CybrosAgent::Api::RateLimited.new(retry_after: 7)

    raised = assert_raises(CybrosAgent::Api::RateLimited) do
      pump.each { raise refusal }
    end

    assert_same refusal, raised
    assert_equal 0, pump.position.sequence,
      "a consumer failure must not be spent against the feed transport budget"
  end

  def test_a_feed_resumes_from_the_position_it_was_given
    replay = Replay.new([page([4, 5], watermark: 5)])
    position = CybrosAgent::KernelFeed::Position.new(cursor: "c3", sequence: 3)

    assert_equal [4, 5], collect(feed(replay, position: position))
    assert_equal ["c3"], replay.asked
  end

  # THE BARRIER: drain, subscribe, drain the gap, live. The second drain is
  # what covers whatever was published between the first one and the
  # subscription being confirmed — nothing here treats a confirmation as
  # proof the gap is closed.
  def test_the_gap_between_the_first_drain_and_the_subscription_is_drained
    replay = Replay.new([
      page([1], watermark: 1),   # first drain
      page([2], watermark: 2),   # the gap drain, after subscribing
    ])
    subscription = Subscription.new([event(3)])
    pump = feed(replay, subscribe: -> { subscription })

    assert_equal [1, 2, 3], collect(pump)
    assert_equal 1, subscription.unsubscribed, "a pump that ends releases its socket"
  end

  # The socket redelivers what replay already gave. Dedupe is by sequence,
  # which is on the wire precisely so nobody decodes a cursor to get it.
  def test_live_frames_already_seen_are_dropped
    replay = Replay.new([page([1, 2], watermark: 2), page([], watermark: 2)])
    subscription = Subscription.new([1, 2, 3].map { event(_1) })
    pump = feed(replay, subscribe: -> { subscription })

    assert_equal [1, 2, 3], collect(pump)
  end

  # A FORWARD GAP IS A REPLAY SIGNAL. The socket can reorder whenever two
  # appends commit on different threads, so an item arriving ahead of the next
  # expected one means something durable has not been seen.
  def test_a_forward_gap_triggers_a_redrain_before_the_frame_is_considered
    replay = Replay.new([
      page([1], watermark: 1),
      page([], watermark: 1),     # gap drain after subscribe
      page([2, 3], watermark: 3), # the re-drain the gap triggers
    ])
    subscription = Subscription.new([event(4), event(3)])
    pump = feed(replay, subscribe: -> { subscription })

    assert_equal [1, 2, 3, 4], collect(pump),
      "the gap is closed from the durable window, and then the live frame lands in order"
  end

  # THE PREDECESSOR'S ONE REAL BUG. It delivered the gapped frame anyway and
  # moved the floor with it, so an item the socket never sent was skipped
  # forever. Dropping loses nothing: the item is durable and the next drain
  # yields it in order.
  def test_a_gap_the_redrain_cannot_close_drops_the_frame_rather_than_skipping_past_it
    replay = Replay.new([
      page([1], watermark: 1),
      page([], watermark: 1),
      page([], watermark: 1),  # the re-drain finds nothing: item 2 is not there yet
    ])
    subscription = Subscription.new([event(3)])
    pump = feed(replay, subscribe: -> { subscription })

    assert_equal [1], collect(pump)
    assert_equal 1, pump.position.sequence,
      "the floor must not step over an item that has never been seen"
  end

  # A lost connection re-drains from the last committed position and
  # resubscribes; backpressure is a lost connection by inheritance, which is
  # the charter's catch-up path with no extra machinery.
  def test_a_lost_connection_redrains_and_resubscribes
    replay = Replay.new([
      page([1], watermark: 1), page([], watermark: 1),
      page([2], watermark: 2), page([], watermark: 2),
    ])
    first = Subscription.new([], ending: CybrosAgent::Realtime::SubscriptionBackpressureError)
    second = Subscription.new([event(3)])
    sockets = [first, second]
    pump = feed(replay, subscribe: -> { sockets.shift })

    assert_equal [1, 2, 3], collect(pump)
    assert_equal 1, first.unsubscribed, "the lost subscription is released, not leaked"
    assert_equal 1, second.unsubscribed
  end

  # A REBIND ENDS THE SUBSCRIPTION, NOT THE PUMP. Ending both would be easy
  # and wrong: a rotated credential is not a reason to stop following a run,
  # and a caller that had to restart the pump would have to know its position
  # to do it without re-delivering.
  def test_a_rebind_resubscribes_without_ending_the_pump
    replay = Replay.new([
      page([1], watermark: 1), page([], watermark: 1),
      page([], watermark: 1), page([], watermark: 1),
    ])
    opened = 0
    sockets = [
      Subscription.new([event(2)]),  # rebound after this one is applied
      Subscription.new([event(3)]),
    ]
    subscribe = lambda do
      opened += 1
      sockets.shift
    end
    pump = feed(replay, subscribe: subscribe)

    seen = []
    pump.each do |item|
      seen << item.sequence
      pump.rebind if item.sequence == 2
      pump.stop if item.sequence == 3
    end

    assert_equal [1, 2, 3], seen, "the pump kept going, and kept its position"
    assert_equal 2, opened, "the rebind opened a second subscription"
  end

  def test_rebinding_with_no_subscription_says_so
    pump = feed(Replay.new([page([], watermark: 0)]))

    refute pump.rebind, "a caller sweeping followers can tell which were listening"
  end

  # A REFUSAL IS AN ANSWER, and reaches the caller. Spending a retry budget on
  # a server that said no is how a pump goes quiet for no reason.
  def test_a_rejected_subscription_reaches_the_caller
    replay = Replay.new([page([1], watermark: 1)])
    pump = feed(replay, subscribe: -> { raise CybrosAgent::Realtime::SubscriptionRejectedError })

    assert_raises(CybrosAgent::Realtime::SubscriptionRejectedError) { collect(pump) }
  end

  def test_a_connection_lost_before_subscription_confirmation_is_retried
    attempts = 0
    subscribe = lambda do
      attempts += 1
      if attempts == 1
        raise CybrosAgent::Realtime::ConnectionLostError,
          "the cable closed before confirmation"
      end

      Subscription.new([event(1)])
    end
    replay = Replay.new([page([], watermark: 0), page([], watermark: 0)])

    assert_equal [1], collect(feed(replay, subscribe: subscribe))
    assert_equal 2, attempts
  end

  # A missing answer is worth retrying; a refusal is not. The predecessor
  # retried every SDK error, which spends the whole budget on a 404.
  def test_a_transient_failure_is_retried_and_a_refusal_is_not
    flaky = Object.new
    def flaky.asked = @asked ||= 0
    def flaky.call(_cursor)
      @asked = asked + 1
      raise CybrosAgent::TransportError, "boom" if @asked < 3

      Page.new(items: [Event.new(sequence: 1, cursor: "c1", public_id: "e1")], next_after: nil, watermark: 1)
    end
    flaky.define_singleton_method(:const_missing) { |name| KernelFeedTest.const_get(name) }

    assert_equal [1], collect(feed(flaky))
    assert_equal 3, flaky.asked

    refusing = ->(_cursor) { raise CybrosAgent::Api::NotFound }
    assert_raises(CybrosAgent::Api::NotFound) { collect(feed(refusing)) }
  end

  def test_a_realtime_subscribe_timeout_uses_the_default_backoff_and_retries
    attempts = 0
    slept = []
    subscribe = lambda do
      attempts += 1
      raise CybrosAgent::Realtime::TimeoutError, "quiet" if attempts == 1

      Subscription.new([event(1)])
    end
    replay = Replay.new([page([], watermark: 0), page([], watermark: 0)])
    pump = CybrosAgent::KernelFeed.new(
      replay: replay, subscribe: subscribe, sleeper: ->(seconds) { slept << seconds }
    )

    assert_equal [1], collect(pump)
    assert_equal [0.5], slept
  end

  # A throttle names its own delay; honouring it is the difference between
  # backing off and hammering a server that just said not to.
  def test_a_throttle_is_waited_out_for_as_long_as_it_asked
    slept = []
    attempts = 0
    replay = lambda do |_cursor|
      attempts += 1
      raise CybrosAgent::Api::RateLimited.new(retry_after: 7) if attempts == 1

      Page.new(items: [], next_after: nil, watermark: 0)
    end
    pump = CybrosAgent::KernelFeed.new(replay: replay, sleeper: ->(seconds) { slept << seconds })

    collect(pump)
    assert_equal [7], slept
  end

  def test_an_exhausted_budget_ends_the_pump_quietly
    replay = ->(_cursor) { raise CybrosAgent::Api::ServerError, "down" }
    pump = feed(replay, max_transient_retries: 2)

    assert_equal [], collect(pump), "a supervisor restarts a finished feed; an exception tells nobody"
  end

  # A pump stopped before it starts still drains: the durable window is
  # readable whether or not anyone means to keep listening, and the caller
  # asked for the events it already has.
  def test_a_pump_stopped_before_it_starts_drains_once_and_never_subscribes
    replay = Replay.new([page([1], watermark: 1)])
    subscribed = 0
    pump = feed(replay, subscribe: -> { subscribed += 1; Subscription.new([]) })
    pump.stop

    assert_equal [1], collect(pump)
    assert_equal 0, subscribed, "there is nothing to listen for once stopping is decided"
  end

  # Stopping mid-flight releases the socket rather than waiting for the pump
  # to notice: a subscription blocked reading frames is exactly the case that
  # would otherwise hang a shutdown.
  def test_stopping_mid_flight_releases_the_live_subscription
    replay = Replay.new([page([], watermark: 0), page([], watermark: 0)])
    subscription = Subscription.new([event(1), event(2)])
    pump = feed(replay, subscribe: -> { subscription })
    seen = []
    pump.each { |item| seen << item.sequence; pump.stop }

    assert_operator subscription.unsubscribed, :>=, 1, "the socket is released, not leaked"
    assert_equal [1, 2], seen,
      "stopping does not abandon frames the subscription has already handed over"
  end
end
