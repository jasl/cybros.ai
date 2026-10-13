begin
  require "async"
  require "async/http/client"
  require "async/http/endpoint"
  require "async/http/protocol/http2/client"
rescue LoadError => e
  raise LoadError,
        "async-http gem is required for SimpleInference::HTTPAdapters::AsyncHTTP " \
        "(add `gem \"async-http\"`)",
        cause: e
end

require "uri"
require "openssl"
require_relative "../internal/envelope"

module SimpleInference
  module HTTPAdapters
    # Reactor-native HTTP adapter built on async-http, for processes whose
    # concurrency IS the Async fiber scheduler (CoreMatrix bin/model_runner;
    # doctrine: async processes speak async-native HTTP, thread processes
    # speak httpx). Inside a reactor, ONE shared AsyncHTTP instance pools
    # connections per origin and multiplexes concurrent same-origin streams
    # natively (HTTP/2 via ALPN against real providers), replacing the HTTPX
    # adapter's private one-shot session per stream — same isolation
    # guarantees, without a TLS handshake per stream.
    #
    # Measured semantics this adapter is built on (2026-07-09 diagnostics
    # against Async::HTTP::Server loopbacks, h1 + h2):
    #   - response headers arrive before the body; body chunks are yielded
    #     with the server's granularity and pacing (genuinely incremental);
    #   - aborting a consuming fiber mid-read (Fiber.scheduler.raise — the
    #     mechanism ModelRunner::Host uses to cancel work) cancels only that
    #     stream: h2 siblings on the same connection and subsequent requests
    #     on the same pool are unaffected, and closing the aborted response
    #     is O(1) (no drain);
    #   - the connection pool is unbounded per origin by default; h2 origins
    #     multiplex (256 concurrent streams rode 2 connections), h1 origins
    #     open one connection per in-flight stream — the same shape as the
    #     HTTPX adapter's one-shot sessions.
    #
    # Timeout vocabulary (SDK contract keys, measured parity with the HTTPX
    # adapter's observed behavior):
    #   - `:timeout` — overall deadline for the WHOLE call, streams included.
    #     The measured HTTPX baseline caps total stream duration exactly the
    #     same way, so this is contract-faithful, not a tightening.
    #   - `:read_timeout` — per-IO-op idle deadline (re-arms on every read;
    #     a steady stream can outlive it indefinitely). The HTTPX adapter
    #     reaches the same behaviour by a different route — its stream plugin
    #     discards a `read_timeout`, so the bound rides `operation_timeout`
    #     there — and both hosts now genuinely detect a stalled provider.
    #   - `:open_timeout` — TCP/TLS establishment only. io-endpoint exposes one
    #     socket timeout, so the endpoint starts with the open deadline and
    #     replaces it with the read deadline immediately after connect.
    class AsyncHTTP < HTTPAdapter
      # The TCP/TLS establishment ceiling when a caller names none. Same value
      # HTTPX defaults to, so the two hosts do not disagree about how long a
      # connection may take to come up.
      CONNECT_TIMEOUT = 60

      module OpenTimeoutEndpoint
        def connect
          socket = super
          # Endpoint timeout is the connect/TLS budget. Once connected, body
          # reads are multiplexed and must carry their own stream-local timer.
          socket.timeout = nil
          return socket unless block_given?

          begin
            yield socket
          ensure
            socket.close
          end
        end
      end
      private_constant :OpenTimeoutEndpoint

      # async-http does not expose the response until headers arrive. Capture
      # the HTTP/2 stream one layer earlier so cancellation while waiting for
      # headers can still send RST_STREAM(CANCEL) without closing siblings.
      class CancelSafeRequest < ::Protocol::HTTP::Request
        def call(connection)
          return super unless connection.is_a?(::Async::HTTP::Protocol::HTTP2::Client)

          # Upstream HTTP2::Client#call's stale-pooled-connection guard,
          # replicated so the race maps through the adapter's ConnectionError
          # path instead of escaping as a NoMethodError off a dead connection.
          raise ::Protocol::HTTP2::Error, "Connection closed!" if connection.closed?

          response = connection.create_response
          returned = false
          begin
            connection.write_request(response, self)
            connection.read_response(response)
            returned = true
            response
          ensure
            self.class.cancel_active_stream(response) unless returned
          end
        end

        def self.cancel_active_stream(response)
          stream = response&.stream
          return unless stream&.active?

          stream.send_reset_stream(::Protocol::HTTP2::Error::CANCEL)
        rescue StandardError
          # Preserve the original cancellation/transport failure. A dead
          # connection needs no additional stream reset.
          nil
        end
      end
      private_constant :CancelSafeRequest

      def initialize(timeout: nil)
        @timeout = timeout
        @mutex = Mutex.new
        @clients = {}
      end

      def call(request)
        perform(request) do |response, read_deadline|
          {
            status: response.status.to_i,
            headers: normalize_headers(response.headers),
            body: read_body(response, read_deadline),
          }
        end
      end

      def call_stream(request)
        return call(request) unless block_given?

        perform(request) do |response, read_deadline|
          status = response.status.to_i
          headers = normalize_headers(response.headers)

          if Internal::Envelope.new(status: status, headers: headers, body: nil).sse?
            while (chunk = read_chunk(response.body, read_deadline))
              yield chunk
            end
            response.body = nil
            { status: status, headers: headers, body: nil }
          else
            { status: status, headers: headers, body: read_body(response, read_deadline) }
          end
        end
      end

      # Callable in or out of a reactor and idempotent; the per-scheduler
      # laziness in #client_for means a post-close call transparently
      # rebuilds, so shutdown ordering stays unimportant.
      def close
        clients = @mutex.synchronize do
          snapshot = @clients.values
          @clients = {}
          snapshot
        end
        return if clients.empty?

        Sync do
          clients.each do |client|
            client.close
          rescue StandardError
            nil
          end
        end
        nil
      end

      private

      # No HTTP response at all — refusal, reset, DNS, TLS, EOF, or a
      # protocol-level failure (Protocol::HTTP1/HTTP2 errors both subclass
      # Protocol::HTTP::Error, so h2 GOAWAY/RST land here too). Enumerated
      # rather than StandardError so programming errors surface as themselves.
      CONNECTION_FAILURES = [
        SystemCallError, SocketError, EOFError, IOError,
        OpenSSL::SSL::SSLError, ::Protocol::HTTP::Error,
      ].freeze

      def perform(request, &consume)
        url = URI.parse(request.fetch(:url).to_s)
        verb = request.fetch(:method).to_s.upcase
        headers = request[:headers] || {}
        body = request[:body]
        total = request[:timeout] || @timeout
        open_deadline, read_deadline = io_deadlines(request, total)
        # Snapshot BEFORE Sync: only an ambient scheduler (the runner's
        # long-lived reactor) is a stable owner for pooled clients. Inside a
        # temporary per-call reactor the scheduler dies with the call, so
        # caching against it would leak one client per call.
        ambient_scheduler = Fiber.scheduler

        run_with_deadline(total, url) do
          if ambient_scheduler
            client = client_for(ambient_scheduler, url, open_deadline)
            exchange(client, verb, url, headers, body, read_deadline, &consume)
          else
            client = build_client(origin_for(url), open_deadline)
            begin
              exchange(client, verb, url, headers, body, read_deadline, &consume)
            ensure
              begin
                client.close
              rescue StandardError
                nil
              end
            end
          end
        end
      end

      def exchange(client, verb, url, headers, body, read_deadline)
        response = with_read_deadline(read_deadline) do
          client.call(build_request(verb, url, headers, body))
        end
        begin
          yield response, read_deadline
        ensure
          CancelSafeRequest.cancel_active_stream(response)
          begin
            response.close
          rescue StandardError
            nil
          end
        end
      end

      def read_body(response, read_deadline)
        body = response.body
        return "" if body.nil?

        buffer = String.new.force_encoding(Encoding::BINARY)
        while (chunk = read_chunk(body, read_deadline))
          buffer << chunk
        end
        response.body = nil
        buffer
      end

      def read_chunk(body, read_deadline)
        return if body.nil?

        with_read_deadline(read_deadline) { body.read }
      end

      def with_read_deadline(read_deadline)
        return yield unless read_deadline

        Async::Task.current.with_timeout(read_deadline.to_f) { yield }
      end

      # Sync reuses the ambient reactor (the runner) or hosts a temporary one
      # (plain threads); the total deadline wraps the whole exchange
      # INCLUDING body/stream consumption — measured parity with the HTTPX
      # adapter, where `:timeout` caps total stream duration.
      def run_with_deadline(total, url)
        Sync do |task|
          if total
            task.with_timeout(total.to_f) { yield }
          else
            yield
          end
        end
      rescue Async::TimeoutError, IO::TimeoutError => e
        raise SimpleInference::TimeoutError,
              "async-http request to #{url.host}:#{url.port} timed out: #{e.message}"
      rescue *CONNECTION_FAILURES => e
        raise SimpleInference::ConnectionError, "#{e.class}: #{e.message}"
      end

      # CONNECT IS ITS OWN BUDGET, and deriving it from the read deadline was
      # a coupling that only looked harmless while every caller set both. A
      # unary send carries no idle bound (it is a stream-only axis), so the
      # connect budget silently became the whole lane deadline — 600s of a
      # held fiber and a held capacity slot for a blackholed TCP connect, then
      # `possibly_accepted` and an attempt burned for a connection that was
      # never made. It defaults to the same ceiling HTTPX uses and is capped
      # by the total, since a connect budget longer than the whole call is not
      # a budget.
      def io_deadlines(request, total)
        read_deadline = request[:read_timeout] || total
        open_deadline = request[:open_timeout] || (total && [total, CONNECT_TIMEOUT].min)
        [open_deadline&.to_f, read_deadline&.to_f]
      end

      # One pooled client per (scheduler, origin, open-timeout). Keys include
      # the ambient scheduler so distinct reactors (e.g. two threads each
      # running Sync) never share connections; in the runner there is exactly
      # one scheduler for the process lifetime, so pools live that long. The
      # deadline tuple comes from a small fixed set of configured timeouts,
      # so the cache stays bounded.
      def client_for(scheduler, url, open_deadline)
        key = [scheduler.object_id, origin_for(url), open_deadline]

        @mutex.synchronize do
          @clients[key] ||= build_client(origin_for(url), open_deadline)
        end
      end

      def origin_for(url)
        "#{url.scheme}://#{url.host}:#{url.port}"
      end

      def build_client(origin, open_deadline)
        endpoint = Async::HTTP::Endpoint.parse(origin, timeout: open_deadline)
        endpoint.extend(OpenTimeoutEndpoint)
        Async::HTTP::Client.new(endpoint)
      end

      def build_request(verb, url, headers, body)
        target = url.path.empty? ? "/" : url.path
        target = "#{target}?#{url.query}" if url.query
        CancelSafeRequest[
          verb, target,
          headers: headers.to_a,
          body: request_body(body, headers),
          scheme: url.scheme,
          authority: authority_for(url)
        ]
      end

      # A BODY THAT ITERATES MUST NOT BE STRINGIFIED. `body&.to_s` was the
      # whole story here, and it silently undoes a streamed multipart upload:
      # the segments would be concatenated into the one copy the body exists
      # to avoid. `Buffered.wrap` is not the answer either — for anything it
      # does not recognize it calls `read`, which materializes the whole body.
      # A Readable that pulls one segment at a time is. The compiler's
      # Content-Type is the semantic boundary: multipart compilation always
      # supplies the iterable body, so the adapter need not probe its class.
      def request_body(body, headers)
        return if body.nil?
        if headers.fetch("Content-Type", "").start_with?("multipart/form-data")
          return StreamedBody.new(body)
        end

        body.to_s
      end

      # The iterated body, as Protocol::HTTP wants to consume it: `read`
      # answers the next chunk and nil at the end, and `length` is known up
      # front so the request states a Content-Length instead of chunking.
      class StreamedBody < ::Protocol::HTTP::Body::Readable
        def initialize(body)
          super()
          @chunks = body.each
          @length = body.bytesize
        end

        attr_reader :length

        def empty? = @length.zero?

        def read
          @chunks.next
        rescue StopIteration
          nil
        end
      end

      def authority_for(url)
        default_port = url.scheme == "https" ? 443 : 80
        url.port == default_port ? url.host : "#{url.host}:#{url.port}"
      end

      def normalize_headers(headers)
        headers.each.with_object({}) do |(key, value), out|
          name = key.to_s.downcase
          out[name] = out.key?(name) ? "#{out[name]}, #{value}" : value.to_s
        end
      end
    end
  end
end
