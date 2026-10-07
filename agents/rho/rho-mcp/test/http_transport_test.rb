require "test_helper"
require "puma"
require "puma/server"
require "puma/log_writer"
require "rack"
require "socket"

# THE HTTP HALF OVER A REAL LOOPBACK SERVER: the gem's own `StreamableHTTPTransport`
# under puma — a real HTTP server, a real SSE stream, the SDK's `net_http` path end to
# end. The row's headers reach the server; no pid, no group, no mutex (two calls in
# flight at once, both answered); a server that HOLDS the per-request stream open after
# its final response is answered promptly (the reason httpx was dropped); a legacy
# session that expires (a 404 with a session) is re-established and the call resent ONCE
# with the notice line, a second expiry `failed` and the next call reconnecting with a
# restart notice; a refused connect is the row's `down:` sentence; a cancelled http call
# poisons nothing.
class HttpTransportTest < Minitest::Test
  include McpTest::Helpers

  HELD_OPEN_SECONDS = 10

  def setup
    @servers = []
    @connections = []
    @log = []
    logger = Object.new
    log = @log
    %i[debug info warn error].each { |level| logger.define_singleton_method(level) { |event, **f| log << [level, event, f] } }
    @logger = logger
    @release = Queue.new
  end

  def teardown
    @connections.each { |c| c.close rescue nil }
    @release << :released
    @servers.each { |server| server.halt(true) rescue nil }
    Rho::Mcp.reset!
  end

  # Puma on a loopback port of the OS's choosing, quiet.
  def serve(app)
    server = Puma::Server.new(app, nil, min_threads: 0, max_threads: 4, log_writer: Puma::LogWriter.null)
    server.add_tcp_listener("127.0.0.1", 0)
    server.run
    @servers << server
    "http://127.0.0.1:#{server.connected_ports.fetch(0)}/mcp"
  end

  def row(url, tools: ["*"], timeout_ms: 5000, headers: { "X-Fixture-Token" => "${FX_TOKEN}" })
    raw = { "transport" => "http", "url" => url, "tools" => tools, "timeout_ms" => timeout_ms,
            "startup_timeout_ms" => 2000, "headers" => headers }
    Rho::Mcp::Settings.parse({ "remote" => raw }, env: { "FX_TOKEN" => McpTest::FX_TOKEN }).fetch(0)
  end

  def open_connection(row)
    Rho::Mcp::Connection.new(row, log: @logger, transport_factory: Rho::Mcp.transport_factory,
      redact: Rho::Runner::Redact.new(row.secrets)).tap { |c| @connections << c }.open!
  end

  def call(connection, raw, args = {})
    Rho::Runner::ExecutionContext.with(Rho::Runner::ExecutionContext.new(task_key: "t1")) do
      connection.call_tool(raw, args, public_name: "mcp__remote__#{raw}")
    end
  end

  # The gem's server transport as a Rack app, with the headers it saw.
  def gem_app(server, seen)
    transport = MCP::Server::Transports::StreamableHTTPTransport.new(server)
    lambda do |env|
      seen << env.select { |key, _| key.start_with?("HTTP_") }
      transport.call(env)
    end
  end

  def test_the_gem_client_connects_lists_calls_and_carries_the_headers_with_no_process_and_no_mutex
    seen = []
    server = McpTest::FixtureServer.build(tools: %w[echo lookup])
    server.define_tool(name: "slow", description: "Answer after a moment.", input_schema: { properties: {} }) do
      sleep 0.5
      MCP::Tool::Response.new([{ type: "text", text: "slow" }])
    end
    connection = open_connection(row(serve(gem_app(server, seen))))
    assert_kind_of Rho::Mcp::HttpTransport, connection.instance_variable_get(:@transport)
    assert_equal %w[echo lookup slow], connection.tools.map(&:name)
    assert_equal ["fx-server", "1.0.0"], [connection.server_name, connection.server_version]
    assert_nil connection.pid, "an http server has no process"
    assert_nil connection.group_pid
    assert_predicate connection, :connected?
    assert_equal McpTest::FX_TOKEN, seen.fetch(0).fetch("HTTP_X_FIXTURE_TOKEN"), "the row's header rides every request"
    assert_equal "hello", call(connection, "echo", { "text" => "hello" }).content

    # No mutex: two calls in flight at once, both answered, the slow one
    # not holding the fast one.
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    slow = Thread.new { call(connection, "slow") }
    fast = Thread.new { call(connection, "echo", { "text" => "fast" }) }
    fast_answer = fast.value
    fast_at = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    assert_equal "fast", fast_answer.content
    assert_equal "slow", slow.value.content
    assert_operator fast_at, :<, 0.45, "the fast call waited on the slow one: #{fast_at}s"
    assert_nil connection.down
  end

  # A hand-written legacy server whose `tools/call` answers on an SSE
  # stream it then HOLDS OPEN: the gem's `on_data` sees the event under
  # `net_http` and aborts the stream the moment the response is in.
  def test_a_stream_held_open_after_its_final_response_is_answered_promptly
    url = serve(held_open_app)
    connection = open_connection(row(url, headers: {}))
    assert_equal %w[stall], connection.tools.map(&:name)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    answer = call(connection, "stall")
    took = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    assert_equal "answered on a stream that stayed open", answer.content
    assert_operator took, :<, 3.0, "the call waited for the server to close the stream: #{took}s"
  end

  def test_a_legacy_session_that_expires_is_re_established_and_the_call_resent_once_with_the_notice
    server = McpTest::FixtureServer.build(tools: %w[echo])
    expiries = [1]
    connection = open_connection(row(serve(legacy_app(server, expiries))))
    assert_equal MCP::Configuration::LATEST_HANDSHAKE_PROTOCOL_VERSION, connection.protocol_version, "a legacy handshake"
    result = call(connection, "echo", { "text" => "hello" })
    assert_equal "note: mcp server remote's session had expired and was re-established for this call\nhello", result.content
    assert_nil connection.down
    assert_includes @log, [:info, "mcp.session_renewed", { server: "remote", tool: "mcp__remote__echo" }]
    assert_equal 0, expiries.fetch(0), "one 404 was spent"
    assert_equal "plain", call(connection, "echo", { "text" => "plain" }).content, "the renewed session serves"
  end

  def test_a_second_expiry_fails_the_call_and_the_next_call_reconnects_with_the_notice
    server = McpTest::FixtureServer.build(tools: %w[echo])
    expiries = [2]
    connection = open_connection(row(serve(legacy_app(server, expiries))))
    error = assert_raises(Rho::Mcp::ServerGone) { call(connection, "echo", { "text" => "x" }) }
    assert_match(/\Amcp server remote's session expired again during mcp__remote__echo, after being re-established once: /,
      error.message)
    assert_match(/; the next call reconnects\z/, error.message)
    assert_match(/\Aunreachable \(.*\) at \d\d:\d\d:\d\d\z/, connection.down)
    refute_predicate connection, :connected?

    result = call(connection, "echo", { "text" => "back" })
    assert_match(/\Anote: mcp server remote had stopped answering \(.* at \d\d:\d\d:\d\d\) and was reconnected for this call; any state it held is gone\nback\z/,
      result.content)
    assert_nil connection.down
    assert_includes @log, [:info, "mcp.server_restarted", { server: "remote", tool: "mcp__remote__echo", after: :unreachable }]
  end

  # `oauth:` rides the gem's constructor (the guard and the bearer are the
  # gem's); the members this slice couples to exist on the pinned gem.
  def test_oauth_is_forwarded_to_the_gems_constructor
    provider = MCP::Client::OAuth::Provider.new(client_metadata: { "redirect_uris" => ["http://127.0.0.1/callback"] },
      redirect_uri: "http://127.0.0.1/callback", redirect_handler: ->(_) { }, callback_handler: -> { [nil, nil] })
    transport = Rho::Mcp::HttpTransport.new(url: "http://127.0.0.1:1/mcp", oauth: provider, open_timeout: 1, timeout: 1)
    assert_same provider, transport.oauth
    assert_nil Rho::Mcp::HttpTransport.new(url: "http://127.0.0.1:1/mcp", open_timeout: 1, timeout: 1).oauth
    error = assert_raises(MCP::Client::HTTP::InsecureURLError) do
      Rho::Mcp::HttpTransport.new(url: "http://mcp.example.com/mcp", oauth: provider, open_timeout: 1, timeout: 1)
    end
    assert_match(/must use https or be a loopback http URL when an oauth provider is set/, error.message)
  end

  def test_the_oauth_members_exist_on_the_pinned_gem
    assert MCP::Client::HTTP.private_method_defined?(:run_step_up_flow!), "the step-up entry HttpTransport wraps"
    assert MCP::Client::OAuth::Provider.instance_method(:initialize).parameters.include?([:key, :authorization_request_validator])
    assert MCP::Client::OAuth::Flow.public_method_defined?(:run!)
    assert MCP::Client::OAuth::Flow::AuthorizationRefusedError < MCP::Client::OAuth::Flow::AuthorizationError
    assert_equal %i[authorization_server scopes server_url resource], MCP::Client::OAuth::AuthorizationRequest.members
    assert_respond_to MCP::Client::OAuth::Discovery, :parse_www_authenticate
    assert_respond_to MCP::Client::OAuth::Discovery, :secure_url?
    assert_respond_to MCP::Client::OAuth::Discovery, :canonicalize_url
    assert %w[tokens save_tokens client_information save_client_information clear_tokens! access_token].all? { |m| MCP::Client::OAuth::Provider.method_defined?(m) }
  end

  def test_a_refused_connect_is_the_rows_down_sentence
    probe = TCPServer.new("127.0.0.1", 0)
    port = probe.addr.fetch(1)
    probe.close
    url = "http://127.0.0.1:#{port}/mcp"
    error = assert_raises(Rho::Mcp::Unavailable) { open_connection(row(url, headers: {})) }
    assert_match(/\Acould not connect to #{Regexp.escape(url)}: ConnectionFailed: /, error.message)
  end

  def test_a_cancelled_http_call_answers_nothing_and_poisons_nothing
    server = McpTest::FixtureServer.build(tools: %w[echo])
    server.define_tool(name: "slow", description: "Answer after a while.", input_schema: { properties: {} }) do
      sleep 2
      MCP::Tool::Response.new([{ type: "text", text: "slow" }])
    end
    connection = open_connection(row(serve(gem_app(server, []))))
    context = Rho::Runner::ExecutionContext.new(task_key: "t9")
    answer = :unset
    worker = Thread.new do
      Rho::Runner::ExecutionContext.with(context) do
        answer = connection.call_tool("slow", {}, public_name: "mcp__remote__slow")
      rescue Rho::Runner::ExecutionContext::Cancelled => error
        answer = error
      end
    end
    sleep 0.3
    context.cancel(:deadline)
    worker.join(5)
    assert_kind_of Rho::Runner::ExecutionContext::Cancelled, answer, "the call returns through the runner's checkpoint"
    assert_predicate connection, :connected?, "http: no poison"
    assert_nil connection.down
    refute(@log.any? { |entry| entry[1] == "mcp.server_killed" })
    assert_equal "after", call(connection, "echo", { "text" => "after" }).content
  end

  private

    # A legacy-only server: a modern probe (a request stamped with a modern
    # `MCP-Protocol-Version`) is 404, as the 2026-07-28 rollout's legacy
    # servers answer; the first N `tools/call` carrying a session are 404
    # — the spec's session-expiry signal — then the gem's transport serves.
    def legacy_app(server, expiries)
      transport = MCP::Server::Transports::StreamableHTTPTransport.new(server)
      lambda do |env|
        version = env["HTTP_MCP_PROTOCOL_VERSION"]
        if version && MCP::Configuration.modern_protocol_version?(version)
          next [404, { "content-type" => "application/json" }, ['{"jsonrpc":"2.0","error":{"code":-32601,"message":"Not found"}}']]
        end

        request = Rack::Request.new(env)
        if request.post? && env["HTTP_MCP_SESSION_ID"] && expiries.fetch(0).positive?
          body = request.body.read
          request.body.rewind if request.body.respond_to?(:rewind)
          if body.include?('"tools/call"')
            expiries[0] -= 1
            next [404, { "content-type" => "application/json" }, ['{"jsonrpc":"2.0","error":{"code":-32001,"message":"Session not found"}}']]
          end
          env["rack.input"] = StringIO.new(body)
        end
        transport.call(env)
      end
    end

    # A legacy server of one tool whose call is answered as the FIRST event
    # of an SSE stream the server then keeps open for a while.
    def held_open_app
      release = @release
      lambda do |env|
        request = Rack::Request.new(env)
        message = JSON.parse(request.body.read) rescue {}
        id = message["id"]
        json = ->(payload) { [200, { "content-type" => "application/json" }, [JSON.generate(payload)]] }
        case message["method"]
        when "server/discover"
          json.call("jsonrpc" => "2.0", "id" => id, "error" => { "code" => -32601, "message" => "Method not found" })
        when "initialize"
          [200, { "content-type" => "application/json", "mcp-session-id" => "held-1" },
           [JSON.generate("jsonrpc" => "2.0", "id" => id,
             "result" => { "protocolVersion" => MCP::Configuration::LATEST_HANDSHAKE_PROTOCOL_VERSION,
                           "capabilities" => { "tools" => {} }, "serverInfo" => { "name" => "held", "version" => "1" } })]]
        when "notifications/initialized" then [202, {}, []]
        when "tools/list"
          json.call("jsonrpc" => "2.0", "id" => id, "result" => { "tools" => [
            { "name" => "stall", "description" => "Answer, then hold the stream open.",
              "inputSchema" => { "type" => "object", "properties" => {} } },
          ] })
        when "tools/call"
          response = JSON.generate("jsonrpc" => "2.0", "id" => id,
            "result" => { "content" => [{ "type" => "text", "text" => "answered on a stream that stayed open" }] })
          body = Enumerator.new do |out|
            out << "event: message\ndata: #{response}\n\n"
            deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + HELD_OPEN_SECONDS
            while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline && release.empty?
              sleep 0.1
              out << ": keepalive\n\n"
            end
          end
          [200, { "content-type" => "text/event-stream", "cache-control" => "no-cache" }, body]
        else
          json.call("jsonrpc" => "2.0", "id" => id, "error" => { "code" => -32601, "message" => "Method not found" })
        end
      end
    end
end
