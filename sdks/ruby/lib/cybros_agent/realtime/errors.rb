module CybrosAgent
  # The realtime plane's ERROR VOCABULARY, and deliberately nothing else.
  #
  # A feed has to recognize a lost connection in order to re-drain and
  # resubscribe, and that recognition must not cost it the websocket stack:
  # the pump is useful with no socket at all (a replay-only feed follows a run
  # over HTTP alone), and a program that never subscribes should not have to
  # install `async-websocket` to name the thing it is not going to see.
  #
  # So this file loads with the base gem and depends on nothing. The client
  # that RAISES these arrives separately and brings its own dependency —
  # consumer-supplied and require-guarded, exactly as the predecessor split it
  # (`rho-core/lib/rho/kernel_feed.rb` opens by requiring the errors alone and
  # says why).
  #
  # One correction to the charter's wording, which claimed "loadable
  # standalone": the predecessor's equivalent is not, and neither is this —
  # both need `CybrosAgent::Error` from the base gem. The property that is
  # real, and the one that matters, is LOADABLE WITHOUT THE SOCKET STACK.
  module Realtime
    # The subscription stopped delivering and the caller must re-establish it.
    # Everything recoverable by reconnecting is under this, so a consumer
    # rescues one class and a new failure mode does not need a new rescue.
    class ConnectionLostError < CybrosAgent::Error
      # What the SERVER said, when it said anything: ActionCable's disconnect
      # frame carries a reason (`unauthorized`, `server_restart`,
      # `invalid_request`) and losing it turns three different operator
      # problems into one indistinguishable "connection lost".
      attr_reader :reason

      def initialize(message = nil, reason: nil)
        @reason = reason
        super(message || default_message(reason))
      end

      private

        def default_message(reason)
          return "the realtime connection was lost" if reason.nil?

          "the server disconnected the realtime connection (#{reason})"
        end
    end

    # The server refused the subscription outright — a containment answer, not
    # a transport failure. Reconnecting with the same address and credential
    # will be refused again.
    #
    # It carries WHICH subscription, because one connection multiplexes many
    # and "the server said no" is not actionable without knowing to what.
    class SubscriptionRejectedError < CybrosAgent::Error
      attr_reader :identifier, :reason

      def initialize(message = nil, identifier: nil, reason: nil)
        @identifier = identifier
        @reason = reason
        detail = reason && " (#{reason})"
        super(message || "the server rejected the subscription #{identifier}#{detail}")
      end
    end

    # The subscription's bounded buffer overflowed: the server produced faster
    # than this consumer drained. TERMINAL for that subscription rather than
    # backpressure onto the socket, because a reader that stalls the frame
    # pump stalls every other subscription sharing the connection.
    #
    # It lives HERE rather than beside the buffer that raises it because the
    # framework plane is precisely what needs to name it — the charter's
    # catch-up path is "discard the opportunistic buffer, re-drain from the
    # last committed cursor", and deciding that must not require the socket.
    class SubscriptionBackpressureError < ConnectionLostError; end

    # The connection or the subscription did not complete inside its bound.
    class TimeoutError < ConnectionLostError; end
  end
end
