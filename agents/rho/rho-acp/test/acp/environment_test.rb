require "test_helper"

# THE SESSION'S ENVIRONMENT: new/load — the open/attach arguments, the two bind
# requests (fs only when advertised, mcp only when non-empty, each its
# own request, fs first), the 409/422 handling, the close binds.
class AcpEnvironmentTest < Minitest::Test
  Methods = Rho::Acp::Methods
  SERVERS = [{ "name" => "fx", "command" => "fx-server", "args" => ["--stdio"], "env" => [{ "name" => "TOKEN", "value" => "s3cret" }] }].freeze

  def setup
    @core = RhoAcpTest::CoreDouble.new
    @harness = RhoAcpTest::AgentHarness.new(core: @core, runner: "exr_1")
  end

  def teardown
    @harness.close
  end

  def binds = @core.calls_of(:bind_environment)

  def test_new_opens_promptless_with_the_cwd_bound_and_the_runner
    @harness.initialize_agent
    answer = @harness.new_session(cwd: "/work/project", extra: { "additionalDirectories" => ["/work/lib"] })

    assert_equal "cnv_1", answer["sessionId"]
    assert_equal [[[], { prompt: nil, directory: "/work/project", directories: ["/work/lib"], runner: "exr_1" }]],
      @core.calls_of(:open_conversation)
    assert_empty binds, "nothing advertised, nothing listed: no bind"
    session = @harness.agent.sessions["cnv_1"]
    assert_equal "/work/project", session.root
    assert_equal ["/work/lib"], session.directories
  end

  def test_a_relative_cwd_a_bad_directory_list_and_a_root_set_past_4_kib_are_invalid_params
    @harness.initialize_agent
    assert_equal(-32602, @harness.refused(Methods::SESSION_NEW, { "cwd" => "project", "mcpServers" => [] }).code)
    assert_equal(-32602, @harness.refused(Methods::SESSION_NEW, { "cwd" => "/p", "additionalDirectories" => ["rel"], "mcpServers" => [] }).code)
    wide = Array.new(60) { |i| "/#{"d" * 70}/#{i}" }
    error = @harness.refused(Methods::SESSION_NEW, { "cwd" => "/p", "additionalDirectories" => wide, "mcpServers" => [] })
    assert_equal(-32602, error.code)
    assert_includes error.message, "4096"
    refute @core.called?(:open_conversation)
  end

  # BY CODE: the door's two
  # validation words are -32602 with the daemon's sentence, any other
  # refusal -32603 with its code as data — the code decides, the sentence
  # is carried, never read.
  def test_the_daemons_validation_words_are_invalid_params_with_the_sentence
    @harness.initialize_agent
    @core.refuse(:open_conversation, "/nowhere is not a directory", code: "not_a_directory", status: 422)
    error = @harness.refused(Methods::SESSION_NEW, { "cwd" => "/nowhere", "mcpServers" => [] })
    assert_equal [-32602, "/nowhere is not a directory"], [error.code, error.message]

    @core.refuse(:open_conversation, "/home/me/.rho is under a protected root", code: "protected_root", status: 422)
    assert_equal(-32602, @harness.refused(Methods::SESSION_NEW, { "cwd" => "/home/me/.rho", "mcpServers" => [] }).code)

    @core.refuse(:open_conversation, "This daemon has no adopted workspace yet", code: "workspace_unavailable", status: 409)
    error = @harness.refused(Methods::SESSION_NEW, { "cwd" => "/p", "mcpServers" => [] })
    assert_equal [-32603, { "code" => "workspace_unavailable" }], [error.code, error.data]
  end

  def test_the_two_live_members_ride_their_own_requests_fs_first
    @harness.initialize_agent(capabilities: RhoAcpTest::AgentHarness.capabilities(read: true))
    @harness.new_session(cwd: "/work/project", servers: SERVERS)

    assert_equal 2, binds.length
    assert_equal ["cnv_1"], binds[0].first
    assert_equal [:fs], binds[0].last.keys
    assert_equal({ "read" => true, "write" => false, "client" => "test-editor" }, binds[0].last[:fs].slice("read", "write", "client"))
    assert_equal [["cnv_1"], { mcp: SERVERS }], binds[1]
    assert @harness.agent.sessions["cnv_1"].servers
  end

  def test_an_fs_refusal_never_blocks_the_servers
    @core.refuse(:bind_fs, "cnv_1 runs on exr_9: a port is this daemon's loopback endpoint", code: "runner_elsewhere", status: 409)
    @harness.initialize_agent(capabilities: RhoAcpTest::AgentHarness.capabilities(write: true))
    @harness.new_session(cwd: "/work/project", servers: SERVERS)

    assert_equal [[:fs], [:mcp]], binds.map { |_args, kwargs| kwargs.keys }
  end

  def test_mcp_is_omitted_when_the_editor_lists_none
    @harness.initialize_agent
    @harness.new_session(cwd: "/work/project", servers: [])
    @harness.request(Methods::SESSION_NEW, { "cwd" => "/work/project" })

    assert_empty binds
  end

  def test_mcp_unavailable_is_one_stderr_line_and_the_session_continues
    @core.refuse(:bind_mcp, "no extension serves an editor's MCP servers on this daemon: enable rho-mcp", code: "mcp_unavailable", status: 422)
    @harness.initialize_agent
    answer = @harness.new_session(cwd: "/work/project", servers: SERVERS)

    assert_equal "cnv_1", answer["sessionId"]
    assert_includes @harness.stderr, "enable rho-mcp"
    refute @harness.agent.sessions["cnv_1"].servers
    @harness.request(Methods::SESSION_CLOSE, { "sessionId" => "cnv_1" })
    refute binds.any? { |_args, kwargs| kwargs[:mcp] == [] }, "no servers were bound: no close"
  end

  def test_a_malformed_server_list_is_invalid_params
    @core.refuse(:bind_mcp, "mcpServers[0]: a stdio server needs a command", code: "malformed_body", status: 400)
    @harness.initialize_agent
    error = @harness.refused(Methods::SESSION_NEW, { "cwd" => "/work/project", "mcpServers" => [{ "name" => "x" }] })

    assert_equal [-32602, "mcpServers[0]: a stdio server needs a command"], [error.code, error.message]
    assert_equal(-32602, @harness.refused(Methods::SESSION_NEW, { "cwd" => "/work/project", "mcpServers" => ["x"] }).code)
  end

  # THE REPLAY'S SHAPE: the kernel's rows as they ARE — every `say` one
  # `direct_reply` turn (role assistant) whose seed's words ride the
  # variant's `prompt_text`, no `role: user` row between — each replayed
  # as one exchange: the user's chunk from `prompt_text`, the loop's
  # calls, the agent's chunk from `content`, both chunks on the turn's
  # `messageId`; a reply whose seed carried no words (a picture alone)
  # has no `prompt_text` and replays its answer alone; the kernel's
  # summary turn nothing.
  def test_load_attaches_an_unfollowed_conversation_binds_the_root_then_the_members_and_replays_first
    @core.turns_pages << {
      "turns" => [
        { "public_id" => "trn_a", "position" => 1, "kind" => "direct_reply", "role" => "assistant",
          "active_variant" => { "prompt_text" => "hi there", "content" => "hello", "run_public_id" => "alp_a" } },
        { "public_id" => "trn_b", "position" => 2, "kind" => "direct_reply", "role" => "assistant",
          "active_variant" => { "content" => "a picture, I see" } },
        { "public_id" => "trn_s", "position" => 3, "kind" => "compaction_summary", "role" => "user", "active_variant" => { "content" => "summary" } },
      ],
      "pagination" => { "has_more" => false },
    }
    @core.transcripts["alp_a"] = { "rounds" => [{ "calls" => { "count" => 1, "items" => [{ "task_key" => "k1", "name" => "bash", "status" => "completed", "is_error" => true, "output_preview" => "x" }] } }],
                                   "has_older" => false }
    @core.rows["cnv_9"] = nil
    @core.rows.delete("cnv_9")
    @harness.initialize_agent(capabilities: RhoAcpTest::AgentHarness.capabilities(read: true))
    answer = @harness.request(Methods::SESSION_LOAD, { "sessionId" => "cnv_9", "cwd" => "/work/project", "mcpServers" => SERVERS })

    assert_equal %w[modes configOptions], answer.keys
    assert_equal [[["cnv_9"], { live: true, host_type: "conversation" }]], @core.calls_of(:attach)
    assert_equal [{ root: "/work/project", directories: [] }, [:fs], [:mcp]],
      [binds[0].last, binds[1].last.keys, binds[2].last.keys]
    # The commands update follows the response LINE: the reader can
    # hand the response over before that line lands, so it is waited for.
    @harness.await_update("available_commands_update")
    kinds = @harness.updates.map { |u| u.dig("update", "sessionUpdate") }
    assert_equal %w[user_message_chunk tool_call agent_message_chunk agent_message_chunk available_commands_update], kinds,
      "one exchange per reply turn: the words that opened it, its calls, its answer; a wordless seed opens nothing"
    assert_equal({ "sessionUpdate" => "user_message_chunk", "content" => { "type" => "text", "text" => "hi there" }, "messageId" => "trn_a:0" }, @harness.updates[0]["update"])
    assert_equal({ "sessionUpdate" => "tool_call", "toolCallId" => "alp_a:k1", "title" => "bash", "kind" => "execute", "status" => "failed" }, @harness.updates[1]["update"])
    assert_equal({ "sessionUpdate" => "agent_message_chunk", "content" => { "type" => "text", "text" => "hello" }, "messageId" => "trn_a:0" }, @harness.updates[2]["update"])
    assert_equal ["a picture, I see", "trn_b:0"], [@harness.updates[3].dig("update", "content", "text"), @harness.updates[3].dig("update", "messageId")]
    assert_equal [[["cnv_9"], { after_position: nil, limit: nil }]], @core.calls_of(:turns)
  end

  def test_load_of_a_followed_conversation_skips_the_attach_and_a_kernel_404_is_resource_not_found
    @core.rows["cnv_1"] = { "public_id" => "cnv_1" }
    @harness.initialize_agent
    @harness.request(Methods::SESSION_LOAD, { "sessionId" => "cnv_1", "cwd" => "/work/project", "mcpServers" => [] })
    refute @core.called?(:attach)

    @core.refuse(:attach, "not_found: no conversation cnv_gone", code: "not_found", status: 404)
    error = @harness.refused(Methods::SESSION_LOAD, { "sessionId" => "cnv_gone", "cwd" => "/work/project", "mcpServers" => [] })
    assert_equal [-32002, "not_found: no conversation cnv_gone"], [error.code, error.message]

    # ONLY that code: any other
    # attach refusal is -32603 with its code, never "not found".
    @core.refuse(:attach, "The local daemon is stopping", code: "daemon_stopping", status: 503)
    error = @harness.refused(Methods::SESSION_LOAD, { "sessionId" => "cnv_gone", "cwd" => "/work/project", "mcpServers" => [] })
    assert_equal [-32603, { "code" => "daemon_stopping" }], [error.code, error.data]
  end

  def test_resume_is_load_without_the_replay
    @core.rows["cnv_1"] = { "public_id" => "cnv_1" }
    @harness.initialize_agent
    answer = @harness.request(Methods::SESSION_RESUME, { "sessionId" => "cnv_1", "cwd" => "/work/project", "mcpServers" => [] })

    assert_equal %w[modes configOptions], answer.keys
    refute @core.called?(:turns)
    assert_equal [[["cnv_1"], { root: "/work/project", directories: [] }]], binds
    @harness.await_update("available_commands_update")
  end

  def test_load_rearms_a_held_ask_without_the_form_as_the_last_chunk_and_the_hold
    @core.rows["cnv_1"] = { "public_id" => "cnv_1", "turn" => "trn_1", "run_public_id" => "alp_1", "attention" => { "reason" => "awaiting_human", "blocked_task_keys" => ["a1"] } }
    @core.tasks[["alp_1", "a1"]] = { "prompt" => "Which one?" }
    @harness.initialize_agent
    @harness.request(Methods::SESSION_LOAD, { "sessionId" => "cnv_1", "cwd" => "/work/project", "mcpServers" => [] })
    @harness.await_update("agent_message_chunk")

    assert_equal "Which one?", @harness.updates_of("agent_message_chunk").last.dig("update", "content", "text")
    assert_equal Rho::Acp::Agent::Hold.new(run_public_id: "alp_1", key: "a1", turn: "trn_1"), @harness.agent.sessions["cnv_1"].held
    refute_predicate @harness.agent.sessions["cnv_1"], :busy?, "no thread, no claim: the next prompt answers the hold"
  end

  # THE RE-ARMED FORM HOLDS THE PROMPT SLOT (`Rearm` in sessions.rb): a `session/load` onto a held ask, with the
  # form, claims the session's one prompt slot before its card's thread
  # starts — a `session/prompt` while the card is open is the drain's
  # -32600, the same refusal a second prompt gets — and releases it once
  # the card is answered and the turn followed to its end, cancelled on
  # the card (the hold set), or cancelled by `session/cancel` (the hold
  # dropped). The slot is watched through `busy?` after the event that
  # orders it; the follower's row is settled by the script before the
  # card is answered, so `catch_up` sees the ask resolved on its first read.
  ASKING_ROW = { "public_id" => "cnv_1", "turn" => "trn_1", "run_public_id" => "alp_1",
                 "attention" => { "reason" => "awaiting_human", "blocked_task_keys" => ["a1"] } }.freeze
  SETTLED_ROW = { "public_id" => "cnv_1", "turn" => "trn_1", "run_public_id" => "alp_1", "status" => "running" }.freeze
  SNAPSHOT = ["snapshot", { "turn" => "trn_1", "run_public_id" => "alp_1" }].freeze
  COMPLETED = ["turn_status", { "turn_public_id" => "trn_1", "run_public_id" => "alp_1", "status" => "completed", "run_status" => "completed" }].freeze
  CLOSED = ["closed", {}].freeze
  PROMPT = { "sessionId" => "cnv_1", "prompt" => [{ "type" => "text", "text" => "next" }] }.freeze
  Rearm = Rho::Acp::Agent::Rearm
  Hold = Rho::Acp::Agent::Hold

  def wait_for(timeout: RhoAcpTest::AgentHarness::TIMEOUT)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      raise "condition not met within #{timeout}s" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.01
    end
  end

  # The load onto the held ask with the form: the card held by the client
  # (its `elicitation/create` inbound answered), the session.
  def load_onto_the_held_ask
    @core.rows["cnv_1"] = ASKING_ROW
    @core.tasks[["alp_1", "a1"]] = { "prompt" => "Which one?" }
    @harness.policy = :hold
    @harness.initialize_agent(capabilities: RhoAcpTest::AgentHarness.capabilities(form: true))
    @harness.request(Methods::SESSION_LOAD, { "sessionId" => "cnv_1", "cwd" => "/work/project", "mcpServers" => [] })
    card = @harness.await_held
    assert_equal [Methods::ELICITATION_CREATE, "Which one?"], [card.method, card.params["message"]]
    [card, @harness.agent.sessions["cnv_1"]]
  end

  def test_load_rearms_the_form_holding_the_prompt_slot_until_the_answered_turn_was_followed_to_its_end
    @core.events["cnv_1"] = [[SNAPSHOT, ["text_delta", { "text" => "done" }], COMPLETED, CLOSED], [SNAPSHOT, COMPLETED, CLOSED]]
    card, session = load_onto_the_held_ask
    assert_predicate session, :busy?
    assert_equal Rearm.new(run_public_id: "alp_1", key: "a1", turn: "trn_1"), session.prompt

    error = @harness.refused(Methods::SESSION_PROMPT, PROMPT)
    assert_equal [-32600, "a prompt is already running on cnv_1"], [error.code, error.message], "the drain's own refusal, no new code"
    refute @core.called?(:say)

    @core.rows["cnv_1"] = SETTLED_ROW
    card.respond("action" => "accept", "content" => { "answer" => "b" })
    @harness.await_update("agent_message_chunk")
    assert_equal [[["alp_1", "a1", "b"], {}]], @core.calls_of(:answer)
    assert_equal ["done"], @harness.updates_of("agent_message_chunk").map { |u| u.dig("update", "content", "text") },
      "the followed turn's updates reach the editor"
    wait_for { !session.busy? }
    assert_nil session.held

    assert_equal "end_turn", @harness.prompt("cnv_1", "next")["stopReason"], "the slot released, the next prompt is claimed"
    assert_equal 1, @core.calls_of(:say).length
    assert_equal 2, @core.calls_of(:follower_events).length, "the re-arm's follow, then the prompt's"
  end

  def test_a_card_cancelled_after_load_sets_the_hold_and_releases_the_slot
    card, session = load_onto_the_held_ask
    card.respond("action" => "cancel")
    wait_for { !session.busy? }

    assert_equal Hold.new(run_public_id: "alp_1", key: "a1", turn: "trn_1"), session.held
    refute @core.called?(:answer)
    refute @core.called?(:follower_events)
  end

  def test_a_card_declined_after_load_fails_the_ask_follows_the_turn_and_releases_the_slot
    @core.events["cnv_1"] = [[SNAPSHOT, COMPLETED, CLOSED]]
    card, session = load_onto_the_held_ask
    @core.rows["cnv_1"] = SETTLED_ROW
    card.respond("action" => "decline")
    wait_for { !session.busy? }

    assert_equal [[["alp_1", "a1", ""], { outcome: "failed" }]], @core.calls_of(:answer)
    assert_equal 1, @core.calls_of(:follower_events).length
    assert_nil session.held
  end

  def test_session_cancel_during_the_rearmed_card_cancels_it_drops_the_hold_and_releases_the_slot
    @core.events["cnv_1"] = [[SNAPSHOT, COMPLETED, CLOSED]]
    card, session = load_onto_the_held_ask
    @harness.notify(Methods::SESSION_CANCEL, { "sessionId" => "cnv_1" })
    wait_for { card.cancelled? }
    card.fail_cancelled
    wait_for { @core.called?(:stop) && !session.busy? }

    assert_equal [[["cnv_1"], { force: true }]], @core.calls_of(:stop)
    assert_nil session.held, "the cascade dropped the hold; the cancelled card never set it"
    refute @core.called?(:answer)
    assert_equal "end_turn", @harness.prompt("cnv_1", "start over")["stopReason"]
    assert_equal 1, @core.calls_of(:say).length, "a new say, never an answer"
  end

  # THE FALLBACK: the slot already a prompt's when the re-arm runs (only a
  # prompt that raced the load's response) — no thread, no card; the
  # question as the last chunk and the hold, the way of a client without
  # the form; the prompt's claim untouched.
  def test_a_rearm_finding_the_slot_taken_holds_the_ask_without_the_form
    @core.rows["cnv_1"] = ASKING_ROW
    @core.tasks[["alp_1", "a1"]] = { "prompt" => "Which one?" }
    @harness.policy = :hold
    @harness.initialize_agent(capabilities: RhoAcpTest::AgentHarness.capabilities(form: true))
    session = Rho::Acp::Agent::Session.new(id: "cnv_1", mode: "ask", model: nil, root: "/work/project")
    @harness.agent.sessions.add(session)
    holder = Object.new
    assert session.claim_prompt(holder)

    Rho::Acp::Agent::Replay.rearm(@harness.agent, session, @core)

    assert_equal "Which one?", @harness.await_update("agent_message_chunk").dig("update", "content", "text")
    assert_equal Hold.new(run_public_id: "alp_1", key: "a1", turn: "trn_1"), session.held
    assert_same holder, session.prompt, "the prompt's claim stands"
    assert_predicate @harness.held, :empty?, "no elicitation/create"
  end

  def test_close_drops_the_port_and_closes_the_servers_best_effort
    @core.refuse(:bind_mcp, "no extension serves an editor's MCP servers on this daemon: enable rho-mcp", code: "mcp_unavailable", status: 422) # for the close
    @harness.initialize_agent(capabilities: RhoAcpTest::AgentHarness.capabilities(read: true))
    # The bind at new succeeds (the refusal above is consumed by the first mcp bind), so queue it after.
    @core.refusals.clear
    @harness.new_session(cwd: "/work/project", servers: SERVERS)
    @core.refuse(:bind_mcp, "no extension serves an editor's MCP servers on this daemon: enable rho-mcp", code: "mcp_unavailable", status: 422)
    assert_equal({}, @harness.request(Methods::SESSION_CLOSE, { "sessionId" => "cnv_1" }))

    tail = binds.last(2)
    assert_equal [{ fs: nil }, { mcp: [] }], tail.map(&:last)
    assert_equal(-32002, @harness.refused(Methods::SESSION_SET_MODE, { "sessionId" => "cnv_1", "modeId" => "ask" }).code)
  end

  def test_eof_releases_every_session
    @harness.initialize_agent(capabilities: RhoAcpTest::AgentHarness.capabilities(read: true))
    @harness.new_session(cwd: "/work/project", servers: SERVERS)
    @harness.close

    assert_equal [{ fs: nil }, { mcp: [] }], binds.last(2).map(&:last)
  end
end
