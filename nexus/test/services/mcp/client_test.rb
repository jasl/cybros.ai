require "test_helper"
require_relative "../../support/mcp_test_server"

class Mcp::ClientTest < ActiveSupport::TestCase
  test "modern discovery and paginated catalogs share one context and carry no optional capabilities" do
    with_server do |request|
      rpc = request.fetch(:body)
      result = case rpc.fetch("method")
      when "server/discover" then discover_result
      when "tools/list"
        rpc.dig("params", "cursor") ? { tools: [tool("second")] } : { tools: [tool("first")], nextCursor: "next" }
      else flunk "unexpected method"
      end
      reply(rpc, result)
    end => server

    catalog = open_client(server) { |client| client.list_tools }
    assert_equal %w[first second], catalog.pluck("name")
    assert_equal({ "type" => "object" }, catalog.first.fetch("input_schema"))
    assert_equal %w[server/discover tools/list tools/list], server.requests.map { |request| request.dig(:body, "method") }
    server.requests.each do |request|
      meta = request.dig(:body, "params", "_meta")
      assert_equal "2026-07-28", request.dig(:headers, "mcp-protocol-version")
      assert_equal "2026-07-28", meta.fetch("io.modelcontextprotocol/protocolVersion")
      assert_equal({}, meta.fetch("io.modelcontextprotocol/clientCapabilities"))
      assert_equal "nexus", meta.fetch("io.modelcontextprotocol/clientInfo").fetch("name")
      refute request.fetch(:headers).key?("mcp-session-id")
    end
  ensure
    server&.close
  end

  test "legacy initialization keeps its session within one operation and closes after a complete SSE result" do
    sessions = []
    with_server do |request|
      next { status: 204 } if request.fetch(:line).start_with?("DELETE")
      rpc = request.fetch(:body)
      case rpc.fetch("method")
      when "server/discover" then rpc_error(rpc, -32601)
      when "initialize"
        sessions << "session-#{sessions.length}"
        reply(rpc, { protocolVersion: "2025-11-25", capabilities: {}, serverInfo: { name: "fixture", version: "1" } },
          headers: { "Mcp-Session-Id" => sessions.last })
      when "notifications/initialized" then { status: 202 }
      when "tools/call"
        data = JSON.generate(jsonrpc: "2.0", id: rpc.fetch("id"), result: { content: [{ type: "text", text: "done" }] })
        { headers: { "Content-Type" => "text/event-stream" }, body: "event: message\r\ndata: #{data}\r\n\r\n", keep_open: 0.1 }
      else flunk "unexpected method"
      end
    end => server

    2.times do
      result = open_client(server) { |client| client.call_tool(name: "write", arguments: { "value" => "x" }) }
      assert_equal "done", result.dig("content", 0, "text")
    end
    calls = server.requests.select { |request| request.dig(:body, "method") == "tools/call" }
    assert_equal %w[session-0 session-1], calls.map { |request| request.dig(:headers, "mcp-session-id") }
    assert_equal 2, server.requests.count { |request| request.fetch(:line).start_with?("DELETE") }
    calls.each { |request| assert_equal "2025-11-25", request.dig(:headers, "mcp-protocol-version") }
  ensure
    server&.close
  end

  test "redirect auth rate limit and server errors never replay a tool or leak remote error details" do
    server = nil
    { 302 => :mcp_redirect_refused, 401 => :mcp_authentication_failed,
      429 => :mcp_rate_limited, 500 => :mcp_http_error }.each do |status, code|
      with_server do |request|
        rpc = request.fetch(:body)
        if rpc.fetch("method") == "server/discover"
          reply(rpc, discover_result)
        else
          { status: status, body: "test-secret-token", headers: { "Location" => "http://127.0.0.1:1/leak", "Retry-After" => "0" } }
        end
      end => server
      error = assert_raises(Mcp::Error) { open_client(server) { |client| client.call_tool(name: "write", arguments: {}) } }
      assert_equal code, error.code
      assert error.request_sent
      assert_nil error.cause
      refute_includes error.message, "test-secret-token"
      assert_equal 1, server.requests.count { |request| request.dig(:body, "method") == "tools/call" }
      server.close
    end
  ensure
    server&.close
  end

  test "modern authentication failure never triggers a legacy handshake" do
    server = McpTestServer.new { { status: 401, body: "token-secret" } }
    error = assert_raises(Mcp::Error) { open_client(server) { flunk "must not connect" } }
    assert_equal :mcp_authentication_failed, error.code
    refute error.request_sent
    assert_equal ["server/discover"], server.requests.map { |request| request.dig(:body, "method") }
  ensure
    server&.close
  end

  test "an advertised alternative origin cannot receive later requests or credentials" do
    alternative = McpTestServer.new { { status: 200 } }
    authority = URI.parse(alternative.endpoint_url).authority
    server = McpTestServer.new do |request|
      rpc = request.fetch(:body)
      result = rpc.fetch("method") == "server/discover" ? discover_result : { content: [{ type: "text", text: "done" }] }
      reply(rpc, result, headers: { "Alt-Svc" => %(h2c="#{authority}") })
    end

    result = open_client(server) { |client| client.call_tool(name: "write", arguments: {}) }
    assert_equal "done", result.dig("content", 0, "text")
    assert_equal %w[server/discover tools/call], server.requests.map { |request| request.dig(:body, "method") }
    assert_empty alternative.requests
  ensure
    server&.close
    alternative&.close
  end

  test "a disconnect after side effect remains sent and receives no retry" do
    effects = 0
    server = McpTestServer.new do |request|
      rpc = request.fetch(:body)
      if rpc.fetch("method") == "server/discover"
        reply(rpc, discover_result)
      else
        effects += 1
        nil
      end
    end
    error = assert_raises(Mcp::Error) { open_client(server) { |client| client.call_tool(name: "write", arguments: {}) } }
    assert error.request_sent
    assert_equal 1, effects
  ensure
    server&.close
  end

  test "input required including state only is explicitly unsupported without continuation" do
    server = nil
    [{ requestState: "state" }, { inputRequests: { question: { method: "elicitation/create", params: {} } } }].each do |extra|
      server = McpTestServer.new do |request|
        rpc = request.fetch(:body)
        result = rpc.fetch("method") == "server/discover" ? discover_result : { resultType: "input_required" }.merge(extra)
        reply(rpc, result)
      end
      error = assert_raises(Mcp::Error) { open_client(server) { |client| client.call_tool(name: "write", arguments: {}) } }
      assert_equal :mcp_input_required, error.code
      assert error.request_sent
      assert_equal 2, server.requests.length
      server.close
    end
  ensure
    server&.close
  end

  test "a partial directory with repeated cursor or malformed page is not returned" do
    server = nil
    [{ tools: [tool("second")], nextCursor: "again" }, {}, { tools: "bad" }].each do |last_page|
      server = McpTestServer.new do |request|
        rpc = request.fetch(:body)
        result = if rpc.fetch("method") == "server/discover"
          discover_result
        elsif rpc.dig("params", "cursor")
          last_page
        else
          { tools: [tool("first")], nextCursor: "again" }
        end
        reply(rpc, result)
      end
      error = assert_raises(Mcp::Error) { open_client(server) { |client| client.list_tools } }
      assert_equal :mcp_invalid_catalog, error.code
      server.close
    end
  ensure
    server&.close
  end

  test "operation timeout covers silent response wait and cancellation refuses before tools call" do
    server = McpTestServer.new do |request|
      rpc = request.fetch(:body)
      reply(rpc, rpc.fetch("method") == "server/discover" ? discover_result : { content: [] },
        delay: rpc.fetch("method") == "tools/call" ? 0.3 : 0)
    end
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    error = assert_raises(Mcp::Error) do
      open_client(server, timeout_seconds: 0.1) { |client| client.call_tool(name: "slow", arguments: {}) }
    end
    assert_equal :mcp_timeout, error.code
    assert error.request_sent
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 0.25
    server.close

    cancelled = false
    server = McpTestServer.new { |request| reply(request.fetch(:body), discover_result) }
    error = assert_raises(Mcp::Error) do
      open_client(server, cancelled: -> { cancelled }) do |client|
        cancelled = true
        client.call_tool(name: "write", arguments: {})
      end
    end
    assert_equal :mcp_cancelled, error.code
    refute error.request_sent
    assert_equal 1, server.requests.length
  ensure
    server&.close
  end

  test "private and reserved destinations are refused before sending authorization" do
    %w[localhost 127.0.0.1 10.0.0.1 169.254.169.254 100.100.100.200 [::1] [fd00::1]].each do |host|
      error = assert_raises(Mcp::Error) do
        Mcp::Client.open(endpoint_url: "http://#{host}/mcp", bearer_token: "test-secret", timeout_seconds: 0.2) { flunk }
      end
      assert_equal :mcp_endpoint_refused, error.code
      refute error.request_sent
    end
  end

  test "both lifecycle versions carry JSON and SSE directories and tool responses" do
    server = nil
    %w[2026-07-28 2025-11-25].product(%w[application/json text/event-stream]).each do |version, type|
      server = McpTestServer.new do |request|
        next { status: 204 } if request.fetch(:line).start_with?("DELETE")
        rpc = request.fetch(:body)
        method = rpc.fetch("method")
        next rpc_error(rpc, -32601) if method == "server/discover" && version == "2025-11-25"
        next { status: 202 } if method == "notifications/initialized"

        result = case method
        when "server/discover" then discover_result
        when "initialize" then { protocolVersion: version, capabilities: {}, serverInfo: { name: "fixture", version: "1" } }
        when "tools/list" then { tools: [tool("read")] }
        when "tools/call" then { content: [{ type: "text", text: "received" }], isError: true }
        else flunk "unexpected method"
        end
        body = JSON.generate({ jsonrpc: "2.0", id: rpc.fetch("id"), result: result })
        body = "data: #{body}\n\n" if type == "text/event-stream"
        { body: body, headers: { "Content-Type" => type } }
      end
      open_client(server) do |client|
        assert_equal ["read"], client.list_tools.pluck("name")
        result = client.call_tool(name: "read", arguments: {})
        assert_equal "received", result.dig("content", 0, "text")
        assert result.fetch("isError")
      end
      server.close
    end
  ensure
    server&.close
  end

  test "a session cleanup timeout cannot replace a completed result or replay the tool" do
    server = McpTestServer.new do |request|
      next { status: 204, delay: 0.2 } if request.fetch(:line).start_with?("DELETE")
      rpc = request.fetch(:body)
      case rpc.fetch("method")
      when "server/discover" then rpc_error(rpc, -32601)
      when "initialize"
        reply(rpc, { protocolVersion: "2025-11-25", capabilities: {}, serverInfo: { name: "fixture", version: "1" } },
          headers: { "Mcp-Session-Id" => "operation-session" })
      when "notifications/initialized" then { status: 202 }
      when "tools/call" then reply(rpc, { content: [{ type: "text", text: "finished" }] })
      else flunk "unexpected method"
      end
    end
    result = stub_const(Mcp::HttpTransport, :CLOSE_TIMEOUT_SECONDS, 0.05) do
      open_client(server) { |client| client.call_tool(name: "write", arguments: {}) }
    end
    assert_equal "finished", result.dig("content", 0, "text")
    assert_equal 1, server.requests.count { |request| request.dig(:body, "method") == "tools/call" }
    assert_equal 1, server.requests.count { |request| request.fetch(:line).start_with?("DELETE") }
  ensure
    server&.close
  end

  test "page and catalog bounds refuse oversized discovery without a partial result" do
    server = nil
    [[:pages, :mcp_catalog_too_large], [:bytes, :mcp_catalog_too_large]].each do |mode, code|
      server = McpTestServer.new do |request|
        rpc = request.fetch(:body)
        result = if rpc.fetch("method") == "server/discover"
          discover_result
        else
          index = rpc.dig("params", "cursor").to_i
          { tools: [tool("tool-#{index}")], nextCursor: (index + 1).to_s }
        end
        reply(rpc, result)
      end
      error = assert_raises(Mcp::Error) do
        if mode == :pages
          stub_const(Mcp::Client, :MAX_PAGES, 2) { open_client(server) { |client| client.list_tools } }
        else
          bounds = Nexus::SizeBounds::BOUNDS.merge(tool_definitions_bound: { unit: :bytes, value: 1 })
          stub_const(Nexus::SizeBounds, :BOUNDS, bounds) { open_client(server) { |client| client.list_tools } }
        end
      end
      assert_equal code, error.code
      server.close
    end
  ensure
    server&.close
  end

  test "response byte bound and unsupported server requests terminate a sent tool without retry" do
    server = nil
    [[:oversize, :mcp_response_too_large], [:server_request, :mcp_unsupported_server_request]].each do |mode, code|
      server = McpTestServer.new do |request|
        rpc = request.fetch(:body)
        next reply(rpc, discover_result) if rpc.fetch("method") == "server/discover"

        body = if mode == :oversize
          "data: #{JSON.generate(jsonrpc: "2.0", id: rpc.fetch("id"), result: { content: [{ type: "text", text: "x" * 2048 }] })}\n\n"
        else
          "data: #{JSON.generate(jsonrpc: "2.0", id: "server-question", method: "sampling/createMessage", params: {})}\n\n"
        end
        { body: body, headers: { "Content-Type" => "text/event-stream" } }
      end
      bounds = Nexus::SizeBounds::BOUNDS.merge(inline_binary_bound: { unit: :bytes, value: 1024 })
      error = assert_raises(Mcp::Error) do
        stub_const(Nexus::SizeBounds, :BOUNDS, bounds) do
          open_client(server) { |client| client.call_tool(name: "write", arguments: {}) }
        end
      end
      assert_equal code, error.code
      assert error.request_sent
      assert_equal 2, server.requests.length
      server.close
    end
  ensure
    server&.close
  end

  private

    def with_server(&block) = McpTestServer.new(&block)

    def open_client(server, **options, &block)
      session = HTTPX.plugin(:ssrf_filter, safe_private_ranges: ["127.0.0.1/32"])
      HTTPX.stub(:plugin, session) do
        Mcp::Client.open(endpoint_url: server.endpoint_url, bearer_token: "test-secret-token", **options, &block)
      end
    end

    def discover_result
      { supportedVersions: ["2026-07-28"], capabilities: { tools: {} }, ttlMs: 0, cacheScope: "private" }
    end

    def tool(name) = { name: name, description: "Fixture tool", inputSchema: { type: "object" } }

    def reply(rpc, result, **options)
      { json: { jsonrpc: "2.0", id: rpc.fetch("id"), result: result }, **options }
    end

    def rpc_error(rpc, code)
      { json: { jsonrpc: "2.0", id: rpc.fetch("id"), error: { code: code, message: "unsupported" } } }
    end
end
