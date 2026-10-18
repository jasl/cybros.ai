require "test_helper"

# Record opened subscriptions, not merely calls that build an opener: the SDK
# deliberately refuses attach while another opener is already installed.
class HostFollowerSubscriptionTest < Minitest::Test
  Event = Data.define(:sequence, :cursor, :public_id, :type, :payload)
  Page = Data.define(:items, :next_after, :watermark)

  class Socket
    attr_reader :items, :closed

    def initialize(items)
      @items = items
      @closed = false
      @events = []
    end

    def push(event) = @events << event

    def each
      until @closed
        event = @events.shift
        event ? yield(event) : Fiber.yield
      end
    end

    def unsubscribe = @closed = true
  end

  class Realtime
    def rebind = true
    def close = raise "the shared client must remain open"
  end

  class Context
    attr_reader :sockets, :cursors
    attr_accessor :opening

    def initialize
      @events = []
      @sockets = []
      @cursors = []
    end

    def append(event) = @events << event

    def events(after: nil, limit: nil)
      @cursors << after
      offset = after ? @events.index { |event| event.cursor == after } + 1 : 0
      items = @events.drop(offset)
      items = items.take(limit) if limit
      Page.new(items: items, next_after: items.last&.cursor || after,
        watermark: @events.last&.sequence || 0)
    end

    def realtime_opener(_realtime, items: nil)
      -> do
        socket = Socket.new(items)
        @sockets << socket
        @opening&.call
        socket
      end
    end

    def feed(realtime: nil, items: nil, **options)
      CybrosAgent::KernelFeed.new(
        replay: ->(cursor) { events(after: cursor) },
        subscribe: realtime && realtime_opener(realtime, items: items), **options
      )
    end
  end

  def setup
    @context = Context.new
    @seen = []
  end

  def teardown
    @run&.stop
    @follower.resume if @follower&.alive?
  end

  def test_a_conversation_widens_and_narrows_its_actual_subscription_without_replaying_delivered_events
    exercise_switch(Rho::Host::Conversation.new(public_id: "c-1"))
  end

  def test_a_standalone_run_widens_and_narrows_its_actual_subscription_without_replaying_delivered_events
    exercise_switch(Rho::Host::Run.new(public_id: "al-1"))
  end

  def test_switching_while_the_first_subscription_opens_discards_the_old_mode
    @context.opening = -> { Fiber.yield }
    start(Rho::Host::Conversation.new(public_id: "c-1"))
    old = @context.sockets.first
    assert @run.attach_socket
    @context.opening = nil
    @follower.resume

    assert old.closed
    assert_equal ["lifecycle", nil], @context.sockets.map(&:items)
    refute @context.sockets.last.closed
    assert_equal [1], @seen
  end

  def test_a_stopped_host_cannot_report_an_attached_subscription
    start(Rho::Host::Conversation.new(public_id: "c-1"))
    @run.stop

    refute @run.attach_socket
    refute @run.snapshot.live
    assert_equal ["lifecycle"], @context.sockets.map(&:items)
  end

  private

    def start(host)
      append(1)
      @run = Rho::HostFollower.new(host: host, context: @context, realtime: Realtime.new,
        live: false, stream: false, sleeper: ->(_seconds) { Fiber.yield })
      @run.listen { |event| @seen << event.sequence }
      @follower = Fiber.new { @run.follow }
      @follower.resume
    end

    def exercise_switch(host)
      start(host)
      assert_equal ["lifecycle"], @context.sockets.map(&:items)
      append(2)
      assert @run.attach_socket
      @follower.resume

      assert @run.snapshot.live
      assert_equal ["lifecycle", nil], @context.sockets.map(&:items)
      assert @context.sockets.first.closed
      assert_equal [1, 2], @seen
      refute @run.attach_socket

      live = @context.sockets.last
      live.push(append(3))
      @follower.resume
      append(4)
      assert @run.detach_socket
      @follower.resume

      refute @run.snapshot.live
      assert live.closed
      assert_equal ["lifecycle", nil, "lifecycle"], @context.sockets.map(&:items)
      refute @context.sockets.last.closed
      assert_equal [1, 2, 3, 4], @seen
      assert_equal 4, @run.snapshot.sequence
      assert_equal 1, @context.cursors.count(nil), "switching retains the one feed's cursor"
      refute @run.detach_socket
    end

    def append(sequence)
      event = Event.new(sequence: sequence, cursor: "cursor-#{sequence}", public_id: "e#{sequence}",
        type: "future_item", payload: {})
      @context.append(event)
      event
    end
end
