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
    assert_equal "completed", await_loop_status(completed.dig("payload", "agent_loop_public_id"), "completed").fetch("status")
  end

  # (iv) THE PARK: under `set_mode ask` the mock's `bash` rests `needs_approval` — the `tool_call`
  # is out first (`pending`, the title, the kind, `rawInput`), then `session/request_permission`
  # with the three options exactly. `allow` runs it (`held.txt`) and the call's `tool_call_update`
  # is `completed` with the output preview; `reject` is `failed approval_denied` naming the client;
  # `always` runs it AND the session grant stands on the daemon (`GET /rules`, what `rho rules`
  # lists). `set_mode` answers `{}`; an unknown mode is -32602.
  def test_acp_agent_under_ask_a_bash_parks_and_allow_reject_always_decide_it
    client = ready(policy: { permission: :hold })
    dir = project("park")
    session = open_session(client, cwd: dir)
    assert_equal({}, client.set_mode(session, "ask"))
    error = assert_raises(RemoteError) { client.set_mode(session, "yolo") }
    assert_equal Code::INVALID_PARAMS, error.code

    # allow
    command = "printf held > held.txt"
    id = client.start_prompt(session, script([bash(command)], "ran it"))
    held = client.await_held(timeout: PROMPT_TIMEOUT)
    params = held.fetch("params")
    assert_equal session, params.fetch("sessionId")
    call = params.fetch("toolCall")
    assert_match(/\A\S+:\S+\z/, call.fetch("toolCallId"))
    assert_equal ["bash #{command}", Methods::ToolKind::EXECUTE, { "command" => command }],
      call.values_at("title", "kind", "rawInput"), call.inspect
    assert_equal PERMISSION_OPTIONS, params.fetch("options")
    announced = client.updates.find { |update| update["sessionId"] == session && update.dig("update", Methods::SESSION_UPDATE_DISCRIMINATOR) == Update::TOOL_CALL }
    refute_nil announced, "the tool_call precedes the permission request"
    assert_equal [call.fetch("toolCallId"), Methods::ToolCallStatus::PENDING], announced.fetch("update").values_at("toolCallId", "status")
    refute_path_exists File.join(dir, "held.txt"), "nothing ran while the call was held"
    client.answer_held(held.fetch("id"), selected("allow"))
    turn = client.finish_prompt(id, timeout: PROMPT_TIMEOUT)
    assert_equal Methods::StopReason::END_TURN, turn.stop_reason
    assert_equal "held", File.read(File.join(dir, "held.txt"))
    loop_id, key = loop_and_key(call.fetch("toolCallId"))
    assert_completed_with_preview(last_frame_for(turn, call.fetch("toolCallId")))
    assert_equal "completed", task_detail(loop_id, key).fetch("status")

    # reject
    id = client.start_prompt(session, script([bash("printf no > rejected.txt")], "tried", spent: 1))
    held = client.await_held(timeout: PROMPT_TIMEOUT)
    client.answer_held(held.fetch("id"), selected("reject"))
    turn = client.finish_prompt(id, timeout: PROMPT_TIMEOUT)
    assert_equal Methods::StopReason::END_TURN, turn.stop_reason
    refute_path_exists File.join(dir, "rejected.txt")
    loop_id, key = loop_and_key(held.dig("params", "toolCall", "toolCallId"))
    task = task_detail(loop_id, key)
    assert_equal "failed", task.fetch("status"), task.inspect
    assert_equal({ "key" => "approval_denied", "detail" => "rejected in #{E2E::AcpClient::CLIENT_INFO.fetch("name")}" }, task.fetch("error"))
    assert_equal Methods::ToolCallStatus::FAILED, tool_call_updates(turn, held.dig("params", "toolCall", "toolCallId")).last.fetch("status")

    # always
    twice = "printf twice > twice.txt"
    id = client.start_prompt(session, script([bash(twice)], "granted", spent: 2))
    held = client.await_held(timeout: PROMPT_TIMEOUT)
    client.answer_held(held.fetch("id"), selected("always"))
    turn = client.finish_prompt(id, timeout: PROMPT_TIMEOUT)
    assert_equal Methods::StopReason::END_TURN, turn.stop_reason
    assert_equal "twice", File.read(File.join(dir, "twice.txt"))
    loop_id, key = loop_and_key(held.dig("params", "toolCall", "toolCallId"))
    grant = @daemon.control(:get, "/rules").fetch("grants").find { |row| row["loop"] == loop_id && row["task_key"] == key }
    refute_nil grant, "the session grant stands on the daemon: #{@daemon.control(:get, "/rules").inspect}"
    assert_equal "bash", grant.dig("rule", "tool"), grant.inspect
    assert_includes JSON.generate(grant.fetch("rule")), twice, "the grant is keyed on the exact command"
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
    assert_equal "completed", await_loop_status(loop_id, "completed").fetch("status")

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
    assert_equal "completed", await_loop_status(loop_id, "completed").fetch("status")

    held = say(plain, session, script([ask_call("and now?")], "later", spent: 1))
    assert_equal Methods::StopReason::END_TURN, held.stop_reason
    held_loop = loop_for_turn(session, turn_id_of(held))
    await_ask(held_loop)
    plain.cancel(session)
    assert_equal "canceled", await_loop_status(held_loop, "canceled").fetch("status"), "a cancel while holding drops the ask"
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
    assert_equal "canceled", await_loop_status(loop_id, "canceled").fetch("status")
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
    assert_equal "canceled", await_loop_status(loop_id, "canceled").fetch("status")
  end

  # A scripted non-retryable 400 halts the round on a LIVE loop — the prompt is -32603 `{hold:
  # true, loop, retry, abandon}` naming the two commands; `/retry` reopens the SAME turn (the feed's
  # second `running` on it) and the mock halts it again — the same error, the same loop; `/abandon`
  # settles it with no model turn, and the next prompt opens a fresh loop and completes. HTTP
  # 400 avoids transport backoff: this case observes manual retry and abandon, and the completion
  # is the abandon's and the next prompt's.
  def test_acp_agent_a_hold_is_an_internal_error_naming_retry_and_abandon_retry_reopens_and_abandon_settles_it
    client = ready
    session = open_session(client)

    error = assert_raises(RemoteError) { say(client, session, "!mock error=400 -- break") }
    assert_equal Code::INTERNAL, error.code, error.message
    assert_equal({ "hold" => true, "retry" => "/retry", "abandon" => "/abandon" }, error.data.slice("hold", "retry", "abandon"), error.data.inspect)
    loop_id = error.data.fetch("loop")
    halted = await_feed(session, "the turn never halted") { |items| turn_status(items, status: "failed", loop: loop_id) }
    assert_equal "halt_failure", halted.dig("payload", "failure_reason_key"), halted.inspect
    refute_empty error.message, "the message is the failure reason"

    again = assert_raises(RemoteError) { say(client, session, "/retry") }
    assert_equal Code::INTERNAL, again.code, again.message
    assert_equal loop_id, again.data.fetch("loop"), "the retry re-followed the same turn"
    assert_equal true, again.data.fetch("hold")
    reopened = feed(session).select { |item| item.fetch("sequence") > halted.fetch("sequence") }
    refute_nil turn_status(reopened, status: "running", loop: loop_id), "the retry reopened the turn: #{types(reopened)}"
    assert_equal halted.dig("payload", "turn_public_id"), turn_status(reopened, status: "running", loop: loop_id).dig("payload", "turn_public_id")

    turn = say(client, session, "/abandon")
    assert_equal Methods::StopReason::END_TURN, turn.stop_reason
    assert_empty updates_of(turn, Update::AGENT_MESSAGE_CHUNK), "a surface command runs no model turn"

    fresh = say(client, session, reply_prompt("carry on"))
    assert_equal Methods::StopReason::END_TURN, fresh.stop_reason
    fresh_loop = loop_for_turn(session, turn_id_of(fresh))
    refute_equal loop_id, fresh_loop, "the next word opens a new loop past the abandoned one"
    assert_equal "completed", await_loop_status(fresh_loop, "completed").fetch("status")
  end

  # (ix) `/compact`: `Core#compact` on the idle conversation, `end_turn` with no model turn; the
  # next turn reads the kernel's summary — a compaction summary turn stands on the conversation and
  # the round's sealed request opens with the re-read frame.
  def test_acp_agent_compact_summarizes_the_history_the_next_turn_reads
    client = ready
    session = open_session(client)
    say(client, session, reply_prompt("one"))
    say(client, session, reply_prompt("two"))

    compacted = say(client, session, "/compact")
    assert_equal Methods::StopReason::END_TURN, compacted.stop_reason
    assert_empty updates_of(compacted, Update::AGENT_MESSAGE_CHUNK), "a surface command runs no model turn"

    after = say(client, session, reply_prompt("three"))
    assert_equal Methods::StopReason::END_TURN, after.stop_reason
    loop_id = loop_for_turn(session, turn_id_of(after))
    await_loop_status(loop_id, "completed")
    chat = steward_client.workspace(@workspace_public_id).conversation(session)
    summaries = await("a summary turn", every: POLL) do
      rows = chat.turns.list.items.select(&:compaction_summary?)
      rows unless rows.empty?
    end
    assert_equal 1, summaries.length, "one compaction, one summary"
    assert_includes sealed_words(loop_id, "r1"), REREAD_RULE, "the round after the compact reads the kernel's frame"
  end
end
