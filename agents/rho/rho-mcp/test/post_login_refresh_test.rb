require "test_helper"
require "support/oauth_world"

class PostLoginRefreshTest < Minitest::Test
  include McpTest::OauthWorld

  Host = Data.define(:home, :config, :serving_tools)
  Config = Data.define(:mcp_servers)

  def setup = oauth_setup
  def teardown = oauth_teardown

  def test_login_restores_a_boot_time_down_server_without_restarting_an_unrelated_connection
    unrelated = McpTest::FakeTransport.new(McpTest::FixtureServer.build(tools: ["echo"]))
    factory = Rho::Mcp.transport_factory
    Rho::Mcp.transport_factory = lambda do |row, **options|
      row.key == "other" ? unrelated : factory.call(row, **options)
    end
    table = {
      "fxo" => { "transport" => "http", "url" => "#{@base}/mcp", "serves" => "runner", "tools" => ["*"] },
      "other" => { "transport" => "stdio", "command" => "ruby", "tools" => ["echo"] },
    }
    host = Host.new(home: @home, config: Config.new(mcp_servers: table), serving_tools: true)
    first = McpTest.load(builtin: [Rho::Mcp], api_options: { host: host, configuration: { "servers" => table } })
    assert_equal "down", Rho::Mcp.entries.fetch("fxo").state
    assert_equal ["mcp__other__echo"], first.registry.names
    original = Rho::Mcp.connections.fetch("other")

    cli = self.cli
    cli.daemon = Object.new
    seen = []
    cli.define_singleton_method(:refresh_mcp) do |name|
      seen << name
      replacement = McpTest.load(builtin: [Rho::Mcp], api_options: { host: host, configuration: { "servers" => table } })
      first.committed.fetch(0).lifecycle.find { |hook| hook.event == :shutdown }.handler.call
      { "refreshed" => Rho::Mcp::NAME, "failures" => replacement.failures.map(&:to_h),
        "server" => Rho::Mcp.report.fetch("servers").find { |server| server.fetch("key") == name } }
    end
    login!(cli: cli)

    assert_equal ["fxo"], seen
    assert_equal "connected", Rho::Mcp.entries.fetch("fxo").state
    assert_equal %w[mcp__fxo__echo mcp__fxo__lookup], Rho::Mcp.entries.fetch("fxo").curated.announced.map(&:public_name)
    assert_same original, Rho::Mcp.connections.fetch("other")
    assert_equal 0, unrelated.closes
    assert_includes cli.out.string, "daemon refreshed fxo: 2 tools announced"
    Rho::Runner::ExecutionContext.with(Rho::Runner::ExecutionContext.new) do
      assert_equal "after login", Rho::Mcp.call("fxo", "echo", { "text" => "after login" }).content
    end
  end

  def test_failed_daemon_publication_keeps_the_successful_login_and_reports_refresh_separately
    cli = self.cli
    cli.daemon = Object.new
    cli.define_singleton_method(:refresh_mcp) do |_name|
      { "failures" => [{ "message" => "announcement refused" }] }
    end
    error = assert_raises(Rho::Error) { login!(cli: cli) }
    assert_match(/logged in; daemon refresh failed: announcement refused/, error.message)
    assert_equal :logged_in, @storage.status.state
    assert_includes cli.out.string, "logged in to fxo"
  end
end
