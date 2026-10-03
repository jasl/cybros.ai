module CybrosAgent
  module Realtime
    # THE ACTIONCABLE CLIENT. Fiber-native: every blocking call suspends the
    # current fiber, so it must run inside an Async reactor.
    #
    #   Async do
    #     realtime = CybrosAgent::Realtime::Client.new(endpoint: endpoint)
    #     realtime.connect
    #     subscription = realtime.subscribe(
    #       channel: "AgentAPI::V1::OneShotEventsChannel",
    #       params: { workspace_id: workspace.public_id, one_shot_id: run.public_id }
    #     )
    #     subscription.each { |message| handle(message.fetch("event")) }
    #   end
    #
    # `connect` handshakes, waits for the welcome frame INLINE — so a refused
    # credential surfaces from `connect` rather than asynchronously later —
    # and only then starts the frame pump on a child task. Pings stamp
    # `last_ping_at`, subscription frames route by their raw identifier, and a
    # disconnect frame or a socket loss fails every subscription with one
    # ConnectionLostError carrying the server's reason.
    #
    # RECONNECTING IS THE CALLER'S POLICY, deliberately: `connect` again and
    # re-subscribe. `CybrosAgent::KernelFeed` is the thing that knows WHEN,
    # because knowing when requires knowing what was already applied.
    #
    # GENERATION FENCING IS THE INVARIANT most of this file pays for. Every
    # connection is stamped, and every write, cleanup task, frame route and
    # teardown re-checks that the connection it holds is still the current one.
    # Without it a timed-out write on a dead socket tears down its
    # replacement — the failure is rare, silent, and impossible to reproduce
    # on demand, which is exactly the kind that must be designed out rather
    # than tested for.
    class Client
      DEFAULT_WELCOME_TIMEOUT = 10
      DEFAULT_SUBSCRIBE_TIMEOUT = 10

      # ALPN IS PINNED TO HTTP/1.1, and this is a production fact rather than a
      # preference. A `wss://` endpoint's TLS terminator normally offers h2 as
      # well; if the negotiation settles there, the WebSocket handshake is no
      # longer an HTTP/1.1 Upgrade but RFC 8441's extended CONNECT — a
      # different handshake, which Rails' hijack-based cable upgrade does not
      # speak. This deployment ships one: the image fronts Puma with Thruster,
      # an HTTP/2 proxy that terminates TLS.
      #
      # Offering only http/1.1 costs nothing real. Every HTTPS endpoint that
      # serves h2 also serves http/1.1, a server that refused it would answer
      # a loud TLS `no_application_protocol` rather than fail obscurely, and
      # the multiplexing given up is worthless for a socket that ActionCable
      # already multiplexes every subscription over.
      #
      # UNPIN WHEN Rails speaks RFC 8441, or when something in front is known
      # to translate it — not before, and not because the list looks
      # redundant against a localhost `ws://` harness, where TLS never happens
      # and so this never bites.
      ALPN_PROTOCOLS = ["http/1.1"].freeze

      ConnectAttempt = Struct.new(
        :cancelled, :connection, :generation, :close_scheduled,
        keyword_init: true
      )
      ConnectionState = Struct.new(
        :connection, :generation, :outbound_lock, :outbound_tasks,
        :pump_task, :subscriptions, :logical_subscriptions,
        keyword_init: true
      )
      private_constant :ConnectAttempt, :ConnectionState

      # Monotonic-clock stamp (Process::CLOCK_MONOTONIC, Float seconds) of the
      # most recent server ping on the current connection; nil before the
      # first ping. Monotonic so liveness math is immune to wall-clock jumps.
      attr_reader :last_ping_at

      def initialize(endpoint:)
        @endpoint = endpoint
        @connection = nil
        @connection_generation = 0
        @connect_attempt = nil
        # Feed openers share this client. Only the first one performs the
        # handshake; the others wait, then add their logical subscription to
        # the same ActionCable connection.
        @feed_connect_lock = Async::Semaphore.new(1)
        @outbound_lock = Async::Semaphore.new(1)
        @outbound_tasks = {}
        @pump_task = nil
        @subscriptions = {}
        @logical_subscriptions = {}
        @closed = false
        @last_ping_at = nil
        @welcomed_at = nil
      end

      # Open the WebSocket, wait for the welcome frame, and start the frame
      # pump. Raises Realtime::TimeoutError when the handshake and welcome do
      # not complete in time,
      # ConnectionLostError when the server disconnects instead of welcoming
      # (a refused credential, say), and TransportError when the
      # handshake itself never completed. Returns self.
      def connect(welcome_timeout: DEFAULT_WELCOME_TIMEOUT)
        task = current_task
        raise CybrosAgent::Error, "already connected — call #close before reconnecting" if connected?
        raise CybrosAgent::Error, "already connecting — call #close to cancel it" if @connect_attempt

        attempt = ConnectAttempt.new(cancelled: false, close_scheduled: false)
        @connect_attempt = attempt
        @closed = false
        @last_ping_at = nil
        @welcomed_at = nil
        connection = nil
        generation = nil
        connected = false
        begin
          task.with_timeout(welcome_timeout, TimeoutError, "handshake and welcome did not complete within #{welcome_timeout}s") do
            connection = open_connection
            attempt.connection = connection
            ensure_current_connect_attempt(attempt)
            generation = attach_connection(connection)
            attempt.generation = generation
            wait_for_welcome(connection)
            ensure_current_connect_attempt(attempt, connection:, generation:)
          end

          @welcomed_at = monotonic_now
          pump_task = task.async { pump(connection, generation) }
          ensure_current_connect_attempt(attempt, connection:, generation:)
          @pump_task = pump_task
          connected = true
          self
        ensure
          @connect_attempt = nil if @connect_attempt.equal?(attempt)
          cleanup_failed_connect(attempt, connection:, generation:) unless connected
        end
      end

      def connected?
        !@closed && !@connection.nil? && @connect_attempt.nil?
      end

      # Lazily establish the connection for a feed subscription. Direct
      # callers may still use #connect when they want the handshake as an
      # explicit step; feed callers use this serialized spelling so two runs
      # opening together multiplex instead of racing two handshakes.
      def connect_for_feed(welcome_timeout: DEFAULT_WELCOME_TIMEOUT)
        return self if connected?

        @feed_connect_lock.acquire do
          connect(welcome_timeout: welcome_timeout) unless connected?
        end
        self
      end

      # Subscribe to a channel and wait for the server's answer. Returns a
      # confirmed Subscription; raises SubscriptionRejectedError on reject and
      # Realtime::TimeoutError when neither confirm nor reject arrives within
      # `timeout:` seconds.
      def subscribe(channel:, params: {}, timeout: DEFAULT_SUBSCRIBE_TIMEOUT)
        raise CybrosAgent::Error, "not connected — call #connect first" unless connected?
        task = current_task

        identifier = Protocol.identifier(channel:, params:)
        raise ArgumentError, "already subscribed to #{identifier}" if @logical_subscriptions.key?(identifier)

        subscription = Subscription.new(
          client: self,
          identifier:,
          wire_identifier: Protocol.wire_identifier(identifier)
        )
        phase = :waiting
        origin_connection = nil
        origin_generation = nil
        begin
          wait_for_subscription(task, subscription, timeout:) do
            send_subscription_frame(subscription) do |next_phase, connection, generation|
              phase = next_phase
              origin_connection = connection
              origin_generation = generation
            end
          end
        rescue TimeoutError => error
          case phase
          when :sent
            # The server may still confirm later. Unregister immediately, but
            # keep cleanup outside the caller's elapsed deadline.
            discard_subscription(subscription, notify_server: true)
          when :writing
            # A timed-out write/flush leaves the wire state indeterminate; the
            # connection is no longer safe for any subscription.
            connection_lost(
              reason: nil,
              cause: error,
              connection: origin_connection,
              generation: origin_generation
            )
          else
            # No frame was attempted while this subscription waited behind an
            # earlier outbound operation, so the connection remains usable.
            subscription.finish
          end
          raise
        rescue StandardError
          discard_subscription(subscription, notify_server: false)
          raise
        end
      end

      # Detach locally without waiting for the best-effort wire unsubscribe.
      # Usually reached via Subscription#unsubscribe. Idempotent.
      def unsubscribe(subscription)
        discard_subscription(subscription, notify_server: true)
        nil
      end

      # Tear the connection down deliberately: stops the pump, closes the
      # socket, and ends every subscription's #each cleanly (no error).
      # Idempotent; the client may #connect again afterwards.
      def close
        attempt = @connect_attempt
        return if @closed && @connection.nil? && attempt.nil?

        if attempt
          attempt.cancelled = true
          @connect_attempt = nil if @connect_attempt.equal?(attempt)
        end
        state = detach_connection(
          connection: @connection,
          generation: @connection_generation,
          closed: true
        )
        @closed = true
        cleanup_connection_state(state, nil, attempt:) if state
        nil
      end

      # End the current generation as a LOSS rather than an orderly close.
      # KernelFeed already knows how to recover a lost connection: retain its
      # durable position, drain the gap, and subscribe again. That makes one
      # call here sufficient to move every multiplexed logical subscription
      # onto a freshly authenticated socket after credential rotation.
      def rebind
        attempt = @connect_attempt
        connection = @connection
        generation = @connection_generation
        return false if attempt.nil? && connection.nil?

        if attempt
          attempt.cancelled = true
          @connect_attempt = nil if @connect_attempt.equal?(attempt)
        end
        state = detach_connection(connection:, generation:, closed: true)
        @closed = true
        error = ConnectionLostError.new("the realtime credential changed")
        cleanup_connection_state(state, error, attempt:) if state
        close_connection_async(attempt.connection, attempt:) if attempt && state.nil?
        true
      end

      # True when the server's ping heartbeat has gone quiet for more than
      # `threshold:` seconds (ActionCable pings every ~3s). Before the first
      # ping the welcome stamp is the baseline. Always false when not connected
      # — a closed client is not stale, it is closed.
      def stale?(threshold:)
        return false unless connected?

        baseline = @last_ping_at || @welcomed_at
        return false if baseline.nil?

        (monotonic_now - baseline) > threshold
      end

      def inspect
        "#<#{self.class.name} url=#{@endpoint.url.inspect} connected=#{connected?} " \
          "subscriptions=#{@subscriptions.size}>"
      end

      private

      def current_task
        Async::Task.current? || raise(
          CybrosAgent::Error,
          "CybrosAgent::Realtime::Client must run inside an Async reactor " \
          "(wrap the caller in Async { } or run under Falcon)"
        )
      end

      def ensure_current_connect_attempt(attempt, connection: nil, generation: nil)
        return if @connect_attempt.equal?(attempt) && !attempt.cancelled &&
                  (connection.nil? || current_connection?(connection, generation))

        raise ConnectionLostError, "the realtime connection changed before welcome completed"
      end

      def attach_connection(connection)
        @connection_generation += 1
        @connection = connection
        @outbound_lock = Async::Semaphore.new(1)
        @outbound_tasks = {}
        @pump_task = nil
        @subscriptions = {}
        @logical_subscriptions = {}
        @closed = false
        @connection_generation
      end

      def cleanup_failed_connect(attempt, connection:, generation:)
        state = detach_connection(connection:, generation:, closed: true)
        if state
          cleanup_connection_state(state, nil, attempt:)
        else
          close_connection_async(connection, attempt:)
          @closed = true if @connection.nil? && @connect_attempt.nil?
        end
      end

      # Handshake headers are computed FRESH per connect: the credential source
      # decides the Authorization value now, which is the only moment a
      # rotated credential can be picked up — a WebSocket pins the bearer it
      # presented for the life of the connection. The subprotocol offer travels
      # via the `protocols:` option, so the static header is dropped here.
      def open_connection
        headers = @endpoint.headers.except("Sec-WebSocket-Protocol")
        http_endpoint = Async::HTTP::Endpoint.parse(@endpoint.url, alpn_protocols: ALPN_PROTOCOLS)
        begin
          Async::WebSocket::Client.connect(http_endpoint, headers: headers, protocols: Endpoint::PROTOCOLS)
        rescue TimeoutError
          raise
        rescue StandardError => error
          # A HANDSHAKE FAILURE IS A MISSING ANSWER, not a refusal, so it is
          # the transport error a feed retries — and the message says which of
          # the two it was, because from a consumer that only sees "nothing
          # arrived" they are indistinguishable and have completely different
          # causes.
          raise TransportError,
                "the server would not upgrade #{@endpoint.url} (#{error.message}). " \
                "Check the mount path and that the credential is accepted on this plane — " \
                "a refused upgrade is not the same as a stream that stayed quiet."
        end
      end

      def wait_for_welcome(connection)
        loop do
          message = connection.read
          raise ConnectionLostError.new("the connection closed before the welcome frame") if message.nil?

          frame = Protocol.parse_frame(message.to_str)
          next if frame.nil?

          case frame["type"]
          when Protocol::TYPE_WELCOME then return
          when Protocol::TYPE_DISCONNECT
            raise ConnectionLostError.new(nil, reason: frame["reason"])
          when Protocol::TYPE_PING then @last_ping_at = monotonic_now
          else nil # anything else before welcome is not this loop's business
          end
        end
      end

      # The frame pump (child task). Runs until the connection ends: an
      # explicit #close stops the task outright (Async::Stop is not a
      # StandardError, so it passes through); everything else — disconnect
      # frame, clean server close, socket error — is a lost connection.
      def pump(connection, generation)
        disconnect_frame = read_until_closed(connection, generation)
        connection_lost(reason: disconnect_frame&.fetch("reason", nil), connection:, generation:)
      rescue StandardError => error
        connection_lost(reason: nil, cause: error, connection:, generation:)
      end

      # Read and route frames until the server closes the socket (returns nil)
      # or sends a disconnect frame (returns it).
      def read_until_closed(connection, generation)
        while current_connection?(connection, generation) && (message = connection.read)
          break unless current_connection?(connection, generation)

          frame = Protocol.parse_frame(message.to_str)
          next if frame.nil?
          return frame if frame["type"] == Protocol::TYPE_DISCONNECT

          route_frame(frame)
        end
        nil
      end

      def route_frame(frame)
        case frame["type"]
        when Protocol::TYPE_PING
          @last_ping_at = monotonic_now
          answer_ping
        when Protocol::TYPE_CONFIRM
          @subscriptions[frame["identifier"]]&.confirm
        when Protocol::TYPE_REJECT
          reject_subscription(frame["identifier"])
        when Protocol::TYPE_WELCOME
          nil # duplicate welcome — nothing to do
        else
          # No `type` at all is the shape a BROADCAST takes: an echoed
          # identifier and a message. Anything else is a frame this gem
          # predates, and dropping it is what keeps a new server-side type
          # from killing a pump that has no use for it.
          route_broadcast(frame)
        end
      end

      # THE PONG: every server ping after welcome is answered
      # with the channel action `pong` on each confirmed executor-inbox
      # subscription — one frame per ping per subscription, no DB write, no
      # HTTP; the kernel closes (reconnect: true) a socket that stops
      # answering, which is how a half-open socket is torn down. Written
      # off the pump fiber, like the unsubscribe notice, so a slow write
      # never stalls the reader; a failed write is the ordinary lost path.
      def answer_ping
        @subscriptions.each_value do |subscription|
          next unless subscription.pongs?

          send_frame_async(Protocol.message_command(subscription.wire_identifier, { "action" => "pong" }))
        end
      end

      # Broadcast frames carry no "type" — just the echoed raw identifier and
      # the message payload. Frames for unknown identifiers (e.g. arriving
      # after an unsubscribe) are dropped.
      def route_broadcast(frame)
        identifier = frame["identifier"]
        return if identifier.nil? || !frame.key?("message")

        subscription = @subscriptions[identifier]
        return if subscription.nil?

        discard_overflowed_subscription(subscription) if subscription.deliver(frame["message"]) == :overflow
      end

      def reject_subscription(identifier)
        subscription = @subscriptions[identifier]
        return if subscription.nil?

        unregister_subscription(subscription)
        subscription.reject
      end

      # An unexpected end (never an explicit #close, which stops the pump
      # before this can run): tear down and fail every subscription with one
      # ConnectionLostError carrying the server's reason when known.
      def connection_lost(reason:, connection:, generation:, cause: nil)
        state = detach_connection(connection:, generation:, closed: true)
        return unless state

        attempt = @connect_attempt
        unless attempt&.connection.equal?(connection) && attempt.generation == generation
          attempt = nil
        end
        message = cause && "the realtime connection was lost: #{cause.message}"
        cleanup_connection_state(state, ConnectionLostError.new(message, reason:), attempt:)
      end

      def discard_subscription(subscription, notify_server:)
        return subscription.finish unless unregister_subscription(subscription)

        notify_unsubscribe_async(subscription) if notify_server
        subscription.finish
      end

      def discard_overflowed_subscription(subscription)
        return unless unregister_subscription(subscription)

        notify_unsubscribe_async(subscription)
      end

      def notify_unsubscribe_async(subscription)
        send_frame_async(Protocol.unsubscribe_command(subscription.wire_identifier))
      end

      # Keep the caller/read pump moving, and never let a late task target a
      # reconnected socket: the frame goes out on a transient child under the
      # outbound lock, fenced to this generation.
      def send_frame_async(text)
        connection = @connection
        generation = @connection_generation
        outbound_lock = @outbound_lock
        outbound_tasks = @outbound_tasks
        return unless current_connection?(connection, generation) && outbound_lock

        outbound_task = Async::Task.current.async(transient: true) do |task|
          begin
            outbound_lock.acquire do
              connection.write(text)
              connection.flush
            end
          rescue StandardError
            nil
          ensure
            outbound_tasks.delete(task)
          end
        end
        outbound_tasks[outbound_task] = generation unless outbound_task.finished?
      end

      def unregister_subscription(subscription)
        registered = @subscriptions[subscription.wire_identifier]
        logical_registered = @logical_subscriptions[subscription.identifier]
        return false unless registered.equal?(subscription) && logical_registered.equal?(subscription)

        @subscriptions = @subscriptions.except(subscription.wire_identifier)
        @logical_subscriptions = @logical_subscriptions.except(subscription.identifier)
        true
      end

      def send_subscription_frame(subscription)
        connection = @connection
        generation = @connection_generation
        outbound_lock = @outbound_lock
        raise ConnectionLostError, "the realtime connection is not writable" unless outbound_lock

        outbound_lock.acquire do
          raise ConnectionLostError, "the realtime connection is not writable" unless current_connection?(connection, generation)

          identifier = subscription.identifier
          raise ArgumentError, "already subscribed to #{identifier}" if @logical_subscriptions.key?(identifier)

          @subscriptions = @subscriptions.merge(subscription.wire_identifier => subscription)
          @logical_subscriptions = @logical_subscriptions.merge(identifier => subscription)
          yield :writing, connection, generation
          write_frame(connection, generation, Protocol.subscribe_command(subscription.wire_identifier))
          yield :sent, connection, generation
        end
      end

      def write_frame(connection, generation, text)
        connection.write(text)
        connection.flush
      rescue TimeoutError
        raise
      rescue StandardError => error
        connection_error = ConnectionLostError.new("failed to send frame: #{error.message}")
        connection_lost(reason: nil, cause: error, connection:, generation:)
        raise connection_error
      end

      def wait_for_subscription(task, subscription, timeout:)
        operation = proc do
          yield
          subscription.wait_confirmed(nil)
        end
        return operation.call if timeout.nil?

        task.with_timeout(
          timeout,
          TimeoutError,
          "no confirm_subscription within #{timeout}s (#{subscription.identifier})",
          &operation
        )
      end

      def stop_outbound_tasks(tasks)
        current_task = Async::Task.current?
        tasks.keys.each do |task|
          tasks.delete(task)
          task.stop unless task.equal?(current_task) || task.finished?
        end
      end

      # Atomically detach every object owned by one generation before any
      # cleanup can yield. Later cleanup only touches this captured state, so a
      # reconnect can install a fresh generation immediately and safely.
      def detach_connection(connection:, generation:, closed:)
        return if connection.nil? || !same_connection?(connection, generation)

        state = ConnectionState.new(
          connection:,
          generation:,
          outbound_lock: @outbound_lock,
          outbound_tasks: @outbound_tasks,
          pump_task: @pump_task,
          subscriptions: @subscriptions,
          logical_subscriptions: @logical_subscriptions
        )
        @connection = nil
        @outbound_lock = nil
        @outbound_tasks = {}
        @pump_task = nil
        @subscriptions = {}
        @logical_subscriptions = {}
        @closed = closed
        @last_ping_at = nil
        @welcomed_at = nil
        state
      end

      def cleanup_connection_state(state, error, attempt: nil)
        state.subscriptions.values.each { |subscription| subscription.finish(error) }

        pump_task = state.pump_task
        if pump_task && !pump_task.equal?(Async::Task.current?) && !pump_task.finished?
          pump_task.stop
        end
        stop_outbound_tasks(state.outbound_tasks)
        close_connection_async(state.connection, attempt:)
      end

      # Socket shutdown is best-effort and must not extend a caller's timeout.
      # Async 2.42 transient children run eagerly but do not keep their parent
      # task (or the reactor) alive when close itself blocks.
      def close_connection_async(connection, attempt: nil)
        return if connection.nil? || (attempt && attempt.close_scheduled)

        attempt.close_scheduled = true if attempt
        task = Async::Task.current?
        return Sync { close_connection_now(connection) } unless task

        task.async(transient: true) { close_connection_now(connection) }
      end

      # protocol-websocket 0.21.1 can swallow a timeout in #close! and block on
      # its framer; closing the framer first lets the decorator's #close
      # release its HTTP client.
      def close_connection_now(connection)
        bounded_close(connection) if bounded_close(connection.framer)
        nil
      end

      def bounded_close(closable)
        task = Async::Task.current?
        return Sync { bounded_close(closable) } unless task

        operation = task.async { closable.close }
        task.with_timeout(
          connection_close_timeout, TimeoutError,
          "realtime connection cleanup exceeded #{connection_close_timeout}s"
        ) { operation.wait }
        true
      rescue StandardError
        false
      ensure
        operation.stop if operation && !operation.equal?(Async::Task.current?) && !operation.finished?
      end

      def connection_close_timeout = 0.25

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def current_connection?(connection, generation)
        !@closed && same_connection?(connection, generation)
      end

      def same_connection?(connection, generation)
        @connection.equal?(connection) && @connection_generation == generation
      end
    end
  end
end
