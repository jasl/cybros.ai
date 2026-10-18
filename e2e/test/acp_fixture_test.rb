require "minitest/autorun"
require "json"
require "fileutils"
require "tmpdir"
require_relative "../support/acp_client"

# THE TWO ACP FIXTURES PINNED AGAINST EACH OTHER OVER STDIO: `E2E::AcpClient`, the scripted CLIENT
# the agent lane drives `rho acp` with, and `support/acp_fixture/agent.rb`, the scripted
# AGENT the client lane hands `delegate_agent`. Neither shares the gem's
# `Wire`/`Connection`: two independent implementations of the facts sheet's framing, so a defect in
# either is a red here and not a diagnosis at the end of a world. No world, no daemon: a child
# `ruby` per case in its own process group, stderr to a file. Each argv mode of the agent is one
# case.
class AcpFixtureTest < Minitest::Test
  AGENT = File.expand_path("../support/acp_fixture/agent.rb", __dir__)
  Methods = E2E::AcpClient::Methods

  def setup
    @dir = Dir.mktmpdir("acp-fixture")
    @clients = []
  end

  def teardown
    @clients.each(&:close)
    FileUtils.rm_rf(@dir)
  end

  def spawn(mode, *extra, **options)
    client = E2E::AcpClient.spawn([Gem.ruby, AGENT, "--mode", mode, *extra],
      stderr: File.join(@dir, "#{mode}-#{@clients.length}.stderr"), **options)
    @clients << client
    client
  end

  def ready(mode, *extra, **options)
    client = spawn(mode, *extra, **options)
    client.initialize_agent
    client
  end

  # THE REGISTRY'S SHAPE: one `initialize` line in, ONE line out, `protocolVersion` 1, nothing else
  # on stdout.
  def test_one_initialize_line_in_is_one_json_line_out_and_nothing_else
    client = spawn("plain")
    client.write_raw(%({"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":1}}))

    result = client.await(0, timeout: 10)
    assert_equal 1, result.fetch("protocolVersion")
    assert_equal "acp-fixture-agent", result.dig("agentInfo", "name")
    assert_equal false, result.dig("agentCapabilities", "loadSession")
    assert_instance_of Array, result.fetch("authMethods")
    assert client.quiet?(0.3), "nothing but the one response on stdout"
    assert_equal 1, client.stdout_lines.length
    assert_equal({ "jsonrpc" => "2.0", "id" => 0, "result" => result }, JSON.parse(client.stdout_lines.first))
  end

  def test_the_client_hands_the_protocol_version_and_its_capabilities_and_the_agent_remembers_them
    client = ready("plain")
    assert_equal Methods::PROTOCOL_VERSION, client.protocol_version
    assert_equal Methods::BASELINE_CLIENT_CAPABILITIES, client.client_capabilities

    session = client.new_session(cwd: @dir).fetch("sessionId")
    turn = client.prompt(session, "client?")
    seen = JSON.parse(turn.text)
    assert_equal "e2e-acp-client", seen.dig("clientInfo", "name")
    assert_equal Methods::BASELINE_CLIENT_CAPABILITIES, seen.fetch("clientCapabilities")
    assert_equal 1, seen.fetch("protocolVersion")
  end

  def test_plain_echoes_a_prompt_in_chunks_of_one_message_id_and_ends_the_turn
    client = ready("plain")
    first = client.new_session(cwd: @dir).fetch("sessionId")
    second = client.new_session(cwd: @dir).fetch("sessionId")
    refute_equal first, second

    turn = client.prompt(first, "hello there")
    assert_equal Methods::StopReason::END_TURN, turn.stop_reason
    assert_equal "echo: hello there", turn.text
    chunks = turn.updates.select { |update| update.fetch("sessionUpdate") == Methods::SessionUpdate::AGENT_MESSAGE_CHUNK }
    assert_equal 2, chunks.length
    assert_equal 1, chunks.map { |chunk| chunk.fetch("messageId") }.uniq.length
    assert chunks.all? { |chunk| chunk.dig("content", "type") == "text" }
    assert turn.updates.all? { |update| update.fetch("sessionId") == first }

    again = client.prompt(first, "again")
    assert_equal "echo: again", again.text
    refute_equal chunks.first.fetch("messageId"), again.updates.first.fetch("messageId"), "a new turn, a new message id"

    session_turn = client.prompt(second, "session?")
    facts = JSON.parse(session_turn.text)
    assert_equal [@dir, 0], [facts.fetch("cwd"), facts.fetch("mcpServers")]
  end

  def test_the_agent_refuses_what_the_spec_refuses
    client = ready("plain")
    error = assert_raises(E2E::AcpClient::RemoteError) { client.new_session(cwd: "relative/path") }
    assert_equal Methods::ErrorCode::INVALID_PARAMS, error.code

    error = assert_raises(E2E::AcpClient::RemoteError) { client.prompt("no-such-session", "x") }
    assert_equal Methods::ErrorCode::RESOURCE_NOT_FOUND, error.code

    error = assert_raises(E2E::AcpClient::RemoteError) { client.request("session/list", {}) }
    assert_equal Methods::ErrorCode::METHOD_NOT_FOUND, error.code
    error = assert_raises(E2E::AcpClient::RemoteError) { client.request("_custom/thing", {}) }
    assert_equal Methods::ErrorCode::METHOD_NOT_FOUND, error.code

    client.notify("_custom/note", { "ignored" => true })
    client.write_raw("this is not json")
    client.write_raw("[1,2]")
    session = client.new_session(cwd: @dir).fetch("sessionId")
    assert_equal "echo: alive", client.prompt(session, "alive").text
    answers = client.stray_failures.map { |failure| [failure.fetch("id"), failure.dig("error", "code")] }
    assert_equal [[nil, Methods::ErrorCode::PARSE], [nil, Methods::ErrorCode::INVALID_REQUEST]], answers
  end

  def test_a_second_prompt_on_a_busy_session_is_invalid_and_session_close_drops_the_session
    client = ready("sleep")
    session = client.new_session(cwd: @dir).fetch("sessionId")
    id = client.start_prompt(session, "sleep 2")
    sleep 0.3
    error = assert_raises(E2E::AcpClient::RemoteError) { client.prompt(session, "sleep 1") }
    assert_equal Methods::ErrorCode::INVALID_REQUEST, error.code
    client.cancel(session)
    assert_equal Methods::StopReason::CANCELLED, client.finish_prompt(id, timeout: 5).stop_reason

    assert_equal({}, client.close_session(session))
    error = assert_raises(E2E::AcpClient::RemoteError) { client.prompt(session, "x") }
    assert_equal Methods::ErrorCode::RESOURCE_NOT_FOUND, error.code
  end

  # PERMISSION: the tool call goes out first, then the request; the
  # scripted policy answers; the update and the text say what happened.
  def test_permission_allowed_rejected_and_the_cancelled_outcome
    client = ready("permission")
    session = client.new_session(cwd: @dir).fetch("sessionId")

    turn = client.prompt(session, "run npm test")
    assert_equal Methods::StopReason::END_TURN, turn.stop_reason
    request = turn.permissions.fetch(0)
    assert_equal session, request.dig("params", "sessionId")
    tool_call = request.dig("params", "toolCall")
    assert_equal({ "command" => "npm test" }, tool_call.fetch("rawInput"))
    assert_equal Methods::ToolKind::EXECUTE, tool_call.fetch("kind")
    assert_equal %w[allow_once allow_always reject_once],
      request.dig("params", "options").map { |option| option.fetch("kind") }
    assert_equal({ "outcome" => { "outcome" => "selected", "optionId" => "allow" } }, request.fetch("answer"))
    kinds = turn.updates.map { |update| update.fetch("sessionUpdate") }
    assert_equal %w[tool_call tool_call_update tool_call_update agent_message_chunk], kinds
    statuses = turn.updates.first(3).map { |update| update["status"] }
    assert_equal %w[pending in_progress completed], statuses
    assert_equal tool_call.fetch("toolCallId"), turn.updates.first.fetch("toolCallId")
    assert_equal "allowed:allow", turn.text
    assert turn.updates.first.fetch("toolCallId").start_with?(session), "tool call ids are session-scoped"

    rejecting = ready("permission", policy: { permission: :reject })
    session = rejecting.new_session(cwd: @dir).fetch("sessionId")
    turn = rejecting.prompt(session, "edit /tmp/x.rb")
    assert_equal "rejected:reject", turn.text
    assert_equal %w[pending failed], turn.updates.first(2).map { |update| update["status"] }
    edit = turn.permissions.fetch(0).dig("params", "toolCall")
    assert_equal [Methods::ToolKind::EDIT, [{ "path" => "/tmp/x.rb" }]], [edit.fetch("kind"), edit.fetch("locations")]

    cancelling = ready("permission", policy: { permission: :cancel })
    session = cancelling.new_session(cwd: @dir).fetch("sessionId")
    turn = cancelling.prompt(session, "run ls")
    assert_equal "cancelled", turn.text
    assert_equal Methods::StopReason::END_TURN, turn.stop_reason, "a cancelled outcome alone does not cancel the turn"
  end

  def test_permission_over_many_lines_asks_once_per_line_and_a_callable_policy_sees_each
    seen = []
    client = ready("permission", policy: { permission: lambda { |params|
      seen << params.dig("toolCall", "rawInput")
      option = params.fetch("options").find { |o| o.fetch("kind") == (seen.length.odd? ? "allow_once" : "reject_once") }
      { "outcome" => { "outcome" => "selected", "optionId" => option.fetch("optionId") } }
    } })
    session = client.new_session(cwd: @dir).fetch("sessionId")

    turn = client.prompt(session, "run rm -rf /\nedit /etc/hosts\nrun npm test")
    assert_equal [{ "command" => "rm -rf /" }, { "path" => "/etc/hosts" }, { "command" => "npm test" }], seen
    assert_equal "allowed:allow\nrejected:reject\nallowed:allow", turn.text
    assert_equal 3, turn.permissions.length
  end

  def test_id_only_requests_carry_the_tool_call_id_alone_and_the_earlier_update_carries_the_shape
    client = ready("id_only")
    session = client.new_session(cwd: @dir).fetch("sessionId")

    turn = client.prompt(session, "run npm test")
    tool_call = turn.permissions.fetch(0).dig("params", "toolCall")
    assert_equal ["toolCallId"], tool_call.keys
    first = turn.updates.first
    assert_equal ["tool_call", tool_call.fetch("toolCallId"), { "command" => "npm test" }, "execute"],
      [first.fetch("sessionUpdate"), first.fetch("toolCallId"), first.fetch("rawInput"), first.fetch("kind")]
    assert_equal "allowed:allow", turn.text
  end

  # CANCEL, THE CLIENT'S: `session/cancel` mid-sleep → the agent stops and
  # answers `cancelled`; the ticks already sent stay.
  def test_session_cancel_stops_a_sleeping_turn_and_the_prompt_answers_cancelled
    client = ready("sleep")
    session = client.new_session(cwd: @dir).fetch("sessionId")
    id = client.start_prompt(session, "sleep 10")
    client.await_update(session, "agent_message_chunk", timeout: 5)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    client.cancel(session)

    turn = client.finish_prompt(id, timeout: 5)
    assert_equal Methods::StopReason::CANCELLED, turn.stop_reason
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 3
    assert_includes turn.text, "tick"
  end

  def test_ignore_cancel_finishes_its_sleep_regardless_and_answers_end_turn
    client = ready("ignore_cancel")
    session = client.new_session(cwd: @dir).fetch("sessionId")
    id = client.start_prompt(session, "sleep 1")
    client.cancel(session)
    client.cancel_request(id)

    turn = client.finish_prompt(id, timeout: 10)
    assert_equal Methods::StopReason::END_TURN, turn.stop_reason
  end

  # THE GENERIC CANCEL, THE CLIENT'S: `$/cancel_request` on the prompt's id
  # → the agent answers -32800 for that id (the cancellation page's rule).
  def test_cancel_request_on_a_running_prompt_is_answered_request_cancelled
    client = ready("sleep")
    session = client.new_session(cwd: @dir).fetch("sessionId")
    id = client.start_prompt(session, "sleep 10")
    client.await_update(session, "agent_message_chunk", timeout: 5)
    client.cancel_request(id)

    error = assert_raises(E2E::AcpClient::RemoteError) { client.finish_prompt(id, timeout: 5) }
    assert_equal [Methods::ErrorCode::REQUEST_CANCELLED, "Request cancelled"], [error.code, error.message]
    assert_equal "echo: still here", client.prompt(session, "still here").text, "the session lives on"
  end

  # THE CASCADE, THE AGENT'S: a permission request held open by the
  # client, then `session/cancel` → the agent sends `$/cancel_request`
  # for its own outstanding request, the client answers -32800, the
  # prompt answers `cancelled`.
  def test_session_cancel_while_a_permission_request_is_held_cascades_a_cancel_request_from_the_agent
    client = ready("permission", policy: { permission: :hold, cancel_answers_held: false })
    session = client.new_session(cwd: @dir).fetch("sessionId")
    id = client.start_prompt(session, "run sleep 5")
    held = client.await_held(timeout: 5)
    assert_equal "session/request_permission", held.fetch("method")
    client.cancel(session)

    turn = client.finish_prompt(id, timeout: 5)
    assert_equal Methods::StopReason::CANCELLED, turn.stop_reason
    assert_equal [held.fetch("id")], client.cancel_notices
    assert_equal({ "code" => -32800, "message" => "Request cancelled" }, held.fetch("answer"))
    assert_equal "cancelled", turn.text
  end

  # THE SPEC'S OTHER HALF: when the CLIENT cancels, it answers every
  # pending permission request `cancelled` itself (the default).
  def test_session_cancel_answers_held_permission_requests_cancelled_by_default
    client = ready("permission", policy: { permission: :hold })
    session = client.new_session(cwd: @dir).fetch("sessionId")
    id = client.start_prompt(session, "run sleep 5")
    held = client.await_held(timeout: 5)
    client.cancel(session)

    turn = client.finish_prompt(id, timeout: 5)
    assert_equal Methods::StopReason::CANCELLED, turn.stop_reason
    assert_equal({ "outcome" => { "outcome" => "cancelled" } }, held.fetch("answer"))
    assert_empty client.cancel_notices
  end

  def test_die_exits_mid_turn_with_its_status_and_the_client_sees_the_end
    client = ready("die")
    session = client.new_session(cwd: @dir).fetch("sessionId")
    id = client.start_prompt(session, "go")

    assert_raises(E2E::AcpClient::Closed) { client.finish_prompt(id, timeout: 5) }
    status = client.wait_exit(timeout: 5)
    assert_equal 3, status.exitstatus
    refute client.alive?
    assert_includes client.stderr, "fixture agent: dying"
    assert_includes client.updates.map { |update| update.dig("update", "sessionUpdate") }, "agent_message_chunk"
  end

  def test_auth_required_gates_session_new_behind_authenticate
    client = ready("auth_required")
    assert_equal [{ "id" => "fixture-login", "name" => "Fixture login", "description" => "Logs the fixture in" }],
      client.auth_methods
    error = assert_raises(E2E::AcpClient::RemoteError) { client.new_session(cwd: @dir) }
    assert_equal Methods::ErrorCode::AUTH_REQUIRED, error.code
    error = assert_raises(E2E::AcpClient::RemoteError) { client.authenticate("no-such-method") }
    assert_equal Methods::ErrorCode::INVALID_PARAMS, error.code

    assert_equal({}, client.authenticate("fixture-login"))
    session = client.new_session(cwd: @dir).fetch("sessionId")
    assert_equal "echo: in", client.prompt(session, "in").text
  end

  def test_terminal_auth_only_names_a_terminal_method_and_never_opens_a_session
    client = ready("terminal_auth_only")
    method = client.auth_methods.fetch(0)
    assert_equal ["login", "terminal", ["login"]], [method.fetch("id"), method.fetch("type"), method.fetch("args")]
    error = assert_raises(E2E::AcpClient::RemoteError) { client.authenticate("login") }
    assert_equal Methods::ErrorCode::INVALID_PARAMS, error.code
    error = assert_raises(E2E::AcpClient::RemoteError) { client.new_session(cwd: @dir) }
    assert_equal Methods::ErrorCode::AUTH_REQUIRED, error.code
  end

  def test_elicit_asks_a_form_and_the_answer_or_the_decline_reaches_the_text
    client = ready("elicit", policy: { elicitation: ->(_params) { { "action" => "accept", "content" => { "answer" => "blue" } } } })
    session = client.new_session(cwd: @dir).fetch("sessionId")
    turn = client.prompt(session, "colour?")
    request = turn.elicitations.fetch(0)
    assert_equal ["form", session], [request.dig("params", "mode"), request.dig("params", "sessionId")]
    assert_equal %w[answer], request.dig("params", "requestedSchema", "required")
    assert_equal "answer:blue", turn.text

    declining = ready("elicit")
    session = declining.new_session(cwd: @dir).fetch("sessionId")
    assert_equal "elicitation:decline", declining.prompt(session, "colour?").text
  end

  def test_model_option_lists_a_model_config_option_and_set_config_option_moves_it
    client = ready("model_option")
    opened = client.new_session(cwd: @dir)
    session = opened.fetch("sessionId")
    option = opened.fetch("configOptions").fetch(0)
    assert_equal ["model", "model", "select", "fx-small"],
      [option.fetch("id"), option.fetch("category"), option.fetch("type"), option.fetch("currentValue")]
    assert_equal %w[fx-small fx-large], option.fetch("options").map { |o| o.fetch("value") }
    assert_equal "model:fx-small", client.prompt(session, "which?").text

    moved = client.set_config_option(session, "model", "fx-large")
    assert_equal "fx-large", moved.fetch("configOptions").fetch(0).fetch("currentValue")
    assert_equal "model:fx-large", client.prompt(session, "which?").text
    error = assert_raises(E2E::AcpClient::RemoteError) { client.set_config_option(session, "model", "fx-none") }
    assert_equal Methods::ErrorCode::INVALID_PARAMS, error.code
    error = assert_raises(E2E::AcpClient::RemoteError) { client.set_config_option(session, "temperature", 1) }
    assert_equal Methods::ErrorCode::INVALID_PARAMS, error.code

    plain = ready("plain")
    session = plain.new_session(cwd: @dir).fetch("sessionId")
    error = assert_raises(E2E::AcpClient::RemoteError) { plain.set_config_option(session, "model", "x") }
    assert_equal Methods::ErrorCode::METHOD_NOT_FOUND, error.code
  end

  def test_the_agent_answers_the_protocol_version_it_is_told_to
    client = spawn("plain", "--protocol-version", "2")
    result = client.initialize_agent
    assert_equal 2, result.fetch("protocolVersion")
  end

  def test_eof_on_stdin_ends_the_agent_with_status_zero_and_the_group_is_gone
    client = ready("plain")
    pid = client.pid
    client.close

    assert_equal 0, client.exit_status.exitstatus
    assert_raises(Errno::ESRCH) { Process.kill(0, -pid) }
  end

  # THE GEM'S OWN CONNECTION AS THE CLIENT (the shape `delegate_agent`
  # uses), by load path, over the same agent: the two
  # implementations agree on the wire.
  def test_the_gems_connection_drives_the_fixture_agent_as_a_client
    lib = File.expand_path("../../agents/rho/rho/lib", __dir__)
    $LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
    require "rho/acp"
    stderr = File.join(@dir, "gem-client.stderr")
    io = IO.popen([Gem.ruby, AGENT, "--mode", "permission"], "r+", err: stderr, pgroup: true)
    pid = io.pid
    connection = Rho::Acp::Connection.new(Rho::Acp::Wire.new(input: io, output: io))
    drainer = Thread.new do
      connection.run do |event|
        next unless event.is_a?(Rho::Acp::Connection::Inbound)

        option = event.params.fetch("options").find { |o| o.fetch("kind") == "allow_once" }
        event.respond({ "outcome" => { "outcome" => "selected", "optionId" => option.fetch("optionId") } })
      end
    end

    initialized = connection.request("initialize",
      { "protocolVersion" => 1, "clientCapabilities" => {}, "clientInfo" => { "name" => "gem", "version" => "0" } })
      .wait(timeout: 10)
    assert_equal 1, initialized.fetch("protocolVersion")
    session = connection.request("session/new", { "cwd" => @dir, "mcpServers" => [] }).wait(timeout: 5).fetch("sessionId")
    prompt = connection.request("session/prompt",
      { "sessionId" => session, "prompt" => [{ "type" => "text", "text" => "run npm test" }] }).wait(timeout: 5)
    assert_equal({ "stopReason" => "end_turn" }, prompt)
  ensure
    connection&.close
    drainer&.join(2)
    if pid
      begin
        Process.kill("KILL", -pid)
      rescue Errno::ESRCH
        nil
      end
      io.close unless io.closed?
    end
  end
end
