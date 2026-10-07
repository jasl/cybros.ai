require "test_helper"
require "rho/acp"

# THE NAMES ON THE WIRE: data, no behaviour — the method and notification names in both
# directions, the error codes, the capability shapes, the stop reasons, the permission
# option kinds, the content block kinds, the session update kinds. Every string here is
# the facts sheet's, so a rename in either role is caught by this file and never by an
# editor.
class AcpMethodsTest < Minitest::Test
  Methods = Rho::Acp::Methods

  def test_the_protocol_version_is_the_stable_one
    assert_equal 1, Methods::PROTOCOL_VERSION
    assert_equal "2.0", Methods::JSONRPC
  end

  def test_the_agent_side_methods_client_to_agent
    assert_equal "initialize", Methods::INITIALIZE
    assert_equal "authenticate", Methods::AUTHENTICATE
    assert_equal "logout", Methods::LOGOUT
    assert_equal "session/new", Methods::SESSION_NEW
    assert_equal "session/load", Methods::SESSION_LOAD
    assert_equal "session/resume", Methods::SESSION_RESUME
    assert_equal "session/close", Methods::SESSION_CLOSE
    assert_equal "session/list", Methods::SESSION_LIST
    assert_equal "session/delete", Methods::SESSION_DELETE
    assert_equal "session/set_mode", Methods::SESSION_SET_MODE
    assert_equal "session/set_config_option", Methods::SESSION_SET_CONFIG_OPTION
    assert_equal "session/prompt", Methods::SESSION_PROMPT
    assert_equal "session/cancel", Methods::SESSION_CANCEL

    assert_equal %w[initialize authenticate logout session/new session/load session/resume session/close session/list
                    session/delete session/set_mode session/set_config_option session/prompt], Methods::AGENT_REQUESTS
    assert_equal %w[session/cancel], Methods::AGENT_NOTIFICATIONS
  end

  def test_the_client_side_methods_agent_to_client
    assert_equal "session/request_permission", Methods::SESSION_REQUEST_PERMISSION
    assert_equal "session/update", Methods::SESSION_UPDATE
    assert_equal "fs/read_text_file", Methods::FS_READ_TEXT_FILE
    assert_equal "fs/write_text_file", Methods::FS_WRITE_TEXT_FILE
    assert_equal "terminal/create", Methods::TERMINAL_CREATE
    assert_equal "terminal/output", Methods::TERMINAL_OUTPUT
    assert_equal "terminal/wait_for_exit", Methods::TERMINAL_WAIT_FOR_EXIT
    assert_equal "terminal/kill", Methods::TERMINAL_KILL
    assert_equal "terminal/release", Methods::TERMINAL_RELEASE
    assert_equal "elicitation/create", Methods::ELICITATION_CREATE
    assert_equal "elicitation/complete", Methods::ELICITATION_COMPLETE

    assert_equal %w[session/request_permission fs/read_text_file fs/write_text_file terminal/create terminal/output
                    terminal/wait_for_exit terminal/kill terminal/release elicitation/create], Methods::CLIENT_REQUESTS
    assert_equal %w[session/update elicitation/complete], Methods::CLIENT_NOTIFICATIONS
  end

  def test_the_protocol_level_cancel_and_the_custom_prefix
    assert_equal "$/cancel_request", Methods::CANCEL_REQUEST
    assert_equal "_", Methods::CUSTOM_PREFIX
  end

  def test_the_two_directions_are_disjoint_and_every_name_is_frozen
    agent = Methods::AGENT_REQUESTS + Methods::AGENT_NOTIFICATIONS
    client = Methods::CLIENT_REQUESTS + Methods::CLIENT_NOTIFICATIONS
    assert_empty agent & client
    (agent + client + [Methods::CANCEL_REQUEST]).each do |name|
      assert name.frozen?, name
      assert_equal name, name.dup.force_encoding(Encoding::UTF_8)
    end
    %i[AGENT_REQUESTS AGENT_NOTIFICATIONS CLIENT_REQUESTS CLIENT_NOTIFICATIONS].each do |list|
      assert Methods.const_get(list).frozen?, list
    end
  end

  def test_the_error_codes
    codes = Methods::ErrorCode
    assert_equal(-32700, codes::PARSE)
    assert_equal(-32600, codes::INVALID_REQUEST)
    assert_equal(-32601, codes::METHOD_NOT_FOUND)
    assert_equal(-32602, codes::INVALID_PARAMS)
    assert_equal(-32603, codes::INTERNAL)
    assert_equal(-32000, codes::AUTH_REQUIRED)
    assert_equal(-32002, codes::RESOURCE_NOT_FOUND)
    assert_equal(-32800, codes::REQUEST_CANCELLED)
    assert_equal "Request cancelled", codes::MESSAGES.fetch(-32800)
    assert_equal "Parse error", codes::MESSAGES.fetch(-32700)
    assert_equal "Invalid Request", codes::MESSAGES.fetch(-32600)
    assert_equal "Method not found", codes::MESSAGES.fetch(-32601)
    assert_equal "Invalid params", codes::MESSAGES.fetch(-32602)
    assert_equal "Internal error", codes::MESSAGES.fetch(-32603)
    assert_equal "Authentication required", codes::MESSAGES.fetch(-32000)
    assert_equal "Resource not found", codes::MESSAGES.fetch(-32002)
  end

  def test_the_stop_reasons
    assert_equal %w[end_turn max_tokens max_turn_requests refusal cancelled], Methods::STOP_REASONS
    assert_equal "end_turn", Methods::StopReason::END_TURN
    assert_equal "cancelled", Methods::StopReason::CANCELLED
    assert_equal "max_tokens", Methods::StopReason::MAX_TOKENS
    assert_equal "max_turn_requests", Methods::StopReason::MAX_TURN_REQUESTS
    assert_equal "refusal", Methods::StopReason::REFUSAL
  end

  def test_the_permission_option_kinds_and_outcomes
    assert_equal %w[allow_once allow_always reject_once reject_always], Methods::PERMISSION_OPTION_KINDS
    assert_equal "allow_once", Methods::PermissionOptionKind::ALLOW_ONCE
    assert_equal "allow_always", Methods::PermissionOptionKind::ALLOW_ALWAYS
    assert_equal "reject_once", Methods::PermissionOptionKind::REJECT_ONCE
    assert_equal "reject_always", Methods::PermissionOptionKind::REJECT_ALWAYS
    assert_equal %w[selected cancelled], Methods::PERMISSION_OUTCOMES
    assert_equal "selected", Methods::PermissionOutcome::SELECTED
    assert_equal "cancelled", Methods::PermissionOutcome::CANCELLED
  end

  def test_the_content_block_kinds
    assert_equal %w[text image audio resource_link resource], Methods::CONTENT_BLOCK_TYPES
    assert_equal "text", Methods::ContentBlock::TEXT
    assert_equal "image", Methods::ContentBlock::IMAGE
    assert_equal "audio", Methods::ContentBlock::AUDIO
    assert_equal "resource_link", Methods::ContentBlock::RESOURCE_LINK
    assert_equal "resource", Methods::ContentBlock::RESOURCE
  end

  def test_the_session_update_kinds_stable_v1_only
    assert_equal %w[user_message_chunk agent_message_chunk agent_thought_chunk tool_call tool_call_update plan
                    available_commands_update current_mode_update config_option_update session_info_update usage_update],
      Methods::SESSION_UPDATE_KINDS
    assert_equal "agent_message_chunk", Methods::SessionUpdate::AGENT_MESSAGE_CHUNK
    assert_equal "agent_thought_chunk", Methods::SessionUpdate::AGENT_THOUGHT_CHUNK
    assert_equal "user_message_chunk", Methods::SessionUpdate::USER_MESSAGE_CHUNK
    assert_equal "tool_call", Methods::SessionUpdate::TOOL_CALL
    assert_equal "tool_call_update", Methods::SessionUpdate::TOOL_CALL_UPDATE
    assert_equal "plan", Methods::SessionUpdate::PLAN
    assert_equal "available_commands_update", Methods::SessionUpdate::AVAILABLE_COMMANDS_UPDATE
    assert_equal "current_mode_update", Methods::SessionUpdate::CURRENT_MODE_UPDATE
    assert_equal "config_option_update", Methods::SessionUpdate::CONFIG_OPTION_UPDATE
    assert_equal "session_info_update", Methods::SessionUpdate::SESSION_INFO_UPDATE
    assert_equal "usage_update", Methods::SessionUpdate::USAGE_UPDATE
    assert_equal "sessionUpdate", Methods::SESSION_UPDATE_DISCRIMINATOR
  end

  def test_the_tool_call_vocabulary
    assert_equal %w[read edit delete move search execute think fetch switch_mode other], Methods::TOOL_KINDS
    assert_equal %w[pending in_progress completed failed], Methods::TOOL_CALL_STATUSES
    assert_equal %w[content diff terminal], Methods::TOOL_CALL_CONTENT_TYPES
    assert_equal "other", Methods::ToolKind::OTHER
    assert_equal "execute", Methods::ToolKind::EXECUTE
    assert_equal "pending", Methods::ToolCallStatus::PENDING
    assert_equal "in_progress", Methods::ToolCallStatus::IN_PROGRESS
    assert_equal "completed", Methods::ToolCallStatus::COMPLETED
    assert_equal "failed", Methods::ToolCallStatus::FAILED
  end

  def test_the_plan_vocabulary
    assert_equal %w[high medium low], Methods::PLAN_PRIORITIES
    assert_equal %w[pending in_progress completed], Methods::PLAN_STATUSES
  end

  def test_the_auth_elicitation_and_config_option_vocabularies
    assert_equal %w[agent terminal], Methods::AUTH_METHOD_TYPES
    assert_equal "agent", Methods::AuthMethodType::AGENT
    assert_equal "terminal", Methods::AuthMethodType::TERMINAL
    assert_equal %w[form url], Methods::ELICITATION_MODES
    assert_equal %w[accept decline cancel], Methods::ELICITATION_ACTIONS
    assert_equal "accept", Methods::ElicitationAction::ACCEPT
    assert_equal "decline", Methods::ElicitationAction::DECLINE
    assert_equal "cancel", Methods::ElicitationAction::CANCEL
    assert_equal %w[select boolean], Methods::CONFIG_OPTION_TYPES
    assert_equal %w[mode model model_config thought_level], Methods::CONFIG_OPTION_CATEGORIES
    assert_equal %w[http sse], Methods::MCP_SERVER_TYPES, "a stdio entry carries no type field"
  end

  # THE CAPABILITY SHAPES (`ClientCapabilities`/`AgentCapabilities`): the key lists,
  # camelCase as the schema spells them, and the two documents each role sends when it
  # claims nothing beyond the baseline.
  def test_the_capability_shapes
    assert_equal %w[fs terminal auth elicitation session], Methods::CLIENT_CAPABILITY_KEYS
    assert_equal %w[readTextFile writeTextFile], Methods::FS_CAPABILITY_KEYS
    assert_equal %w[loadSession promptCapabilities mcpCapabilities sessionCapabilities auth], Methods::AGENT_CAPABILITY_KEYS
    assert_equal %w[image audio embeddedContext], Methods::PROMPT_CAPABILITY_KEYS
    assert_equal %w[http sse], Methods::MCP_CAPABILITY_KEYS
    assert_equal %w[list delete additionalDirectories resume close], Methods::SESSION_CAPABILITY_KEYS
    assert_equal %w[form url], Methods::ELICITATION_CAPABILITY_KEYS

    assert_equal({ "fs" => { "readTextFile" => false, "writeTextFile" => false }, "terminal" => false,
                   "auth" => { "terminal" => false } }, Methods::BASELINE_CLIENT_CAPABILITIES)
    assert_equal({ "loadSession" => false,
                   "promptCapabilities" => { "image" => false, "audio" => false, "embeddedContext" => false },
                   "mcpCapabilities" => { "http" => false, "sse" => false } }, Methods::BASELINE_AGENT_CAPABILITIES)
    assert Methods::BASELINE_CLIENT_CAPABILITIES.frozen?
    assert Methods::BASELINE_AGENT_CAPABILITIES.frozen?
    assert Methods::BASELINE_AGENT_CAPABILITIES.fetch("promptCapabilities").frozen?
  end

  def test_the_module_holds_data_only
    assert_empty Methods.singleton_methods.grep_v(/__RBS_TEST_/)
    assert_empty Methods.instance_methods(false)
  end
