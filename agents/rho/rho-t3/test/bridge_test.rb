require_relative "test_helper"
require_relative "support/t3_server"

class BridgeTest < Minitest::Test
  include T3Test

  PROJECTION = "orchestration.getThreadProjection".freeze
  PAYLOAD = { "threadId" => "thread" }.freeze

  def test_project_directory_and_explicit_create_use_authenticated_finite_http
    rows = [{ "id" => "project", "title" => "Project", "workspaceRoot" => "/work/project" }]
    with_server(projects: rows) do |server, bridge|
      assert_equal rows, bridge.projects
      created = bridge.create_project(path: "/work/new", title: "new")
      assert_equal "/work/new", created.fetch("workspaceRoot")
      assert_equal %w[GET POST], server.http_requests.map { |row| row.fetch(:method) }
      assert server.http_requests.all? { |row| row.fetch(:authorization) == "Bearer fixture-bearer" }
      assert_equal "project.create", server.http_requests.last.fetch(:body).fetch("type")
      assert_empty server.rpc_requests
    end
  end

  def test_all_five_calls_authenticate_and_use_effect_request_exit_on_fresh_connections
    calls = {
      "orchestration.launchThread" => launch,
      PROJECTION => PAYLOAD,
      "orchestration.dispatchCommand" => { "type" => "run.interrupt", "commandId" => "command", "threadId" => "thread", "runId" => "run", "holdQueue" => true, "reason" => "stop" },
      "orchestration.getFullThreadDiff" => { "threadId" => "thread", "toTurnCount" => 1 },
      "orchestration.getTurnItem" => { "threadId" => "thread", "itemId" => "item" },
    }
    with_server do |server, bridge|
      calls.each { |method, payload| assert_equal({ "received" => payload }, bridge.call(method, payload)) }
      assert_equal calls.keys, server.rpc_requests.reject { |frame| frame.fetch("tag") == "server.getConfig" }.map { |frame| frame.fetch("tag") }
      assert_equal 5, server.rpc_requests.count { |frame| frame.fetch("tag") == "server.getConfig" }
      tickets = server.http_requests.select { |request| request.fetch(:path) == "/api/auth/websocket-ticket" }
      assert_equal 5, tickets.length
      tickets.each do |request|
        assert_equal "POST", request.fetch(:method)
        assert_equal "Bearer fixture-bearer", request.fetch(:authorization)
      end
      sockets = server.http_requests - tickets
      assert_equal 5, sockets.length
      sockets.each do |request|
        assert_equal "/ws?wsTicket=fixture-ticket&orchestrationProtocol=2", request.fetch(:path)
        assert_nil request.fetch(:authorization)
        assert_nil request.fetch(:compression)
      end
      server.rpc_requests.each do |frame|
        assert_equal [], frame.fetch("headers")
        refute frame.key?("jsonrpc")
      end
    end
  end

  def test_bridge_runs_on_an_ordinary_runner_worker_thread
    with_server do |_, bridge|
      worker = Thread.new { bridge.call(PROJECTION, PAYLOAD) }
      sleep(0.01) while worker.alive?
      assert_equal({ "received" => PAYLOAD }, worker.value)
    end
  end

  def test_invalid_method_and_payload_fail_before_network_io
    bridge = Rho::T3::Bridge.new(settings(url: "http://127.0.0.1:1"))
    assert_raises(Rho::T3::Error) { bridge.call("server.refreshProviders", {}) }
    assert_raises(Rho::T3::Error) { bridge.call(PROJECTION, {}) }
    assert_raises(Rho::T3::Error) { bridge.call(PROJECTION, { "threadId" => 1 }) }
    assert_raises(Rho::T3::Error) { bridge.call("orchestration.launchThread", launch.merge("runtimeMode" => "full-access")) }
    assert_raises(Rho::T3::Error) { bridge.call("orchestration.dispatchCommand", { "type" => "runtime-request.respond", "commandId" => "c", "threadId" => "t", "requestId" => "r", "decision" => "acceptAlways" }) }
  end

  def test_agent_discovery_reuses_the_configuration_handshake_without_a_second_request
    with_server do |server, bridge|
      config = bridge.call("server.getConfig", {})
      assert_equal 2, config.dig("environment", "orchestrationProtocolVersion")
      assert_equal T3Test.provider_catalog, config.fetch("providers")
      assert_equal ["server.getConfig"], server.rpc_requests.map { |frame| frame.fetch("tag") }
    end
  end

  def test_old_server_that_accepts_the_handshake_receives_no_business_rpc
    [1, nil].each do |version|
      with_server(version: version) do |server, bridge|
        error = assert_raises(Rho::T3::Error) { bridge.call("orchestration.launchThread", launch) }
        assert_equal Rho::T3::Bridge::INCOMPATIBLE, error.message
        assert_equal ["server.getConfig"], server.rpc_requests.map { |frame| frame.fetch("tag") }
      end
    end
    with_server(upgrade_status: 426) do |server, bridge|
      error = assert_raises(Rho::T3::Error) { bridge.call(PROJECTION, PAYLOAD) }
      assert_equal Rho::T3::Bridge::INCOMPATIBLE, error.message
      assert_empty server.rpc_requests
    end
  end

  def test_ticket_redirects_and_bad_credentials_are_not_retried_or_forwarded
    [307, 401].each do |status|
      with_server(ticket_status: status) do |server, bridge|
        assert_raises(Rho::T3::Error) { bridge.call(PROJECTION, PAYLOAD) }
        assert_equal 1, server.http_requests.length
        assert_empty server.rpc_requests
      end
    end
  end

  def test_lost_mutation_response_is_uncertain_and_never_retried
    with_server(behavior: ->(_, connection, _) { connection.close }) do |server, bridge|
      assert_raises(Rho::T3::Uncertain) { bridge.call("orchestration.launchThread", launch) }
      assert_equal 1, server.rpc_requests.count { |frame| frame.fetch("tag") == "orchestration.launchThread" }
      assert_equal 2, server.http_requests.length
    end
  end

  def test_effect_failure_defect_and_malformed_frames_do_not_expose_remote_material
    [
      ->(id) { { "_tag" => "Exit", "requestId" => id, "exit" => { "_tag" => "Failure", "cause" => [{ "_tag" => "Fail", "error" => "fixture-ticket fixture-bearer" }] } } },
      ->(_) { { "_tag" => "Defect", "defect" => "fixture-ticket fixture-bearer" } },
      ->(id) { { "_tag" => "Exit", "requestId" => "other-#{id}", "exit" => { "_tag" => "Success", "value" => "secret" } } },
      ->(_) { ["fixture-ticket fixture-bearer"] },
    ].each do |frame|
      behavior = ->(server, connection, request) { server.send_frame(connection, frame.call(request.fetch("id"))) }
      with_server(behavior: behavior) do |_, bridge|
        error = assert_raises(Rho::T3::Uncertain) { bridge.call(PROJECTION, PAYLOAD) }
        assert_equal Rho::T3::Bridge::UNAVAILABLE, error.message
        assert_nil error.cause
      end
    end
  end

  def test_batch_frames_and_both_heartbeat_directions
    behavior = lambda do |server, connection, request|
      server.send_frame(connection, [{ "_tag" => "Ping" }, { "_tag" => "Pong" }])
      pong = JSON.parse(connection.read.to_str)
      ping = JSON.parse(connection.read.to_str)
      server.success(connection, request, { "pong" => pong, "ping" => ping })
    end
    with_constant(:HEARTBEAT, 0.01) do
      with_server(behavior: behavior) do |_, bridge|
        assert_equal({ "pong" => { "_tag" => "Pong" }, "ping" => { "_tag" => "Ping" } }, bridge.call(PROJECTION, PAYLOAD))
      end
    end
  end

  def test_ticket_and_single_frame_and_fragmented_message_bounds
    with_server(ticket_body: "x" * (Rho::T3::Bridge::TICKET_LIMIT + 1)) do |server, bridge|
      assert_raises(Rho::T3::Error) { bridge.call(PROJECTION, PAYLOAD) }
      assert_empty server.rpc_requests
    end
    [false, true].each do |fragmented|
      behavior = lambda do |_, connection, _|
        size = Rho::T3::Bridge::LIMIT
        if fragmented
          connection.write_frame(Protocol::WebSocket::TextFrame.new(false, "x" * (size / 2)))
          connection.write_frame(Protocol::WebSocket::ContinuationFrame.new(true, "x" * (size / 2 + 1)))
        else
          connection.write("x" * (size + 1))
        end
        connection.flush
      end
      with_server(behavior: behavior) do |_, bridge|
        assert_raises(Rho::T3::Error) { bridge.call(PROJECTION, PAYLOAD) }
      end
    end
  end

  def test_rpc_timeout_closes_the_connection_without_retries
    with_constant(:RPC_TIMEOUT, 0.02) do
      with_server(behavior: ->(*) { sleep(60) }) do |server, bridge|
        error = assert_raises(Rho::T3::Uncertain) { bridge.call(PROJECTION, PAYLOAD) }
        assert_equal Rho::T3::Bridge::UNAVAILABLE, error.message
        assert_equal 1, server.rpc_requests.count { |frame| frame.fetch("tag") == PROJECTION }
      end
    end
  end

  def test_cancellation_interrupts_ticket_and_rpc_waits_but_cleanup_may_still_call
    [true, false].each do |ticket|
      context = Rho::Runner::ExecutionContext.new(run_public_id: "run", conversation_public_id: "conversation", task_key: "tool")
      options = ticket ? { stall_ticket: true } : { behavior: ->(*) { sleep(60) } }
      with_server(**options) do |server, bridge, task|
        cancel = task.async do
          sleep(0.01) until ticket ? server.http_requests.any? : server.rpc_requests.length == 2
          context.cancel
        end
        Rho::Runner::ExecutionContext.with(context) do
          assert_raises(Rho::Runner::ExecutionContext::Cancelled) { bridge.call(PROJECTION, PAYLOAD) }
        end
      ensure
        cancel&.stop
      end
      with_server do |_, bridge|
        Rho::Runner::ExecutionContext.with(context) do
          assert_equal({ "received" => PAYLOAD }, bridge.call(PROJECTION, PAYLOAD, cancelled: false))
        end
      end
    end
  end

  private

  def launch
    { "commandId" => "command", "threadId" => "thread", "projectId" => "project", "title" => "Fix parser",
      "modelSelection" => { "instanceId" => "provider", "model" => "fixture-model" }, "runtimeMode" => "approval-required", "interactionMode" => "default",
      "workspaceStrategy" => { "type" => "root" }, "initialMessage" => { "messageId" => "message", "text" => "Fix parser", "attachments" => [] } }
  end

  def with_server(behavior: nil, **options)
    Sync do |task|
      server = Server.new(**options, &behavior).start(task)
      yield server, Rho::T3::Bridge.new(settings(url: server.url)), task
    ensure
      server&.stop
    end
  end

  def with_constant(name, value)
    owner = Rho::T3::Bridge
    original = owner.const_get(name)
    owner.send(:remove_const, name)
    owner.const_set(name, value)
    yield
  ensure
    owner.send(:remove_const, name)
    owner.const_set(name, original)
  end
end
