class RhoAcpAgentTest
  # (iii) A reply written slowly reaches the editor as `agent_message_chunk`s
  # under ONE `messageId` — "<turn>:0", the turn the feed names — each a
  # text block, and the prompt answers `end_turn`.
  def test_acp_agent_a_slow_reply_streams_chunks_under_one_message_id_and_ends_the_turn
    client = ready
    session = open_session(client)

    turn = say(client, session, "!mock stream_chunk_delay=#{STREAM_CHUNK_DELAY} reply=#{CGI.escape(STREAM_WORDS)} -- say it")

    assert_equal Methods::StopReason::END_TURN, turn.stop_reason
    chunks = updates_of(turn, Update::AGENT_MESSAGE_CHUNK)
    assert_operator chunks.length, :>, 1, "the reply arrived as deltas: #{kinds(turn)}"
    chunks.each { |chunk| assert_equal Methods::ContentBlock::TEXT, chunk.dig("content", "type"), chunk.inspect }
    ids = chunks.map { |chunk| chunk.fetch("messageId") }.uniq
    assert_equal 1, ids.length, "one message id for one reply: #{ids.inspect}"
    turn_id = turn_id_of(turn)
    assert_equal "#{turn_id}:0", ids.first
    assert_equal "Mock: #{STREAM_WORDS}", turn.text.strip
    completed = await_turn(session, turn_id, "completed")
    assert_equal "completed", await_run_status(completed.dig("payload", "run_public_id"), "completed").fetch("status")
  end

  # (vi) THE ASK: with `elicitation.form` the model's `ask` is `elicitation/create {mode: form,
  # message, requestedSchema}` exactly; `accept` answers the ask and the SAME turn completes (the
  # task holds the answer). Without the form the question is streamed and the prompt answers
  # `end_turn` with the ask held; the NEXT prompt is the answer — the same turn followed on, the
  # task holding the words — and `session/cancel` while a later ask is held cancels the loop.
  def test_acp_agent_the_ask_is_a_form_when_the_client_has_one_else_the_next_prompt_answers_it_and_cancel_drops_it
    formed = ready(capabilities: E2E::AcpClient.capabilities(form: true), policy: { elicitation: :accept })
    session = open_session(formed)
    turn = say(formed, session, script([ask_call(QUESTION)], "thanks"))
    assert_equal Methods::StopReason::END_TURN, turn.stop_reason
    assert_equal 1, turn.elicitations.length, "one form for one ask: #{turn.elicitations.inspect}"
    form = turn.elicitations.first.fetch("params")
    assert_equal({ "sessionId" => session, "mode" => "form", "message" => QUESTION, "requestedSchema" => ANSWER_SCHEMA },
      form.slice("sessionId", "mode", "message", "requestedSchema"), form.inspect)
    # The schema's own id (`elicitation/complete {elicitationId}` names it) may ride beside the
    # design's four keys, and nothing else.
    assert_empty form.keys - %w[sessionId mode message requestedSchema elicitationId], form.inspect
    assert_kind_of String, form["elicitationId"] if form.key?("elicitationId")
    loop_id = loop_for_turn(session, turn_id_of(turn))
    ask = await_ask_settled(loop_id)
    assert_equal "yes", task_output(loop_id, ask.fetch("key")), "the form's answer is the task's"
    assert_equal "completed", await_run_status(loop_id, "completed").fetch("status")

    plain = ready
    session = open_session(plain)
    first = say(plain, session, script([ask_call(QUESTION)], "noted"))
    assert_equal Methods::StopReason::END_TURN, first.stop_reason
    assert_empty first.elicitations, "no form was advertised"
    assert_includes first.text, QUESTION, "the question streams as the reply"
    turn_id = turn_id_of(first)
    loop_id = loop_for_turn(session, turn_id)
    assert_equal "awaiting_input", await_ask(loop_id).fetch("status"), "the ask stands on the kernel while the surface holds it"
    second = say(plain, session, "postgres")
    assert_equal Methods::StopReason::END_TURN, second.stop_reason
    assert_equal turn_id, turn_id_of(second), "the answer follows the SAME turn on"
    ask = await_ask_settled(loop_id)
    assert_equal "postgres", task_output(loop_id, ask.fetch("key"))
    assert_equal "completed", await_run_status(loop_id, "completed").fetch("status")

    held = say(plain, session, script([ask_call("and now?")], "later", spent: 1))
    assert_equal Methods::StopReason::END_TURN, held.stop_reason
    held_loop = loop_for_turn(session, turn_id_of(held))
    await_ask(held_loop)
    plain.cancel(session)
    assert_equal "canceled", await_run_status(held_loop, "canceled").fetch("status"), "a cancel while holding drops the ask"
  end

  # (vii) CANCEL: with a `request_permission` held open by the client, `session/cancel` sends
  # `$/cancel_request` for it (the client answers -32800), the prompt answers `cancelled` and the
  # loop is `canceled` — nothing ran. A `bash` mid-`sleep` under bypass: the cancel stops the turn,
  # `cancelled`, the loop `canceled`.
  def test_acp_agent_cancel_cascades_to_a_held_permission_and_stops_a_running_tool
    client = ready(policy: { permission: :hold, cancel_answers_held: false })
    dir = project("cancel")
    session = open_session(client, cwd: dir)
    client.set_mode(session, "ask")
    id = client.start_prompt(session, script([bash("printf ran > ran.txt")], "done"))
    held = client.await_held(timeout: PROMPT_TIMEOUT)
    client.cancel(session)
    turn = client.finish_prompt(id, timeout: PROMPT_TIMEOUT)
    assert_equal Methods::StopReason::CANCELLED, turn.stop_reason
    assert_includes client.cancel_notices, held.fetch("id"), "the surface cancelled its own outstanding request"
    assert_equal Code::REQUEST_CANCELLED, held.dig("answer", "code"), "the client answered it -32800: #{held.inspect}"
    loop_id, = loop_and_key(held.dig("params", "toolCall", "toolCallId"))
    assert_equal "canceled", await_run_status(loop_id, "canceled").fetch("status")
    refute_path_exists File.join(dir, "ran.txt")

    running = ready
    session = open_session(running, cwd: dir)
    id = running.start_prompt(session, script([bash("sleep #{SLEEP_SECONDS}")], "slept"))
    call = running.await_update(session, Update::TOOL_CALL, timeout: PROMPT_TIMEOUT).fetch("update")
    loop_id, key = loop_and_key(call.fetch("toolCallId"))
    await_task_status(loop_id, key, %w[dispatched running])
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    running.cancel(session)
    turn = running.finish_prompt(id, timeout: PROMPT_TIMEOUT)
    assert_equal Methods::StopReason::CANCELLED, turn.stop_reason
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, SLEEP_SECONDS, "the cancel ended the hold, not its clock"
    assert_equal "canceled", await_run_status(loop_id, "canceled").fetch("status")
  end
end
