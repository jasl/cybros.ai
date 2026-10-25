require "base64"
require "json"
require "io/wait"

module Rho
  module Env
    # One optional transport per handler connection. The caller owns this
    # handle and closes it in ensure; it never owns or recreates the PTY.
    class WebrtcTransport
      class Unavailable < Error; end
      Network = Data.define(:advertised_ip, :udp_port_min, :udp_port_max)
      DEFAULT_NETWORK = Network.new(advertised_ip: "", udp_port_min: 0, udp_port_max: 0)
      MAX_BYTES = 16 * 1024
      Poll = Data.define(:data, :state, :pair, :ready)

      def initialize(executable:, context: nil)
        @context = context
        @input, child_input = IO.pipe
        child_output, @output = IO.pipe
        @pid = Process.spawn(executable, in: child_output, out: child_input, err: File::NULL)
        child_input.close
        child_output.close
        @closed = false
      rescue SystemCallError
        [@input, @output, child_input, child_output].compact.each(&:close)
        raise
      end

      attr_reader :pid

      def offer(servers: [], relay: false, network: DEFAULT_NETWORK)
        request(op: "offer", servers: servers, relay: relay, **network.to_h).fetch("sdp")
      end

      def answer(sdp:, servers: [], relay: false)
        request(op: "answer", sdp: sdp, servers: servers, relay: relay).fetch("sdp")
      end

      def remote(sdp:)
        request(op: "remote", sdp: sdp)
        nil
      end

      # Called from the existing worker. The reactor publishes the offer and
      # refreshes permission through ClaimRealtime while this handler waits.
      def connect(servers: [], relay: false)
        signal = @context.realtime
        connection = signal.offer(sdp: offer(servers: servers, relay: relay)).connection_id
        deadline = monotonic + 10
        loop do
          @context.raise_if_cancelled!
          snapshot = signal.snapshot
          raise Error, "realtime connection closed" if snapshot && (snapshot.closed? || snapshot.connection_id != connection)
          if snapshot&.answer_sdp
            remote(sdp: snapshot.answer_sdp)
            return connection
          end
          raise Error, "realtime answer timed out" if monotonic >= deadline

          sleep 0.01
        end
      end

      def send_bytes(bytes)
        raise ArgumentError, "realtime block exceeds 16 KiB" if bytes.bytesize > MAX_BYTES
        return false if @context && !@context.realtime.allowed?

        request(op: "send", data: Base64.strict_encode64(bytes))
        true
      end

      def poll
        started = monotonic
        value = request(op: "poll")
        nonce = value.fetch("permission", 0)
        if nonce.positive?
          request(op: "permission", nonce: nonce, max_age_ms: @context ? @context.realtime.remaining_ms : 0)
        end
        elapsed = monotonic - started
        data = value.fetch("data").filter_map do |block|
          # Include the whole IPC round trip conservatively; never treat
          # bytes queued across an expired permission window as new input.
          age = block.fetch("age_seconds") + elapsed
          Base64.strict_decode64(block.fetch("bytes")) if !@context || @context.realtime.received_allowed?(age: age)
        end
        Poll.new(data: data, state: value.fetch("state"), pair: value["pair"], ready: value.fetch("ready"))
      end

      def close
        return if @closed

        @closed = true
        @output.close
        @input.close
        # Cancellation can interrupt a pending gather, so EOF alone is not a
        # bounded teardown. This process has no execution state to preserve.
        Process.kill("KILL", @pid)
      rescue Errno::ESRCH
        nil
      ensure
        if @pid
          Process.wait(@pid)
          @pid = nil
        end
      end

      private

        def request(**value)
          raise Error, "realtime transport closed" if @closed

          @context&.raise_if_cancelled!
          @output.puts(JSON.generate(value))
          deadline = monotonic + 12
          buffer = +""
          loop do
            @context&.raise_if_cancelled!
            if @input.wait_readable(0.01)
              chunk = @input.read_nonblock(4096, exception: false)
              raise Unavailable, "realtime transport ended" unless chunk

              buffer << chunk unless chunk == :wait_readable
              raise Error, "realtime transport response too large" if buffer.bytesize > 128 * 1024
              if buffer.end_with?("\n")
                result = JSON.parse(buffer).to_h
                raise Unavailable, "realtime transport unavailable" if result.key?("error")

                return result
              end
            end
            raise Unavailable, "realtime transport timed out" if monotonic >= deadline
          end
        rescue Error
          close
          raise
        rescue IOError, SystemCallError
          close
          raise Unavailable, "realtime transport failed", cause: nil
        rescue JSON::ParserError
          close
          raise Error, "invalid realtime transport response", cause: nil
        end

        def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
