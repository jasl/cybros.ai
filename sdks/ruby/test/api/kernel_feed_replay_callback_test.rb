require "test_helper"

class KernelFeedReplayCallbackTest < Minitest::Test
  Event = Data.define(:sequence, :cursor)
  Page = Data.define(:items, :watermark)

  class Subscription
    def each = nil
    def unsubscribe = nil
  end

  def test_recovery_runs_after_the_entire_frozen_drain_and_before_subscribing
    pages = [page([1], 2), page([2], 3), page([3], 3)]
    calls = []
    feed = CybrosAgent::KernelFeed.new(replay: ->(_cursor) { pages.shift },
      after_replay: ->(head) { calls << [:recovered, head, Fiber.current] },
      subscribe: -> { calls << :subscribe; Subscription.new })

    feed.each { |event| calls << event.sequence }

    assert_equal [1, 2, [:recovered, 2, Fiber.current], :subscribe, 3,
      [:recovered, 3, Fiber.current]], calls
    assert_equal 3, feed.position.sequence
  end

  def test_an_empty_retained_window_reports_its_head_without_inventing_a_consumed_event
    restored = []
    position = CybrosAgent::KernelFeed::Position.new(cursor: "c2", sequence: 2)
    feed = CybrosAgent::KernelFeed.new(replay: ->(_cursor) { page([], 8) }, position: position,
      after_replay: restored.method(:<<))

    feed.each { flunk "expired events cannot be replayed" }

    assert_equal [8], restored
    assert_equal position, feed.position
  end

  def test_a_transient_consumer_recovery_failure_escapes_without_opening_the_socket
    recoveries = 0
    subscriptions = 0
    error = CybrosAgent::Api::ServerError.new("temporarily unavailable")
    feed = CybrosAgent::KernelFeed.new(replay: ->(_cursor) { page([], 8) },
      after_replay: ->(_head) { recoveries += 1; raise error if recoveries == 1 },
      subscribe: -> { subscriptions += 1; Subscription.new })

    assert_same error, assert_raises(CybrosAgent::Api::ServerError) { feed.each { } }
    assert_equal 1, recoveries, "consumer failures do not spend the feed's transport retry budget"
    assert_equal 0, subscriptions

    feed.each { }
    assert_equal 1, subscriptions
  end

  def test_exhausting_transport_retries_does_not_report_a_successful_replay
    restored = []
    feed = CybrosAgent::KernelFeed.new(
      replay: ->(_cursor) { raise CybrosAgent::TransportError, "offline" },
      max_transient_retries: 0, after_replay: ->(head) { restored << head })

    feed.each { flunk "the transport returned no events" }

    assert_empty restored
    assert_equal CybrosAgent::KernelFeed::Position.start, feed.position
  end

  def test_an_explicit_stop_during_replay_does_not_start_state_recovery
    restored = []
    feed = CybrosAgent::KernelFeed.new(replay: ->(_cursor) { page([1], 1) },
      after_replay: ->(head) { restored << head })

    feed.each { feed.stop }

    assert_empty restored
    assert_equal 1, feed.position.sequence
  end

  private

    def page(sequences, head)
      Page.new(items: sequences.map { |sequence| Event.new(sequence: sequence, cursor: "c#{sequence}") },
        watermark: head)
    end
end
