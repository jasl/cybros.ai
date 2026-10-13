require "test_helper"
require "rho/mcp"
require_relative "../../rho-mcp/test/support/fake_transport"

class McpRefreshTest < Minitest::Test
  include RhoTest::DaemonHarness

  def teardown
    super
    Rho::Mcp.reset!
  end

  def test_login_refreshes_the_running_daemon_through_its_authenticated_owner
    unrelated = McpTest::FakeTransport.new(McpTest::FixtureServer.build(tools: ["echo"]))
    Rho::Mcp.transport_factory = lambda do |row, oauth: nil, **|
      if row.key == "other"
        unrelated
      else
        McpTest::FakeTransport.new(McpTest::FixtureServer.build(tools: %w[echo lookup])).tap do |transport|
          transport.spawn_error = "authorization required" if oauth.nil?
        end
      end
    end
    servers = {
      "fxo" => { "transport" => "http", "url" => "https://mcp.example/mcp", "tools" => ["*"] },
      "other" => { "transport" => "stdio", "command" => "ruby", "tools" => ["echo"] },
    }
    daemon = boot(extensions: [], config: Rho::Config.from_hash({ "plugins" => { "rho.mcp" => { "enabled" => true,
      "configuration_version" => 1, "configuration" => { "servers" => servers } } } }))
    assert_equal "down", Rho::Mcp.entries.fetch("fxo").state
    original = Rho::Mcp.connections.fetch("other")
    assert_equal "401", request(daemon, :post, "/mcp/refresh", body: { name: "fxo" }).code
    missing = request(daemon, :post, "/mcp/refresh", token: bearer(daemon), body: { name: "unknown" })
    assert_equal "400", missing.code

    core = Rho::Core.new(home: daemon.home)
    row = Rho::Mcp::Settings.parse({ "fxo" => servers.fetch("fxo") }).fetch(0)
    storage = Rho::Mcp::Oauth.storage_for(row, home: daemon.home)
    storage.save_tokens({ "access_token" => "fixture-access-token", "refresh_token" => "fixture-refresh-token", "scope" => "read" })
    result = core.refresh_mcp("fxo")
    assert_equal "rho.mcp", result.fetch("refreshed")
    assert_empty result.fetch("failures")

    document = JSON.parse(request(daemon, :get, "/mcp", token: bearer(daemon)).body)
    server = document.fetch("servers").find { |entry| entry.fetch("key") == "fxo" }
    assert_equal "connected", server.fetch("state")
    assert_equal %w[mcp__fxo__echo mcp__fxo__lookup], server.fetch("tools").map { |tool| tool.fetch("name") }
    assert_equal "logged_in", server.dig("auth", "state")
    assert_same original, Rho::Mcp.connections.fetch("other")
    assert_equal 0, unrelated.closes
    Rho::Runner::ExecutionContext.with(Rho::Runner::ExecutionContext.new) do
      assert_equal "authenticated", Rho::Mcp.call("fxo", "echo", { "text" => "authenticated" }).content
    end
  end
end
