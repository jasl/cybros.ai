require "support/daemon_run_helpers"

class DaemonCodeModeTest < Minitest::Test
  include RhoTest::DaemonRunHelpers

  def test_new_conversations_capture_mode_defaults_and_existing_choices_survive_settings_changes
    api = kernel_api(user_public_id: IDENTITY.user_public_id, conversation_events: [])
    daemon = member_ready(boot(config: catalog_config("subagent_default" => false,
      "plugins" => { "rho.codemode" => { "configuration_version" => 1, "configuration" => { "default" => "off" } } }),
      realtime_factory: ->(*) { nil }), api)
    _, opened = open(daemon, {})
    id = opened.dig("conversation", "public_id")
    assert_equal false, store.find(id).code_mode
    assert_equal false, store.find(id).subagent
    daemon.stop
    restarted = member_ready(boot(realtime_factory: ->(*) { nil }), api)
    response = request(restarted, :get, "/conversations/modes?public_id=#{id}", token: bearer(restarted))
    assert_equal "200", response.code, response.body
    assert_equal({ "code_mode" => false, "subagent" => false, "available" => true, "code_mode_available" => true },
      JSON.parse(response.body).fetch("modes"))
    _, fresh = open(restarted, {})
    assert_equal true, host_store(restarted).find(fresh.dig("conversation", "public_id")).code_mode
    assert_equal true, host_store(restarted).find(fresh.dig("conversation", "public_id")).subagent
  end

  def test_global_default_request_override_and_explicit_names_share_one_policy
    api = kernel_api(user_public_id: IDENTITY.user_public_id, conversation_events: [])
    daemon = member_ready(boot(config: catalog_config("plugins" => { "rho.codemode" => { "configuration_version" => 1, "configuration" => { "default" => "off" } } }), realtime_factory: ->(*) { nil }), api, identity: RUNNER_IDENTITY)
    status, opened = open(daemon, {})
    assert_equal "201", status, opened.inspect
    id = opened.dig("conversation", "public_id")

    input = say(daemon, api, id)
    refute_includes input.fetch("tool_names"), "code"
    refute_match(/^- code:/, input.dig("inline", 0, "text"))
    input = say(daemon, api, id, code_mode: true)
    assert_nil input["tool_names"]
    assert_match(/^- code:/, input.dig("inline", 0, "text"))
    assert_equal true, store.find(id).code_mode
    assert_nil say(daemon, api, id)["tool_names"], "omission retains the conversation override"

    input = say(daemon, api, id, code_mode: false, tool_names: %w[code read])
    assert_equal ["read"], input.fetch("tool_names")
    assert_equal false, store.find(id).code_mode
    assert_includes daemon.context.registry.names, "code", "turn policy must not unregister pending executors"
  end

  def test_conversation_policy_can_be_read_updated_and_restored_after_cache_loss
    api = kernel_api(user_public_id: IDENTITY.user_public_id, conversation_events: [])
    daemon = member_ready(boot(realtime_factory: ->(*) { nil }), api)
    _, opened = open(daemon, code_mode: false)
    id = opened.dig("conversation", "public_id")
    read = policy(daemon, id)
    assert_equal({ "code_mode" => false, "subagent" => true, "available" => true, "code_mode_available" => true }, read)
    response = request(daemon, :patch, "/conversations/modes", token: bearer(daemon), body: { public_id: id, code_mode: true })
    assert_equal "200", response.code, response.body
    assert_equal true, policy(daemon, id).fetch("code_mode")
    cache_path = daemon.home.host_cache_path(IDENTITY.user_public_id)
    refute JSON.parse(File.read(cache_path)).fetch("hosts").first.key?("code_mode")
    daemon.stop
    FileUtils.rm_f(cache_path)
    restarted = member_ready(boot(realtime_factory: ->(*) { nil }), api)
    response = request(restarted, :post, "/followers/attach", token: bearer(restarted), body: { public_id: id, host_type: "conversation" })
    assert_equal "200", response.code, response.body
    assert_equal true, host_store(restarted).find(id).code_mode
    response = request(restarted, :patch, "/conversations/modes", token: bearer(restarted), body: { public_id: id, code_mode: nil })
    assert_equal "400", response.code, response.body
    assert_equal true, policy(restarted, id).fetch("code_mode")
  end

  def test_invalid_overrides_fail_before_open_and_foreign_answerers_keep_their_own_surface
    api = kernel_api(user_public_id: IDENTITY.user_public_id, conversation_events: [],
      principals: [{ public_id: "other", handle: "other", kind: "agent", display_name: "Other", agent_identifier: "other", steward_public_id: "steward" }.transform_keys(&:to_s)])
    now = Time.utc(2026, 10, 5)
    daemon = member_ready(boot(realtime_factory: ->(*) { nil }, clock: -> { now += 60 }, sleeper: ->(_) { }), api)
    status, = open(daemon, code_mode: "off")
    assert_equal "400", status
    assert_empty api.conversation_creates
    status, = open(daemon, agent: "@other", code_mode: false)
    assert_equal "400", status
    assert_empty api.conversation_creates
    status, opened = open(daemon, agent: "@other")
    assert_equal "201", status
    id = opened.dig("conversation", "public_id")
    input = say(daemon, api, id)
    refute input.key?("tool_names")
    refute input.key?("inline")
    response = request(daemon, :post, "/say", token: bearer(daemon), body: { public_id: id, text: "hi", code_mode: true })
    assert_equal "400", response.code, response.body
    assert_equal false, policy(daemon, id).fetch("available")
    response = request(daemon, :patch, "/conversations/modes", token: bearer(daemon), body: { public_id: id, code_mode: false })
    assert_equal "400", response.code, response.body
    status, = open(daemon, agent: "@other", prompt: "work", model: "dev/model")
    assert_equal "201", status
  end

  def test_remote_conversation_and_standalone_apply_global_off_and_explicit_on
    api = kernel_api(user_public_id: IDENTITY.user_public_id, conversation_events: [],
      executors: [NexusDoubles.remote_runner("remote", tools: [NexusDoubles.served_tool("code"), NexusDoubles.served_tool("slow_read")])])
    daemon = member_ready(boot(config: catalog_config("plugins" => { "rho.codemode" => { "configuration_version" => 1, "configuration" => { "default" => "off" } } }), realtime_factory: ->(*) { nil }), api)
    status, opened = open(daemon, default_runner_executor_public_id: "remote")
    assert_equal "201", status, opened.inspect
    id = opened.dig("conversation", "public_id")
    refute_includes say(daemon, api, id).fetch("tool_names"), "code"
    remote_code = NexusDoubles.runner_tool_name("remote", "code")
    remote_read = "slow_read"
    refute_includes say(daemon, api, id).fetch("tool_names"), remote_code
    assert_nil say(daemon, api, id, code_mode: true)["tool_names"], "enabled uses the complete declaration"
    assert_equal [remote_read], say(daemon, api, id, code_mode: false,
      tool_names: ["code", remote_code, remote_read]).fetch("tool_names")
    declarations = api.configuration_declarations.last.dig("configuration", "tool_definitions")
    assert_includes declarations.map { |entry| entry.dig("function", "name") }, "code"
    [nil, "remote"].each do |runner|
      [false, true].each do |enabled|
        fields = { prompt: "work", model: "dev/model", code_mode: enabled }
        fields[:default_runner_executor_public_id] = runner if runner
        response = request(daemon, :post, "/runs", token: bearer(daemon), body: fields)
        assert_equal "201", response.code, response.body
        names = JSON.parse(response.body).fetch("tools")
        assert_equal enabled, names.include?("code")
        assert_equal enabled, names.include?(remote_code) if runner
      end
    end
  end

  def test_bot_keeps_its_declared_subset_with_code_mode_off_and_refuses_conversation_overrides
    model = { "ref" => "dev/model", "provider" => "dev", "workload" => "text_generation", "visible" => true, "available" => true,
              "unavailable_reason" => nil, "capabilities" => {}, "pricing" => { "state" => "unknown" } }
    api = kernel_api(user_public_id: IDENTITY.user_public_id, conversation_events: [], models: [model],
      workspaces: [{ public_id: "ws-1", name: "Home", dedicated: false }])
    daemon = member_ready(boot(config: catalog_config("plugins" => { "rho.codemode" => { "configuration_version" => 1, "configuration" => { "default" => "off" } } }), realtime_factory: ->(*) { nil }), api, identity: RUNNER_IDENTITY)
    preset = daemon.context.agent_presets do |catalog|
      catalog.create(name: "Author", description: "Authors work", configuration: { "tools" => [], "runner_tool_names" => %w[code read], "model" => "dev/model" })
    end
    daemon.context.declare_named_definition(name: "author", description: "Authors work", preset_public_id: preset.public_id)
    named = daemon.host_followers.named_edge.answers.fetch("author")
    api.stock_principals([named.to_h.transform_keys(&:to_s).slice("public_id", "handle", "kind", "display_name", "agent_identifier", "steward_public_id")])
    daemon.context.replace_bot_settings(agent_public_id: named.public_id, home_workspace_public_id: "ws-1")
    opened = request(daemon, :post, "/bots/current", token: bearer(daemon),
      body: { agent_public_id: named.public_id, operation_id: "open-author" })
    assert_equal "200", opened.code, opened.body
    id = JSON.parse(opened.body).dig("current", "public_id")
    assert_equal ["read"], say(daemon, api, id).fetch("tool_names")
    [true, false].each do |value|
      response = request(daemon, :post, "/say", token: bearer(daemon),
        body: { public_id: id, text: "next", model: "dev/model", wait: false, code_mode: value })
      assert_equal "409", response.code, response.body
      assert_equal "bot_modes_managed", JSON.parse(response.body).dig("error", "code")
    end
    assert_equal({ "code_mode" => false, "subagent" => true, "available" => true, "code_mode_available" => false }, policy(daemon, id))
    response = request(daemon, :patch, "/conversations/modes", token: bearer(daemon), body: { public_id: id, code_mode: false })
    assert_equal "409", response.code, response.body
    assert_equal "bot_modes_managed", JSON.parse(response.body).dig("error", "code")
    assert_equal ["read"], say(daemon, api, id).fetch("tool_names")
    response = request(daemon, :post, "/side", token: bearer(daemon), body: { parent_public_id: id, tools: "write" })
    assert_equal "409", response.code, response.body
    assert_equal "bot_conversation_required", JSON.parse(response.body).dig("error", "code")
    assert_empty api.forks
  end

  def test_registered_answerer_side_preserves_its_subset_and_conversation_override
    definition = Rho::Agents::Definition.new(name: "author", description: "Authors work", tools: %w[code read],
      model: nil, body: "Complete the task.", path: "<extension>", ignored_keys: [])
    extension = Module.new do
      const_set(:NAME, "rho.author")
      define_singleton_method(:register) { |api| api.register_agent(definition) }
    end
    api = kernel_api(user_public_id: IDENTITY.user_public_id, conversation_events: [])
    daemon = member_ready(boot(config: catalog_config, extensions: Rho::Extensions::DEFAULT_EXTENSIONS + [extension],
      realtime_factory: ->(*) { nil }), api, identity: RUNNER_IDENTITY)
    daemon.context.declare_profile
    api.stock_principals(api.named_agents_listing.body.fetch("agents").map do |row|
      row.slice("public_id", "handle", "kind", "display_name", "agent_identifier", "steward_public_id")
    end)
    status, opened = open(daemon, agent: "@author", code_mode: false)
    assert_equal "201", status, opened.inspect
    id = opened.dig("conversation", "public_id")
    input = say(daemon, api, id)
    assert_equal "Complete the task.", input.dig("execution_declaration", "system_prompt", "content")
    assert_equal ["read"], input.fetch("tool_names")
    response = request(daemon, :post, "/side", token: bearer(daemon), body: { parent_public_id: id, tools: "write" })
    assert_equal "201", response.code, response.body
    side_id = JSON.parse(response.body).dig("side", "public_id")
    assert_equal false, store.find(side_id).code_mode
    refute_includes say(daemon, api, side_id).fetch("tool_names"), "code"
    response = request(daemon, :post, "/side", token: bearer(daemon), body: { parent_public_id: id, tools: "write" })
    assert_equal "200", response.code, response.body
    assert_equal ["read"], say(daemon, api, side_id).fetch("tool_names"), "write cannot expand the named answerer's declaration or enable code"
    runner_code = NexusDoubles.runner_tool_name(RUNNER_IDENTITY.runner_executor_public_id, "code")
    assert_equal ["code", runner_code, "read"].sort, say(daemon, api, side_id, code_mode: true).fetch("tool_names").sort
  end

  private

    def say(daemon, api, id, **fields)
      response = request(daemon, :post, "/say", token: bearer(daemon),
        body: { public_id: id, text: "next", model: "dev/model", wait: false }.merge(fields))
      assert_equal "200", response.code, response.body
      api.conversation_inputs.last.fetch("input")
    end

    def policy(daemon, id)
      response = request(daemon, :get, "/conversations/modes?public_id=#{id}", token: bearer(daemon))
      assert_equal "200", response.code, response.body
      JSON.parse(response.body).fetch("modes")
    end
end
