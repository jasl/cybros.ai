require "test_helper"

class MountTest < Minitest::Test
  def setup
    @transports = []
    transports = @transports
    Rho::Mcp.transport_factory = lambda do |_row, **|
      McpTest::FakeTransport.new(McpTest::FixtureServer.build(tools: %w[echo lookup])).tap { |transport| transports << transport }
    end
  end

  def teardown = Rho::Mcp.reset!

  def prepare(tools: %w[echo lookup])
    Rho::Mcp.settings_table = { "fx" => { "transport" => "stdio", "command" => "ruby", "tools" => tools } }
    result = Rho::Runner::Extensions::Loader.call(builtin: [Rho::Mcp])
    assert_predicate result, :ok?, result.failures.inspect
    result.committed.fetch(0)
  end

  def start(api) = api.lifecycle.find { |hook| hook.event == :startup }.handler.call
  def stop(api) = api.lifecycle.find { |hook| hook.event == :shutdown }.handler.call

  def test_a_prepared_candidate_keeps_the_live_report_and_captured_tools_on_the_old_mount
    first = prepare
    start(first)
    old = Rho::Mcp.entries.fetch("fx")
    klass = old.curated.classes.find { |tool| tool::RAW_NAME == "echo" }

    candidate = prepare(tools: ["lookup"])
    assert_same old, Rho::Mcp.entries.fetch("fx")
    assert_equal [0, 0], @transports.map(&:closes)
    start(candidate)
    refute_same old.connection, Rho::Mcp.entries.fetch("fx").connection
    Rho::Runner::ExecutionContext.with(Rho::Runner::ExecutionContext.new) do
      assert_equal "captured", klass.new(env: nil).call({ "text" => "captured" }).content
    end
    assert_equal 1, @transports.first.requests.count { |request| request[:method] == "tools/call" }
    assert_equal 0, @transports.last.requests.count { |request| request[:method] == "tools/call" }

    stop(first)
    assert_equal [1, 0], @transports.map(&:closes)
    stop(candidate)
    assert_equal [1, 1], @transports.map(&:closes)
    assert_empty Rho::Mcp.entries
  end

  def test_discarding_an_unstarted_candidate_does_not_close_the_reused_active_connection
    first = prepare
    start(first)
    old = Rho::Mcp.entries.fetch("fx").connection
    candidate = prepare
    stop(candidate)
    assert_same old, Rho::Mcp.connections.fetch("fx")
    assert_equal [0], @transports.map(&:closes)
  end

  def test_failed_activation_after_publication_restores_the_previous_live_mount
    first = prepare
    start(first)
    old = Rho::Mcp.entries.fetch("fx")
    candidate = prepare(tools: ["lookup"])
    start(candidate)
    stop(candidate)
    assert_same old, Rho::Mcp.entries.fetch("fx")
    assert_equal [0, 1], @transports.map(&:closes)
    Rho::Runner::ExecutionContext.with(Rho::Runner::ExecutionContext.new) do
      assert_equal "restored", Rho::Mcp.call("fx", "echo", { "text" => "restored" }).content
    end
  end

  def test_successive_replacements_keep_a_connection_until_its_last_captured_owner_retires
    first = prepare
    start(first)
    klass = Rho::Mcp.entries.fetch("fx").curated.classes.find { |tool| tool::RAW_NAME == "echo" }
    middle = prepare
    start(middle)
    latest = prepare(tools: ["lookup"])
    start(latest)
    stop(middle)
    assert_equal [0, 0], @transports.map(&:closes)
    Rho::Runner::ExecutionContext.with(Rho::Runner::ExecutionContext.new) do
      assert_equal "old call", klass.new(env: nil).call({ "text" => "old call" }).content
    end
    stop(first)
    assert_equal [1, 0], @transports.map(&:closes)
  end

  def test_explicit_cleanup_attempts_every_connection_and_reports_only_safe_failure_facts
    first = Object.new
    first.define_singleton_method(:close) { raise IOError, "transport included a secret token" }
    closed = []
    second = Object.new
    second.define_singleton_method(:close) { closed << true }
    error = assert_raises(Rho::Mcp::Error) { Rho::Mcp.close_all([first, second]) }
    assert_equal [true], closed
    assert_equal "MCP connection cleanup failed (IOError)", error.message
  end
end
