class RhoAcpAgentTest
  # (i) THE REGISTRY'S SHAPE: one `initialize` line in, ONE line out, the document as the design
  # fixes it — `authMethods` non-empty — and nothing else on stdout; EOF exits 0. With
  # `auth.terminal` and `elicitation.form` advertised the terminal method joins the list and nothing
  # else moves; a client's higher `protocolVersion` is answered with 1 (the agent's highest).
  def test_acp_agent_initialize_is_one_line_in_one_line_out_and_the_document_is_the_designs
    client = surface
    client.write_raw(JSON.generate(
      { "jsonrpc" => Methods::JSONRPC, "id" => 0, "method" => Methods::INITIALIZE,
        "params" => { "protocolVersion" => 1, "clientCapabilities" => Methods::BASELINE_CLIENT_CAPABILITIES, "clientInfo" => E2E::AcpClient::CLIENT_INFO } }
    ))
    result = client.await(0, timeout: SPAWN_TIMEOUT)
    assert client.quiet?(1), "nothing but the one response on stdout:\n#{client.stdout_lines.join("\n")}"
    assert_equal 1, client.stdout_lines.length, client.stdout_lines.inspect
    assert_equal({ "jsonrpc" => "2.0", "id" => 0, "result" => INITIALIZE_DOCUMENT }, JSON.parse(client.stdout_lines.first))
    assert_equal INITIALIZE_DOCUMENT, result
    client.end_input
    status = client.wait_exit(timeout: EXIT_TIMEOUT)
    assert_equal 0, status.exitstatus, "EOF exits 0: #{status.inspect}\n#{client.stderr}"

    advertised = surface
    result = advertised.initialize_agent(capabilities: E2E::AcpClient.capabilities(form: true, terminal_auth: true), timeout: SPAWN_TIMEOUT)
    methods = result.fetch("authMethods")
    assert_equal 2, methods.length, methods.inspect
    assert_equal NEXUS_METHOD, methods.first
    assert_equal TERMINAL_METHOD, methods.last.except("env"), methods.inspect
    assert_empty Array(methods.last["env"]), "the terminal method hands the client no environment"
    assert_equal INITIALIZE_DOCUMENT.except("authMethods"), result.except("authMethods")

    newer = surface
    answered = newer.request(Methods::INITIALIZE, { "protocolVersion" => 99, "clientCapabilities" => Methods::BASELINE_CLIENT_CAPABILITIES }, timeout: SPAWN_TIMEOUT)
    assert_equal 1, answered.fetch("protocolVersion"), "the agent answers its highest; only the client closes"
  end

  # (xii) THE DOORS: a home whose daemon runs but was NEVER CONNECTED (no ceremony started, so no
  # grant spent) answers `initialize` (no kernel call) and refuses `session/new` -32000 naming the
  # auth methods; a runner-mode home answers `initialize` and refuses `session/new` -32603 by the
  # sentence — the mode is the home's own word, read before any daemon or connection question. (No
  # daemon at all is the -32603 of the eviction case.)
  def test_acp_agent_a_never_connected_home_is_refused_by_its_methods_and_a_runner_mode_home_opens_no_conversation
    bare = home_with({ "settings_version" => 1, "plugins" => {} })
    unconnected = E2E::RhoDaemon.new(base_url: @base_url, home: bare)
    unconnected.start
    begin
      stranger = surface(home: bare)
      result = stranger.initialize_agent(timeout: SPAWN_TIMEOUT)
      assert_equal INITIALIZE_DOCUMENT, result
      error = assert_raises(RemoteError) { stranger.new_session(cwd: project("bare")) }
      assert_equal Code::AUTH_REQUIRED, error.code, error.message
      assert_includes error.message, NEXUS_METHOD.fetch("id"), "the refusal names the method: #{error.message}"
      assert_equal [NEXUS_METHOD.fetch("id")], error.data && error.data["authMethods"], "and the ids ride the data: #{error.data.inspect}"
    ensure
      stop_quietly("the never-connected rho") { unconnected.stop }
    end

    runner = home_with({ "mode" => "runner", "settings_version" => 1, "plugins" => {} })
    machine = surface(home: runner)
    assert_equal INITIALIZE_DOCUMENT, machine.initialize_agent(timeout: SPAWN_TIMEOUT)
    error = assert_raises(RemoteError) { machine.new_session(cwd: project("runner")) }
    assert_equal Code::INTERNAL, error.code, error.message
    assert_equal RUNNER_SENTENCE, error.message
  end

  # (xiii) HYGIENE: a `bash` that prints on both descriptors runs under the surface and nothing of
  # it reaches fd 1 — every stdout line is the wire (the teardown's pin, made explicit here). EOF
  # while a tool holds the turn: the surface exits 0 and the kernel's turn runs on to `completed` —
  # a conversation outlives its reader.
  def test_acp_agent_stdout_carries_the_wire_alone_and_eof_exits_0_with_the_loop_running
    client = ready
    session = open_session(client)
    turn = say(client, session, script([bash("echo not-on-the-wire; echo nor-this 1>&2")], "printed"))
    assert_equal Methods::StopReason::END_TURN, turn.stop_reason
    assert_wire_only(client)

    leaver = ready
    session = open_session(leaver)
    leaver.start_prompt(session, script([bash("sleep #{OUTLIVE_SECONDS}")], "slept"))
    call = leaver.await_update(session, Update::TOOL_CALL, timeout: PROMPT_TIMEOUT).fetch("update")
    loop_id, key = loop_and_key(call.fetch("toolCallId"))
    await_task_status(loop_id, key, %w[dispatched running])
    leaver.end_input
    status = leaver.wait_exit(timeout: EXIT_TIMEOUT)
    assert_equal 0, status.exitstatus, "EOF exits 0 with the loop running: #{status.inspect}\n#{leaver.stderr}"
    assert_equal "completed", await_run_status(loop_id, "completed").fetch("status"), "the turn ran on without its reader"
    assert_equal "completed", task_detail(loop_id, key).fetch("status")
  end

  # (xiv) `rho-acp connect`: the word the terminal auth method appends; on a connected home it exits
  # 0 at once.
  def test_acp_agent_connect_on_a_connected_home_exits_0_at_once
    output, status = run_surface("connect")

    assert_predicate status, :success?, "rho-acp connect failed:\n#{output}"
  end

  # THE REFUSALS THE DESIGN FIXES: an unknown method and a method the capabilities do not advertise
  # are -32601; an unknown session is -32002; a second prompt while one runs is -32600 (the first is
  # then cancelled).
  def test_acp_agent_refusals_are_the_codes_the_design_fixes
    client = ready
    session = open_session(client)

    [[Methods::SESSION_LIST, {}], ["_custom/thing", {}], [Methods::LOGOUT, {}]].each do |method, params|
      error = assert_raises(RemoteError, method) { client.request(method, params) }
      assert_equal Code::METHOD_NOT_FOUND, error.code, "#{method}: #{error.message}"
    end
    error = assert_raises(RemoteError) { client.prompt("no-such-session", "hello") }
    assert_equal Code::RESOURCE_NOT_FOUND, error.code, error.message

    id = client.start_prompt(session, script([bash("sleep #{SLEEP_SECONDS}")], "slept"))
    client.await_update(session, Update::TOOL_CALL, timeout: PROMPT_TIMEOUT)
    error = assert_raises(RemoteError) { client.prompt(session, "again?") }
    assert_equal Code::INVALID_REQUEST, error.code, error.message
    client.cancel(session)
    assert_equal Methods::StopReason::CANCELLED, client.finish_prompt(id, timeout: PROMPT_TIMEOUT).stop_reason
  end
end
