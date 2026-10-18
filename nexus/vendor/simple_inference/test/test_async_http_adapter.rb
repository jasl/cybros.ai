require "test_helper"
require "simple_inference/http_adapters/async_http"
require "async"
require "async/http/server"
require "io/endpoint"
require "protocol/http/body/streamable"
require "socket"

# Contract battery for HTTPAdapters::AsyncHTTP — the reactor-native adapter
# (async processes; CoreMatrix bin/model_runner). Mirrors the envelope and
# error-vocabulary pins of test_default_adapter.rb / test_httpx_adapter.rb,
# plus the three measured semantics the adapter exists to provide (2026-07-09
# diagnostics, recorded in the adapter's header comment):
#   - concurrent same-origin streams through ONE shared adapter overlap;
#   - aborting a stream fiber (Fiber.scheduler.raise — ModelRunner::Host's
#     mechanism) leaves the shared pool healthy;
#   - `timeout:` caps total stream duration (httpx-adapter parity, measured)
#     while `read_timeout:` is a genuinely per-chunk idle deadline.
class TestAsyncHTTPAdapter < Minitest::Test
  class HTTP2Adapter < SimpleInference::HTTPAdapters::AsyncHTTP
    private

    def build_client(origin, open_deadline, *)
      endpoint = Async::HTTP::Endpoint.parse(origin, timeout: open_deadline)
      Async::HTTP::Client.new(endpoint, protocol: Async::HTTP::Protocol::HTTP2)
    end
  end

  class HTTP2Server
    attr_reader :port

    def initialize(&handler)
      @endpoint = IO::Endpoint.tcp("127.0.0.1", 0).bound
      @port = @endpoint.sockets.fetch(0).local_address.ip_port
      @connections = []
      @server = Async::HTTP::Server.for(
        @endpoint, protocol: Async::HTTP::Protocol::HTTP2, scheme: "http"
      ) do |request|
        @connections << request.connection unless @connections.include?(request.connection)
        handler.call(request)
      end
    end

    def start
      @task = @server.run
      @task.transient = true
      self
    end

    def stop
      @connections.each(&:close)
      @endpoint.close
      @task&.stop
      @task&.wait
    rescue IOError, Async::Stop
      nil
    end
  end

  # Scriptable chunked-HTTP/1.1 loopback server (same raw-TCPServer style as
  # test_default_adapter.rb): each accepted request gets `status` +
  # `content_type`, then `chunks` written `gap` seconds apart; `stall_after`
  # freezes the stream after N chunks to exercise idle deadlines.
  class ChunkedServer
    attr_reader :port

    def initialize(status: 200, content_type: "text/event-stream",
                   chunks: [], gap: 0.0, stall_after: nil, stall_seconds: 600)
      @server = TCPServer.new("127.0.0.1", 0)
      @port = @server.addr[1]
      @mutex = Mutex.new
      @requests = 0
      @in_flight = 0
      @peak = 0
      @thread = Thread.new do
        loop do
          socket = @server.accept
          Thread.new(socket) do |io|
            handle(io, status:, content_type:, chunks:, gap:, stall_after:, stall_seconds:)
          end
        end
      rescue IOError
        nil
      end
    end

    def request_count = @mutex.synchronize { @requests }
    def peak_concurrency = @mutex.synchronize { @peak }

    def stop
      @server.close
      @thread.join(2)
    end

    private

    def handle(io, status:, content_type:, chunks:, gap:, stall_after:, stall_seconds:)
      loop do
        line = io.gets
        break if line.nil? || line == "\r\n"
      end
      @mutex.synchronize do
        @requests += 1
        @in_flight += 1
        @peak = [@peak, @in_flight].max
      end
      reason = status == 200 ? "OK" : "ERR"
      # This server closes the socket after every response (see ensure), so it
      # must SAY so: without `connection: close` the HTTP/1.1 default is
      # keep-alive and a pooled client legitimately reuses the connection —
      # whether the next request EOFs then depends on a write-vs-close race
      # (won locally, lost on slow CI). Advertising the close makes the client
      # open a fresh connection per request, deterministically.
      io.write("HTTP/1.1 #{status} #{reason}\r\ncontent-type: #{content_type}\r\n" \
               "x-request-id: req-#{@requests}\r\ntransfer-encoding: chunked\r\n" \
               "connection: close\r\n\r\n")
      chunks.each_with_index do |chunk, index|
        io.write("#{chunk.bytesize.to_s(16)}\r\n#{chunk}\r\n")
        sleep(stall_after && index + 1 == stall_after ? stall_seconds : gap)
      end
      io.write("0\r\n\r\n")
    rescue IOError, Errno::EPIPE, Errno::ECONNRESET
      nil
    ensure
      @mutex.synchronize { @in_flight -= 1 }
      begin
        io.close
      rescue IOError
        nil
      end
    end
  end

  SSE_CHUNKS = ["data: {\"i\":0}\n\n", "data: {\"i\":1}\n\n", "data: {\"i\":2}\n\n"].freeze

  def sse_request(server, **overrides)
    {
      method: :post,
      url: "http://127.0.0.1:#{server.port}/v1/stream",
      headers: { "content-type" => "application/json" },
      body: "{}",
    }.merge(overrides)
  end

  def h2_request(server, path:, **overrides)
    sse_request(server, url: "http://127.0.0.1:#{server.port}#{path}", **overrides)
  end

  def test_call_returns_the_envelope_contract
    server = ChunkedServer.new(content_type: "application/json", chunks: ["{\"ok\":true}"])
    adapter = SimpleInference::HTTPAdapters::AsyncHTTP.new

    envelope = adapter.call(sse_request(server))

    assert_equal 200, envelope[:status]
    assert_equal "application/json", envelope[:headers]["content-type"]
    assert_equal "req-1", envelope[:headers]["x-request-id"]
    assert_equal "{\"ok\":true}", envelope[:body]
  ensure
    adapter&.close
    server&.stop
  end

  def test_compiled_multipart_body_keeps_its_streaming_contract
    body = SimpleInference::MultipartBody.new(
      [->(&emit) { emit.call("first") }, ->(&emit) { emit.call("second") }],
      11
    )
    adapter = SimpleInference::HTTPAdapters::AsyncHTTP.new

    streamed = adapter.send(
      :request_body, body,
      { "Content-Type" => "multipart/form-data; boundary=example" }
    )

    assert_equal 11, streamed.length
    assert_equal %w[first second], [streamed.read, streamed.read]
    assert_nil streamed.read
  ensure
    adapter&.close
  end

  def test_call_returns_non_2xx_in_the_envelope_without_raising
    server = ChunkedServer.new(status: 429, content_type: "application/json",
                               chunks: ["{\"error\":\"rate\"}"])
    adapter = SimpleInference::HTTPAdapters::AsyncHTTP.new

    envelope = adapter.call(sse_request(server))

    assert_equal 429, envelope[:status]
    assert_equal "{\"error\":\"rate\"}", envelope[:body]
  ensure
    adapter&.close
    server&.stop
  end

  def test_call_wraps_connection_refused_as_connection_error
    probe = TCPServer.new("127.0.0.1", 0)
    port = probe.addr[1]
    probe.close
    adapter = SimpleInference::HTTPAdapters::AsyncHTTP.new

    error = assert_raises(SimpleInference::ConnectionError) do
      adapter.call(method: :get, url: "http://127.0.0.1:#{port}/v1/x", headers: {}, body: nil)
    end
    assert_match(/refused|Errno::ECONNREFUSED/i, error.message)
  ensure
    adapter&.close
  end

  def test_call_stream_yields_sse_chunks_incrementally
    server = ChunkedServer.new(chunks: SSE_CHUNKS, gap: 0.15)
    adapter = SimpleInference::HTTPAdapters::AsyncHTTP.new

    arrivals = []
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    envelope = adapter.call_stream(sse_request(server)) do |chunk|
      arrivals << [Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0, chunk]
    end

    assert_equal 200, envelope[:status]
    assert_nil envelope[:body]
    assert_equal SSE_CHUNKS, arrivals.map(&:last)
    # Incremental, not buffered: the spread between first and last chunk must
    # reflect the server's pacing (buffered delivery collapses it to ~0).
    spread = arrivals.last[0] - arrivals.first[0]
    assert_operator spread, :>, 0.15, "chunks must arrive incrementally (spread=#{spread.round(3)}s)"
  ensure
    adapter&.close
    server&.stop
  end

  def test_call_stream_buffers_non_sse_bodies_without_yielding
    server = ChunkedServer.new(content_type: "application/json", chunks: ["{\"a\":", "1}"])
    adapter = SimpleInference::HTTPAdapters::AsyncHTTP.new

    yielded = []
    envelope = adapter.call_stream(sse_request(server)) { |chunk| yielded << chunk }

    assert_empty yielded
    assert_equal "{\"a\":1}", envelope[:body]
  ensure
    adapter&.close
    server&.stop
  end

  def test_call_stream_returns_non_2xx_envelope_without_raising
    server = ChunkedServer.new(status: 500, content_type: "application/json",
                               chunks: ["{\"error\":\"boom\"}"])
    adapter = SimpleInference::HTTPAdapters::AsyncHTTP.new

    yielded = []
    envelope = adapter.call_stream(sse_request(server)) { |chunk| yielded << chunk }

    assert_empty yielded
    assert_equal 500, envelope[:status]
    assert_equal "{\"error\":\"boom\"}", envelope[:body]
  ensure
    adapter&.close
    server&.stop
  end

  def test_call_stream_without_a_block_behaves_like_call
    server = ChunkedServer.new(content_type: "application/json", chunks: ["{\"ok\":1}"])
    adapter = SimpleInference::HTTPAdapters::AsyncHTTP.new

    envelope = adapter.call_stream(sse_request(server))

    assert_equal "{\"ok\":1}", envelope[:body]
  ensure
    adapter&.close
    server&.stop
  end

  def test_timeout_caps_total_stream_duration
    # Measured httpx-adapter parity (2026-07-09 baseline): `timeout:` bounds
    # the WHOLE stream even while chunks flow steadily. The kernel runs with
    # timeout=180s today; this pin keeps the semantics identical post-switch.
    server = ChunkedServer.new(chunks: Array.new(20) { |i| "data: {\"i\":#{i}}\n\n" }, gap: 0.2)
    adapter = SimpleInference::HTTPAdapters::AsyncHTTP.new

    received = 0
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    assert_raises(SimpleInference::TimeoutError) do
      adapter.call_stream(sse_request(server, timeout: 0.6)) { |_chunk| received += 1 }
    end
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0

    assert_operator received, :>=, 1, "stream must have been flowing before the cap"
    assert_in_delta 0.6, elapsed, 0.4
  ensure
    adapter&.close
    server&.stop
  end

  def test_read_timeout_is_a_per_chunk_idle_deadline
    # Steady chunks 0.15s apart under read_timeout 0.5 => survives (the
    # deadline re-arms per read); a stall after 2 chunks => TimeoutError.
    steady = ChunkedServer.new(chunks: SSE_CHUNKS, gap: 0.15)
    adapter = SimpleInference::HTTPAdapters::AsyncHTTP.new
    received = 0
    adapter.call_stream(sse_request(steady, read_timeout: 0.5)) { |_chunk| received += 1 }
    assert_equal SSE_CHUNKS.size, received

    stalled = ChunkedServer.new(chunks: SSE_CHUNKS, gap: 0.05, stall_after: 2)
    got = 0
    assert_raises(SimpleInference::TimeoutError) do
      adapter.call_stream(sse_request(stalled, read_timeout: 0.5)) { |_chunk| got += 1 }
    end
    assert_equal 2, got
  ensure
    adapter&.close
    steady&.stop
    stalled&.stop
  end

  def test_open_timeout_does_not_shorten_the_stream_read_timeout
    server = ChunkedServer.new(chunks: SSE_CHUNKS, gap: 0.15)
    adapter = SimpleInference::HTTPAdapters::AsyncHTTP.new
    received = []

    adapter.call_stream(sse_request(
      server,
      timeout: 2,
      open_timeout: 0.05,
      read_timeout: 0.5,
    )) { |chunk| received << chunk }

    assert_equal SSE_CHUNKS, received
  ensure
    adapter&.close
    server&.stop
  end

  def test_concurrent_streams_through_one_shared_adapter_overlap
    # The property the adapter exists for (measured 2026-07-09): under a
    # reactor, N same-origin streams through ONE shared adapter run
    # concurrently — the shared-httpx-session shape serializes them instead.
    server = ChunkedServer.new(chunks: Array.new(4) { "data: {}\n\n" }, gap: 0.1)
    adapter = SimpleInference::HTTPAdapters::AsyncHTTP.new

    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    Sync do
      Array.new(4) do
        Async do
          adapter.call_stream(sse_request(server)) { |_chunk| nil }
        end
      end.map(&:wait)
    end
    wall = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0

    assert_operator server.peak_concurrency, :>=, 2, "streams must overlap"
    assert_operator wall, :<, 1.2, "4 overlapping ~0.4s streams must not serialize (wall=#{wall.round(2)}s)"
  ensure
    adapter&.close
    server&.stop
  end

  def test_aborting_a_stream_fiber_leaves_the_shared_pool_healthy
    # ModelRunner::Host cancels in-flight work by raising into the fiber
    # (host.rb Fiber.scheduler.raise); the abort must not poison the
    # adapter's shared per-origin pool for subsequent invocations.
    abort_error = Class.new(StandardError)
    server = ChunkedServer.new(chunks: Array.new(50) { "data: {}\n\n" }, gap: 0.1)
    adapter = SimpleInference::HTTPAdapters::AsyncHTTP.new

    Sync do
      victim_fiber = nil
      aborted = false
      victim = Async do
        victim_fiber = Fiber.current
        adapter.call_stream(sse_request(server)) { |_chunk| nil }
      rescue abort_error
        aborted = true
      end
      sleep(0.25)
      Fiber.scheduler.raise(victim_fiber, abort_error.new("cancel"))
      victim.wait
      assert aborted, "victim stream must have been aborted"

      follow_up = ChunkedServer.new(chunks: SSE_CHUNKS)
      begin
        received = 0
        envelope = adapter.call_stream(
          sse_request(follow_up, url: "http://127.0.0.1:#{follow_up.port}/v1/next")
        ) { |_chunk| received += 1 }
        assert_equal 200, envelope[:status]
        assert_equal SSE_CHUNKS.size, received
      ensure
        follow_up.stop
      end
    end
  ensure
    adapter&.close
    server&.stop
  end

  def test_aborting_before_h2_headers_resets_only_that_stream
    request_seen = Async::Queue.new
    release_headers = Async::Notification.new
    sibling_started = Async::Notification.new
    release_sibling = Async::Notification.new
    sibling_request_seen = Async::Queue.new
    server = HTTP2Server.new do |request|
      if request.path == "/sibling"
        sibling_request_seen.enqueue(request)
        body = Protocol::HTTP::Body::Streamable.response(request) do |stream|
          stream.write("sibling-start")
          sibling_started.signal
          release_sibling.wait
          stream.write("-sibling-end")
        ensure
          stream.close
        end
        next Protocol::HTTP::Response[200, { "content-type" => "text/plain" }, body]
      end

      request_seen.enqueue(request)
      release_headers.wait
      raise Async::Stop if request.stream.closed?

      Protocol::HTTP::Response[200, { "content-type" => "application/json" }, ["{}"]]
    end
    adapter = HTTP2Adapter.new
    abort_error = Class.new(StandardError)

    Sync do |task|
      server.start
      sibling = task.async do
        adapter.call(h2_request(server, path: "/sibling"))
      end
      sibling_started.wait
      sibling_request = sibling_request_seen.dequeue

      victim_fiber = nil
      aborted = false
      victim = task.async do
        victim_fiber = Fiber.current
        adapter.call(h2_request(server, path: "/before-headers"))
      rescue abort_error
        aborted = true
      end
      request = request_seen.dequeue
      assert_same sibling_request.connection, request.connection,
                  "the sibling and canceled request must share one HTTP/2 connection"

      Fiber.scheduler.raise(victim_fiber, abort_error.new("cancel"))
      victim.wait
      assert aborted, "victim request must observe cancellation"
      Async::Task.current.yield

      assert request.stream.closed?, "cancel must send RST_STREAM before response headers arrive"
      release_sibling.signal
      sibling_response = sibling.wait
      assert_equal 200, sibling_response[:status]
      assert_equal "sibling-start-sibling-end", sibling_response[:body]
    ensure
      release_headers.signal
      release_sibling.signal
    end
  ensure
    adapter&.close
    server&.stop
  end

  def test_aborting_after_h2_headers_resets_only_that_stream
    request_seen = Async::Queue.new
    body_started = Async::Notification.new
    sibling_started = Async::Notification.new
    release_sibling = Async::Notification.new
    sibling_request_seen = Async::Queue.new
    server = HTTP2Server.new do |request|
      if request.path == "/sibling"
        sibling_request_seen.enqueue(request)
        body = Protocol::HTTP::Body::Streamable.response(request) do |stream|
          stream.write("sibling-start")
          sibling_started.signal
          release_sibling.wait
          stream.write("-sibling-end")
        ensure
          stream.close
        end
        next Protocol::HTTP::Response[200, { "content-type" => "text/plain" }, body]
      end

      request_seen.enqueue(request)
      body = Protocol::HTTP::Body::Streamable.response(request) do |stream|
        body_started.signal
        loop do
          stream.write("data: {}\n\n")
          sleep(0.05)
        end
      ensure
        stream.close
      end
      Protocol::HTTP::Response[200, { "content-type" => "text/event-stream" }, body]
    end
    adapter = HTTP2Adapter.new
    abort_error = Class.new(StandardError)

    Sync do |task|
      server.start
      sibling = task.async do
        adapter.call(h2_request(server, path: "/sibling"))
      end
      sibling_started.wait
      sibling_request = sibling_request_seen.dequeue

      victim_fiber = nil
      aborted = false
      victim = task.async do
        victim_fiber = Fiber.current
        adapter.call_stream(h2_request(server, path: "/after-headers")) { |_chunk| nil }
      rescue abort_error
        aborted = true
      end
      body_started.wait
      request = request_seen.dequeue
      assert_same sibling_request.connection, request.connection,
                  "the sibling and canceled request must share one HTTP/2 connection"

      Fiber.scheduler.raise(victim_fiber, abort_error.new("cancel"))
      victim.wait
      assert aborted, "victim stream must observe cancellation"
      task.yield

      assert request.stream.closed?, "cancel must send RST_STREAM while the response body is active"
      release_sibling.signal
      sibling_response = sibling.wait
      assert_equal 200, sibling_response[:status]
      assert_equal "sibling-start-sibling-end", sibling_response[:body]
    ensure
      release_sibling.signal
    end
  ensure
    adapter&.close
    server&.stop
  end

  def test_h2_read_timeout_is_per_stream_while_a_sibling_is_active
    server = HTTP2Server.new do |request|
      body = Protocol::HTTP::Body::Streamable.response(request) do |stream|
        if request.path == "/stalled"
          stream.write("data: first\n\n")
          sleep(0.5)
          stream.write("data: late\n\n")
        else
          12.times do
            stream.write("data: sibling\n\n")
            sleep(0.05)
          end
        end
      ensure
        stream.close
      end
      Protocol::HTTP::Response[200, { "content-type" => "text/event-stream" }, body]
    end
    adapter = HTTP2Adapter.new

    Sync do |task|
      server.start
      sibling = task.async do
        adapter.call_stream(h2_request(server, path: "/sibling", read_timeout: 0.15)) { |_chunk| nil }
      end

      error = assert_raises(SimpleInference::TimeoutError) do
        adapter.call_stream(h2_request(server, path: "/stalled", read_timeout: 0.15)) { |_chunk| nil }
      end
      assert_match(/timed out/, error.message)
      assert_equal 200, sibling.wait[:status]
    end
  ensure
    adapter&.close
    server&.stop
  end

  def test_works_outside_a_reactor
    # Plain thread, no scheduler: the adapter must run its own reactor per
    # call (one-shot client, no cache leak) — SI consumers outside async
    # processes still get correct behavior.
    server = ChunkedServer.new(chunks: SSE_CHUNKS)
    adapter = SimpleInference::HTTPAdapters::AsyncHTTP.new

    refute Fiber.scheduler, "test precondition: no ambient scheduler"
    received = []
    envelope = adapter.call_stream(sse_request(server)) { |chunk| received << chunk }

    assert_equal 200, envelope[:status]
    assert_equal SSE_CHUNKS, received
  ensure
    adapter&.close
    server&.stop
  end

  def test_close_is_idempotent_and_the_adapter_recovers
    server = ChunkedServer.new(content_type: "application/json", chunks: ["{}"])
    adapter = SimpleInference::HTTPAdapters::AsyncHTTP.new

    adapter.call(sse_request(server))
    adapter.close
    adapter.close

    envelope = adapter.call(sse_request(server))
    assert_equal 200, envelope[:status]
  ensure
    adapter&.close
    server&.stop
  end

  def test_is_a_valid_config_adapter
    adapter = SimpleInference::HTTPAdapters::AsyncHTTP.new
    config = SimpleInference::Config.new(base_url: "http://127.0.0.1:1", adapter: adapter)

    assert_same adapter, config.adapter
  end

  def test_pools_clients_only_under_a_stable_ambient_scheduler
    # Outside a reactor every call hosts a TEMPORARY scheduler — caching
    # against it would leak one client per call, so the cache must stay
    # empty (one-shot client, closed per call). Inside a long-lived reactor
    # (the runner) repeated same-origin calls must share ONE pooled client.
    server = ChunkedServer.new(content_type: "application/json", chunks: ["{}"])
    adapter = SimpleInference::HTTPAdapters::AsyncHTTP.new
    cache = adapter.instance_variable_get(:@clients)

    2.times { adapter.call(sse_request(server)) }
    assert_empty cache, "outside a reactor the client cache must not grow"

    Sync do
      2.times { adapter.call(sse_request(server)) }
    end
    assert_equal 1, cache.size, "same origin+deadline inside one reactor must share one client"
  ensure
    adapter&.close
    server&.stop
  end
end
