require "test_helper"
require "cybros_agent/realtime"
require "socket"
require_relative "../support/fake_cable_server"

module CybrosAgent
  module Realtime
    # THE RACES, against a real socket.
    #
    # Two thirds of this file is reconnect-race coverage, and it is ported
    # rather than written because it cannot be rediscovered: every case here
    # is a window between a connection dying and its replacement being
    # installed, and reading the client does not tell you which windows exist.
    # Generation fencing, the three-phase subscribe timeout and the bounded
    # framer-first close are each load-bearing for a handful of these and for
    # nothing a happy path would notice.
    #
    # It runs against an in-process ActionCable on a loopback port, so a test
    # can script what no live server would do on demand — stall a handshake,
    # disconnect instead of welcoming, confirm and then vanish.
    class ClientTest < Minitest::Test
      CHANNEL = "AgentAPI::V1::OneShotEventsChannel"
      ACCESS_TOKEN = "sk-cybros-api-v1-test"
      WORKSPACE_ID = "ws_1"

      # The production connection contract always exposes a framer (the client
      # hard-closes it first); doubles mirror that contract with an instantly
      # closable framer so close-path tests exercise the real sequence.
      class NullFramer
        attr_reader :close_calls

        def initialize = @close_calls = 0
        def close = @close_calls += 1
      end

      module FakeFramer
        def framer = @framer ||= NullFramer.new
      end

      class FailingWriteConnection
        include FakeFramer
        attr_reader :closed

        def write(*) = raise(IOError, "socket is closed")
        def flush = nil
        def close = @closed = true
      end

      class StallingConnection
        include FakeFramer
        attr_reader :closed

        def initialize(stall:, stall_close: false)
          @stall = stall
          @stall_close = stall_close
          @close_release = Async::Queue.new
          @close_started = false
        end

        def write(*)
          sleep(10) if @stall == :write
        end

        def flush
          sleep(10) if @stall == :flush
        end

        def close
          @close_started = true
          @close_release.dequeue if @stall_close
          @closed = true
        end

        def close_started? = @close_started

        def release_close
          @close_release.enqueue(true) unless @closed
        end
      end

      class ConnectionSequenceClient < Client
        def initialize(connections:, **)
          @connections = connections
          super(**)
        end

        private

        def open_connection
          @connections.shift || raise("no scripted connection remains")
        end
      end

      class PendingOpenSequenceClient < Client
        attr_reader :open_count

        def initialize(connections:, **)
          @connections = connections
          @open_releases = connections.map { Async::Queue.new }
          @open_count = 0
          super(**)
        end

        def release_open(index)
          @open_releases.fetch(index).enqueue(true)
        end

        private

        def open_connection
          index = @open_count
          @open_count += 1
          @open_releases.fetch(index).dequeue
          @connections.fetch(index)
        end
      end

      class CloseTimeoutSequenceClient < ConnectionSequenceClient
        attr_reader :cleanup_tasks

        def initialize(**)
          @cleanup_tasks = []
          super
        end

        def live_cleanup_tasks
          @cleanup_tasks.count { |task| !task.finished? }
        end

        private

        def connection_close_timeout = 0.02

        def close_connection_async(...)
          result = super
          @cleanup_tasks << result if result.is_a?(Async::Task)
          result
        end
      end

      # Hands ITSELF out twice, which is the only way to ask whether the fence
      # is the generation counter or merely object identity. Every other
      # scripted connection here is a distinct object, so identity alone
      # carries them — and a fence that rested on identity would pass all of
      # them while failing the one case it exists for.
      class RewelcomingConnection
        include FakeFramer
        attr_reader :closed

        def initialize
          @incoming = Async::Queue.new
          rewelcome
        end

        def rewelcome = @incoming.enqueue(JSON.generate({ "type" => "welcome" }))
        def read = @incoming.dequeue
        def write(_text) = nil
        def flush = nil
        def close = @closed = true
      end

      class ReconnectConnection
        include FakeFramer
        attr_reader :closed

        def initialize(stall_write: false, stall_flush: false, release_reader_on_close: true)
          @stall_write = stall_write
          @stall_flush = stall_flush
          @release_reader_on_close = release_reader_on_close
          @incoming = Async::Queue.new
          @incoming.enqueue(JSON.generate({ "type" => "welcome" }))
          @write_started = false
          @flush_started = false
        end

        def read = @incoming.dequeue

        def write(text)
          @write_started = true
          sleep(10) if @stall_write

          command = JSON.parse(text)
          return unless command["command"] == "subscribe"

          @incoming.enqueue(
            JSON.generate({ "identifier" => command.fetch("identifier"), "type" => "confirm_subscription" })
          )
        end

        def flush
          @flush_started = true
          sleep(10) if @stall_flush
        end

        def write_started? = @write_started
        def flush_started? = @flush_started

        def close
          @closed = true
          release_reader if @release_reader_on_close
        end

        def release_reader
          @incoming.enqueue(nil)
        end
      end

      class BlockingCloseConnection
        include FakeFramer
        attr_reader :closed

        def initialize
          @incoming = Async::Queue.new
          @incoming.enqueue(JSON.generate({ "type" => "welcome" }))
          @close_release = Async::Queue.new
          @close_started = false
        end

        def read = @incoming.dequeue

        def write(text)
          command = JSON.parse(text)
          return unless command["command"] == "subscribe"

          @incoming.enqueue(
            JSON.generate({ "identifier" => command.fetch("identifier"), "type" => "confirm_subscription" })
          )
        end

        def flush = nil
        def close_started? = @close_started

        def disconnect
          @incoming.enqueue(nil)
        end

        def release_close
          @close_release.enqueue(true) unless @closed
        end

        def close
          @close_started = true
          @close_release.dequeue
          @closed = true
        end
      end

      class ImmediateLossConnection
        include FakeFramer
        attr_reader :close_calls

        def initialize
          @incoming = Async::Queue.new
          @incoming.enqueue(JSON.generate({ "type" => "welcome" }))
          @incoming.enqueue(nil)
          @close_calls = 0
        end

        def read = @incoming.dequeue
        def close = @close_calls += 1
      end

      class DelayedWelcomeConnection
        include FakeFramer
        attr_reader :closed

        def initialize
          @welcome_release = Async::Queue.new
          @incoming = Async::Queue.new
          @read_started = false
        end

        def read
          unless @read_started
            @read_started = true
            @welcome_release.dequeue
            return JSON.generate({ "type" => "welcome" })
          end

          @incoming.dequeue
        end

        def read_started? = @read_started
        def release_welcome = @welcome_release.enqueue(true)

        def close
          @closed = true
          release_welcome
          @incoming.enqueue(nil)
        end
      end

      class HardCloseFramer
        attr_reader :close_calls

        def initialize
          @close_calls = 0
        end

        def close
          @close_calls += 1
        end

        def closed? = @close_calls.positive?
      end

      class HangingCloseConnection
        attr_reader :active_close_calls, :close_calls, :framer

        def initialize
          @incoming = Async::Queue.new
          @incoming.enqueue(JSON.generate({ "type" => "welcome" }))
          @framer = HardCloseFramer.new
          @active_close_calls = 0
          @close_calls = 0
          @decorator_released = false
        end

        def read = @incoming.dequeue

        def write(*)
          sleep(10)
        end

        def flush = nil

        def close
          @close_calls += 1
          @active_close_calls += 1
          if @framer.closed?
            @decorator_released = true
            @incoming.enqueue(nil)
            sleep(10)
          else
            sleep
          end
        ensure
          @active_close_calls -= 1
        end

        def hard_closed? = @framer.closed?
        def decorator_released? = @decorator_released
      end

      class StallingProtocolFramer
        attr_reader :close_calls

        def initialize
          @close_calls = 0
          @hard_closed = false
        end

        def write_frame(*) = nil

        def flush
          sleep(10) unless @hard_closed
        end

        def close
          @close_calls += 1
          @hard_closed = true
        end

        def hard_closed? = @hard_closed
      end

      class DecoratedClientOwner
        attr_reader :close_calls

        def initialize
          @close_calls = 0
        end

        def close
          @close_calls += 1
        end
      end

      class BlockingCleanupConnection
        include FakeFramer
        attr_reader :commands

        def initialize(release_cleanup_on_close: true, confirm_replacement: true)
          @incoming = Async::Queue.new
          @incoming.enqueue(JSON.generate({ "type" => "welcome" }))
          @cleanup_release = Async::Queue.new
          @release_cleanup_on_close = release_cleanup_on_close
          @confirm_replacement = confirm_replacement
          @commands = []
          @subscribe_count = 0
          @cleanup_started = false
          @cleanup_released = false
          @cleanup_finished = false
          @replacement_entered_during_cleanup = false
          @closed = false
        end

        def read = @incoming.dequeue

        def write(text)
          command = JSON.parse(text)
          @commands << command.fetch("command")

          case command.fetch("command")
          when "subscribe"
            @subscribe_count += 1
            @identifier = command.fetch("identifier")
            if @subscribe_count > 1
              @replacement_entered_during_cleanup = @cleanup_started && !@cleanup_released
              confirm if @confirm_replacement
            end
          when "unsubscribe"
            @cleanup_started = true
            begin
              @cleanup_release.dequeue unless @closed
              @cleanup_released = true
            ensure
              @cleanup_finished = true
            end
          else nil # this script only cares about the two it stalls
          end
        end

        def flush = nil
        def cleanup_started? = @cleanup_started
        def cleanup_finished? = @cleanup_finished
        def replacement_entered_during_cleanup? = @replacement_entered_during_cleanup
        def replacement_written? = @subscribe_count > 1

        def confirm
          @incoming.enqueue(JSON.generate({ "identifier" => @identifier, "type" => "confirm_subscription" }))
        end

        def broadcast(message)
          @incoming.enqueue(JSON.generate({ "identifier" => @identifier, "message" => message }))
        end

        def release_cleanup
          @cleanup_release.enqueue(true) unless @cleanup_released
        end

        def close
          @closed = true
          release_cleanup if @release_cleanup_on_close
          @incoming.enqueue(nil)
        end
      end

      class WireIdentityConnection
        include FakeFramer
        attr_reader :commands, :subscribe_identifiers

        def initialize
          @incoming = Async::Queue.new
          @incoming.enqueue(JSON.generate({ "type" => "welcome" }))
          @second_write_release = Async::Queue.new
          @commands = []
          @subscribe_identifiers = []
          @second_write_started = false
          @second_write_released = false
          @closed = false
        end

        def read = @incoming.dequeue

        def write(text)
          command = JSON.parse(text)
          @commands << command
          return unless command.fetch("command") == "subscribe"

          @subscribe_identifiers << command.fetch("identifier")
          return unless @subscribe_identifiers.size == 2

          @second_write_started = true
          @second_write_release.dequeue unless @closed
          @second_write_released = true
        end

        def flush = nil
        def second_write_started? = @second_write_started

        def release_second_write
          @second_write_release.enqueue(true) unless @second_write_released
        end

        def confirm(identifier)
          inject({ "identifier" => identifier, "type" => "confirm_subscription" })
        end

        def reject(identifier)
          inject({ "identifier" => identifier, "type" => "reject_subscription" })
        end

        def broadcast(identifier, message)
          inject({ "identifier" => identifier, "message" => message })
        end

        def close
          @closed = true
          release_second_write
          @incoming.enqueue(nil)
        end

        private

        def inject(frame)
          @incoming.enqueue(JSON.generate(frame))
        end
      end

      def test_connect_waits_for_welcome_and_handshake_carries_auth_and_subprotocol
        run_cable(behavior: welcome_then_drain) do |server|
          client = build_client(server)
          assert_nil client.last_ping_at

          client.connect
          assert client.connected?

          handshake = server.handshakes.fetch(0)
          assert_equal "Bearer #{ACCESS_TOKEN}", handshake[:authorization]
          assert_includes handshake[:protocols], "actioncable-v1-json"
          assert_includes handshake[:protocols], "actioncable-unsupported"
          assert_equal "/agent_api/v1/cable", handshake[:path]

          client.close
          refute client.connected?
        end
      end

      def test_connect_times_out_when_no_welcome_arrives
        behavior = ->(session) { session.drain }
        run_cable(behavior:) do |server|
          client = build_client(server)
          error = assert_raises(Realtime::TimeoutError) { client.connect(welcome_timeout: 0.2) }
          assert_match(/welcome/, error.message)
          refute client.connected?
        end
      end

      def test_connect_timeout_bounds_a_stalled_websocket_handshake
        with_stalled_handshake_peer do |base_url|
          client = Realtime::Client.new(endpoint: endpoint_for(base_url))
          started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

          error = assert_raises(Realtime::TimeoutError) do
            Sync do |task|
              task.with_timeout(1, RuntimeError, "stalled handshake test watchdog") do
                client.connect(welcome_timeout: 0.1)
              end
            end
          end

          elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
          assert_operator elapsed, :<, 0.75
          assert_match(/welcome/, error.message)
          refute client.connected?
        ensure
          client&.close
        end
      end

      def test_close_cancels_a_pending_open_without_leaking_its_socket_or_clobbering_a_reconnect
        first = ReconnectConnection.new
        second = ReconnectConnection.new
        client = PendingOpenSequenceClient.new(
          connections: [first, second], endpoint: endpoint_for("http://kernel.test")
        )

        Sync do |task|
          first_connect = task.async do
            client.connect
          rescue StandardError => error
            error
          end
          wait_until { client.open_count == 1 }

          client.close
          second_connect = task.async { client.connect }
          wait_until { client.open_count == 2 }
          client.release_open(1)
          assert_same client, second_connect.wait

          client.release_open(0)
          first_result = first_connect.wait
          sleep(0.01)

          assert_instance_of ConnectionLostError, first_result
          assert first.closed
          assert client.connected?
          replacement = client.subscribe(channel: CHANNEL, params: conversation_params("replacement"), timeout: 1)
          refute replacement.closed?
          client.close
        end
      ensure
        client&.release_open(0) if client&.open_count.to_i >= 1
        client&.release_open(1) if client&.open_count.to_i >= 2
        first&.release_reader
        second&.release_reader
        client&.close
      end

      def test_connect_rejects_a_second_in_progress_handshake
        connection = ReconnectConnection.new
        client = PendingOpenSequenceClient.new(
          connections: [connection], endpoint: endpoint_for("http://kernel.test")
        )

        Sync do |task|
          pending = task.async do
            client.connect
          rescue StandardError => error
            error
          end
          wait_until { client.open_count == 1 }

          error = assert_raises(CybrosAgent::Error) { client.connect }
          assert_match(/already connecting/, error.message)

          client.close
          client.release_open(0)
          assert_instance_of ConnectionLostError, pending.wait
        end
      ensure
        client&.release_open(0) if client&.open_count.to_i >= 1
        connection&.release_reader
        client&.close
      end

      def test_connected_remains_false_until_the_welcome_handshake_completes
        connection = DelayedWelcomeConnection.new
        client = ConnectionSequenceClient.new(
          connections: [connection], endpoint: endpoint_for("http://kernel.test")
        )

        Sync do |task|
          pending = task.async { client.connect }
          wait_until { connection.read_started? }

          refute client.connected?
          error = assert_raises(CybrosAgent::Error) do
            client.subscribe(channel: CHANNEL, params: conversation_params("c_1"))
          end
          assert_match(/not connected/, error.message)

          connection.release_welcome
          assert_same client, pending.wait
          assert client.connected?
          client.close
        end
      ensure
        connection&.release_welcome
        client&.close
      end

      def test_immediate_pump_loss_schedules_the_origin_socket_close_once
        connection = ImmediateLossConnection.new
        client = ConnectionSequenceClient.new(
          connections: [connection], endpoint: endpoint_for("http://kernel.test")
        )

        Sync do
          assert_raises(ConnectionLostError) { client.connect }
          sleep(0.01)

          assert_equal 1, connection.close_calls
          refute client.connected?
        end
      ensure
        client&.close
      end

      # A HANDSHAKE FAILURE IS A MISSING ANSWER, not a refusal — so it is the
      # transport error a feed retries, and the message has to say which of
      # the two it was. From a consumer that only sees "nothing arrived" a
      # refused upgrade and a quiet stream look identical and have completely
      # different causes.
      def test_an_unreachable_server_is_a_transport_failure_that_says_which_kind
        server = TCPServer.new("127.0.0.1", 0)
        port = server.addr.fetch(1)
        server.close
        client = Realtime::Client.new(endpoint: endpoint_for("http://127.0.0.1:#{port}"))

        error = assert_raises(CybrosAgent::TransportError) do
          Sync { client.connect(welcome_timeout: 1) }
        end

        assert_match(/would not upgrade/, error.message)
        assert_match(%r{ws://127\.0\.0\.1:#{port}/agent_api/v1/cable}, error.message,
          "the address it could not reach is the first thing an operator needs")
        assert_match(/not the same as a stream that stayed quiet/, error.message)
        assert_kind_of CybrosAgent::TransportError, error,
          "a feed retries this; a rejection it must not"
        refute client.connected?
      ensure
        server&.close
        client&.close
      end

      def test_connect_raises_connection_lost_when_server_disconnects_instead_of_welcoming
        behavior = ->(session) { session.disconnect(reason: "unauthorized") }
        run_cable(behavior:) do |server|
          client = build_client(server)
          error = assert_raises(ConnectionLostError) { client.connect }
          assert_equal "unauthorized", error.reason
          refute client.connected?
        end
      end

      # THE ENDPOINT IS THE ONLY SOURCE, so "which credential" is settled
      # before a client exists — and a source that answers nothing is a
      # failure at the moment the handshake needs it, not a header that says
      # `Bearer `.
      def test_a_credential_source_that_answers_nothing_is_refused_at_the_handshake
        endpoint = Realtime::Endpoint.new(base_url: "http://kernel.test", credential: -> { })

        assert_raises(ArgumentError) { endpoint.headers }
      end

      def test_connect_requires_an_async_reactor
        client = Realtime::Client.new(endpoint: endpoint_for("http://127.0.0.1:1"))
        error = assert_raises(CybrosAgent::Error) { client.connect }
        assert_match(/Async reactor/, error.message)
      end

      def test_subscribe_confirms_and_each_yields_messages_in_order
        behavior = lambda do |session|
          session.welcome
          command = session.read_command
          session.confirm(command["identifier"])
          1.upto(3) { |n| session.broadcast(command["identifier"], { "event" => { "cursor" => n } }) }
          session.drain
        end
        run_cable(behavior:) do |server|
          client = build_client(server)
          client.connect
          subscription = client.subscribe(channel: CHANNEL, params: conversation_params("c_1"))

          received = []
          consumer = Async::Task.current.async do
            subscription.each { |message| received << message }
            :returned
          end
          wait_until { received.size == 3 }
          client.close

          assert_equal :returned, consumer.wait, "each returns cleanly on explicit close"
          assert_equal [1, 2, 3], received.map { |message| message.dig("event", "cursor") }
        end
      end

      def test_feed_openers_multiplex_concurrent_subscriptions_on_one_connection
        commands = []
        behavior = lambda do |session|
          session.welcome
          2.times do
            command = session.read_command
            commands << command
            session.confirm(command.fetch("identifier"))
          end
          session.drain
        end
        run_cable(behavior:) do |server|
          client = build_client(server)
          mapper = ->(message) { message }
          first = Async::Task.current.async do
            FeedSubscription.open(
              client: client, channel: CHANNEL,
              params: conversation_params("first"), event: mapper
            )
          end
          second = Async::Task.current.async do
            FeedSubscription.open(
              client: client, channel: CHANNEL,
              params: conversation_params("second"), event: mapper
            )
          end

          subscriptions = [first.wait, second.wait]
          assert_equal 1, server.handshakes.size,
            "one daemon-owned client performs one handshake for both logical feeds"
          assert_equal %w[subscribe subscribe], commands.map { |command| command.fetch("command") }

          subscriptions.each(&:unsubscribe)
          assert client.connected?, "logical unsubscribe does not close the shared transport"
          client.close
        end
      end

      def test_rebind_loses_every_logical_subscription_and_lazily_reconnects_once
        first_connection = ReconnectConnection.new
        second_connection = ReconnectConnection.new
        client = ConnectionSequenceClient.new(
          connections: [first_connection, second_connection],
          endpoint: endpoint_for("http://kernel.test")
        )

        Sync do
          first = FeedSubscription.open(
            client: client, channel: CHANNEL,
            params: conversation_params("first"), event: ->(message) { message }
          )
          second = FeedSubscription.open(
            client: client, channel: CHANNEL,
            params: conversation_params("second"), event: ->(message) { message }
          )

          assert client.rebind
          assert_raises(ConnectionLostError) { first.each { } }
          assert_raises(ConnectionLostError) { second.each { } }

          replacement = FeedSubscription.open(
            client: client, channel: CHANNEL,
            params: conversation_params("replacement"), event: ->(message) { message }
          )
          assert client.connected?
          replacement.unsubscribe
          client.close
        end
      ensure
        first_connection&.release_reader
        second_connection&.release_reader
        client&.close
      end

      def test_rebind_cancels_an_in_flight_feed_connect_without_clobbering_the_replacement
        first_connection = ReconnectConnection.new
        second_connection = ReconnectConnection.new
        client = PendingOpenSequenceClient.new(
          connections: [first_connection, second_connection],
          endpoint: endpoint_for("http://kernel.test")
        )

        Sync do |task|
          first_connect = task.async do
            client.connect_for_feed
          rescue StandardError => error
            error
          end
          wait_until { client.open_count == 1 }

          assert client.rebind
          replacement = task.async { client.connect_for_feed }
          client.release_open(0)
          wait_until { client.open_count == 2 }
          client.release_open(1)

          assert_instance_of ConnectionLostError, first_connect.wait
          assert_same client, replacement.wait
          assert client.connected?
          client.close
        end
      ensure
        client&.release_open(0) if client&.open_count.to_i >= 1
        client&.release_open(1) if client&.open_count.to_i >= 2
        first_connection&.release_reader
        second_connection&.release_reader
        client&.close
      end

      def test_slow_consumer_overflow_is_terminal_and_does_not_block_the_socket_pump
        commands = []
        message_count = Subscription::MAX_BUFFERED_MESSAGES + 1
        behavior = lambda do |session|
          session.welcome
          command = session.read_command
          commands << command
          session.confirm(command["identifier"])
          1.upto(message_count) do |cursor|
            session.broadcast(command["identifier"], { "event" => { "cursor" => cursor } })
          end
          session.ping

          first_follow_up = session.read_command
          next if first_follow_up.nil?

          commands << first_follow_up
          second_follow_up = session.read_command
          next if second_follow_up.nil?

          commands << second_follow_up
          replacement = [first_follow_up, second_follow_up].find { |candidate| candidate["command"] == "subscribe" }
          next if replacement.nil?

          session.confirm(replacement["identifier"])
          session.broadcast(replacement["identifier"], { "event" => { "cursor" => "replayed" } })
          session.drain
        end
        run_cable(behavior:) do |server|
          client = build_client(server)
          client.connect
          subscription = client.subscribe(channel: CHANNEL, params: conversation_params("c_1"))

          wait_until { client.last_ping_at }

          assert subscription.closed?, "an unread subscription terminates when its buffer overflows"

          received = Subscription::MAX_BUFFERED_MESSAGES.times.map { subscription.pop(timeout: 5) }
          error = assert_raises(SubscriptionBackpressureError) { subscription.pop(timeout: 5) }

          assert_match(/buffer/, error.message)
          assert_equal Subscription::MAX_BUFFERED_MESSAGES, received.size
          assert_equal (1..Subscription::MAX_BUFFERED_MESSAGES).to_a,
                       received.map { |message| message.dig("event", "cursor") }
          assert_includes client.inspect, "subscriptions=0"

          replacement = client.subscribe(channel: CHANNEL, params: conversation_params("c_1"))

          assert_equal 3, commands.size
          assert_equal "unsubscribe", commands.fetch(1).fetch("command")
          assert_equal commands.fetch(0).fetch("identifier"), commands.fetch(1).fetch("identifier")
          assert_equal "subscribe", commands.fetch(2).fetch("command")
          assert_equal({ "event" => { "cursor" => "replayed" } }, replacement.pop(timeout: 5))
        end
      end

      def test_subscribe_raises_when_the_server_rejects
        behavior = lambda do |session|
          session.welcome
          command = session.read_command
          session.reject(command["identifier"])
          session.drain
        end
        run_cable(behavior:) do |server|
          client = build_client(server)
          client.connect
          error = assert_raises(SubscriptionRejectedError) do
            client.subscribe(channel: CHANNEL, params: conversation_params("denied"))
          end
          assert_includes error.identifier, "denied"
          client.close
        end
      end

      def test_subscribe_times_out_when_the_server_stays_silent
        commands = []
        behavior = lambda do |session|
          session.welcome
          stable = session.read_command
          commands << stable
          session.confirm(stable.fetch("identifier"))

          commands << session.read_command
          commands << session.read_command
          session.broadcast(stable.fetch("identifier"), { "event" => { "cursor" => "still-live" } })

          replacement = session.read_command
          commands << replacement
          session.confirm(replacement.fetch("identifier"))
          session.drain
        end
        run_cable(behavior:) do |server|
          client = build_client(server)
          client.connect

          stable = client.subscribe(channel: CHANNEL, params: conversation_params("stable"))
          assert_raises(Realtime::TimeoutError) do
            client.subscribe(channel: CHANNEL, params: conversation_params("c_1"), timeout: 0.2)
          end

          assert client.connected?
          assert_includes client.inspect, "subscriptions=1"
          assert_equal({ "event" => { "cursor" => "still-live" } }, stable.pop(timeout: 1))

          replacement = client.subscribe(channel: CHANNEL, params: conversation_params("c_1"), timeout: 1)
          refute replacement.closed?

          assert_equal %w[subscribe subscribe unsubscribe subscribe], commands.map { |command| command.fetch("command") }
          client.close
        end
      end

      def test_subscribe_timeout_bounds_a_stalled_write
        assert_subscribe_send_timeout(stall: :write)
      end

      def test_subscribe_timeout_bounds_a_stalled_flush
        assert_subscribe_send_timeout(stall: :flush)
      end

      def test_subscribe_timeout_is_not_delayed_by_a_blocked_pump_stop
        assert_subscribe_timeout_ignores_blocked_teardown_task(slot: :pump)
      end

      def test_subscribe_timeout_is_not_delayed_by_a_blocked_outbound_task_stop
        assert_subscribe_timeout_ignores_blocked_teardown_task(slot: :outbound)
      end

      def test_repeated_timeouts_bound_physical_close_and_release_old_websocket_clients
        old_connections = Array.new(4) { HangingCloseConnection.new }
        current_connection = ReconnectConnection.new
        client = CloseTimeoutSequenceClient.new(
          connections: old_connections + [current_connection],
          endpoint: endpoint_for("http://kernel.test")
        )

        Sync do
          old_connections.each_with_index do |_connection, index|
            client.connect
            started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            assert_raises(Realtime::TimeoutError) do
              client.subscribe(
                channel: CHANNEL,
                params: conversation_params("old-#{index}"),
                timeout: 0.03
              )
            end
            elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
            assert_operator elapsed, :<, 0.2
          end

          client.connect
          replacement = client.subscribe(
            channel: CHANNEL, params: conversation_params("replacement"), timeout: 1
          )

          cleanup_deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 0.5
          while client.live_cleanup_tasks.positive? &&
                Process.clock_gettime(Process::CLOCK_MONOTONIC) < cleanup_deadline
            sleep(0.005)
          end

          assert_equal 0, client.live_cleanup_tasks
          assert old_connections.all?(&:hard_closed?)
          assert old_connections.all?(&:decorator_released?)
          assert old_connections.all? { |connection| connection.close_calls == 1 }
          assert old_connections.all? { |connection| connection.framer.close_calls == 1 }
          assert old_connections.all? { |connection| connection.active_close_calls.zero? }
          assert client.connected?
          refute replacement.closed?
          client.close
        end
      ensure
        current_connection&.release_reader
        client&.close
      end

      def test_hard_close_releases_the_actual_async_websocket_client_decorator
        framer = StallingProtocolFramer.new
        owner = DecoratedClientOwner.new
        protocol_connection = ::Protocol::WebSocket::Connection.new(framer)
        decorated_connection = Async::WebSocket::Client::ClientCloseDecorator.new(owner, protocol_connection)
        client = CloseTimeoutSequenceClient.new(
          connections: [], endpoint: endpoint_for("http://kernel.test")
        )
        client.instance_variable_set(:@connection, decorated_connection)

        Sync do
          client.close
          cleanup_deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 0.25
          while client.live_cleanup_tasks.positive? &&
                Process.clock_gettime(Process::CLOCK_MONOTONIC) < cleanup_deadline
            sleep(0.005)
          end

          assert_equal 0, client.live_cleanup_tasks
          assert framer.hard_closed?
          assert_operator framer.close_calls, :>=, 1
          assert_equal 1, owner.close_calls
        end
      ensure
        client&.close
      end

      def test_close_outside_an_async_reactor_still_bounds_physical_cleanup
        connection = HangingCloseConnection.new
        client = CloseTimeoutSequenceClient.new(
          connections: [], endpoint: endpoint_for("http://kernel.test")
        )
        client.instance_variable_set(:@connection, connection)

        closer = Thread.new { client.close }
        assert closer.join(0.25), "physical close remained unbounded outside an Async reactor"
        assert connection.hard_closed?
        assert connection.decorator_released?
        assert_equal 0, connection.active_close_calls
      ensure
        closer&.kill
        closer&.join
        client&.close
      end

      def test_confirm_timeout_cleanup_does_not_delay_the_subscribe_task
        connection = BlockingCleanupConnection.new
        client = Realtime::Client.new(endpoint: endpoint_for("http://kernel.test"))
        client.instance_variable_set(:@connection, connection)
        outcome = nil
        reactor = Thread.new do
          outcome = Sync do
            begin
              client.subscribe(channel: CHANNEL, params: conversation_params("c_1"), timeout: 0.05)
            rescue StandardError => error
              error
            end
          end
        end

        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1
        until connection.cleanup_started?
          raise "cleanup did not start" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

          sleep(0.005)
        end

        assert reactor.join(0.25), "timeout cleanup kept the caller's reactor alive"
        assert_instance_of Realtime::TimeoutError, outcome
      ensure
        connection&.release_cleanup
        reactor&.join(1)
        client&.close
      end

      def test_send_timeout_old_pump_cannot_close_an_immediately_reconnected_connection
        first = ReconnectConnection.new(stall_write: true, release_reader_on_close: false)
        second = ReconnectConnection.new
        client = ConnectionSequenceClient.new(
          connections: [first, second], endpoint: endpoint_for("http://kernel.test")
        )

        Sync do
          client.connect
          assert_raises(Realtime::TimeoutError) do
            client.subscribe(channel: CHANNEL, params: conversation_params("c_1"), timeout: 0.1)
          end

          client.connect
          first.release_reader
          sleep(0.01)

          assert client.connected?
          subscription = client.subscribe(channel: CHANNEL, params: conversation_params("c_1"), timeout: 1)
          refute subscription.closed?
          client.close
        end
      ensure
        first&.release_reader
        client&.close
      end

      def test_old_generation_write_timeout_cannot_close_a_reconnected_connection
        assert_old_generation_send_timeout_is_fenced(stall: :write)
      end

      def test_old_generation_flush_timeout_cannot_close_a_reconnected_connection
        assert_old_generation_send_timeout_is_fenced(stall: :flush)
      end

      # THE COUNTER, NOT THE OBJECT. A late teardown carries the connection it
      # was started for; if the fence compared only identity, a connection
      # object handed out a second time would let that teardown kill its own
      # replacement. Nothing else in this file can ask the question, because
      # every other scripted connection is a distinct object.
      def test_the_generation_counter_fences_a_reused_connection_object
        connection = RewelcomingConnection.new
        client = ConnectionSequenceClient.new(
          connections: [connection, connection], endpoint: endpoint_for("http://kernel.test")
        )

        Sync do
          client.connect
          stale_generation = client.instance_variable_get(:@connection_generation)
          client.close
          connection.rewelcome
          client.connect

          assert_equal stale_generation + 1, client.instance_variable_get(:@connection_generation),
            "a reconnect installs a new generation even onto the same object"
          client.send(:connection_lost, reason: nil, connection: connection, generation: stale_generation)

          assert client.connected?,
            "a teardown from the previous generation must not reach its replacement"
          client.close
        end
      end

      def test_old_connection_loss_finishes_only_its_captured_subscriptions_when_close_yields
        first = BlockingCloseConnection.new
        second = ReconnectConnection.new
        client = ConnectionSequenceClient.new(
          connections: [first, second], endpoint: endpoint_for("http://kernel.test")
        )

        Sync do
          client.connect
          old_subscription = client.subscribe(
            channel: CHANNEL, params: conversation_params("old"), timeout: 1
          )
          first.disconnect
          wait_until { first.close_started? }

          client.connect
          replacement = client.subscribe(
            channel: CHANNEL, params: conversation_params("replacement"), timeout: 1
          )
          first.release_close
          wait_until { first.closed }
          sleep(0.01)

          assert old_subscription.closed?
          assert client.connected?
          refute replacement.closed?
          client.close
        end
      ensure
        first&.release_close
        second&.release_reader
        client&.close
      end

      def test_timeout_cleanup_is_serialized_before_an_immediate_replacement_subscribe
        connection = BlockingCleanupConnection.new
        client = ConnectionSequenceClient.new(
          connections: [connection], endpoint: endpoint_for("http://kernel.test")
        )

        Sync do |task|
          client.connect
          assert_raises(Realtime::TimeoutError) do
            client.subscribe(channel: CHANNEL, params: conversation_params("c_1"), timeout: 0.1)
          end

          replacement_task = task.async do
            client.subscribe(channel: CHANNEL, params: conversation_params("c_1"), timeout: 1)
          end
          wait_until { connection.cleanup_started? }
          sleep(0.01)

          refute connection.replacement_entered_during_cleanup?
          connection.release_cleanup

          replacement = replacement_task.wait
          refute replacement.closed?
          assert_equal %w[subscribe unsubscribe subscribe], connection.commands
          client.close
        end
      ensure
        connection&.release_cleanup
        client&.close
      end

      def test_close_stops_a_blocked_cleanup_before_reconnecting
        first = BlockingCleanupConnection.new(release_cleanup_on_close: false)
        second = ReconnectConnection.new
        client = ConnectionSequenceClient.new(
          connections: [first, second], endpoint: endpoint_for("http://kernel.test")
        )

        Sync do
          client.connect
          assert_raises(Realtime::TimeoutError) do
            client.subscribe(channel: CHANNEL, params: conversation_params("c_1"), timeout: 0.1)
          end
          wait_until { first.cleanup_started? }

          client.close
          sleep(0.01)
          assert first.cleanup_finished?

          client.connect
          subscription = client.subscribe(channel: CHANNEL, params: conversation_params("c_1"), timeout: 1)
          refute subscription.closed?
          client.close
        end
      ensure
        first&.release_cleanup
        client&.close
      end

      def test_late_frames_cannot_target_a_replacement_waiting_behind_cleanup
        connection = BlockingCleanupConnection.new(confirm_replacement: false)
        client = ConnectionSequenceClient.new(
          connections: [connection], endpoint: endpoint_for("http://kernel.test")
        )

        Sync do |task|
          client.connect
          assert_raises(Realtime::TimeoutError) do
            client.subscribe(channel: CHANNEL, params: conversation_params("c_1"), timeout: 0.1)
          end

          replacement_task = task.async do
            client.subscribe(channel: CHANNEL, params: conversation_params("c_1"), timeout: 1)
          end
          wait_until { connection.cleanup_started? }

          connection.confirm
          connection.broadcast({ "event" => { "cursor" => "stale-a" } })
          sleep(0.01)

          assert_includes client.inspect, "subscriptions=0"
          refute replacement_task.finished?

          connection.release_cleanup
          wait_until { connection.replacement_written? }
          assert_includes client.inspect, "subscriptions=1"
          refute replacement_task.finished?

          connection.confirm
          replacement = replacement_task.wait
          assert_raises(Realtime::TimeoutError) { replacement.pop(timeout: 0.05) }
          client.close
        end
      ensure
        connection&.release_cleanup
        client&.close
      end

      def test_timeout_waiting_behind_cleanup_keeps_the_connection_usable
        connection = BlockingCleanupConnection.new
        client = ConnectionSequenceClient.new(
          connections: [connection], endpoint: endpoint_for("http://kernel.test")
        )

        Sync do
          client.connect
          assert_raises(Realtime::TimeoutError) do
            client.subscribe(channel: CHANNEL, params: conversation_params("c_1"), timeout: 0.1)
          end
          wait_until { connection.cleanup_started? }

          assert_raises(Realtime::TimeoutError) do
            client.subscribe(channel: CHANNEL, params: conversation_params("c_1"), timeout: 0.05)
          end

          assert client.connected?
          assert_includes client.inspect, "subscriptions=0"
          connection.release_cleanup
          client.close
        end
      ensure
        connection&.release_cleanup
        client&.close
      end

      def test_queued_duplicate_subscribe_is_rejected_without_losing_the_connection
        connection = BlockingCleanupConnection.new
        client = ConnectionSequenceClient.new(
          connections: [connection], endpoint: endpoint_for("http://kernel.test")
        )

        Sync do |task|
          client.connect
          assert_raises(Realtime::TimeoutError) do
            client.subscribe(channel: CHANNEL, params: conversation_params("c_1"), timeout: 0.1)
          end
          wait_until { connection.cleanup_started? }

          first_task = task.async do
            client.subscribe(channel: CHANNEL, params: conversation_params("c_1"), timeout: 1)
          end
          duplicate_task = task.async do
            client.subscribe(channel: CHANNEL, params: conversation_params("c_1"), timeout: 1)
          rescue StandardError => error
            error
          end

          connection.release_cleanup
          first = first_task.wait
          duplicate_error = duplicate_task.wait

          refute first.closed?
          assert_instance_of ArgumentError, duplicate_error
          assert client.connected?
          client.close
        end
      ensure
        connection&.release_cleanup
        client&.close
      end

      def test_replacement_wire_identifier_isolates_late_frames_after_its_write_starts
        connection = WireIdentityConnection.new
        client = ConnectionSequenceClient.new(
          connections: [connection], endpoint: endpoint_for("http://kernel.test")
        )
        params = conversation_params("c_1")

        Sync do |task|
          client.connect
          assert_raises(Realtime::TimeoutError) do
            client.subscribe(channel: CHANNEL, params:, timeout: 0.1)
          end

          replacement_task = task.async do
            client.subscribe(channel: CHANNEL, params:, timeout: 1)
          end
          wait_until { connection.second_write_started? }
          first_identifier, replacement_identifier = connection.subscribe_identifiers

          connection.confirm(first_identifier)
          connection.broadcast(first_identifier, { "event" => { "cursor" => "stale-a" } })
          connection.reject(first_identifier)
          connection.release_second_write
          sleep(0.01)

          refute replacement_task.finished?
          connection.confirm(replacement_identifier)
          replacement = replacement_task.wait

          refute_equal first_identifier, replacement_identifier
          assert_equal Protocol.identifier(channel: CHANNEL, params:), replacement.identifier
          assert_raises(Realtime::TimeoutError) { replacement.pop(timeout: 0.05) }
          assert_raises(ArgumentError) { client.subscribe(channel: CHANNEL, params:, timeout: 0.1) }

          replacement.unsubscribe
          unsubscribe = connection.commands.reverse.find { |command| command["command"] == "unsubscribe" }
          assert_equal replacement_identifier, unsubscribe.fetch("identifier")
          client.close
        end
      ensure
        connection&.release_second_write
        client&.close
      end

      def test_subscribe_write_failure_marks_the_connection_lost_and_clears_registration
        client = Realtime::Client.new(endpoint: endpoint_for("http://kernel.test"))
        connection = FailingWriteConnection.new
        client.instance_variable_set(:@connection, connection)

        error = assert_raises(ConnectionLostError) do
          Sync do
            client.subscribe(channel: CHANNEL, params: conversation_params("c_1"))
          end
        end

        assert_match(/failed to send frame/, error.message)
        refute client.connected?
        assert connection.closed
        assert_includes client.inspect, "subscriptions=0"
      ensure
        client&.close
      end

      def test_ping_frames_stamp_last_ping_at
        behavior = lambda do |session|
          session.welcome
          session.ping
          session.drain
        end
        run_cable(behavior:) do |server|
          client = build_client(server)
          client.connect
          wait_until { client.last_ping_at }

          assert_kind_of Float, client.last_ping_at
          assert_in_delta Process.clock_gettime(Process::CLOCK_MONOTONIC), client.last_ping_at, 5
          refute client.stale?(threshold: 60)
          client.close
        end
      end

      # THE PONG: every server ping after welcome is answered
      # with the channel action `pong` on each confirmed executor-inbox
      # subscription — the kernel's pong expectation closes a socket that
      # stops answering. One frame per ping, no DB write, no HTTP.
      def test_a_ping_on_an_executor_inbox_subscription_is_answered_with_the_pong_action
        commands = Async::Queue.new
        behavior = lambda do |session|
          session.welcome
          subscribe = session.read_command
          session.confirm(subscribe["identifier"])
          session.ping
          commands.enqueue(session.read_command)
          session.ping
          commands.enqueue(session.read_command)
          session.drain
        end
        run_cable(behavior:) do |server|
          client = build_client(server)
          client.connect
          subscription = client.subscribe(channel: Realtime::EXECUTOR_INBOX_CHANNEL)

          2.times do
            pong = commands.dequeue
            assert_equal "message", pong.fetch("command")
            assert_equal subscription.wire_identifier, pong.fetch("identifier")
            assert_equal({ "action" => "pong" }, JSON.parse(pong.fetch("data")))
          end
          assert subscription.pongs?
          client.close
        end
      end

      def test_a_ping_on_a_conversation_subscription_is_not_answered
        commands = Async::Queue.new
        behavior = lambda do |session|
          session.welcome
          subscribe = session.read_command
          session.confirm(subscribe["identifier"])
          session.ping
          session.ping
          commands.enqueue(session.read_command)
          session.drain
        end
        run_cable(behavior:) do |server|
          client = build_client(server)
          client.connect
          subscription = client.subscribe(channel: CHANNEL, params: conversation_params("c_1"))
          wait_until { client.last_ping_at }
          refute subscription.pongs?

          subscription.unsubscribe
          assert_equal "unsubscribe", commands.dequeue.fetch("command"),
            "the next command after two pings is the unsubscribe — no pong was sent"
          client.close
        end
      end

      # A pong is sent only for a CONFIRMED subscription: an answer on a
      # pending one would be a message the server cannot route. The frames
      # are ordered on the wire, so the ping before the confirm meets a
      # pending subscription and the one after meets a confirmed one.
      def test_a_ping_before_the_subscription_is_confirmed_is_not_answered_for_it
        commands = Async::Queue.new
        behavior = lambda do |session|
          session.welcome
          subscribe = session.read_command
          session.ping
          session.confirm(subscribe["identifier"])
          session.ping
          while (command = session.read_command)
            commands.enqueue(command)
          end
          commands.enqueue(nil)
        end
        run_cable(behavior:) do |server|
          client = build_client(server)
          client.connect
          client.subscribe(channel: Realtime::EXECUTOR_INBOX_CHANNEL)

          assert_equal "message", commands.dequeue.fetch("command")
          client.close
          rest = []
          while (command = commands.dequeue)
            rest << command
          end
          assert_empty rest.select { |command| command["command"] == "message" },
            "one pong for the one ping that met a confirmed subscription"
        end
      end

      def test_server_disconnect_frame_raises_connection_lost_with_reason_from_each
        behavior = lambda do |session|
          session.welcome
          command = session.read_command
          session.confirm(command["identifier"])
          session.disconnect(reason: "server_restart", reconnect: true)
          session.drain
        end
        run_cable(behavior:) do |server|
          client = build_client(server)
          client.connect
          subscription = client.subscribe(channel: CHANNEL, params: conversation_params("c_1"))

          error = assert_raises(ConnectionLostError) { subscription.each { |_message| } }
          assert_equal "server_restart", error.reason
          refute client.connected?
        end
      end

      def test_abrupt_server_close_raises_connection_lost_without_reason
        behavior = lambda do |session|
          session.welcome
          command = session.read_command
          session.confirm(command["identifier"])
          # behavior returns → the adapter closes the socket with no disconnect frame
        end
        run_cable(behavior:) do |server|
          client = build_client(server)
          client.connect
          subscription = client.subscribe(channel: CHANNEL, params: conversation_params("c_1"))

          error = assert_raises(ConnectionLostError) { subscription.each { |_message| } }
          assert_nil error.reason
          refute client.connected?
        end
      end

      def test_explicit_close_ends_each_cleanly_with_no_messages
        behavior = lambda do |session|
          session.welcome
          command = session.read_command
          session.confirm(command["identifier"])
          session.drain
        end
        run_cable(behavior:) do |server|
          client = build_client(server)
          client.connect
          subscription = client.subscribe(channel: CHANNEL, params: conversation_params("c_1"))

          consumer = Async::Task.current.async do
            received = []
            subscription.each { |message| received << message }
            received
          end
          client.close
          client.close # idempotent

          assert_equal [], consumer.wait, "each returns cleanly with nothing yielded"
          assert subscription.closed?
        end
      end

      def test_unsubscribe_sends_the_command_and_stops_delivery
        commands = []
        behavior = lambda do |session|
          session.welcome
          command = session.read_command
          commands << command
          session.confirm(command["identifier"])
          session.broadcast(command["identifier"], { "event" => { "cursor" => 1 } })
          commands << session.read_command
          session.drain
        end
        run_cable(behavior:) do |server|
          client = build_client(server)
          client.connect
          subscription = client.subscribe(channel: CHANNEL, params: conversation_params("c_1"))

          assert_equal({ "event" => { "cursor" => 1 } }, subscription.pop(timeout: 5))
          subscription.unsubscribe
          assert_nil subscription.pop, "pop returns nil after unsubscribe"

          collected = []
          subscription.each { |message| collected << message }
          assert_equal [], collected, "each returns immediately after unsubscribe"

          wait_until { commands.size == 2 }
          assert_equal "unsubscribe", commands.fetch(1).fetch("command")
          assert_equal commands.fetch(0).fetch("identifier"), commands.fetch(1).fetch("identifier")
          client.close
        end
      end

      def test_old_handle_cannot_unsubscribe_a_reconnected_replacement_with_the_same_identifier
        connection_count = 0
        behavior = lambda do |session|
          connection_count += 1
          session.welcome
          command = session.read_command
          session.confirm(command["identifier"])

          if connection_count == 1
            session.drain
          else
            sleep 0.05
            session.broadcast(command["identifier"], { "event" => { "cursor" => 2 } })
            session.drain
          end
        end
        run_cable(behavior:) do |server|
          client = build_client(server)
          client.connect
          old_subscription = client.subscribe(channel: CHANNEL, params: conversation_params("c_1"))
          client.close

          client.connect
          replacement = client.subscribe(channel: CHANNEL, params: conversation_params("c_1"))
          old_subscription.unsubscribe

          assert_includes client.inspect, "subscriptions=1"
          assert_equal({ "event" => { "cursor" => 2 } }, replacement.pop(timeout: 5))
          refute replacement.closed?
        end
      end

      def test_two_subscriptions_route_independently_by_identifier
        behavior = lambda do |session|
          session.welcome
          # Confirm each subscribe before reading the next command — the client
          # blocks in #subscribe until its confirmation arrives.
          identifiers = 2.times.map do
            identifier = session.read_command.fetch("identifier")
            session.confirm(identifier)
            identifier
          end
          session.broadcast(identifiers.fetch(0), { "event" => { "conversation" => "c_1", "cursor" => 1 } })
          session.broadcast(identifiers.fetch(1), { "event" => { "conversation" => "c_2", "cursor" => 1 } })
          session.broadcast(identifiers.fetch(0), { "event" => { "conversation" => "c_1", "cursor" => 2 } })
          session.drain
        end
        run_cable(behavior:) do |server|
          client = build_client(server)
          client.connect
          first = client.subscribe(channel: CHANNEL, params: conversation_params("c_1"))
          second = client.subscribe(channel: CHANNEL, params: conversation_params("c_2"))

          first_messages = [first.pop(timeout: 5), first.pop(timeout: 5)]
          second_messages = [second.pop(timeout: 5)]

          assert_equal [["c_1", 1], ["c_1", 2]],
                       first_messages.map { |m| [m.dig("event", "conversation"), m.dig("event", "cursor")] }
          assert_equal [["c_2", 1]],
                       second_messages.map { |m| [m.dig("event", "conversation"), m.dig("event", "cursor")] }
          client.close
        end
      end

      def test_duplicate_subscribe_to_the_same_identifier_is_rejected_client_side
        behavior = lambda do |session|
          session.welcome
          command = session.read_command
          session.confirm(command["identifier"])
          session.drain
        end
        run_cable(behavior:) do |server|
          client = build_client(server)
          client.connect
          client.subscribe(channel: CHANNEL, params: conversation_params("c_1"))
          assert_raises(ArgumentError) do
            client.subscribe(channel: CHANNEL, params: conversation_params("c_1"))
          end
          client.close
        end
      end

      def test_duplicate_subscribe_rejects_logically_equivalent_nested_params
        behavior = lambda do |session|
          session.welcome
          command = session.read_command
          session.confirm(command["identifier"])
          session.drain
        end
        run_cable(behavior:) do |server|
          client = build_client(server)
          client.connect
          client.subscribe(
            channel: CHANNEL,
            params: { workspace_id: WORKSPACE_ID, filters: { z: 2, "a" => 1 } }
          )

          assert_raises(ArgumentError) do
            client.subscribe(
              channel: CHANNEL,
              params: { "filters" => { a: 1, "z" => 2 }, "workspace_id" => WORKSPACE_ID }
            )
          end
          client.close
        end
      end

      def test_each_connect_fetches_a_fresh_authorization_header
        run_cable(behavior: welcome_then_drain) do |server|
          client = track_client(Realtime::Client.new(endpoint: endpoint_for(server.base_url, credential: rotating_credential)))
          client.connect
          client.close
          client.connect
          client.close

          authorizations = server.handshakes.map { |handshake| handshake[:authorization] }
          assert_equal ["Bearer rotating-1", "Bearer rotating-2"], authorizations
        end
      end

      private

      # A credential that rotates on every ask, which is how the "fresh header
      # per connect" property is observable at all: a WebSocket pins the
      # bearer it presented, so the only moment rotation can be picked up is
      # the next handshake.
      def rotating_credential
        calls = 0
        -> { "rotating-#{calls += 1}" }
      end

      def endpoint_for(base_url, credential: ACCESS_TOKEN)
        Realtime::Endpoint.new(base_url: base_url, credential: credential)
      end

      def welcome_then_drain
        lambda do |session|
          session.welcome
          session.drain
        end
      end

      def build_client(server, **options)
        track_client(Realtime::Client.new(endpoint: endpoint_for(server.base_url), **options))
      end

      def conversation_params(conversation_id)
        { workspace_id: WORKSPACE_ID, conversation_id: }
      end

      def assert_subscribe_send_timeout(stall:)
        client = Realtime::Client.new(endpoint: endpoint_for("http://kernel.test"))
        connection = StallingConnection.new(stall:, stall_close: true)
        client.instance_variable_set(:@connection, connection)
        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        Sync do |task|
          child = task.async do
            assert_raises(Realtime::TimeoutError) do
              client.subscribe(channel: CHANNEL, params: conversation_params("c_1"), timeout: 0.1)
            end
          end

          begin
            error = task.with_timeout(0.75, RuntimeError, "stalled #{stall} cleanup delayed its caller") do
              child.wait
            end

            elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
            assert_operator elapsed, :<, 0.5
            assert_match(/confirm_subscription/, error.message)
            refute client.connected?
            assert connection.close_started?
            refute connection.closed
            assert_includes client.inspect, "subscriptions=0"
          ensure
            connection.release_close
          end
          wait_until { connection.closed }
        end
      ensure
        connection&.release_close
        client&.close
      end

      def assert_old_generation_send_timeout_is_fenced(stall:)
        first = ReconnectConnection.new(
          stall_write: stall == :write,
          stall_flush: stall == :flush
        )
        second = ReconnectConnection.new
        client = ConnectionSequenceClient.new(
          connections: [first, second], endpoint: endpoint_for("http://kernel.test")
        )

        Sync do |task|
          client.connect
          old_task = task.async do
            client.subscribe(channel: CHANNEL, params: conversation_params("c_1"), timeout: 0.2)
          rescue StandardError => error
            error
          end
          wait_until { stall == :write ? first.write_started? : first.flush_started? }

          client.close
          client.connect
          replacement = client.subscribe(channel: CHANNEL, params: conversation_params("c_1"), timeout: 1)

          old_error = old_task.wait
          assert_instance_of Realtime::TimeoutError, old_error
          assert client.connected?
          refute replacement.closed?
          client.close
        end
      ensure
        client&.close
      end

      def assert_subscribe_timeout_ignores_blocked_teardown_task(slot:)
        client = Realtime::Client.new(endpoint: endpoint_for("http://kernel.test"))
        connection = StallingConnection.new(stall: :write)
        client.instance_variable_set(:@connection, connection)
        stop_release = Async::Queue.new
        stop_started = false

        Sync do |task|
          teardown_target = task.async do
            begin
              sleep
            ensure
              stop_started = true
              stop_release.dequeue
            end
          end
          if slot == :pump
            client.instance_variable_set(:@pump_task, teardown_target)
          else
            client.instance_variable_get(:@outbound_tasks)[teardown_target] = 0
          end

          subscriber = task.async do
            assert_raises(Realtime::TimeoutError) do
              client.subscribe(channel: CHANNEL, params: conversation_params("c_1"), timeout: 0.05)
            end
          end
          wait_until { stop_started }

          begin
            error = task.with_timeout(0.25, RuntimeError, "blocked #{slot} stop delayed timeout") do
              subscriber.wait
            end
            assert_match(/confirm_subscription/, error.message)
          ensure
            stop_release.enqueue(true)
          end
          teardown_target.wait
        end
      ensure
        stop_release&.enqueue(true)
        client&.close
      end

      # Every client a test builds gets closed in run_cable's ensure — a
      # failing assertion must not leak a pump fiber that keeps the reactor
      # (and therefore the suite) alive forever.
      def track_client(client)
        @tracked_clients = (@tracked_clients || []) + [client]
        client
      end

      def with_stalled_handshake_peer
        server = TCPServer.new("127.0.0.1", 0)
        socket = nil
        peer = Thread.new do
          socket = server.accept
          sleep
        rescue IOError, Errno::EBADF
          nil
        end

        yield "http://127.0.0.1:#{server.addr.fetch(1)}"
      ensure
        socket&.close
        server&.close
        peer&.kill
        peer&.join
      end

      # Run one scripted server + the test body inside a reactor, with a
      # watchdog so a protocol bug fails the test instead of hanging the suite.
      def run_cable(behavior:)
        Sync do |task|
          task.with_timeout(15) do
            server = CybrosAgentTest::FakeCableServer.new(&behavior).start(task)
            begin
              yield server
            ensure
              (@tracked_clients || []).each(&:close)
              server.stop
            end
          end
        end
      end

      # Fiber-friendly busy-wait, bounded by the run_cable watchdog.
      def wait_until
        sleep(0.005) until yield
      end
    end
  end
end
