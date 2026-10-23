class RhoAcpAgentTest
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
    await_run_status(loop_for_turn(session, turn_ids.last), "completed")

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
    assert_equal "completed", await_run_status(loop_for_turn(session, turn_id_of(turn)), "completed").fetch("status")
  end
end
