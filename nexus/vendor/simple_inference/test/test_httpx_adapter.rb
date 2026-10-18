require "test_helper"

require "simple_inference/http_adapters/httpx"

class TestHTTPXAdapter < Minitest::Test
  class FakeStreamResponse
    attr_reader :status, :headers, :close_calls

    def initialize(status:, headers:, chunks:, raise_http_error: false)
      @status = status
      @headers = headers
      @chunks = chunks
      @raise_http_error = raise_http_error
      @close_calls = 0
    end

    def each
      return enum_for(__method__) unless block_given?

      @chunks.each do |chunk|
        yield chunk
      end

      raise ::HTTPX::HTTPError.new(self) if @raise_http_error
    end

    def body
      @chunks.join
    end

    def close
      @close_calls += 1
    end
  end

  class FakeClient < ::HTTPX::Session
    attr_reader :calls, :timeouts, :derived_clients, :close_calls

    def self.build(response, calls: [], timeouts: [], derived_clients: [], on_with: nil)
      obj = allocate
      obj.instance_variable_set(:@response, response)
      obj.instance_variable_set(:@calls, calls)
      obj.instance_variable_set(:@timeouts, timeouts)
      obj.instance_variable_set(:@derived_clients, derived_clients)
      obj.instance_variable_set(:@on_with, on_with)
      obj.instance_variable_set(:@close_calls, 0)
      obj
    end

    def plugin(_name)
      self
    end

    def with(timeout:)
      @timeouts << timeout
      @on_with&.call
      derived = self.class.build(
        @response, calls: @calls, timeouts: @timeouts,
        derived_clients: @derived_clients
      )
      @derived_clients << derived
      derived
    end

    def request(method, url, headers: {}, body: nil, stream: false, **options)
      @calls << {
        method: method, url: url, headers: headers, body: body, stream: stream, options: options,
      }
      @response
    end

    def close
      @close_calls += 1
    end
  end

  def test_error_response_raises_connection_error_instead_of_calling_headers
    skip "HTTPX::ErrorResponse not available" unless ::HTTPX.const_defined?(:ErrorResponse)

    # Simulate HTTPX returning an ErrorResponse object which does not implement
    # the normal response API (e.g. `#headers`).
    err = StandardError.new("boom")

    response = ::HTTPX::ErrorResponse.allocate
    response.define_singleton_method(:status) { 599 }
    response.define_singleton_method(:error) { err }
    close_calls = 0
    response.define_singleton_method(:close) { close_calls += 1 }
    adapter = SimpleInference::HTTPAdapters::HTTPX.new(client: FakeClient.build(response), stream_client: FakeClient.build(response))

    e =
      assert_raises(SimpleInference::ConnectionError) do
        adapter.call(method: :get, url: "https://example.test")
      end

    assert_includes e.message, "boom"
    assert_equal 1, close_calls, "an error response remains owned by the adapter"
    refute_kind_of SimpleInference::ConnectionNotEstablishedError, e,
                   "an unclassified failure never claims the request was unsent"
  end

  # The one distinction a caller cannot make for itself: HTTPX raises
  # ConnectTimeoutError only while its connection state machine is still
  # connecting, strictly before any request framing. Everything else this
  # adapter folds into ConnectionError may have happened AFTER bytes went out.
  def test_a_connect_timeout_is_reported_as_never_sent
    skip "HTTPX::ConnectTimeoutError not available" unless ::HTTPX.const_defined?(:ConnectTimeoutError)

    client = FakeClient.build(nil)
    client.define_singleton_method(:request) do |*, **|
      raise ::HTTPX::ConnectTimeoutError.new(1, "connect timed out")
    end
    adapter = SimpleInference::HTTPAdapters::HTTPX.new(client: client, stream_client: client)

    error = assert_raises(SimpleInference::ConnectionNotEstablishedError) do
      adapter.call(method: :get, url: "https://example.test")
    end

    # Still a ConnectionError, so every existing rescue keeps working.
    assert_kind_of SimpleInference::ConnectionError, error
  end

  # And the same answer when HTTPX RETURNS the failure instead of raising it,
  # so the not-sent conclusion never depends on which mode produced it.
  def test_a_returned_connect_timeout_is_reported_as_never_sent
    skip "HTTPX error classes not available" unless ::HTTPX.const_defined?(:ErrorResponse) &&
                                                    ::HTTPX.const_defined?(:ConnectTimeoutError)

    err = ::HTTPX::ConnectTimeoutError.new(1, "connect timed out")
    response = ::HTTPX::ErrorResponse.allocate
    response.define_singleton_method(:status) { 599 }
    response.define_singleton_method(:error) { err }
    response.define_singleton_method(:close) { nil }
    adapter = SimpleInference::HTTPAdapters::HTTPX.new(
      client: FakeClient.build(response), stream_client: FakeClient.build(response)
    )

    assert_raises(SimpleInference::ConnectionNotEstablishedError) do
      adapter.call(method: :get, url: "https://example.test")
    end
  end

  def test_initialize_raises_configuration_error_for_invalid_client
    error =
      assert_raises(SimpleInference::ConfigurationError) do
        SimpleInference::HTTPAdapters::HTTPX.new(client: Object.new)
      end

    assert_includes error.message, "client must be"
  end

  def test_call_copies_the_envelope_and_closes_its_response
    response = FakeStreamResponse.new(status: 200, headers: { "x-test" => "yes" }, chunks: ["ok"])
    client = FakeClient.build(response)
    adapter = SimpleInference::HTTPAdapters::HTTPX.new(client: client)

    envelope = adapter.call(method: :get, url: "https://example.test")

    assert_equal({ status: 200, headers: { "x-test" => "yes" }, body: "ok" }, envelope)
    assert_equal 1, response.close_calls
    assert_equal 0, client.close_calls, "the persistent base session remains cache-owned"
  end

  def test_dynamic_request_timeout_cap_clamps_all_httpx_deadlines_at_the_send_boundary
    response = FakeStreamResponse.new(status: 200, headers: {}, chunks: ["ok"])
    client = FakeClient.build(response)
    adapter = SimpleInference::HTTPAdapters::HTTPX.new(
      client: client, request_timeout_cap: -> { 3.0 }
    )

    adapter.call(
      method: :get, url: "https://example.test", timeout: 10,
      open_timeout: 8, read_timeout: 6
    )

    assert_equal 1, client.calls.length
    # Dynamic caps use a private one-shot derived session: constructing the
    # session happens before the cap is resolved, then the exact remaining
    # budget rides the request call and the session closes after the response.
    assert_equal [{}], client.timeouts
    assert_equal(
      { request_timeout: 3.0, connect_timeout: 3.0, read_timeout: 3.0 },
      client.calls.last.fetch(:options).fetch(:timeout)
    )
    assert_equal 1, client.derived_clients.fetch(0).close_calls
    assert_equal 0, client.close_calls, "only the one-shot child is adapter-owned"
    assert_equal 1, response.close_calls
  end

  def test_decaying_caps_use_closed_one_shot_sessions_without_a_permanent_cache_key
    response = FakeStreamResponse.new(status: 200, headers: {}, chunks: ["ok"])
    client = FakeClient.build(response)
    caps = [30.9, 30.2].each
    adapter = SimpleInference::HTTPAdapters::HTTPX.new(
      client: client, request_timeout_cap: -> { caps.next }
    )

    2.times { adapter.call(method: :get, url: "https://example.test", timeout: 60) }

    assert_equal [{}, {}], client.timeouts
    assert_equal 2, client.calls.length
    assert_equal [30.9, 30.2], client.calls.map { |call| call.dig(:options, :timeout, :request_timeout) }
    assert(client.derived_clients.all? { |derived| derived.close_calls == 1 })
    assert_equal 2, response.close_calls
  end

  def test_a_sub_second_cap_keeps_its_exact_value
    response = FakeStreamResponse.new(status: 200, headers: {}, chunks: ["ok"])
    client = FakeClient.build(response)
    adapter = SimpleInference::HTTPAdapters::HTTPX.new(
      client: client, request_timeout_cap: -> { 0.4 }
    )

    adapter.call(method: :get, url: "https://example.test", timeout: 60)

    assert_equal [{}], client.timeouts
    assert_equal 0.4, client.calls.fetch(0).dig(:options, :timeout, :request_timeout)
    assert_equal 1, client.derived_clients.fetch(0).close_calls
  end

  def test_dynamic_request_timeout_cap_can_refuse_with_zero_httpx_requests
    response = FakeStreamResponse.new(status: 200, headers: {}, chunks: ["unused"])
    client = FakeClient.build(response)
    boundary_error = Class.new(StandardError)
    adapter = SimpleInference::HTTPAdapters::HTTPX.new(
      client: client,
      request_timeout_cap: -> { raise boundary_error, "synthetic exhausted deadline" }
    )

    assert_raises(boundary_error) do
      adapter.call(method: :get, url: "https://example.test", timeout: 10)
    end
    assert_empty client.calls
    assert_equal [{}], client.timeouts
    assert_equal 1, client.derived_clients.fetch(0).close_calls
  end

  def test_dynamic_cap_is_resolved_after_session_derivation_and_refuses_equality_with_zero_io
    response = FakeStreamResponse.new(status: 200, headers: {}, chunks: ["unused"])
    at_deadline = false
    client = FakeClient.build(response, on_with: -> { at_deadline = true })
    boundary_error = Class.new(StandardError)
    adapter = SimpleInference::HTTPAdapters::HTTPX.new(
      client: client,
      request_timeout_cap: lambda do
        raise boundary_error, "synthetic deadline equality" if at_deadline

        5.0
      end
    )

    assert_raises(boundary_error) do
      adapter.call(method: :get, url: "https://example.test", timeout: 10)
    end
    assert_empty client.calls
    assert_equal 1, client.derived_clients.fetch(0).close_calls
    assert_equal 0, response.close_calls
  end

  def test_dynamic_request_timeout_cap_also_clamps_stream_requests
    response = FakeStreamResponse.new(status: 200, headers: {}, chunks: ["ok"])
    client = FakeClient.build(response)
    adapter = SimpleInference::HTTPAdapters::HTTPX.new(
      client: client, stream_client: client, request_timeout_cap: -> { 2.0 }
    )

    adapter.call_stream(method: :get, url: "https://example.test", timeout: 9) { |_chunk| }

    call = client.calls.fetch(0)
    assert_equal true, call.fetch(:stream)
    assert_equal [{}], client.timeouts
    assert_equal(
      # A stream carries NO request-level timer: httpx swallows an
      # OperationTimeoutError while one is armed, so the idle bound would be
      # inert. The total is enforced by the adapter's own per-chunk deadline.
      { connect_timeout: 2.0, operation_timeout: 2.0 },
      call.fetch(:options).fetch(:timeout)
    )
    assert_equal 1, client.derived_clients.fetch(0).close_calls
    assert_equal 0, client.close_calls, "the injected stream base remains caller-owned"
    assert_equal 1, response.close_calls
  end

  def test_dynamic_stream_cap_refuses_equality_after_session_derivation_with_zero_io
    response = FakeStreamResponse.new(status: 200, headers: {}, chunks: ["unused"])
    at_deadline = false
    client = FakeClient.build(response, on_with: -> { at_deadline = true })
    boundary_error = Class.new(StandardError)
    adapter = SimpleInference::HTTPAdapters::HTTPX.new(
      client: client, stream_client: client,
      request_timeout_cap: lambda do
        raise boundary_error, "synthetic deadline equality" if at_deadline

        5.0
      end
    )

    assert_raises(boundary_error) do
      adapter.call_stream(method: :get, url: "https://example.test", timeout: 10) { |_chunk| }
    end
    assert_empty client.calls
    assert_equal 1, client.derived_clients.fetch(0).close_calls
    assert_equal 0, response.close_calls
  end

  def test_default_client_is_a_memoized_httpx_session
    first = SimpleInference::HTTPAdapters::HTTPX.default_client
    second = SimpleInference::HTTPAdapters::HTTPX.default_client

    assert_kind_of ::HTTPX::Session, first
    assert_same first, second
  end

  def test_default_client_includes_fiber_concurrency_via_persistent_plugin
    session = SimpleInference::HTTPAdapters::HTTPX.default_client

    assert_includes session.class.ancestors, ::HTTPX::Plugins::Persistent::InstanceMethods
    assert_includes session.class.ancestors, ::HTTPX::Plugins::FiberConcurrency::InstanceMethods
  end

  # C2-1 entry resolution R1: the persistent plugin implicitly installs
  # :retries with max_retries: 1 AND overrides retryable_request? to re-send
  # even non-idempotent POSTs once on reconnectable connection errors. The
  # production synchronous session config keeps connection persistence but
  # neutralizes that implicit resend — a hidden adapter retry on a paid
  # inference POST is exactly what the no-hidden-retry truth table forbids.
  # Re-verify the plugin's defaults at every httpx version bump.
  def test_default_client_neutralizes_the_persistent_plugins_implicit_retry
    session = SimpleInference::HTTPAdapters::HTTPX.default_client
    options = session.instance_variable_get(:@options)

    assert_equal 0, options.max_retries,
                 "the persistent plugin's implicit max_retries: 1 must be neutralized to zero"
  end

  def test_call_stream_yields_chunks_for_event_stream
    response =
      FakeStreamResponse.new(
        status: 200,
        headers: { "content-type" => "text/event-stream" },
        chunks: ["data: 1\n\n", "data: 2\n\n"]
      )

    adapter = SimpleInference::HTTPAdapters::HTTPX.new(client: FakeClient.build(response), stream_client: FakeClient.build(response))

    yielded = []
    resp =
      adapter.call_stream(method: :get, url: "https://example.test") do |chunk|
        yielded << chunk
      end

    assert_equal ["data: 1\n\n", "data: 2\n\n"], yielded
    assert_equal 200, resp[:status]
    assert_equal "text/event-stream", resp.dig(:headers, "content-type")
    assert_nil resp[:body]
    assert_equal 1, response.close_calls
    assert_equal 1, adapter.instance_variable_get(:@stream_client).derived_clients.fetch(0).close_calls
  end

  def test_call_stream_buffers_non_event_stream_body
    response =
      FakeStreamResponse.new(
        status: 200,
        headers: { "content-type" => "application/json" },
        chunks: ['{"ok":', "true}"]
      )

    adapter = SimpleInference::HTTPAdapters::HTTPX.new(client: FakeClient.build(response), stream_client: FakeClient.build(response))

    yielded = []
    resp =
      adapter.call_stream(method: :get, url: "https://example.test") do |chunk|
        yielded << chunk
      end

    assert_equal [], yielded
    assert_equal 200, resp[:status]
    assert_equal '{"ok":true}', resp[:body]
    assert_equal 1, response.close_calls
  end

  def test_call_stream_swallows_http_error_and_returns_body
    response =
      FakeStreamResponse.new(
        status: 401,
        headers: { "content-type" => "application/json" },
        chunks: ['{"error":"nope"}'],
        raise_http_error: true
      )

    adapter = SimpleInference::HTTPAdapters::HTTPX.new(client: FakeClient.build(response), stream_client: FakeClient.build(response))

    yielded = []
    resp =
      adapter.call_stream(method: :get, url: "https://example.test") do |chunk|
        yielded << chunk
      end

    assert_equal [], yielded
    assert_equal 401, resp[:status]
    assert_equal '{"error":"nope"}', resp[:body]
    assert_equal 1, response.close_calls
  end

  def test_call_stream_closes_response_and_derived_session_when_the_consumer_raises
    response =
      FakeStreamResponse.new(
        status: 200,
        headers: { "content-type" => "text/event-stream" },
        chunks: ["data: 1\n\n"]
      )
    stream_client = FakeClient.build(response)
    adapter = SimpleInference::HTTPAdapters::HTTPX.new(
      client: FakeClient.build(response), stream_client: stream_client
    )
    consumer_error = Class.new(StandardError)

    assert_raises(consumer_error) do
      adapter.call_stream(method: :get, url: "https://example.test") do |_chunk|
        raise consumer_error, "synthetic consumer interruption"
      end
    end

    assert_equal 1, response.close_calls
    assert_equal 1, stream_client.derived_clients.fetch(0).close_calls
    assert_equal 0, stream_client.close_calls, "the injected stream base remains caller-owned"
  end

  # A REAL SOCKET, because the claim is about what HTTPX does with the value
  # and no double can observe that. The previous version of these tests drove
  # a fake client and asserted the hash the adapter had just handed it — they
  # passed while the bound was being discarded by the stream plugin, which is
  # exactly the defect they were written to catch.
  class StallingServer
    def initialize(chunks: 1, interval: nil)
      @server = TCPServer.new("127.0.0.1", 0)
      @chunks = chunks
      @interval = interval
      @thread = Thread.new { serve }
    end

    def url = "http://127.0.0.1:#{@server.addr[1]}/stream"

    def close
      @thread&.kill
      begin
        @server.close
      rescue StandardError
        nil
      end
    end

    private

    def serve
      socket = @server.accept
      line = socket.gets
      line = socket.gets while line && line.strip != ""
      socket.write("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n" \
                   "Transfer-Encoding: chunked\r\n\r\n")
      socket.flush
      emit(socket)
      sleep # silence, until the client gives up
    rescue StandardError
      nil
    end

    def emit(socket)
      count = 0
      while @chunks.nil? || count < @chunks
        body = "data: {\"n\":#{count}}\n\n"
        socket.write(format("%x\r\n%s\r\n", body.bytesize, body))
        socket.flush
        count += 1
        sleep @interval if @interval
      end
    end
  end

  # THE IDLE BOUND, on the wire. A provider that accepts and then goes quiet
  # costs the idle bound, not the whole deadline — which is the entire reason
  # spec 12 calls this a second time axis.
  def test_a_silent_stream_is_cut_at_the_idle_bound_not_the_deadline
    server = StallingServer.new(chunks: 1)
    adapter = SimpleInference::HTTPAdapters::HTTPX.new
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    error = assert_raises(SimpleInference::TimeoutError) do
      adapter.call_stream(
        method: :get, url: server.url, timeout: 30, read_timeout: 1
      ) { |_chunk| nil }
    end

    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    assert_operator elapsed, :<, 10, "cut at the idle bound, not the 30s deadline (#{error.message})"
  ensure
    server&.close
  end

  # THE TOTAL BOUND, which HTTPX cannot hold at the same time as the idle one:
  # its request-level timers swallow the operation timeout. So a provider that
  # trickles forever is stopped by the adapter's own per-chunk deadline.
  def test_a_trickling_stream_is_cut_at_its_total_deadline
    server = StallingServer.new(chunks: nil, interval: 0.05)
    adapter = SimpleInference::HTTPAdapters::HTTPX.new
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    assert_raises(SimpleInference::TimeoutError) do
      adapter.call_stream(
        method: :get, url: server.url, timeout: 1, read_timeout: 30
      ) { |_chunk| nil }
    end

    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    assert_operator elapsed, :<, 10, "the deadline is enforced even while data keeps arriving"
  ensure
    server&.close
  end

  # CONNECT IS ITS OWN BUDGET. Handing it the whole lane deadline meant a
  # blackholed connect held a fiber and a capacity slot for 600 seconds and
  # then landed `possibly_accepted` — an attempt burned for a connection that
  # was never made.
  def test_connect_is_capped_below_the_lane_deadline
    client = FakeClient.build(FakeStreamResponse.new(status: 200, headers: {}, chunks: ["ok"]))
    adapter = SimpleInference::HTTPAdapters::HTTPX.new(client: client)

    adapter.call(method: :get, url: "https://example.test", timeout: 900)

    timeouts = client.timeouts.fetch(0)
    assert_equal 60.0, timeouts.fetch(:connect_timeout)
    assert_equal 900.0, timeouts.fetch(:request_timeout)
  end

  # The option shape, kept as a unit test but no longer pretending to prove
  # library behaviour: a stream carries the idle bound and NO request-level
  # timer, because httpx swallows an OperationTimeoutError while one is armed.
  def test_stream_options_carry_the_idle_bound_and_no_request_level_timer
    response = FakeStreamResponse.new(status: 200, headers: {}, chunks: ["ok"])
    client = FakeClient.build(response)
    adapter = SimpleInference::HTTPAdapters::HTTPX.new(client: client, stream_client: client)

    adapter.call_stream(
      method: :get, url: "https://example.test", timeout: 600, read_timeout: 45
    ) { |_chunk| }

    timeouts = client.calls.fetch(0).fetch(:options).fetch(:timeout)
    assert_equal 45.0, timeouts.fetch(:operation_timeout)
    refute timeouts.key?(:read_timeout), "the plugin forces read_timeout to Infinity on streams"
    refute timeouts.key?(:request_timeout), "an armed request timer makes the idle bound inert"
    assert_equal [{}], client.timeouts, "nothing rides the session: the plugin rewrites it"
  end

  def test_stream_without_an_explicit_idle_bound_keeps_the_plugin_default
    response = FakeStreamResponse.new(status: 200, headers: {}, chunks: ["ok"])
    client = FakeClient.build(response)
    adapter = SimpleInference::HTTPAdapters::HTTPX.new(client: client, stream_client: client)

    adapter.call_stream(method: :get, url: "https://example.test", timeout: 600) { |_chunk| }

    # NOT the 600s deadline: an idle bound equal to the total deadline is not
    # a bound, so the plugin's own 60s default stands instead.
    assert_equal 60.0,
      client.calls.fetch(0).fetch(:options).fetch(:timeout).fetch(:operation_timeout)
  end

  # The unary side is the carve-out's other half: no idle bound at all, and
  # `read_timeout` keeps meaning what HTTPX means by it.
  def test_unary_sends_carry_read_timeout_and_no_operation_timeout
    client = FakeClient.build(FakeStreamResponse.new(status: 200, headers: {}, chunks: ["ok"]))
    adapter = SimpleInference::HTTPAdapters::HTTPX.new(client: client)

    adapter.call(method: :get, url: "https://example.test", timeout: 900)

    timeouts = client.timeouts.fetch(0)
    assert_equal 900.0, timeouts.fetch(:read_timeout)
    refute timeouts.key?(:operation_timeout)
  end

  # The stream half of the one phase a library can prove. It is the rung that
  # authorizes a resend, so "unreachable on streams" would be a costly thing
  # to believe wrongly — and the unary case has been pinned since it landed
  # while this one had not.
  def test_a_connect_timeout_on_a_stream_is_also_reported_as_never_sent
    skip "HTTPX::ConnectTimeoutError not available" unless ::HTTPX.const_defined?(:ConnectTimeoutError)

    # The stream path always derives a one-shot session, so the raise has to
    # live on the derived object too — which is what `on_with` is for.
    raiser = lambda do |target|
      target.define_singleton_method(:request) do |*, **|
        raise ::HTTPX::ConnectTimeoutError.new(1, "connect timed out")
      end
    end
    derived = []
    client = FakeClient.build(nil, derived_clients: derived,
                              on_with: -> { nil })
    client.define_singleton_method(:with) do |timeout:|
      child = FakeClient.build(nil, derived_clients: derived)
      raiser.call(child)
      derived << child
      child
    end
    adapter = SimpleInference::HTTPAdapters::HTTPX.new(client: client, stream_client: client)

    assert_raises(SimpleInference::ConnectionNotEstablishedError) do
      adapter.call_stream(method: :get, url: "https://example.test") { |_chunk| }
    end
  end

  def test_httpx_request_has_stream_accessor
    assert ::HTTPX::Request.method_defined?(:stream)
    assert ::HTTPX::Request.method_defined?(:stream=)
  end

  def test_proxy_connect_request_inherits_stream_accessor
    begin
      require "httpx/plugins/proxy/http"
    rescue LoadError
      skip "httpx/plugins/proxy/http not available"
    end

    klass = ::HTTPX::Plugins::Proxy::HTTP::ConnectRequest
    assert klass.method_defined?(:stream)
    assert klass.method_defined?(:stream=)
  end
  def test_derived_sessions_are_memoized_per_timeout_tuple
    base = ::HTTPX.plugin(:persistent)
    opts = { request_timeout: 180.0, connect_timeout: 180.0, read_timeout: 180.0 }

    first = SimpleInference::HTTPAdapters::HTTPX.derived_session(base, timeout_opts: opts)
    second = SimpleInference::HTTPAdapters::HTTPX.derived_session(base, timeout_opts: opts.dup)
    other = SimpleInference::HTTPAdapters::HTTPX.derived_session(base, timeout_opts: opts.merge(request_timeout: 900.0))

    assert_same first, second
    refute_same first, other
  end

  def test_stream_sessions_are_private_per_call_and_closed_by_the_block_api
    opts = { request_timeout: 180.0 }
    first = nil
    second = nil

    SimpleInference::HTTPAdapters::HTTPX.with_stream_session(timeout_opts: opts) do |session|
      first = session
    end
    SimpleInference::HTTPAdapters::HTTPX.with_stream_session(timeout_opts: opts) do |session|
      second = session
    end

    refute_same first, second
  end
end
