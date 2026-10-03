require "test_helper"

# THE REAL CHILD: the gem's stdio transport re-parented
# — its own process group, the REPLACED environment, the watcher, the
# ladder, two concurrent calls serialized, a cancelled call → the group
# KILLED and reaped inside the runner's grace → the next call restarts, a server that never answers
# `initialize` costing its own tools within `startup_timeout_ms`, the
# token in a stderr tail redacted from the sentence. The four overridden
# members are the coupling to `mcp ~> 1.6.0`: a rename fails here, loudly.
class StdioTransportTest < Minitest::Test
  include McpTest::Helpers

  def setup
    @connections = []
  end

  def teardown
    @connections.each { |c| c.close rescue nil }
  end

  def open_connection(row = McpTest.real_row, log: nil)
    Rho::Mcp::Connection.new(row, log: log, transport_factory: McpTest.real_transport_factory,
      redact: Rho::Runner::Redact.new(row.secrets)).tap { |c| @connections << c }
  end

  def transport_of(connection) = connection.instance_variable_get(:@transport)

  def call(connection, raw, args = {})
    Rho::Runner::ExecutionContext.with(Rho::Runner::ExecutionContext.new(task_key: "t1")) do
      connection.call_tool(raw, args, public_name: "mcp__fx__#{raw}")
    end
  end

  def test_the_child_runs_in_its_own_group_with_the_replaced_environment_and_lists_its_tools
    connection = open_connection.open!
    transport = transport_of(connection)
    assert_kind_of Rho::Mcp::StdioTransport, transport
    assert_equal %w[echo env hang exit whisper reveal], connection.tools.map(&:name)
    echo = connection.tools.fetch(0)
    assert_equal({ "$schema" => "https://json-schema.org/draft/2020-12/schema", "properties" => { "text" => { "type" => "string" } },
                   "required" => ["text"], "type" => "object" }, echo.input_schema, "the schema as the gem lists it")
    assert_equal ["fx-server", "1.0.0"], [connection.server_name, connection.server_version]
    refute_equal Process.pid, transport.group_pid
    assert_equal transport.group_pid, Process.getpgid(transport.pid), "the child is in the guard's group, not ours"
    refute_equal Process.getpgrp, transport.group_pid
    assert process_group_alive?(transport.group_pid)

    keys = call(connection, "env").content.split("\n")
    assert_includes keys, "FX_TOKEN"
    assert_includes keys, "BUNDLE_GEMFILE", "the row's env rides"
    assert_includes keys, "PATH"
    # RUBYOPT/BUNDLE_* are the child's OWN `bundle exec`'s; the pin is on
    # what rho withheld: its credentials and every credential-shaped name.
    %w[RHO_ACCESS_PASSPHRASE OPENROUTER_API_KEY RHO_HOME].each { |name| refute_includes keys, name }
    refute(keys.any? { |name| name.match?(Rho::Runner::Secrets::CREDENTIAL_SHAPED) && name != "FX_TOKEN" },
      "a credential-shaped name of ours reached the child: #{keys.grep(Rho::Runner::Secrets::CREDENTIAL_SHAPED).inspect}")
    assert_equal "hello", call(connection, "echo", { "text" => "hello" }).content
  end

  def test_the_ladder_ends_the_group_and_reaps_it
    connection = open_connection.open!
    pgid = transport_of(connection).group_pid
    connection.close
    assert await(seconds: 5) { !process_group_alive?(pgid) }, "the group #{pgid} outlived the ladder"
    refute_predicate connection, :connected?
  end

  def test_two_concurrent_calls_on_one_connection_are_both_answered
    connection = open_connection.open!
    answers = Queue.new
    threads = %w[one two].map do |word|
      Thread.new { answers << call(connection, "echo", { "text" => word }).content }
    end
    threads.each { |t| t.join(10) }
    assert_equal %w[one two], 2.times.map { answers.pop }.sort
  end

  def test_a_cancelled_call_kills_and_reaps_the_group_and_the_next_call_restarts_with_a_new_pid
    connection = open_connection.open!
    first = transport_of(connection)
    context = Rho::Runner::ExecutionContext.new(task_key: "t2")
    answer = :unset
    worker = Thread.new do
      Rho::Runner::ExecutionContext.with(context) do
        answer = connection.call_tool("hang", {}, public_name: "mcp__fx__hang")
      rescue Rho::Runner::ExecutionContext::Cancelled => error
        answer = error
      end
    end
    sleep 0.5
    assert worker.alive?
    context.cancel(:deadline)
    # THE RUNNER'S GRACE: the pool abandons a handler that has not returned
    # two seconds after the clamp, and the claim's park is smaller still —
    # the KILL and the reap must fit inside it, or the sweep writes
    # `uncertain` for a runner that was alive the whole time.
    worker.join(Rho::Runner::Pool::CANCELLATION_GRACE_SECONDS)
    refute worker.alive?, "the worker did not return inside the runner's grace"
    assert_kind_of Rho::Runner::ExecutionContext::Cancelled, answer, "the call returns through the runner's checkpoint"
    assert_equal :deadline, answer.reason
    assert await(seconds: 5) { !process_group_alive?(first.group_pid) }, "the poisoned group survived"
    assert_match(/\Akilled after a timed-out call \(mcp__fx__hang\) at /, connection.down)

    result = call(connection, "echo", { "text" => "back" })
    assert_match(/\Anote: mcp server fx had been stopped after a timed-out call \(mcp__fx__hang\) and was restarted for this call; any state it held is gone\nback\z/, result.content)
    refute_equal first.pid, transport_of(connection).pid
    assert process_group_alive?(transport_of(connection).group_pid)
  end

  def test_death_under_a_call_fails_naming_the_exit_with_the_token_redacted_and_the_next_call_restarts
    connection = open_connection.open!
    first = transport_of(connection)
    error = assert_raises(Rho::Mcp::ServerGone) { call(connection, "exit") }
    assert_equal "mcp server fx exited (status 3) during mcp__fx__exit; its stderr ended: fixture: leaving now (•••); " \
                 "the next call restarts it", error.message
    refute_includes error.message, McpTest::FX_TOKEN
    assert await(seconds: 5) { !process_group_alive?(first.group_pid) }
    assert_match(/\Aexited \(status 3\) at /, connection.down)
    result = call(connection, "echo", { "text" => "again" })
    assert_match(/\Anote: mcp server fx had exited \(status 3 at \d\d:\d\d:\d\d; its stderr ended: fixture: leaving now \(•••\)\) and was restarted for this call; any state it held is gone\nagain\z/, result.content)
    refute_equal first.pid, transport_of(connection).pid
  end

  def test_the_token_a_server_whispers_to_stderr_never_reaches_a_sentence_or_the_log
    log = []
    logger = Object.new
    %i[debug info warn error].each { |level| logger.define_singleton_method(level) { |event, **f| log << [level, event, f] } }
    connection = open_connection(McpTest.real_row, log: Rho::Mcp::RedactingLog.new(logger, Rho::Runner::Redact.new([McpTest::FX_TOKEN])))
    connection.open!
    call(connection, "whisper")
    sleep 0.2
    tail = transport_of(connection).stderr_tail
    assert_includes tail, McpTest::FX_TOKEN, "the raw tail holds the token — the redaction is on every reader"
    assert_equal "fixture: the token is •••", Rho::Mcp::Mapping.capped_tail(Rho::Runner::Redact.new([McpTest::FX_TOKEN]).call(tail))
    error = assert_raises(Rho::Mcp::ServerGone) { call(connection, "exit") }
    refute_includes error.message, McpTest::FX_TOKEN
    refute(log.any? { |entry| entry.inspect.include?(McpTest::FX_TOKEN) }, "the token reached the log: #{log.inspect}")
  end

  # The model-read surface over the REAL child: the token
  # the child holds in its environment comes back in a result's text and
  # structure and in a resource's body — and reaches nothing past
  # rho-mcp unredacted.
  def test_the_token_a_server_answers_in_a_result_or_a_resource_reaches_the_model_redacted
    connection = open_connection
    connection.open!
    result = call(connection, "reveal")
    assert_equal "the token is •••", result.content
    assert_equal({ "token" => "•••" }, result.structured_content)
    assert_equal "secret=•••", connection.load_resource("fx://secret", name: "fx-secret").content
  end

  def test_a_server_that_never_speaks_costs_its_own_bound_and_leaves_no_group
    row = McpTest.real_row(args: ["sleep"], startup_timeout_ms: 1500)
    connection = open_connection(row)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    error = assert_raises(Rho::Mcp::Unavailable) { connection.open! }
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    assert_equal "did not answer within 1500 ms", error.message
    assert_operator elapsed, :<, 10, "the bound was not enforced (#{elapsed.round(1)} s)"
    refute_predicate connection, :connected?
  end

  def test_a_server_that_crashes_at_startup_names_its_exit_and_tail_redacted
    connection = open_connection(McpTest.real_row(args: ["crash"], startup_timeout_ms: 5000))
    error = assert_raises(Rho::Mcp::Unavailable) { connection.open! }
    assert_equal "exited (status 7) during startup; its stderr ended: fixture: cannot start (•••)", error.message
  end

  def test_a_command_that_does_not_exist_is_a_spawn_failure_not_a_hang
    row = Rho::Mcp::Settings.parse({ "nope" => { "transport" => "stdio", "command" => "/nonexistent/mcp-server", "tools" => "*" } },
      env: {}).fetch(0)
    connection = open_connection(row)
    error = assert_raises(Rho::Mcp::Unavailable) { connection.open! }
    assert_match(/\Acould not connect: Failed to spawn server process: /, error.message)
  end

  def test_the_four_overridden_members_exist_on_the_pinned_gem
    %i[start close send_notification].each do |name|
      assert MCP::Client::Stdio.public_method_defined?(name), "mcp #{MCP::VERSION} lost public ##{name}"
      assert_equal Rho::Mcp::StdioTransport, Rho::Mcp::StdioTransport.instance_method(name).owner
    end
    assert MCP::Client::Stdio.private_method_defined?(:ensure_running!), "mcp #{MCP::VERSION} lost #ensure_running!"
    assert_equal Rho::Mcp::StdioTransport, Rho::Mcp::StdioTransport.instance_method(:ensure_running!).owner
    assert_includes MCP::Client::Stdio.instance_method(:initialize).parameters, [:key, :read_timeout]
    assert_match(/\A1\.6\./, MCP::VERSION)
  end
end
