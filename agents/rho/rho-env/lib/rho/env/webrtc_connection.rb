require "rho/env/webrtc_transport"

module Rho
  module Env
    # Polled by the existing handler; owns only replaceable transport state.
    class WebrtcConnection
      def initialize(executable:, context:, servers: [], clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
        @executable = executable
        @context = context
        @servers = servers
        @clock = clock
        @peer = nil
        @connection_id = nil
        @state = "retrying"
        @next_at = 0.0
        @deadline = 0.0
        @failures = 0
        @relay = false
      end

      attr_reader :connection_id

      def pid = @peer&.pid

      def poll
        @context.raise_if_cancelled!
        close if @context.realtime.closed?
        return empty if @state == "closed"

        if @state == "retrying"
          return empty if @clock.call < @next_at

          @peer = WebrtcTransport.new(executable: @executable, context: @context)
          sdp = @peer.offer(servers: @servers, relay: @relay)
          @connection_id = @context.realtime.offer(sdp: sdp, reopen: false).connection_id
          @deadline = @clock.call + 10
          @state = "answering"
        end

        if @state == "answering"
          snapshot = @context.realtime.snapshot
          if snapshot && (snapshot.closed? || snapshot.connection_id != @connection_id)
            close
            return empty
          end
          if snapshot&.answer_sdp
            @peer.remote(sdp: snapshot.answer_sdp)
            @state = "connecting"
            @deadline = @clock.call + 10
          else
            retry_connection if @clock.call >= @deadline
            return empty
          end
        end

        packet = @peer.poll
        if %w[disconnected failed closed].include?(packet.state) || (@state == "connecting" && @clock.call >= @deadline)
          retry_connection
          return empty
        end
        if packet.state == "connected" && packet.ready
          @state = "connected"
          @failures = 0
          return packet
        end
        empty
      rescue WebrtcTransport::Unavailable
        @context.raise_if_cancelled!
        @context.realtime.closed? ? close : retry_connection
        empty
      rescue CybrosAgent::TransportError, CybrosAgent::Api::RateLimited, CybrosAgent::Api::ServerError => error
        @context.raise_if_cancelled!
        retry_connection(delay: error.retry_after || 0)
        empty
      rescue ClaimRealtime::Closed
        close
        empty
      rescue CybrosAgent::Error
        raise unless @context.realtime.closed?

        close
        empty
      end

      def send_bytes(bytes)
        raise ArgumentError, "realtime block exceeds 16 KiB" if bytes.bytesize > WebrtcTransport::MAX_BYTES

        @context.raise_if_cancelled!
        return false unless @state == "connected"

        @peer.send_bytes(bytes)
      rescue WebrtcTransport::Unavailable
        retry_connection
        false
      end

      def close
        @peer&.close
        @peer = nil
        @state = "closed"
        nil
      end

      private

        def retry_connection(delay: 0)
          @peer&.close
          @peer = nil
          @state = "retrying"
          @relay = true unless @servers.empty?
          @next_at = @clock.call + [delay, 2**[@failures, 3].min].max
          @failures = [@failures + 1, 3].min
        end

        def empty
          WebrtcTransport::Poll.new(data: [], state: @state, pair: nil, ready: false)
        end
    end
  end
end