end

# THE SURFACE'S TABLE against the core double: the
# initialize document byte-pinned (mcpCapabilities http true, authMethods
# non-empty), -32601 for the rest, -32002 for an unknown session, -32600
# for a second prompt, the runner-mode refusal by sentence, -32000 naming
# the methods when not connected, -32603 with Core's sentence when no
# daemon runs, the modes and config options, the PromptResponse table's
# refusals (the hold, the terminal failure, the block), the surface
# commands, `$/cancel_request` against a load, and `authenticate`.
class AcpAgentMethodsTest < Minitest::Test
  Methods = Rho::Acp::Methods
  Agent = Rho::Acp::Agent
  SNAPSHOT = ["snapshot", { "turn" => "trn_1", "run_public_id" => "alp_1" }].freeze
  COMPLETED = ["turn_status", { "turn_public_id" => "trn_1", "run_public_id" => "alp_1", "status" => "completed", "run_status" => "completed" }].freeze
  CLOSED = ["closed", {}].freeze
  DONE = [SNAPSHOT, COMPLETED, CLOSED].freeze

  def setup
    @core = RhoAcpTest::CoreDouble.new
  end

  def teardown
    @harness&.close
  end

  def open(**options)
    @harness = RhoAcpTest::AgentHarness.new(core: @core, **options)
  end

  def ready(capabilities: RhoAcpTest::AgentHarness.capabilities, **options)
    harness = open(**options)
    harness.initialize_agent(capabilities: capabilities)
    harness.new_session(cwd: "/tmp")
    harness
  end

  def test_the_initialize_document_is_byte_pinned
    harness = open
    document = harness.initialize_agent

    expected = '{"protocolVersion":1,"agentInfo":{"name":"rho","title":"rho","version":"' + Rho::VERSION + '"},' \
      '"agentCapabilities":{"loadSession":true,"promptCapabilities":{"image":true,"audio":false,"embeddedContext":true},' \
      '"mcpCapabilities":{"http":true,"sse":false},"sessionCapabilities":{"resume":{},"close":{},"additionalDirectories":{}}},' \
      '"authMethods":[{"id":"nexus","name":"Connect this machine to Nexus","description":"opens the device page"}]}'
    assert_equal expected, JSON.generate(document)
    refute_empty document["authMethods"]
    refute @core.called?(:require_daemon), "initialize makes no kernel call"
  end

  def test_a_terminal_capable_client_is_offered_the_connect_method_too
    harness = open
    document = harness.initialize_agent(capabilities: RhoAcpTest::AgentHarness.capabilities(terminal_auth: true))

    assert_equal [
      { "id" => "nexus", "name" => "Connect this machine to Nexus", "description" => "opens the device page" },
      { "id" => "connect", "type" => "terminal", "name" => "Connect from the terminal", "args" => ["connect"] },
    ], document["authMethods"]
  end

  def test_any_protocol_version_is_answered_with_one
    harness = open
    document = harness.request(Methods::INITIALIZE, { "protocolVersion" => 7, "clientCapabilities" => {} })

    assert_equal 1, document["protocolVersion"]
  end

  def test_unknown_methods_and_the_absent_capabilities_are_method_not_found
    harness = open
    harness.initialize_agent
    %w[session/list session/delete logout session/fork providers/list mcp/list nes/x document/open _custom/thing bogus].each do |method|
      assert_equal(-32601, harness.refused(method, {}).code, method)
    end
    harness.notify("_custom/note", {})
    assert_equal({}, harness.request(Methods::SESSION_CLOSE, { "sessionId" => harness.new_session(cwd: "/tmp")["sessionId"] }))
  end

  def test_an_unknown_session_is_resource_not_found
    harness = open
    harness.initialize_agent
    [
      [Methods::SESSION_PROMPT, { "sessionId" => "cnv_none", "prompt" => [] }],
      [Methods::SESSION_SET_MODE, { "sessionId" => "cnv_none", "modeId" => "ask" }],
      [Methods::SESSION_SET_CONFIG_OPTION, { "sessionId" => "cnv_none", "configId" => "mode", "value" => "ask" }],
      [Methods::SESSION_CLOSE, { "sessionId" => "cnv_none" }],
    ].each do |method, params|
      error = harness.refused(method, params)
      assert_equal(-32002, error.code, method)
      assert_includes error.message, "cnv_none"
    end
  end

  def test_a_second_prompt_while_one_runs_is_invalid_request
    live = Queue.new
    @core.events["cnv_1"] = live
    harness = ready
    first = harness.start_prompt("cnv_1", "one")
    live << SNAPSHOT
    harness.await_update("agent_message_chunk", timeout: 1) rescue nil
    error = harness.refused(Methods::SESSION_PROMPT, { "sessionId" => "cnv_1", "prompt" => [{ "type" => "text", "text" => "two" }] })

    assert_equal(-32600, error.code)
    live << COMPLETED << CLOSED
    assert_equal "end_turn", first.wait(timeout: 5)["stopReason"]
  end

  def test_a_prompt_response_allows_the_next_prompt_before_its_thread_returns
    @core.events["cnv_1"] = [DONE.dup]
    harness = ready

    pause_first_prompt_reply(harness, :respond) do
      assert_equal "end_turn", harness.prompt("cnv_1", "one")["stopReason"]
      assert_equal "end_turn", harness.prompt("cnv_1", "/compact")["stopReason"]
      assert_equal [[["cnv_1"], {}]], @core.calls_of(:compact)
    end
  end

  def test_a_prompt_error_allows_the_next_prompt_before_its_thread_returns
    @core.say_answers << { "pending" => true, "blocked" => "unknown_model" }
    harness = ready

    pause_first_prompt_reply(harness, :fail) do
      error = harness.refused(Methods::SESSION_PROMPT, { "sessionId" => "cnv_1", "prompt" => [{ "type" => "text", "text" => "go" }] })
      assert_equal(-32602, error.code)
      assert_equal "end_turn", harness.prompt("cnv_1", "/compact")["stopReason"]
      assert_equal [[["cnv_1"], {}]], @core.calls_of(:compact)
    end
  end

  def test_a_runner_mode_home_answers_initialize_and_refuses_new_by_sentence
    @core.settings.mode = "runner"
    harness = open
    harness.initialize_agent
    error = harness.refused(Methods::SESSION_NEW, { "cwd" => "/tmp", "mcpServers" => [] })

    assert_equal(-32603, error.code)
    assert_equal "this rho runs in mode runner: it opens no conversations", error.message
    refute @core.called?(:open_conversation)
  end

  def test_not_connected_is_auth_required_naming_the_methods
    @core.connected = false
    harness = open
    harness.initialize_agent(capabilities: RhoAcpTest::AgentHarness.capabilities(terminal_auth: true))
    error = harness.refused(Methods::SESSION_NEW, { "cwd" => "/tmp", "mcpServers" => [] })

    assert_equal(-32000, error.code)
    assert_includes error.message, "nexus, connect"
    assert_equal({ "authMethods" => %w[nexus connect] }, error.data)
    refute @core.called?(:open_conversation)
  end

  def test_a_daemon_whose_status_is_not_active_is_not_connected
    @core.status_state = "connecting"
    harness = open
    harness.initialize_agent

    assert_equal(-32000, harness.refused(Methods::SESSION_NEW, { "cwd" => "/tmp", "mcpServers" => [] }).code)
  end

  def test_no_daemon_is_internal_with_cores_sentence
    @core.daemon = nil
    harness = open
    harness.initialize_agent
    error = harness.refused(Methods::SESSION_NEW, { "cwd" => "/tmp", "mcpServers" => [] })

    assert_equal(-32603, error.code)
    assert_equal "no local daemon is running; start one with `rho server`", error.message
  end

  def test_set_mode_applies_to_the_next_prompt_and_refuses_another_id
    @core.events["cnv_1"] = [DONE.dup]
    harness = ready
    assert_equal({}, harness.request(Methods::SESSION_SET_MODE, { "sessionId" => "cnv_1", "modeId" => "ask" }))
    assert_equal(-32602, harness.refused(Methods::SESSION_SET_MODE, { "sessionId" => "cnv_1", "modeId" => "yolo" }).code)
    harness.prompt("cnv_1", "go")

    assert_equal "ask", @core.calls_of(:say).first.last[:approval_mode]
    assert_empty harness.updates_of("current_mode_update")
  end

  def test_set_config_option_model_learns_a_known_ref_and_refuses_an_unknown_one
    @core.known_models = ["openrouter/other"]
    @core.events["cnv_1"] = [DONE.dup]
    harness = ready(model: "openrouter/flag")
    document = harness.request(Methods::SESSION_SET_CONFIG_OPTION, { "sessionId" => "cnv_1", "configId" => "model", "value" => "openrouter/other" })

    model = document["configOptions"].find { |option| option["id"] == "model" }
    assert_equal "openrouter/other", model["currentValue"]
    assert_equal %w[openrouter/other openrouter/flag openrouter/default-model], model["options"].map { |o| o["value"] }
    assert_equal(-32602, harness.refused(Methods::SESSION_SET_CONFIG_OPTION, { "sessionId" => "cnv_1", "configId" => "model", "value" => "nope/x" }).code)
    assert_equal(-32602, harness.refused(Methods::SESSION_SET_CONFIG_OPTION, { "sessionId" => "cnv_1", "configId" => "colour", "value" => "x" }).code)
    harness.prompt("cnv_1", "go")
    assert_equal "openrouter/other", @core.calls_of(:say).first.last[:model]

    mode = harness.request(Methods::SESSION_SET_CONFIG_OPTION, { "sessionId" => "cnv_1", "configId" => "mode", "value" => "rules" })
    assert_equal "rules", mode["configOptions"].first["currentValue"]
  end

  def test_the_session_document_carries_modes_model_and_conversation_code_mode
    harness = ready(mode: "ask", model: "openrouter/flag")
    document = harness.request(Methods::SESSION_RESUME, { "sessionId" => "cnv_1", "cwd" => "/tmp", "mcpServers" => [] })

    assert_equal "ask", document.dig("modes", "currentModeId")
    assert_equal %w[bypass ask rules], document.dig("modes", "availableModes").map { |m| m["id"] }
    assert_equal %w[mode model code_mode], document["configOptions"].map { |o| o["id"] }
    assert_equal "openrouter/flag", document["configOptions"].find { |o| o["id"] == "model" }["currentValue"]
    assert_equal "default", document["configOptions"].last["currentValue"]
  end

  def test_code_mode_changes_the_conversation_setting_and_survives_resume
    harness = ready
    ["off", "on", "default"].each do |value|
      document = harness.request(Methods::SESSION_SET_CONFIG_OPTION,
        { "sessionId" => "cnv_1", "configId" => "code_mode", "value" => value })
      assert_equal value, document.fetch("configOptions").last.fetch("currentValue")
    end
    assert_equal [false, true, nil], @core.calls_of(:update_conversation_code_mode).map { |_args, fields| fields.fetch(:code_mode) }

    @core.update_conversation_code_mode("cnv_1", code_mode: false)
    loaded = harness.request(Methods::SESSION_RESUME, { "sessionId" => "cnv_1", "cwd" => "/tmp", "mcpServers" => [] })
    assert_equal "off", loaded.fetch("configOptions").last.fetch("currentValue")
    error = harness.refused(Methods::SESSION_SET_CONFIG_OPTION,
      { "sessionId" => "cnv_1", "configId" => "code_mode", "value" => "auto" })
    assert_equal(-32602, error.code)
    assert_equal false, @core.conversation_code_mode("cnv_1").fetch("code_mode")
  end

  def test_loading_a_foreign_agent_conversation_omits_rho_code_mode
    harness = ready
    @core.define_singleton_method(:conversation_code_mode) do |_id|
      { "available" => false, "code_mode" => nil, "effective" => false }
    end
    loaded = harness.request(Methods::SESSION_RESUME, { "sessionId" => "cnv_1", "cwd" => "/tmp", "mcpServers" => [] })
    assert_equal %w[mode model], loaded.fetch("configOptions").map { |option| option.fetch("id") }
  end

  def test_a_blocked_input_is_invalid_params_with_the_kernels_word
    @core.say_answers << { "pending" => true, "blocked" => "unknown_model" }
    harness = ready
    error = harness.refused(Methods::SESSION_PROMPT, { "sessionId" => "cnv_1", "prompt" => [{ "type" => "text", "text" => "go" }] })

    assert_equal(-32602, error.code)
    assert_equal "the kernel blocked the input (unknown_model)", error.message
  end

  def test_a_hold_is_internal_with_the_two_commands_and_retry_reopens_it
    @core.events["cnv_1"] = [
      [SNAPSHOT, ["turn_status", { "turn_public_id" => "trn_1", "run_public_id" => "alp_1", "status" => "failed",
                                   "run_status" => "running", "failure_reason" => "the model call failed",
                                   "failure_reason_key" => "provider_error" }]],
      DONE.dup,
    ]
    harness = ready
    error = harness.refused(Methods::SESSION_PROMPT, { "sessionId" => "cnv_1", "prompt" => [{ "type" => "text", "text" => "go" }] })

    assert_equal(-32603, error.code)
    assert_equal "the model call failed", error.message
    assert_equal({ "hold" => true, "run_public_id" => "alp_1", "retry" => "/retry", "abandon" => "/abandon" }, error.data)

    assert_equal "end_turn", harness.prompt("cnv_1", "/retry")["stopReason"]
    assert_equal [[["alp_1"], {}]], @core.calls_of(:retry)
    assert_equal 1, @core.calls_of(:say).length, "/retry is no say"
  end

  # `/retry` re-follows only once the follower saw the turn leave
  # `failed` (`Turn.catch_up`): the row stays stale for two reads after
  # the retry — the kernel's `running` not landed yet — and a re-follow
  # on it would have answered the old hold to a retry that took.
  def test_retry_waits_for_the_follower_to_leave_failed_before_the_refollow
    @core = RhoAcpTest::SettlingCore.new
    @core.events["cnv_1"] = [
      [SNAPSHOT, ["turn_status", { "turn_public_id" => "trn_1", "run_public_id" => "alp_1", "status" => "failed",
                                   "run_status" => "running", "failure_reason" => "the model call failed",
                                   "failure_reason_key" => "provider_error" }]],
      DONE.dup,
    ]
    @core.settle("cnv_1", reads: 2,
      stale: { "public_id" => "cnv_1", "turn" => "trn_1", "run_public_id" => "alp_1", "status" => "failed", "run_status" => "running" },
      settled: { "public_id" => "cnv_1", "turn" => "trn_1", "run_public_id" => "alp_1", "status" => "running", "run_status" => "running" })
    harness = ready
    assert_equal true, harness.refused(Methods::SESSION_PROMPT, { "sessionId" => "cnv_1", "prompt" => [{ "type" => "text", "text" => "go" }] }).data["hold"]
    reads = @core.calls_of(:run_row).length

    assert_equal "end_turn", harness.prompt("cnv_1", "/retry")["stopReason"]
    assert_equal [[["alp_1"], {}]], @core.calls_of(:retry)
    assert_operator @core.calls_of(:run_row).length - reads, :>=, 2, "the row was polled until it left failed"
    assert_equal 2, @core.calls_of(:follower_events).length
  end

  def test_a_terminal_failure_is_internal_with_the_ids
    @core.events["cnv_1"] = [[SNAPSHOT, ["turn_status", { "turn_public_id" => "trn_1", "run_public_id" => "alp_1",
                                                          "status" => "failed", "run_status" => "completed",
                                                          "failure_reason" => "gone", "failure_reason_key" => "abandoned" }], CLOSED]]
    harness = ready
    error = harness.refused(Methods::SESSION_PROMPT, { "sessionId" => "cnv_1", "prompt" => [{ "type" => "text", "text" => "go" }] })

    assert_equal(-32603, error.code)
    assert_equal({ "run_public_id" => "alp_1", "turn" => "trn_1", "failure_reason_key" => "abandoned" }, error.data)
    assert_equal "gone", error.message
  end

  def test_abandon_and_compact_answer_end_turn_and_another_slash_word_is_posted_verbatim
    @core.events["cnv_1"] = [DONE.dup, DONE.dup]
    harness = ready
    harness.prompt("cnv_1", "one")
    assert_equal "end_turn", harness.prompt("cnv_1", "/compact")["stopReason"]
    assert_equal [[["cnv_1"], {}]], @core.calls_of(:compact)
    assert_equal "end_turn", harness.prompt("cnv_1", "/abandon now")["stopReason"]
    assert_equal [[["alp_1"], {}]], @core.calls_of(:abandon)
    assert_equal "end_turn", harness.prompt("cnv_1", "/my-skill do the thing")["stopReason"]

    assert_equal ["one", "/my-skill do the thing"], @core.calls_of(:say).map { |args, _| args[1] }
  end

  def test_a_turn_canceled_by_someone_else_is_cancelled
    @core.events["cnv_1"] = [[SNAPSHOT, ["turn_status", { "turn_public_id" => "trn_1", "run_public_id" => "alp_1", "status" => "canceled", "run_status" => "canceled" }], CLOSED]]
    harness = ready

    assert_equal({ "stopReason" => "cancelled" }, harness.prompt("cnv_1", "go"))
  end

  def test_conversation_ended_under_the_follow_is_resource_not_found_for_good
    @core.events["cnv_1"] = [[SNAPSHOT, ["conversation_ended", {}], CLOSED]]
    harness = ready
    error = harness.refused(Methods::SESSION_PROMPT, { "sessionId" => "cnv_1", "prompt" => [{ "type" => "text", "text" => "go" }] })

    assert_equal(-32002, error.code)
    assert_equal(-32002, harness.refused(Methods::SESSION_SET_MODE, { "sessionId" => "cnv_1", "modeId" => "ask" }).code)
  end

  def test_the_stream_ending_without_a_word_settles_on_the_row
    @core.rows["cnv_1"] = { "public_id" => "cnv_1", "turn" => "trn_1", "run_public_id" => "alp_1", "status" => "completed", "run_status" => "completed" }
    @core.events["cnv_1"] = [[SNAPSHOT]]
    harness = ready

    assert_equal "end_turn", harness.prompt("cnv_1", "go")["stopReason"]
  end

  def test_the_commands_update_lands_after_the_response_with_the_skills
    @core.skills_document = { "user" => [{ "name" => "deploy", "description" => "ship it" }], "workspace" => [], "project" => [{ "name" => "lint", "description" => nil }] }
    harness = ready
    update = harness.await_update("available_commands_update")

    assert_equal [
      { "name" => "retry", "description" => "Retry the holding turn (the turn failed and the loop is holding)" },
      { "name" => "abandon", "description" => "Abandon the holding turn" },
      { "name" => "compact", "description" => "Compact the conversation now" },
      { "name" => "deploy", "description" => "ship it" },
      { "name" => "lint", "description" => "" },
    ], update.dig("update", "availableCommands")
  end

  def test_cancel_request_against_a_load_aborts_the_replay
    slow = Class.new(RhoAcpTest::CoreDouble) do
      def turns(*args, **kwargs)
        sleep 0.15
        super
      end
    end.new
    slow.turns_pages = Array.new(40) { { "turns" => [], "pagination" => { "has_more" => true, "after_position" => 1 } } }
    slow.rows["cnv_9"] = { "public_id" => "cnv_9" }
    harness = open
    @core = slow
    harness = RhoAcpTest::AgentHarness.new(core: slow)
    @harness.close
    @harness = harness
    harness.initialize_agent
    pending = harness.client.request(Methods::SESSION_LOAD, { "sessionId" => "cnv_9", "cwd" => "/tmp", "mcpServers" => [] })
    sleep 0.2
    pending.cancel
    error = assert_raises(Rho::Acp::RemoteError) { pending.wait(timeout: 5) }

    assert_equal(-32800, error.code)
  end

  def test_authenticate_unknown_id_connected_and_the_code_without_a_card
    @core.connected = false
    @core.ceremony = { "phase" => "pending", "verification_uri" => "https://nexus.example/device",
                       "verification_uri_complete" => "https://nexus.example/device?code=ABCD", "user_code" => "ABCD" }
    harness = open
    harness.initialize_agent
    assert_equal(-32602, harness.refused(Methods::AUTHENTICATE, { "methodId" => "github" }).code)

    error = harness.refused(Methods::AUTHENTICATE, { "methodId" => "nexus" })
    assert_equal(-32000, error.code)
    assert_includes error.message, "https://nexus.example/device"
    assert_includes error.message, "ABCD"
    assert_equal({ "url" => "https://nexus.example/device?code=ABCD", "code" => "ABCD" }, error.data)

    @core.connected = true
    assert_equal({}, harness.request(Methods::AUTHENTICATE, { "methodId" => "nexus" }))
  end

  def test_authenticate_with_a_url_card_waits_for_the_connection_and_closes_the_card
    @core.connected = false
    @core.status_state = "connecting"
    @core.ceremony = { "phase" => "pending", "verification_uri" => "https://nexus.example/device",
                       "verification_uri_complete" => "https://nexus.example/device?code=ABCD", "user_code" => "ABCD" }
    seen = nil
    harness = open
    harness.policy = lambda do |inbound|
      seen = inbound.params
      @core.connected = true
      @core.status_state = "active"
      inbound.respond("action" => "accept")
    end
    harness.initialize_agent(capabilities: RhoAcpTest::AgentHarness.capabilities(url: true))

    assert_equal({}, harness.request(Methods::AUTHENTICATE, { "methodId" => "nexus" }, timeout: 10))
    assert_equal "url", seen["mode"]
    assert_equal "https://nexus.example/device?code=ABCD", seen["url"]
    assert_includes seen["message"], "ABCD"
    complete = harness.notifications.find { |frame| frame.method == Methods::ELICITATION_COMPLETE }
    assert_equal seen["elicitationId"], complete.params["elicitationId"]
  end

  # A START THAT JOINED another client's ceremony can answer the bare
  # `starting` phase: the daemon's short wait ran out before the Nexus
  # call answered, so the document has no code and no URL. The card is
  # built from the status once a pending document carries the code.
  BARE_START = { "phase" => "starting", "branch" => "combined", "mode" => "full" }.freeze
  PENDING = { "phase" => "pending", "branch" => "combined", "mode" => "full", "user_code" => "ABCD",
              "verification_uri" => "https://nexus.example/device",
              "verification_uri_complete" => "https://nexus.example/device?code=ABCD" }.freeze

  def test_authenticate_on_a_bare_joined_start_takes_the_card_from_the_status
    @core.connected = false
    @core.status_state = "connecting"
    @core.ceremony = BARE_START
    @core.status_connection = PENDING
    seen = nil
    harness = open
    harness.policy = lambda do |inbound|
      seen = inbound.params
      @core.connected = true
      @core.status_state = "active"
      @core.status_connection = nil
      inbound.respond("action" => "accept")
    end
    harness.initialize_agent(capabilities: RhoAcpTest::AgentHarness.capabilities(url: true))

    assert_equal({}, harness.request(Methods::AUTHENTICATE, { "methodId" => "nexus" }, timeout: 10))
    assert_equal "https://nexus.example/device?code=ABCD", seen["url"]
    assert_includes seen["message"], "ABCD"
    refute_match(/Open  and enter:/, seen["message"])
  end

  def test_authenticate_on_a_bare_joined_start_without_a_card_names_the_code_from_the_status
    @core.connected = false
    @core.status_state = "connecting"
    @core.ceremony = BARE_START
    @core.status_connection = PENDING
    harness = open
    harness.initialize_agent

    error = harness.refused(Methods::AUTHENTICATE, { "methodId" => "nexus" })
    assert_equal(-32000, error.code)
    assert_includes error.message, "https://nexus.example/device"
    assert_includes error.message, "ABCD"
    assert_equal({ "url" => "https://nexus.example/device?code=ABCD", "code" => "ABCD" }, error.data)
  end

  # A joined `activating` start has no code to show: the device page was
  # already approved, so the connection completes with no card at all.
  def test_authenticate_on_a_joined_activating_start_answers_once_connected_with_no_card
    @core.connected = false
    @core.status_state = "active"
    @core.ceremony = { "phase" => "activating", "branch" => "combined", "mode" => "full" }
    seen = nil
    harness = open
    harness.policy = lambda do |inbound|
      seen = inbound.params
      inbound.respond("action" => "accept")
    end
    harness.initialize_agent(capabilities: RhoAcpTest::AgentHarness.capabilities(url: true))

    assert_equal({}, harness.request(Methods::AUTHENTICATE, { "methodId" => "nexus" }, timeout: 10))
    assert_nil seen, "no card for a ceremony past its code"
    refute(harness.notifications.any? { |frame| frame.method == Methods::ELICITATION_COMPLETE })
  end

  # The ceremony's own error while the code is awaited is the answer.
  def test_authenticate_on_a_bare_joined_start_refuses_with_the_ceremonys_error
    @core.connected = false
    @core.status_state = "connecting"
    @core.ceremony = BARE_START
    @core.status_connection = { "phase" => "error", "branch" => "combined", "mode" => "full",
                                "error" => "the device code expired" }
    seen = nil
    harness = open
    harness.policy = lambda do |inbound|
      seen = inbound.params
      inbound.respond("action" => "accept")
    end
    harness.initialize_agent(capabilities: RhoAcpTest::AgentHarness.capabilities(url: true))

    error = harness.refused(Methods::AUTHENTICATE, { "methodId" => "nexus" })
    assert_equal(-32603, error.code)
    assert_equal "the device code expired", error.message
    assert_nil seen, "no card is built from a document without a code"
    refute(harness.notifications.any? { |frame| frame.method == Methods::ELICITATION_COMPLETE })
  end

  private

    # Hold the reply thread after its bytes reached the client, exposing
    # the boundary where an editor can immediately send another prompt.
    def pause_first_prompt_reply(harness, method)
      resume = Queue.new
      published = Queue.new
      first = true
      harness.agent.sessions["cnv_1"].define_singleton_method(:claim_prompt) do |holder|
        accepted = super(holder)
        if accepted && first
          first = false
          holder.define_singleton_method(method) do |*args, **kwargs|
            super(*args, **kwargs)
            published << Thread.current
            resume.pop(timeout: 5)
            nil
          end
        end
        accepted
      end
      yield
    ensure
      resume << true
      published.pop(timeout: 5)&.join(5)
    end
end
