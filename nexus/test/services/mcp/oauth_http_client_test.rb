require "test_helper"
require_relative "../../support/mcp_test_server"

class Mcp::OAuthHttpClientTest < ActiveSupport::TestCase
  test "JSON registration and form exchange preserve streamed OAuth error bodies" do
    server = McpTestServer.new do |request|
      if request.fetch(:line).include?("/register")
        { json: { client_id: "test-client" } }
      else
        { status: 400, json: { error: "invalid_grant" } }
      end
    end
    with_client do |client|
      registration = client.post(server.endpoint_url.sub("/mcp", "/register")) do |request|
        request.headers["Content-Type"] = "application/json"
        request.body = JSON.generate(client_name: "Nexus")
      end
      assert_equal "test-client", JSON.parse(registration.body).fetch("client_id")

      streamed = +""
      response = client.post(server.endpoint_url) do |request|
        request.headers["Content-Type"] = "application/x-www-form-urlencoded"
        request.body = URI.encode_www_form(grant_type: "authorization_code", code: "synthetic-code")
        request.options.on_data = ->(chunk, _bytes, _env) { streamed << chunk }
      end
      assert_equal 400, response.status
      assert_equal "invalid_grant", JSON.parse(response.body).fetch("error")
      assert_equal response.body, streamed
      assert client.request_sent
    end
    assert_equal({ "client_name" => "Nexus" }, server.requests.first.fetch(:body))
    assert_equal "synthetic-code", URI.decode_www_form(server.requests.last.fetch(:body)).to_h.fetch("code")
    assert_equal 2, server.requests.size
  ensure
    server&.close
  end

  test "redirects and alternative origins receive no credential-bearing followup" do
    destination = McpTestServer.new { { json: {} } }
    server = McpTestServer.new do
      { status: 302, headers: { "Location" => destination.endpoint_url,
        "Alt-Svc" => %(h2c="#{URI.parse(destination.endpoint_url).authority}") } }
    end
    error = assert_raises(Mcp::Error) do
      with_client { |client| client.post(server.endpoint_url) { |request| request.body = "synthetic-secret" } }
    end
    assert_equal :mcp_redirect_refused, error.code
    assert error.request_sent
    assert_equal 1, server.requests.size
    assert_empty destination.requests
    assert_nil error.cause
  ensure
    server&.close
    destination&.close
  end

  test "a disconnected token exchange is not retried and exposes no upstream detail" do
    server = McpTestServer.new { nil }
    error = assert_raises(Mcp::Error) do
      with_client { |client| client.post(server.endpoint_url) { |request| request.body = "synthetic-secret" } }
    end
    assert error.request_sent
    assert_equal 1, server.requests.size
    refute_includes error.message, "synthetic-secret"
    assert_nil error.cause
  ensure
    server&.close
  end

  test "response bytes and silent peers are bounded" do
    server = McpTestServer.new { { body: "x" * 2048 } }
    error = assert_raises(Mcp::Error) do
      stub_const(Mcp::OAuthHttpClient, :MAX_RESPONSE_BYTES, 1024) do
        with_client { |client| client.get(server.endpoint_url) { |_request| } }
      end
    end
    assert_equal :mcp_response_too_large, error.code
    server.close

    server = McpTestServer.new { { json: {}, delay: 0.3 } }
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    error = assert_raises(Mcp::Error) do
      with_client(timeout_seconds: 0.1) { |client| client.get(server.endpoint_url) { |_request| } }
    end
    assert_equal :mcp_timeout, error.code
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 0.25
  ensure
    server&.close
  end

  test "private destinations are refused before sending an exchange" do
    client = Mcp::OAuthHttpClient.new(timeout_seconds: 0.2)
    error = assert_raises(Mcp::Error) do
      client.post("http://127.0.0.1/token") { |request| request.body = "synthetic-secret" }
    end
    assert_equal :mcp_endpoint_refused, error.code
    refute error.request_sent
  ensure
    client&.close
  end

  private

    def with_client(**options)
      session = HTTPX.plugin(:ssrf_filter, safe_private_ranges: ["127.0.0.1/32"])
      HTTPX.stub(:plugin, session) do
        client = Mcp::OAuthHttpClient.new(**options)
        begin
          yield client
        ensure
          client.close
        end
      end
    end
end
