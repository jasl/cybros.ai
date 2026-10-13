require "test_helper"
require "cybros_agent/realtime"

class KernelFeedShutdownTest < Minitest::Test
  Page = Data.define(:items, :next_after, :watermark)

  # Only network writes are scripted: the real client, subscription, adapter
  # and feed still own their queues, lifecycle and cursor.
  class Connection
    attr_reader :commands, :unsubscribe_started

    def initialize
      @incoming = Async::Queue.new
      @incoming.enqueue(JSON.generate({ "type" => "welcome" }))
      @unsubscribe_started = Async::Queue.new
      @release = Async::Queue.new
      @closed = false
      @commands = []
    end

    def read = @incoming.dequeue

    def write(text)
      command = JSON.parse(text)
      @commands << command
      case command.fetch("command")
      when "subscribe"
        @incoming.enqueue(JSON.generate({
          "type" => "confirm_subscription", "identifier" => command.fetch("identifier"),
        }))
      when "unsubscribe"
        @unsubscribe_started.enqueue(true)
        @release.dequeue
      else nil
      end
    end

    def flush = nil

    def release = @release.enqueue(true)

    def broadcast(identifier, message)
      @incoming.enqueue(JSON.generate({ "identifier" => identifier, "message" => message }))
    end

    def framer = self

    def close
      return if @closed

      @closed = true
      release
      @incoming.enqueue(nil)
    end
  end

  class Client < CybrosAgent::Realtime::Client
    def initialize(connection:, **)
      @scripted_connection = connection
      super(**)
    end

    private

      def open_connection = @scripted_connection
  end

  def test_stopping_the_feed_releases_its_consumer_without_waiting_for_unsubscribe_io
    Sync do |task|
      connection = Connection.new
      client = Client.new(connection: connection, endpoint: CybrosAgent::Realtime::Endpoint.new(
        base_url: "http://kernel.test", credential: "test-member"
      ))
      subscribed = Async::Queue.new
      reads = 0
      replay = ->(_cursor) do
        reads += 1
        subscribed.enqueue(true) if reads == 2
        Page.new(items: [], next_after: nil, watermark: 0)
      end
      opener = CybrosAgent::Realtime::FeedSubscription.opener(
        client: client, channel: "AgentAPI::V1::EventsChannel",
        params: { conversation_id: "c-1", workspace_id: "ws-1" },
        event: ->(message) { message }
      )
      feed = CybrosAgent::KernelFeed.new(replay: replay, subscribe: opener)
      consumer = task.async { feed.each { flunk "this stream has no events" } }
      subscribed.dequeue
      stopping = task.async { feed.stop }
      connection.unsubscribe_started.dequeue
      task.yield

      assert stopping.finished?, "a best-effort wire unsubscribe must not block local stop"
      assert_same feed, task.with_timeout(1) { consumer.wait },
        "the feed must return while its shared client's read pump remains open"
      assert_equal 0, feed.position.sequence
    ensure
      connection&.release
      client&.close
    end
  end

  def test_replacing_an_unsubscribed_address_preserves_wire_order_and_ignores_the_old_handle
    Sync do |task|
      connection = Connection.new
      client = Client.new(connection: connection, endpoint: CybrosAgent::Realtime::Endpoint.new(
        base_url: "http://kernel.test", credential: "test-member"
      ))
      client.connect
      old = client.subscribe(channel: "AgentAPI::V1::EventsChannel", params: { conversation_id: "c-1" })
      unsubscribing = task.async { old.unsubscribe }
      connection.unsubscribe_started.dequeue
      task.yield

      assert unsubscribing.finished?
      assert_nil old.pop
      replacing = task.async do
        client.subscribe(channel: "AgentAPI::V1::EventsChannel", params: { conversation_id: "c-1" })
      end
      task.yield
      refute replacing.finished?, "the replacement must wait behind the old wire cleanup"
      assert_equal %w[subscribe unsubscribe], connection.commands.map { |command| command.fetch("command") }

      connection.release
      replacement = task.with_timeout(1) { replacing.wait }
      refute_equal old.wire_identifier, replacement.wire_identifier
      old.unsubscribe
      connection.broadcast(old.wire_identifier, { "event" => "stale" })
      connection.broadcast(replacement.wire_identifier, { "event" => "current" })

      assert_equal({ "event" => "current" }, replacement.pop(timeout: 1))
      refute replacement.closed?
      assert_equal %w[subscribe unsubscribe subscribe], connection.commands.map { |command| command.fetch("command") }
    ensure
      connection&.release
      client&.close
    end
  end
end
