require "test_helper"

# The profile's configuration block and its one writer: `PUT /profile/configuration` is a whole
# replacement by the Agent Profile itself, refused typed for the words nothing reads yet.
class AgentAPI::V1::ProfilesControllerTest < ActionDispatch::IntegrationTest
  BASH = {
    "type" => "function",
    "function" => { "name" => "bash", "description" => "Run a command",
                    "parameters" => { "type" => "object", "properties" => {} } },
  }.freeze
  READ = {
    "type" => "function",
    "function" => { "name" => "read", "description" => "Read a file",
                    "parameters" => { "type" => "object", "properties" => {} } },
  }.freeze
  RULES = [
    { "tool" => "bash", "path" => "command", "match" => "*rm -rf /*", "verdict" => "deny", "reason" => "no" },
    { "tool" => "memory_*|ask|task|compose", "verdict" => "allow" },
  ].freeze
  DECLARATION = {
    "tool_definitions" => [READ, BASH], "approval_mode" => "bypass", "approval_rules" => RULES,
    "prompt_mechanism" => "default", "prompt_template" => nil,
    "compaction_policy" => { "mode" => "kernel" },
  }.freeze
  TEMPLATE = {
    "blocks" => [{ "type" => "slot", "slot" => "system_prompt" }, { "type" => "history" }, { "type" => "input" }],
    "variables" => { "scene" => "dusk" },
  }.freeze

  setup do
    @agent = users(:agent)
    # An Agent's member credential is OAuth-only, so it comes from the real
    # connection ceremony rather than a fixture shortcut.
    connection = connect_agent_session(steward: users(:owner), agent_identifier: @agent.agent_identifier)
    @agent_secret = connection.access_secret
    @transport_secret = connection.executor_access_secret
    @human_secret = create_access_token_fixture(user: users(:member), name: "M").secret
  end

  test "an undeclared agent profile shows an empty configuration block" do
    get agent_api_v1_profile_path, headers: bearer(@agent_secret)

    assert_response :success
    assert_equal %w[configuration credential measured_at member], response.parsed_body.keys.sort
    assert_equal(
      { "tool_definitions" => [], "approval_mode" => nil, "approval_rules" => nil, "prompt_mechanism" => nil,
        "prompt_template" => nil, "compaction_policy" => nil, "default_model" => nil, "fallback_model" => nil,
        "lifecycle_hooks" => nil },
      response.parsed_body.fetch("configuration")
    )
  end

  test "a human profile carries no configuration block at all" do
    get agent_api_v1_profile_path, headers: bearer(@human_secret)

    assert_response :success
    assert_not response.parsed_body.key?("configuration")
  end

  test "lifecycle hooks round trip as a whole declaration and require tool approval policy" do
    hooks = { "stop" => { "tool" => "check_lifecycle", "timeout_ms" => 30_000, "max_continuations" => 2 } }
    put agent_api_v1_profile_configuration_path,
      params: { configuration: { lifecycle_hooks: hooks, approval_mode: "bypass" } },
      headers: bearer(@agent_secret), as: :json
    assert_response :success
    assert_equal hooks, response.parsed_body.dig("configuration", "lifecycle_hooks")
    assert_empty response.parsed_body.dig("configuration", "tool_definitions")

    put agent_api_v1_profile_configuration_path,
      params: { configuration: { lifecycle_hooks: hooks } }, headers: bearer(@agent_secret), as: :json
    assert_response :unprocessable_content
    assert_equal hooks, @agent.reload.lifecycle_hooks

    put agent_api_v1_profile_configuration_path,
      params: { configuration: { approval_mode: "bypass" } }, headers: bearer(@agent_secret), as: :json
    assert_response :success
    assert_nil response.parsed_body.dig("configuration", "lifecycle_hooks")
  end

  test "the declaration is written whole and read back canonical" do
    put agent_api_v1_profile_configuration_path,
      params: { configuration: DECLARATION }, headers: bearer(@agent_secret), as: :json

    assert_response :success
    body = response.parsed_body
    assert_equal @agent.public_id, body.dig("member", "public_id")
    assert_equal @agent.handle, body.dig("member", "handle"), "the member's handle rides the profile"
    assert_equal %w[bash read],
      body.dig("configuration", "tool_definitions").map { |entry| entry.dig("function", "name") }
    assert_equal "bypass", body.dig("configuration", "approval_mode")
    assert_equal RULES, body.dig("configuration", "approval_rules"), "the rule list round-trips as sent"
    assert_equal({ "mode" => "kernel" }, body.dig("configuration", "compaction_policy"))

    get agent_api_v1_profile_path, headers: bearer(@agent_secret)
    assert_equal body.fetch("configuration"), response.parsed_body.fetch("configuration")
  end

  # THE SEVENTH FIELD over HTTP: the profile's own model round-trips as a catalog ref; a ref this
  # account may not run is a validation failure naming the field with the resolver's word.
  test "default_model declares as a catalog ref and an unauthorized one is a validation failure naming it" do
    DevModelLane.ensure_enabled!(@agent.account)
    put agent_api_v1_profile_configuration_path,
      params: { configuration: DECLARATION.merge("default_model" => "dev/mock-text") },
      headers: bearer(@agent_secret), as: :json

    assert_response :success
    assert_equal "dev/mock-text", response.parsed_body.dig("configuration", "default_model")
    get agent_api_v1_profile_path, headers: bearer(@agent_secret)
    assert_equal "dev/mock-text", response.parsed_body.dig("configuration", "default_model")

    put agent_api_v1_profile_configuration_path,
      params: { configuration: DECLARATION.merge("default_model" => "dev/no-such-model") },
      headers: bearer(@agent_secret), as: :json
    assert_response :unprocessable_content
    assert_equal "validation_failed", response.parsed_body.dig("error", "code")
    assert_match(/Default model is not a model this account may run \(unknown_model\)/,
      response.parsed_body.dig("error", "message"))
    assert_equal "dev/mock-text", @agent.reload.default_model, "a refused declaration writes nothing"
  end

  # THE NINTH FIELD over HTTP: the model a declined step re-runs on round-trips as a catalog ref,
  # judged as the seventh is.
  test "fallback_model declares as a catalog ref and an unauthorized one is a validation failure naming it" do
    DevModelLane.ensure_enabled!(@agent.account)
    put agent_api_v1_profile_configuration_path,
      params: { configuration: DECLARATION.merge("fallback_model" => "dev/mock-unmetered") },
      headers: bearer(@agent_secret), as: :json

    assert_response :success
    assert_equal "dev/mock-unmetered", response.parsed_body.dig("configuration", "fallback_model")
    get agent_api_v1_profile_path, headers: bearer(@agent_secret)
    assert_equal "dev/mock-unmetered", response.parsed_body.dig("configuration", "fallback_model")

    put agent_api_v1_profile_configuration_path,
      params: { configuration: DECLARATION.merge("fallback_model" => "dev/no-such-model") },
      headers: bearer(@agent_secret), as: :json
    assert_response :unprocessable_content
    assert_equal "validation_failed", response.parsed_body.dig("error", "code")
    assert_match(/Fallback model is not a model this account may run \(unknown_model\)/,
      response.parsed_body.dig("error", "message"))
    assert_equal "dev/mock-unmetered", @agent.reload.fallback_model, "a refused declaration writes nothing"
  end

  # PUT is a full replacement: the tool list is a SET at the front of every cached prefix, and a
  # merged set is a different prefix.
  test "a second declaration replaces the whole block; omitted fields clear" do
    put agent_api_v1_profile_configuration_path,
      params: { configuration: DECLARATION }, headers: bearer(@agent_secret), as: :json
    put agent_api_v1_profile_configuration_path,
      params: { configuration: { "tool_definitions" => [BASH], "approval_mode" => "ask", "prompt_mechanism" => "raw" } },
      headers: bearer(@agent_secret), as: :json

    assert_response :success
    assert_equal(
      { "tool_definitions" => [BASH], "approval_mode" => "ask", "approval_rules" => nil, "prompt_mechanism" => "raw",
        "prompt_template" => nil, "compaction_policy" => nil, "default_model" => nil, "fallback_model" => nil,
        "lifecycle_hooks" => nil },
      response.parsed_body.fetch("configuration")
    )
  end

  # The alias through HTTP: the compact entry in, the render out — the same read a turn's
  # materialization takes.
  test "an alias is declared compact and read back as the profile's render, with its facts" do
    put agent_api_v1_profile_configuration_path,
      params: { configuration: DECLARATION.merge("tool_definitions" => [READ, LoopLaneTestHelper::AGENT_ALIAS]) },
      headers: bearer(@agent_secret), as: :json

    assert_response :success
    agent = response.parsed_body.dig("configuration", "tool_definitions").find { |e| e.dig("function", "name") == "Agent" }
    assert_equal %w[canonical function params type], agent.keys.sort
    assert_equal "nexus.graph.task", agent.fetch("canonical")
    assert_includes agent.dig("function", "description"), "→ one message: Agent({prompt:", "the worked example spells the alias (C-S2)"
    assert_equal true, agent.dig("function", "parameters", "properties", "run_in_background", "default")

    get agent_api_v1_profile_path, headers: bearer(@agent_secret)
    assert_equal agent, response.parsed_body.dig("configuration", "tool_definitions").find { |e| e.dig("function", "name") == "Agent" }
  end

  test "an alias refusal is a validation failure naming the word" do
    entry = { "name" => "task", "canonical" => "nexus.graph.compose" }
    put agent_api_v1_profile_configuration_path,
      params: { configuration: DECLARATION.merge("tool_definitions" => [READ, entry]) },
      headers: bearer(@agent_secret), as: :json

    assert_response :unprocessable_content
    assert_equal "validation_failed", response.parsed_body.dig("error", "code")
    assert_match(/kernel spelling/, response.parsed_body.dig("error", "message"))
  end

  # NO SILENT DEFAULT: tools declared without a mode are a validation failure naming the field; the
  # three words all declare.
  test "tools without an approval mode are refused, and every mode declares" do
    put agent_api_v1_profile_configuration_path,
      params: { configuration: DECLARATION.except("approval_mode") },
      headers: bearer(@agent_secret), as: :json
    assert_response :unprocessable_content
    assert_equal "validation_failed", response.parsed_body.dig("error", "code")
    assert_match(/Approval mode/, response.parsed_body.dig("error", "message"))
    assert_nil @agent.reload.approval_mode

    %w[ask rules].each do |mode|
      put agent_api_v1_profile_configuration_path,
        params: { configuration: DECLARATION.merge("approval_mode" => mode) },
        headers: bearer(@agent_secret), as: :json
      assert_response :success, mode
      assert_equal mode, response.parsed_body.dig("configuration", "approval_mode")
      assert_equal mode, @agent.reload.approval_mode
    end
  end

  test "a malformed rule is a validation failure naming the fault; assembly declares with its template" do
    put agent_api_v1_profile_configuration_path,
      params: { configuration: DECLARATION.merge("approval_rules" => [{ "tool" => "bash", "verdict" => "deny", "scope" => "x" }]) },
      headers: bearer(@agent_secret), as: :json
    assert_response :unprocessable_content
    assert_equal "validation_failed", response.parsed_body.dig("error", "code")
    assert_match(/Approval rules .*scope/, response.parsed_body.dig("error", "message"))
    assert_nil @agent.reload.approval_rules

    put agent_api_v1_profile_configuration_path,
      params: { configuration: DECLARATION.merge("prompt_mechanism" => "assembly") },
      headers: bearer(@agent_secret), as: :json
    assert_response :unprocessable_content
    assert_equal "validation_failed", response.parsed_body.dig("error", "code")
    assert_match(/Prompt template/, response.parsed_body.dig("error", "message"), "assembly needs its template")

    put agent_api_v1_profile_configuration_path,
      params: { configuration: DECLARATION.merge("prompt_mechanism" => "assembly", "prompt_template" => TEMPLATE) },
      headers: bearer(@agent_secret), as: :json
    assert_response :success
    assert_equal "assembly", response.parsed_body.dig("configuration", "prompt_mechanism")
    assert_equal TEMPLATE, response.parsed_body.dig("configuration", "prompt_template")
    assert_equal TEMPLATE, @agent.reload.prompt_template

    put agent_api_v1_profile_configuration_path,
      params: { configuration: DECLARATION.merge("prompt_mechanism" => "assembly",
        "prompt_template" => TEMPLATE.merge("blocks" => TEMPLATE.fetch("blocks") + [{ "type" => "memory" }])) },
      headers: bearer(@agent_secret), as: :json
    assert_response :unprocessable_content
    assert_equal "validation_failed", response.parsed_body.dig("error", "code")
    assert_match(%r{/blocks/3}, response.parsed_body.dig("error", "message"), "the path of the block after input")
  end

  test "a declaration the model refuses is a validation failure" do
    reserved = BASH.merge("function" => BASH.fetch("function").merge("name" => "spawn"))
    put agent_api_v1_profile_configuration_path,
      params: { configuration: DECLARATION.merge("tool_definitions" => [reserved]) },
      headers: bearer(@agent_secret), as: :json

    assert_response :unprocessable_content
    assert_equal "validation_failed", response.parsed_body.dig("error", "code")
    assert_match(/Tool definitions/, response.parsed_body.dig("error", "message"))
  end

  test "a human has no declaration to write" do
    put agent_api_v1_profile_configuration_path,
      params: { configuration: DECLARATION }, headers: bearer(@human_secret), as: :json

    assert_response :forbidden
    assert_equal "not_agent_profile", response.parsed_body.dig("error", "code")
  end

  test "a body without its root is 400, and the transport plane is fenced" do
    put agent_api_v1_profile_configuration_path,
      params: { approval_mode: "bypass" }, headers: bearer(@agent_secret), as: :json
    assert_response :bad_request
    assert_equal "parameter_missing", response.parsed_body.dig("error", "code")

    put agent_api_v1_profile_configuration_path,
      params: { configuration: DECLARATION }, headers: bearer(@transport_secret), as: :json
    assert_response :unauthorized
  end

  private

    def bearer(secret)
      { "Authorization" => "Bearer #{secret}" }
    end

  test "a rename leaves the member block its five keys: no previous handle, no redirect hint (S-A2 step 3c)" do
    @agent.update!(handle: "lark-x")

    get agent_api_v1_profile_path, headers: bearer(@agent_secret)

    assert_response :success
    assert_equal %w[display_name handle kind public_id role], response.parsed_body.fetch("member").keys.sort
    assert_equal "lark-x", response.parsed_body.dig("member", "handle")
  end
end
