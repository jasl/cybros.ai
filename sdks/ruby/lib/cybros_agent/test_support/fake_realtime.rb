module CybrosAgent
  # Test support the gem ships the way Minitest ships `Mock`: NOT required
  # by `cybros_agent.rb` — a consumer requires it by name
  # (`require "cybros_agent/test_support/fake_realtime"`).
  module TestSupport
    # THE SHARED CABLE DOUBLE: the `Realtime::Client` surface a
    # daemon touches — `connect`, `connect_for_feed`, `connected?`,
    # `subscribe`, `unsubscribe`, `close` — with frames pushed by the test
    # through `deliver` instead of arriving on a socket. It keeps the real
    # client's ending order: frames delivered before a close still drain,
    # then `each` returns cleanly; a frame delivered after it is dropped.
    #
    # Thread and fiber neutral on purpose: the queue is `Thread::Queue`,
    # which the fiber scheduler honours inside an Async reactor and a
    # plain thread honours outside one, so the same double serves a
    # daemon's stream fiber and a unit test's thread.
    class FakeRealtime
      # One recorded subscription, as data.
      Recorded = Data.define(:channel, :params)

      attr_reader :subscriptions

      def initialize
        @subscriptions = []
        @live = []
        @connected = false
        @closed = false
      end

      def connect(welcome_timeout: nil)
        raise Realtime::ConnectionLostError.new(reason: "closed") if @closed

        @connected = true
        self
      end

      # The real client serializes racing consumers onto one handshake; the
      # double has no handshake, so the two spellings are one.
      def connect_for_feed(welcome_timeout: nil) = connect(welcome_timeout: welcome_timeout)

      def connected? = @connected && !@closed

      def subscribe(channel:, params: {}, timeout: nil)
        raise Realtime::ConnectionLostError.new(reason: "closed") if @closed

        recorded = Recorded.new(channel: channel, params: params || {})
        @subscriptions = [*@subscriptions, recorded]
        subscription = FakeSubscription.new(client: self, channel: channel, params: recorded.params)
        @live = [*@live, subscription]
        subscription
      end

      def unsubscribe(subscription)
        subscription.finish
        @live = @live.reject { |live| live.equal?(subscription) }
        nil
      end

      # Push one frame to every live subscription on `channel` whose params
      # equal `params` as data (key spelling ignored). Answers how many
      # received it, so a test can assert a frame went nowhere.
      def deliver(channel, message, params: {})
        return 0 if @closed

        targets = @live.select { |live| live.matches?(channel, params) }
        targets.each { |live| live.deliver(message) }
        targets.length
      end

      def close
        @closed = true
        @connected = false
        @live.each(&:finish)
        @live = []
        nil
      end

      def closed? = @closed

      def inspect
        "#<#{self.class.name} connected=#{connected?} closed=#{closed?} subscriptions=#{@subscriptions.length}>"
      end
    end

    # One stream of the double: `each` yields frames in delivery order and
    # returns once the stream ended; `pop` answers nil then.
    class FakeSubscription
      include Enumerable

      attr_reader :channel, :params

      def initialize(client:, channel:, params:)
        @client = client
        @channel = channel
        @params = params
        @queue = Thread::Queue.new
      end

      def each
        while (message = pop)
          yield message
        end
        nil
      end

      def pop
        @queue.pop
      end

      def unsubscribe
        @client.unsubscribe(self)
        nil
      end

      def closed? = @queue.closed?

      def matches?(channel, params)
        @channel == channel && normalize(@params) == normalize(params)
      end

      # -- driven by FakeRealtime --

      def deliver(message)
        return if closed?

        @queue.push(message)
        nil
      end

      # Idempotent: a closed queue drains what it holds, then answers nil.
      def finish
        @queue.close
        nil
      end

      private

        def normalize(params)
          (params || {}).to_h.transform_keys(&:to_s)
        end
    end
  end
end
