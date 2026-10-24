class RhoAcpAgentTest
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
end
