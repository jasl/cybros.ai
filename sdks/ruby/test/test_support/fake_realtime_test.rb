require "test_helper"
require "cybros_agent/test_support/fake_realtime"

# THE SHARED CABLE DOUBLE: the `Realtime::Client` surface a daemon touches,
# with frames pushed by the test instead of a socket. Delivery, drain and
# close keep the real client's ordering — buffered frames drain before the
# end is seen, and a closed stream ends `each` cleanly.
class TestSupportFakeRealtimeTest < Minitest::Test
  CHANNEL = "AgentAPI::V1::ExecutorInboxChannel".freeze

  def setup
    @realtime = CybrosAgent::TestSupport::FakeRealtime.new
  end

  def test_connect_records_the_state_the_daemon_reads
    refute_predicate @realtime, :connected?
    assert_same @realtime, @realtime.connect
    assert_predicate @realtime, :connected?
    assert_same @realtime, @realtime.connect_for_feed
    refute_predicate @realtime, :closed?
  end

  def test_subscriptions_are_recorded_with_their_params
    @realtime.connect
    @realtime.subscribe(channel: CHANNEL)
    @realtime.subscribe(channel: "AgentAPI::V1::RunEventsChannel",
      params: { workspace_id: "ws", run_id: "run" }, timeout: 5)

    assert_equal [
      { channel: CHANNEL, params: {} },
      { channel: "AgentAPI::V1::RunEventsChannel",
        params: { workspace_id: "ws", run_id: "run" } },
    ], @realtime.subscriptions.map(&:to_h)
  end

  def test_delivered_frames_reach_every_matching_subscription_in_order
    first = @realtime.connect.subscribe(channel: CHANNEL)
    second = @realtime.subscribe(channel: CHANNEL)
    other = @realtime.subscribe(channel: "AgentAPI::V1::RunEventsChannel",
      params: { workspace_id: "ws" })

    assert_equal 2, @realtime.deliver(CHANNEL, { "event" => { "type" => "work_available", "task_key" => "r1t0" } })
    assert_equal 2, @realtime.deliver(CHANNEL, { "event" => { "type" => "work_canceled", "task_key" => "r1t0" } })
    assert_equal 0, @realtime.deliver("AgentAPI::V1::RunEventsChannel", { "event" => {} },
      params: { workspace_id: "elsewhere" })
    @realtime.close

    [first, second].each do |subscription|
      types = []
      subscription.each { |frame| types << frame.dig("event", "type") }
      assert_equal %w[work_available work_canceled], types
    end
    assert_equal [], other.to_a, "an unmatched subscription received a frame"
  end

  # Params match as data: a subscription with symbol keys hears a delivery
  # spelled with string keys, the way the wire would have carried them.
  def test_params_match_by_value_across_key_spellings
    subscription = @realtime.connect.subscribe(channel: "Feed", params: { workspace_id: "ws" })

    assert_equal 1, @realtime.deliver("Feed", { "n" => 1 }, params: { "workspace_id" => "ws" })
    @realtime.close
    assert_equal [{ "n" => 1 }], subscription.to_a
  end

  # Ending order: frames delivered BEFORE the close still drain; a frame
  # delivered after it is dropped; `each` returns instead of raising.
  def test_close_ends_every_stream_after_the_buffered_frames_drain
    subscription = @realtime.connect.subscribe(channel: CHANNEL)
    @realtime.deliver(CHANNEL, { "n" => 1 })
    @realtime.close
    assert_equal 0, @realtime.deliver(CHANNEL, { "n" => 2 })

    assert_equal [{ "n" => 1 }], subscription.to_a
    assert_predicate subscription, :closed?
    assert_predicate @realtime, :closed?
    refute_predicate @realtime, :connected?
    assert_nil subscription.pop
  end

  def test_unsubscribe_ends_one_stream_and_leaves_the_client_open
    ended = @realtime.connect.subscribe(channel: CHANNEL)
    kept = @realtime.subscribe(channel: CHANNEL)

    assert_nil ended.unsubscribe
    assert_predicate ended, :closed?
    refute_predicate kept, :closed?
    refute_predicate @realtime, :closed?
    assert_equal 1, @realtime.deliver(CHANNEL, { "n" => 1 })
    assert_equal [], ended.to_a
    assert_equal({ "n" => 1 }, kept.pop)
  end

  # A reader blocked on an empty stream wakes when a frame lands or the
  # client closes — the shape a daemon's stream fiber relies on.
  def test_a_blocked_reader_wakes_on_delivery_and_on_close
    subscription = @realtime.connect.subscribe(channel: CHANNEL)
    seen = []
    reader = Thread.new { subscription.each { |frame| seen << frame } }

    Thread.pass until reader.status == "sleep"
    @realtime.deliver(CHANNEL, { "n" => 1 })
    Thread.pass until seen.length == 1
    @realtime.close

    assert reader.join(2), "the reader did not return after close"
    assert_equal [{ "n" => 1 }], seen
  end

  def test_subscribing_a_closed_client_is_refused
    @realtime.connect.close

    assert_raises(CybrosAgent::Realtime::ConnectionLostError) { @realtime.subscribe(channel: CHANNEL) }
  end
end
