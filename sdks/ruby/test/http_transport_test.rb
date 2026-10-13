require "test_helper"
require "open3"
require "rbconfig"
require "socket"
require "stringio"

# The one httpx transport behind both API planes and the device flow. A
# long-running host runs on it, so the caller's timeout has to bound every
# phase — resolve, connect and TLS all run before a total-request timer starts.
class HttpTransportTest < Minitest::Test
  DEVICE_CODE = "dc-cybros-v1-debug-device-secret".freeze
  ACCESS_TOKEN = "sk-cybros-api-v1-debug-access-secret".freeze
  REFRESH_TOKEN = "rt-cybros-api-v1-debug-refresh-secret".freeze
  RESOLVER_DELAY_KEY = :cybros_resolver_delay

  module SlowResolverProbe
    def nolookup_resolve(hostname, options)
      delay = Thread.current[RESOLVER_DELAY_KEY]
      sleep(delay) if delay
      super
    end
  end
  HTTPX::Resolver::Multi.prepend(SlowResolverProbe)

  module ConnectionFailureProbe
    module InstanceMethods
      private

        def send_request(request, *)
          error = HTTPX::ConnectionError.new("connect failed for sk-cybros-api-v1-leaked.secret")
          response = HTTPX::ErrorResponse.new(request, error)
          request.response = response
          request.emit_response(response)
        end
    end
  end

  class SessionStub
    attr_reader :requests

    def initialize(response)
      @response = response
      @requests = []
    end

    def request(*args, **options)
      @requests << [args, options]
      @response
    end
  end

  class RefusedSession
    def request(*) = raise Errno::ECONNREFUSED
    def plugin(*) = self
  end

  ResponseStub = Struct.new(:status, :headers, :body)

  RequestStub = Struct.new(:response, :options, :connection, :started) do
    def log_exception(*) = nil

    def started? = started
  end

  def transport_with(session, timeout: 30)
    transport = CybrosAgent::HttpTransport.new(base_url: "http://example.test", timeout: timeout)
    transport.instance_variable_set(:@session, session)
    transport
  end

  def test_the_credential_travels_in_the_authorization_header_and_the_body_is_parsed
    session = SessionStub.new(ResponseStub.new(200, {}, '{"executor":{"public_id":"x"}}'))

    response = transport_with(session).call("/agent_api/v1/executor", credential: "sk-secret", timeout: 5)

    (args, options) = session.requests.fetch(0)
    assert_equal [:get, "/agent_api/v1/executor"], args
    assert_equal "Bearer sk-secret", options.fetch(:headers).fetch("Authorization")
    assert_equal "application/json", options.fetch(:headers).fetch("Accept")
    refute options.key?(:params), "a request without query parameters encodes none"
    refute options.key?(:json), "a request without a body encodes none"
    refute options.key?(:form)
    assert_equal 200, response.status
    assert_equal({ "executor" => { "public_id" => "x" } }, response.body)
  end

  # The base URL's origin and path prefix are session-level, so a request
  # names only its path and a prefixed deployment keeps its prefix.
  def test_the_base_url_keeps_its_path_prefix
    transport = CybrosAgent::HttpTransport.new(base_url: "https://nexus.test/prefix/")
    options = transport.instance_variable_get(:@session).instance_variable_get(:@options)

    assert_equal URI("https://nexus.test/prefix"), options.origin
    assert_equal "/prefix", options.base_path
  end

  def test_params_become_the_query_string_and_a_body_becomes_json
    session = SessionStub.new(ResponseStub.new(200, {}, "{}"))

    transport_with(session).call(
      "/agent_api/v1/workspaces",
      method: :post,
      credential: "sk-x",
      body: { "workspace" => { "name" => "Notes", "metadata" => nil } },
      params: { "limit" => 50 },
      headers: { "Idempotency-Key" => "key-1" },
      timeout: 5
    )

    (args, options) = session.requests.fetch(0)
    assert_equal [:post, "/agent_api/v1/workspaces"], args
    assert_equal({ "limit" => 50 }, options.fetch(:params))
    assert_equal({ "workspace" => { "name" => "Notes", "metadata" => nil } }, options.fetch(:json))
    headers = options.fetch(:headers)
    assert_equal "application/json", headers.fetch("Content-Type")
    assert_equal "key-1", headers.fetch("Idempotency-Key")
  end

  # Machine endpoints speak application/x-www-form-urlencoded with no bearer.
  def test_a_form_without_a_credential_carries_no_authorization
    session = SessionStub.new(ResponseStub.new(200, {}, "{}"))

    transport_with(session).call("/oauth/token", method: :post, form: { grant_type: "x" }, timeout: 5)

    (args, options) = session.requests.fetch(0)
    assert_equal [:post, "/oauth/token"], args
    assert_equal({ grant_type: "x" }, options.fetch(:form))
    refute options.fetch(:headers).key?("Authorization")
    refute options.fetch(:headers).key?("Content-Type"), "httpx owns the form's media type"
  end

  def test_the_credential_authorization_header_always_wins
    session = SessionStub.new(ResponseStub.new(200, {}, "{}"))

    transport_with(session).call(
      "/agent_api/v1/workspaces",
      credential: "sk-real",
      headers: { "Authorization" => "Bearer sk-forged" },
      timeout: 5
    )

    (_args, options) = session.requests.fetch(0)
    assert_equal "Bearer sk-real", options.fetch(:headers).fetch("Authorization")
  end

  def test_an_unknown_method_is_refused
    session = SessionStub.new(ResponseStub.new(200, {}, "{}"))

    assert_raises(ArgumentError) do
      transport_with(session).call("/agent_api/v1/profile", method: :head, credential: "sk-x", timeout: 5)
    end
    assert_empty session.requests
  end

  def test_an_unsupported_url_scheme_keeps_the_httpx_configuration_error_on_both_doors
    [["ws://127.0.0.1", "/oauth/token"], ["http://127.0.0.1", "ftp://127.0.0.1/token"]].each do |base_url, path|
      [{}, { sink: StringIO.new }].each do |options|
        transport = CybrosAgent::HttpTransport.new(base_url: base_url)

        assert_raises(HTTPX::UnsupportedSchemeError) do
          transport.call(path, method: :post, form: {}, timeout: 0.1, **options)
        end
      end
    end
  end

  def test_every_timeout_phase_is_bounded_by_the_call_budget
    session = SessionStub.new(ResponseStub.new(200, {}, "{}"))

    transport_with(session, timeout: 30).call("/agent_api/v1/profile", credential: "sk-x", timeout: 2)

    (_args, options) = session.requests.fetch(0)
    timeouts = options.fetch(:timeout)
    assert_equal 2, timeouts.fetch(:total_request_timeout)
    assert_equal 2, timeouts.fetch(:operation_timeout)
    assert_equal 2, timeouts.fetch(:connect_timeout)
    assert_equal 2, timeouts.fetch(:settings_timeout)
    resolve_timeouts = options.fetch(:resolver_options).fetch(:timeouts)
    assert_operator resolve_timeouts.sum, :<=, 2
    assert_predicate resolve_timeouts, :any?
  end

  def test_ordinary_requests_have_operation_and_total_timeouts
    transport = CybrosAgent::HttpTransport.new(base_url: "https://nexus.test", timeout: 7)
    timeouts = transport.instance_variable_get(:@session).instance_variable_get(:@options).timeout

    assert_equal 7, timeouts[:operation_timeout]
    assert_equal 28, timeouts[:total_request_timeout]
  end

  def test_a_non_json_or_empty_body_is_not_a_transport_failure
    ["", "<html>oops</html>"].each do |body|
      session = SessionStub.new(ResponseStub.new(502, {}, body))

      response = transport_with(session).call("/agent_api/v1/profile", credential: "sk-x", timeout: 5)

      assert_equal 502, response.status
      assert_nil response.body
    end
  end

  def test_a_non_json_caller_gets_the_bytes
    session = SessionStub.new(ResponseStub.new(200, {}, "\x89PNG"))

    response = transport_with(session).call("/f", credential: "sk-x", timeout: 5, accept: CybrosAgent::ANY_MEDIA)

    assert_equal "\x89PNG".b, response.body
  end

  def test_pre_dispatch_failures_are_known_not_to_have_sent_the_request
    [
      HTTPX::ResolveError.new("unresolved"),
      HTTPX::ConnectionError.new("connection refused"),
      HTTPX::SettingsTimeoutError.new(Object.new, "peer settings timed out"),
      HTTPX::TLSError.new("TLS handshake failed"),
    ].each do |httpx_error|
      assert_raises(CybrosAgent::RequestNotSentError) do
        transport_for(httpx_error, started: false).call("/oauth/token", method: :post, form: {}, timeout: 12)
      end
    end
  end

  def test_failures_after_request_serialization_keep_the_outcome_uncertain
    [
      HTTPX::ReadTimeoutError.new(Object.new, nil, 1),
      HTTPX::TLSError.new("connection failed after dispatch"),
    ].each do |httpx_error|
      error = assert_raises(CybrosAgent::TransportError) do
        transport_for(httpx_error, started: true).call("/oauth/token", method: :post, form: {}, timeout: 12)
      end

      refute_kind_of CybrosAgent::RequestNotSentError, error
    end
  end

  def test_a_connection_failure_is_a_typed_transport_error_with_the_secret_scrubbed
    error = RuntimeError.new("connect failed for sk-cybros-api-v1-leaked.secret")

    raised = assert_raises(CybrosAgent::TransportError) do
      transport_for(error, started: true).call("/agent_api/v1/profile", credential: "sk-x", timeout: 5)
    end
    refute_includes raised.message, "leaked.secret"
    refute_includes raised.full_message, "leaked.secret"
    assert_includes raised.message, "[REDACTED]"
  end

  # Use the real stream enumerator: its ErrorResponse is raised as a cause,
  # which must not bypass the SDK's diagnostic redaction.
  def test_a_streamed_connection_failure_keeps_the_scrubbed_diagnostic_contract
    [{}, { sink: StringIO.new }].each do |options|
      transport = CybrosAgent::HttpTransport.new(base_url: "http://127.0.0.1")
      session = transport.instance_variable_get(:@session)
      transport.instance_variable_set(:@session, session.plugin(ConnectionFailureProbe))

      raised = assert_raises(CybrosAgent::RequestNotSentError) do
        transport.call("/oauth/token", method: :post, form: {}, timeout: 0.1, **options)
      end

      refute_includes raised.message, "leaked.secret"
      refute_includes raised.full_message, "leaked.secret"
      assert_includes raised.message, "[REDACTED]"
    end
  end

  def test_a_nonpositive_or_infinite_timeout_is_refused
    session = SessionStub.new(ResponseStub.new(200, {}, "{}"))

    [0, -1, Float::INFINITY].each do |bad|
      assert_raises(ArgumentError) do
        transport_with(session).call("/agent_api/v1/profile", credential: "sk-x", timeout: bad)
      end
      assert_raises(ArgumentError) { CybrosAgent::HttpTransport.new(base_url: "http://x", timeout: bad) }
    end
  end

  # Retry-After is read once, case-insensitively, whatever object carries the
  # headers; anything unparseable is still throttling for one second.
  def test_retry_after_is_case_insensitive_with_a_one_second_floor
    assert_equal 7, CybrosAgent::Response.new(status: 429, headers: { "Retry-After" => "7" }, body: nil).retry_after
    assert_equal 7, CybrosAgent::Response.new(status: 429, headers: { "retry-after" => "7" }, body: nil).retry_after
    assert_equal 7, CybrosAgent::Response.new(status: 429, headers: HTTPX::Headers.new("Retry-After" => "7"), body: nil).retry_after
    assert_equal 1, CybrosAgent::Response.new(status: 429, headers: {}, body: nil).retry_after
    assert_equal 1, CybrosAgent::Response.new(status: 429, headers: { "Retry-After" => "soon" }, body: nil).retry_after
  end

  def test_httpx_debug_output_redacts_oauth_secrets
    server = TCPServer.new("127.0.0.1", 0)
    server_thread = Thread.new { serve_token_response(server) }
    environment = {
      "HTTPX_DEBUG" => "2",
      "DEVICE_FLOW_BASE_URL" => "http://127.0.0.1:#{server.local_address.ip_port}",
      "DEVICE_FLOW_DEVICE_CODE" => DEVICE_CODE,
    }
    script = <<~'RUBY'
      transport = CybrosAgent::HttpTransport.new(base_url: ENV.fetch("DEVICE_FLOW_BASE_URL"))
      response = transport.call("/oauth/token", method: :post, form: {
        client_id: "cybros-first-party-connector",
        grant_type: "urn:ietf:params:oauth:grant-type:device_code",
        device_code: ENV.fetch("DEVICE_FLOW_DEVICE_CODE"),
      }, timeout: 12)
      abort "unexpected HTTP status: #{response.status}" unless response.status == 200
    RUBY

    stdout, stderr, status = Open3.capture3(
      environment, RbConfig.ruby, "-I", File.expand_path("../lib", __dir__), "-rcybros_agent", "-e", script
    )
    server_thread.value
    debug_output = "#{stdout}\n#{stderr}"

    assert status.success?, "debug subprocess failed"
    assert debug_output.include?("[REDACTED]"), "the real HTTPX debug path did not run with redaction"
    refute debug_output.include?(DEVICE_CODE), "HTTPX debug output exposed the device code"
    refute debug_output.include?(ACCESS_TOKEN), "HTTPX debug output exposed the access token"
    refute debug_output.include?(REFRESH_TOKEN), "HTTPX debug output exposed the refresh token"
  ensure
    server&.close
  end

  # A BODILESS ANSWER THROUGH THE STREAM PLUGIN: httpx answers a
  # streamed response's status once its first chunk has landed, and the
  # 304 of a conditional read has none — the plugin's enumerator ended in
  # StopIteration under `status` on the first attachment read that sent a
  # tag. The answer is the status with its headers, nothing written, and
  # the request sent ONCE: a second `each` on that response would send it
  # again. An empty 200 is the same shape.
  def test_a_bodiless_response_streamed_into_a_sink_answers_its_status_and_headers_once
    { "304 Not Modified" => 304, "200 OK" => 200 }.each do |status_line, status|
      response, sink, connections = stream_response(status_line)

      assert_equal status, response.status
      assert_equal '"abc"', response.headers["etag"]
      assert_nil response.body
      assert_equal "", sink.string, "nothing is written on a bodiless answer"
      assert_equal 1, connections, "the request is sent once"
    end
  end

  # A STREAMED REFUSAL KEEPS ITS ENVELOPE: with the stream plugin on, httpx
  # hands every chunk to the stream and stores none of the body, so the
  # refusal's JSON must be read off the chunks — `body.to_s` was empty and
  # the failure ladder built a code-less NotFound for a text upload's
  # `representation_unavailable`.
  def test_a_streamed_refusal_keeps_its_json_envelope_for_the_failure_ladder
    envelope = { "error" => { "code" => "representation_unavailable", "message" => "no thumbnail" } }
    response, sink, connections = stream_response("404 Not Found", body: JSON.generate(envelope))

    assert_equal 404, response.status
    assert_equal envelope, response.body, "the refusal's JSON is read off the stream's chunks"
    assert_equal "", sink.string, "nothing is written on a refusal"
    assert_equal 1, connections
  end

  def test_httpx_total_request_timeout_interrupts_a_dispatched_slow_response
    [{}, { sink: StringIO.new, accept: CybrosAgent::ANY_MEDIA }].each do |options|
      TCPServer.open("127.0.0.1", 0) do |server|
        server_thread = Thread.new { serve_delayed_response(server) }
        transport = CybrosAgent::HttpTransport.new(base_url: "http://127.0.0.1:#{server.local_address.ip_port}")

        error = assert_raises(CybrosAgent::TransportError) do
          transport.call("/oauth/token", method: :post, form: {}, timeout: 0.05, **options)
        end

        refute_kind_of CybrosAgent::RequestNotSentError, error
        server_thread.value
      end
    end
  end

  # Time spent resolving counts against the same budget instead of the
  # deadline restarting once the name is known.
  def test_the_deadline_spans_resolution_instead_of_restarting_after_it
    # The listener binds the address `localhost` resolves to FIRST on this host
    # (::1 on some macOS resolvers, 127.0.0.1 on others): the pin is about the
    # deadline spanning resolution, never about the address family — a fixed
    # 127.0.0.1 listener behind a `localhost` URL was refused on an ::1-first
    # host.
    server = TCPServer.new("localhost", 0)
    server_thread = Thread.new { serve_delayed_response(server, delay: 0.3) }
    transport = CybrosAgent::HttpTransport.new(base_url: "http://localhost:#{server.local_address.ip_port}")
    Thread.current[RESOLVER_DELAY_KEY] = 0.12
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    error = assert_raises(CybrosAgent::TransportError) do
      transport.call("/agent_api/v1/profile", credential: "sk-x", timeout: 0.2)
    end
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    refute_kind_of CybrosAgent::RequestNotSentError, error
    assert_operator elapsed, :<, 0.27,
      "resolution and response handling must share one budget, not receive independent ones"
    server_thread.value
  ensure
    Thread.current[RESOLVER_DELAY_KEY] = nil
    server&.close
  end

  # A refused connect can escape httpx's selector as a raw Errno. Close the
  # listener before either call: a resolver that tries the next localhost
  # address must also see refusal, rather than connect to an idle listener
  # and eventually report a read timeout. HTTPX may report a known-unsent
  # connection failure or raise the raw error, depending on the resolver.
  def test_a_refused_first_address_is_a_transport_error_not_a_raw_errno
    addresses = Addrinfo.getaddrinfo("localhost", nil, nil, :STREAM).map(&:ip_address).uniq
    skip "localhost resolves to one address on this host" if addresses.length < 2

    port = TCPServer.open(addresses.last, 0) { |server| server.local_address.ip_port }
    transport = CybrosAgent::HttpTransport.new(base_url: "http://localhost:#{port}")

    { "the plain door" => {}, "the sink door" => { sink: StringIO.new, accept: CybrosAgent::ANY_MEDIA } }.each do |door, options|
      error = assert_raises(CybrosAgent::TransportError, door) do
        transport.call("/agent_api/v1/profile", credential: "sk-x", timeout: 2, **options)
      end

      assert_match(/refused/i, error.message, door)
    end
  end

  # A raw selector error carries no request state, so neither response door
  # may classify it as known-unsent merely from its exception class.
  def test_a_raw_connection_error_is_uncertain_on_both_response_doors
    transport = transport_with(RefusedSession.new)

    { "the plain door" => {}, "the sink door" => { sink: StringIO.new, accept: CybrosAgent::ANY_MEDIA } }.each do |door, options|
      error = assert_raises(CybrosAgent::TransportError, door) do
        transport.call("/agent_api/v1/profile", credential: "sk-x", timeout: 2, **options)
      end

      refute_kind_of CybrosAgent::RequestNotSentError, error, door
      assert_match(/refused/i, error.message, door)
    end
  end

  private

    def transport_for(error, started:)
      request = RequestStub.new(nil, nil, nil, started)
      transport_with(SessionStub.new(HTTPX::ErrorResponse.new(request, error)))
    end

    def serve_token_response(server)
      raise "debug subprocess did not connect" unless IO.select([server], nil, nil, 5)

      socket = server.accept
      request = +""
      request << socket.readpartial(1024) until request.include?("\r\n\r\n")
      headers, body = request.split("\r\n\r\n", 2)
      content_length = headers[/\r\ncontent-length:\s*(\d+)/i, 1].to_i
      body << socket.readpartial(1024) while body.bytesize < content_length

      response_body = JSON.generate({ access_token: ACCESS_TOKEN, refresh_token: REFRESH_TOKEN })
      socket.write(
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" \
        "Content-Length: #{response_body.bytesize}\r\nConnection: close\r\n\r\n#{response_body}"
      )
    ensure
      socket&.close
    end

    def stream_response(status_line, body: "")
      server = TCPServer.new("127.0.0.1", 0)
      server_thread = Thread.new { serve_streamed_response(server, status_line, body) }
      transport = CybrosAgent::HttpTransport.new(base_url: "http://127.0.0.1:#{server.local_address.ip_port}")
      sink = StringIO.new
      response = transport.call("/uploads/u-1/thumbnail", sink: sink, accept: "*/*", timeout: 5)
      [response, sink, server_thread.value]
    ensure
      server&.close
    end

    # Answers the one request (a JSON body, or none) and reports how many
    # connections arrived: a second one inside the window is the request
    # sent again.
    def serve_streamed_response(server, status_line, body)
      raise "client never connected" unless IO.select([server], nil, nil, 5)

      socket = server.accept
      request = +""
      request << socket.readpartial(1024) until request.include?("\r\n\r\n")
      socket.write(
        "HTTP/1.1 #{status_line}\r\nETag: \"abc\"\r\nContent-Type: application/json\r\n" \
        "Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}"
      )
      socket.close
      IO.select([server], nil, nil, 0.3) ? 2 : 1
    end

    def serve_delayed_response(server, delay: 0.2)
      raise "client never connected" unless IO.select([server], nil, nil, 5)

      socket = server.accept
      request = +""
      request << socket.readpartial(1024) until request.include?("\r\n\r\n")
      sleep delay
      socket.write("HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
    rescue IOError, Errno::EPIPE, Errno::ECONNRESET
      nil
    ensure
      socket&.close
    end
end
