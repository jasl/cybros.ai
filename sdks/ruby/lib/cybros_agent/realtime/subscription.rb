module CybrosAgent
  module Realtime
    # One confirmed channel subscription: a single-consumer stream of broadcast
    # messages in arrival order. Obtained from Client#subscribe — never built
    # directly.
    #
    # Consumption ends one of three ways:
    #   - #unsubscribe or an explicit Client#close → #each returns cleanly
    #     (and #pop returns nil).
    #   - a server disconnect frame or an abrupt socket loss → #each / #pop
    #     raise ConnectionLostError (messages already buffered are still
    #     yielded first).
    #   - a slow consumer exhausts the bounded buffer → #each / #pop raise
    #     SubscriptionBackpressureError after the buffered messages drain.
    #
    # The deliver/confirm/reject/finish methods are internal — the Client's
    # pump fiber drives them; consumers only use #each, #pop, and #unsubscribe.
    class Subscription
      # BOUNDED, AND OVERFLOW IS TERMINAL FOR THIS SUBSCRIPTION rather than
      # backpressure onto the socket. A reader that stalled the frame pump
      # would stall every other subscription sharing the connection, so a
      # consumer that cannot keep up loses its own stream and nobody else's —
      # and losing it is recoverable, because `SubscriptionBackpressureError`
      # is a lost connection and a feed answers one by re-draining the durable
      # window from its last committed position.
      MAX_BUFFERED_MESSAGES = 100

      attr_reader :identifier, :wire_identifier

      def initialize(client:, identifier:, wire_identifier:)
        @client = client
        @identifier = identifier
        @wire_identifier = wire_identifier
        @queue = Async::Queue.new
        @buffered_messages = 0
        @confirmation = Async::Promise.new
        @confirmed = false
        @terminal = nil
        @pongs = channel_name == EXECUTOR_INBOX_CHANNEL
      end

      # Whether this subscription answers the server's pings:
      # only the executor-inbox channel, and only once confirmed — a pong on
      # a pending subscription is a message the server cannot route.
      def pongs?
        @pongs && @confirmed && !closed?
      end

      # Yields each broadcast `message` payload (for conversation events the
      # {"event" => {...}} hash) in arrival order. Returns cleanly on
      # unsubscribe/close; raises ConnectionLostError when the connection died.
      def each
        while (message = pop)
          yield message
        end
      end

      # The next broadcast message, blocking until one arrives. Returns nil
      # once the stream ended cleanly; raises ConnectionLostError when the
      # connection died, SubscriptionBackpressureError after buffer overflow,
      # or Realtime::TimeoutError if `timeout:` (seconds) elapses first.
      def pop(timeout: nil)
        outcome = with_deadline(timeout, "no message within") { next_outcome }
        case outcome
        in [:message, payload] then payload
        in [:closed] then nil
        in [:error, error] then raise error
        end
      end

      # Stop the stream: sends the unsubscribe command (best effort) and ends
      # #each cleanly. Idempotent.
      def unsubscribe
        @client.unsubscribe(self)
        nil
      end

      # True once the stream has ended (unsubscribed, closed, or lost).
      def closed?
        !@terminal.nil?
      end

      def inspect
        "#<#{self.class.name} identifier=#{@identifier.inspect} closed=#{closed?}>"
      end

      # -- internal surface below: driven by Client, not by consumers --

      # Enqueue one broadcast payload (pump fiber).
      def deliver(payload)
        return if closed?

        if @buffered_messages >= MAX_BUFFERED_MESSAGES
          finish(
            SubscriptionBackpressureError.new(
              "subscription message buffer exceeded #{MAX_BUFFERED_MESSAGES} messages (#{@identifier})"
            )
          )
          return :overflow
        end

        @buffered_messages += 1
        @queue.enqueue([:message, payload])
        nil
      end

      # Resolve the pending subscribe as confirmed (pump fiber).
      def confirm
        @confirmed = true
        resolve_confirmation(:confirmed)
      end

      # Resolve the pending subscribe as rejected (pump fiber).
      def reject
        resolve_confirmation(:rejected)
      end

      # Terminate the stream. `error` nil means a clean end (unsubscribe or
      # explicit close); an exception means the connection was lost. Buffered
      # messages still drain before the terminal outcome is seen. Idempotent.
      def finish(error = nil)
        return if closed?

        @terminal = error ? [:error, error] : [:closed]
        resolve_confirmation(@terminal)
        @queue.enqueue(@terminal)
      end

      # Block until the server answers the subscribe command. Returns self on
      # confirm; raises SubscriptionRejectedError on reject, the connection
      # error if the connection ended first, or Realtime::TimeoutError.
      def wait_confirmed(timeout)
        outcome = with_deadline(timeout, "no confirm_subscription within") { @confirmation.wait }
        case outcome
        in :confirmed then self
        in :rejected
          raise SubscriptionRejectedError.new(identifier: @identifier)
        in [:error, error] then raise error
        in [:closed]
          raise CybrosAgent::Error, "the client was closed before the subscription was confirmed"
        end
      end

      private

      # The logical identifier is the canonical JSON the client built
      # (Protocol.identifier), so the channel reads straight out of it; a
      # double handing a bare channel name answers itself.
      def channel_name
        parsed = JSON.parse(@identifier)
        parsed.is_a?(Hash) ? parsed["channel"] : nil
      rescue JSON::ParserError
        @identifier
      end

      # Next queue item; once the terminal outcome has been reached and the
      # queue is drained, keeps returning the terminal outcome so repeated
      # #pop/#each calls stay consistent instead of blocking forever.
      def next_outcome
        return @terminal if @terminal && @queue.empty?

        outcome = @queue.dequeue
        @buffered_messages -= 1 if outcome.first == :message
        outcome
      end

      # Promise#resolve ignores calls after the first, so a late confirm/reject
      # for an already-finished subscription is a safe no-op.
      def resolve_confirmation(outcome)
        @confirmation.resolve(outcome)
      end

      def with_deadline(timeout, message, &block)
        return block.call if timeout.nil?

        Async::Task.current.with_timeout(
          timeout, TimeoutError, "#{message} #{timeout}s (#{@identifier})", &block
        )
      end
    end
  end
end
