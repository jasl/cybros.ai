class RhoAcpAgentTest
  # (ii) + THE FLOW: `session/new` BINDS the session's cwd as the CONVERSATION's environment — a
  # followed conversation (`GET /loops`, host_type conversation) whose record's root is the cwd,
  # `additionalDirectories` its directories — and answers `{sessionId, modes, configOptions}` THEN
  # the commands update (the three surface commands lead), after the response line. Two sessions on
  # two cwds prompt in turn: each relative `write` lands under its own root, no 409, and `rho env` —
  # the daemon default — never moves. A relative cwd, a cwd that is no directory and a cwd under a
  # protected root (the rho checkout) are -32602 with the daemon's sentence.
  def test_acp_agent_session_new_binds_each_cwd_answers_modes_and_config_options_then_lists_the_commands
    client = ready
    env_before = rho_env
    dir_a, dir_b, extra = project("a"), project("b"), project("extra")

    id = client.send_request(Methods::SESSION_NEW, { "cwd" => dir_a, "mcpServers" => [] })
    opened = client.await(id, timeout: PROMPT_TIMEOUT)
    session_a = opened.fetch("sessionId")
    assert_equal %w[sessionId modes configOptions], opened.keys, opened.inspect
    assert_equal MODES, opened.fetch("modes")
    assert_config_options(opened.fetch("configOptions"), mode: "bypass", model: MODEL)
    commands = client.await_update(session_a, Update::AVAILABLE_COMMANDS_UPDATE, timeout: SPAWN_TIMEOUT)
    assert_operator response_index(client, id), :<, notification_index(client, session_a, Update::AVAILABLE_COMMANDS_UPDATE),
      "the commands update follows the response line:\n#{client.stdout_lines.join("\n")}"
    listed = commands.dig("update", "availableCommands")
    assert_equal SURFACE_COMMANDS, listed.first(3).map { |command| command.fetch("name") }, listed.inspect
    listed.each { |command| assert_kind_of String, command.fetch("description"), command.inspect }
    assert_equal "conversation", follower(session_a).fetch("host_type"), "the conversation is followed"
    environment = environment_of(session_a)
    assert_equal [dir_a, []], environment.values_at("root", "directories"), environment.inspect
    assert_nil environment["fs"], "no port was advertised: #{environment.inspect}"

    session_b = client.request(Methods::SESSION_NEW, { "cwd" => dir_b, "mcpServers" => [], "additionalDirectories" => [extra] }, timeout: PROMPT_TIMEOUT).fetch("sessionId")
    refute_equal session_a, session_b
    assert_equal [dir_b, [extra]], environment_of(session_b).values_at("root", "directories")

    marker_a = "from a #{SecureRandom.hex(4)}"
    marker_b = "from b #{SecureRandom.hex(4)}"
    turn = say(client, session_a, script([write_call("note.txt", "#{marker_a}\n")], "wrote a"))
    assert_equal Methods::StopReason::END_TURN, turn.stop_reason
    turn = say(client, session_b, script([write_call("note.txt", "#{marker_b}\n")], "wrote b"))
    assert_equal Methods::StopReason::END_TURN, turn.stop_reason
    turn = say(client, session_a, script([write_call("again.txt", "#{marker_a}\n")], "wrote a again", spent: 1))
    assert_equal Methods::StopReason::END_TURN, turn.stop_reason
    assert_equal "#{marker_a}\n", File.read(File.join(dir_a, "note.txt"))
    assert_equal "#{marker_b}\n", File.read(File.join(dir_b, "note.txt"))
    assert_equal "#{marker_a}\n", File.read(File.join(dir_a, "again.txt"))
    refute_path_exists File.join(dir_b, "again.txt"), "a's second write stayed under a"
    assert_equal env_before, rho_env, "the daemon default never moved"
    roots = @daemon.control(:get, "/environments").fetch("environments").to_h { |row| [row.fetch("conversation"), row.fetch("root")] }
    assert_equal({ session_a => dir_a, session_b => dir_b }, roots.slice(session_a, session_b))

    error = assert_raises(RemoteError) { client.new_session(cwd: "relative/path") }
    assert_equal Code::INVALID_PARAMS, error.code, error.message
    file = File.join(dir_a, "note.txt")
    error = assert_raises(RemoteError) { client.new_session(cwd: file) }
    assert_equal Code::INVALID_PARAMS, error.code, error.message
    assert_includes error.message, "is not a directory"
    error = assert_raises(RemoteError) { client.new_session(cwd: E2E::RhoDaemon::RHO_ROOT) }
    assert_equal Code::INVALID_PARAMS, error.code, error.message
    assert_includes error.message, "is under a protected root"
  end

  # The model picker lists references already known from the session, launch flag, home default, or
  # previous selection. An unlisted reference is validated through `Core#model_facts`; a known
  # provider model becomes both listed and current, and the next turn uses it. Unknown model
  # references and option IDs return -32602. The mode option uses the same mode transition as
  # `set_mode`.
  def test_acp_agent_set_config_option_model_names_the_next_turns_model_and_a_value_outside_the_options_is_refused
    client = ready
    session, opened = open_with_document(client)
    model_option = opened.fetch("configOptions").find { |option| option.fetch("id") == "model" }
    assert_equal [MODEL], model_option.fetch("options").map { |option| option.fetch("value") },
      "before any set the picker offers the known refs alone: #{model_option.inspect}"

    answered = client.set_config_option(session, "model", OTHER_MODEL)
    assert_config_options(answered.fetch("configOptions"), mode: "bypass", model: OTHER_MODEL)
    listed = answered.fetch("configOptions").find { |option| option.fetch("id") == "model" }
    assert_equal [OTHER_MODEL, MODEL].sort, listed.fetch("options").map { |option| option.fetch("value") }.sort,
      "the learned ref joins the known ones: #{listed.inspect}"
    turn = say(client, session, reply_prompt("on the twin"))
    assert_equal Methods::StopReason::END_TURN, turn.stop_reason
    loop_id = loop_for_turn(session, turn_id_of(turn))
    await_loop_status(loop_id, "completed")
    assert_equal OTHER_MODEL, task_detail(loop_id, "r1").dig("model", "model"), "the round's frozen selection is the picked row"

    error = assert_raises(RemoteError) { client.set_config_option(session, "model", "dev/no-such-model") }
    assert_equal Code::INVALID_PARAMS, error.code, error.message
    error = assert_raises(RemoteError) { client.set_config_option(session, "colour", "blue") }
    assert_equal Code::INVALID_PARAMS, error.code, error.message
    answered = client.set_config_option(session, "mode", "ask")
    assert_config_options(answered.fetch("configOptions"), mode: "ask", model: OTHER_MODEL)
  end

  # (x) PERSISTENCE: `session/load` replays every turn — a `user_message_chunk` per person input
  # (the input's own text), an `agent_message_chunk` per reply (whole), a `tool_call` per settled
  # call `{toolCallId "<loop>:<key>", title, kind, status}` — with `messageId` "<turn>:0", BEFORE
  # the response `{modes, configOptions}`, then the commands update. `session/resume` is the same
  # without the replay. `session/close` drops the in-process session: a prompt on it is -32002. A
  # row the daemon FORGOT (an emptied store over a restart) is loaded through the attach arm and
  # followed again; while the daemon is down (xii) `initialize` answers and `session/new` is -32603
  # with Core's sentence.
  def test_acp_agent_load_replays_the_turns_and_their_calls_resume_does_not_close_drops_it_and_an_evicted_row_is_attached
    client = ready
    dir = project("load")
    session = open_session(client, cwd: dir)
    prompts = [script([write_call(File.join(dir, "first.txt"), "first\n")], "first words"), reply_prompt("second words")]
    turns = prompts.map { |prompt| say(client, session, prompt) }
    turns.each { |turn| assert_equal Methods::StopReason::END_TURN, turn.stop_reason }
    turn_ids = turns.map { |turn| turn_id_of(turn) }
    call = tool_calls(turns.first).first
    loop_id, key = loop_and_key(call.fetch("toolCallId"))
    await_loop_status(loop_for_turn(session, turn_ids.last), "completed")

    loader = ready
    id = loader.send_request(Methods::SESSION_LOAD, { "sessionId" => session, "cwd" => dir, "mcpServers" => [] })
    loaded = loader.await(id, timeout: PROMPT_TIMEOUT)
    assert_equal %w[modes configOptions], loaded.keys, loaded.inspect
    assert_equal MODES, loaded.fetch("modes")
    replay = replayed_before_response(loader, session, id)
    user = replay.select { |update| update.fetch("sessionUpdate") == Update::USER_MESSAGE_CHUNK }
    agent = replay.select { |update| update.fetch("sessionUpdate") == Update::AGENT_MESSAGE_CHUNK }
    assert_equal prompts, user.map { |update| update.dig("content", "text") }, "each person input, its own text: #{replay.inspect}"
    assert_equal ["Mock: first words", "Mock: second words"], agent.map { |update| update.dig("content", "text").strip }
    assert_equal turn_ids.map { |turn_id| "#{turn_id}:0" }, agent.map { |update| update.fetch("messageId") }
    user.each { |update| assert_match(/\A\S+:0\z/, update.fetch("messageId")) }
    # ONE EXCHANGE PER REPLY TURN: every `say` is one direct_reply turn, the person's words on its
    # seed's `prompt_text` — the user's chunk rides the turn's own `messageId`, the same as its
    # answer's.
    assert_equal turn_ids.map { |turn_id| "#{turn_id}:0" }, user.map { |update| update.fetch("messageId") },
      "the words that opened a turn replay under that turn's id: #{replay.inspect}"
    calls = replay.select { |update| update.fetch("sessionUpdate") == Update::TOOL_CALL }
    assert_equal [{ "toolCallId" => "#{loop_id}:#{key}", "kind" => Methods::ToolKind::EDIT, "status" => Methods::ToolCallStatus::COMPLETED }],
      calls.map { |update| update.slice("toolCallId", "kind", "status") }
    assert_match(/\Awrite\b/, calls.first.fetch("title"), "the replayed call is titled by its tool")
    kinds = replay.map { |update| update.fetch("sessionUpdate") }
    assert_equal [Update::USER_MESSAGE_CHUNK, Update::TOOL_CALL, Update::AGENT_MESSAGE_CHUNK,
                  Update::USER_MESSAGE_CHUNK, Update::AGENT_MESSAGE_CHUNK], kinds,
      "the first prompt's words, its write, its answer; the second prompt's words, its answer: #{kinds.inspect}"
    assert_equal [prompts.first.strip, "Mock: first words", prompts.last.strip, "Mock: second words"],
      (user + agent).sort_by { |update| replay.index(update) }.map { |update| update.dig("content", "text").strip },
      "the exchange reads as it was spoken: #{replay.inspect}"
    assert_equal [Update::USER_MESSAGE_CHUNK, Update::AGENT_MESSAGE_CHUNK] * 2, kinds - [Update::TOOL_CALL],
      "the replay walks the turns in order: #{kinds.inspect}"
    assert_operator kinds.index(Update::TOOL_CALL), :<, kinds.rindex(Update::USER_MESSAGE_CHUNK),
      "the first reply's call is replayed under its turn, before the second: #{kinds.inspect}"
    loader.await_update(session, Update::AVAILABLE_COMMANDS_UPDATE, timeout: SPAWN_TIMEOUT)
    assert_operator response_index(loader, id), :<, notification_index(loader, session, Update::AVAILABLE_COMMANDS_UPDATE)

    resumer = ready
    id = resumer.send_request(Methods::SESSION_RESUME, { "sessionId" => session, "cwd" => dir, "mcpServers" => [] })
    resumed = resumer.await(id, timeout: PROMPT_TIMEOUT)
    assert_equal %w[modes configOptions], resumed.keys, resumed.inspect
    assert_empty replayed_before_response(resumer, session, id), "resume replays nothing"

    assert_equal({}, client.close_session(session))
    error = assert_raises(RemoteError) { say(client, session, reply_prompt("anyone?")) }
    assert_equal Code::RESOURCE_NOT_FOUND, error.code, error.message

    # THE FORCED EVICTION (the `rho_conversation` attach lane's shape): the
    # store is a bounded cache under tmp/; emptied over a restart, the
    # row is one the daemon forgot. The stale announcement goes with it,
    # so the stopped daemon is "no daemon" and not a refused socket.
    cache = @daemon.host_cache_path
    @daemon.stop
    assert_path_exists cache
    File.unlink(cache)
    FileUtils.rm_f(File.join(@world.home, "tmp", "announcement.json"))
    stranded = surface
    assert_equal INITIALIZE_DOCUMENT, stranded.initialize_agent(timeout: SPAWN_TIMEOUT), "initialize needs no daemon"
    error = assert_raises(RemoteError) { stranded.new_session(cwd: dir) }
    assert_equal Code::INTERNAL, error.code, error.message
    assert_includes error.message, NO_DAEMON_SENTENCE
    restart_daemon!
    refute follower(session), "the restarted daemon follows the forgotten row"

    attacher = ready
    id = attacher.send_request(Methods::SESSION_LOAD, { "sessionId" => session, "cwd" => dir, "mcpServers" => [] })
    attacher.await(id, timeout: PROMPT_TIMEOUT)
    assert_equal 2, replayed_before_response(attacher, session, id).count { |update| update.fetch("sessionUpdate") == Update::USER_MESSAGE_CHUNK }
    assert_equal "conversation", follower(session).fetch("host_type"), "the load attached the forgotten row"
    assert_equal dir, environment_of(session).fetch("root"), "the load re-asserted the cwd as the root"
    turn = say(attacher, session, reply_prompt("and again"))
    assert_equal Methods::StopReason::END_TURN, turn.stop_reason
    assert_equal "completed", await_loop_status(loop_for_turn(session, turn_id_of(turn)), "completed").fetch("status")
  end
end
