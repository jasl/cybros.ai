require "test_helper"

class DaemonExternalBotPolicyTest < Minitest::Test
  include RhoTest::DaemonHarness

  TOOLS = {
    "nexus.memory.read" => "memory_read", "nexus.memory.write" => "memory_write",
    "nexus.conversation.spawn" => "spawn", "nexus.conversation.send" => "send",
    "nexus.tools.search" => "tool_search", "nexus.runners.list" => "runners_list",
  }.freeze
  CATALOG = TOOLS.map do |canonical, name|
    { "canonical_name" => canonical, "name" => name, "effect_profile" => {},
      "definition" => { "type" => "function", "function" => { "name" => name, "description" => "The #{name} verb.",
        "parameters" => { "type" => "object", "properties" => {} } } } }
  end.freeze
  MODEL = { "ref" => "dev/text", "provider" => "dev", "workload" => "text_generation", "visible" => true, "available" => true,
            "unavailable_reason" => nil, "capabilities" => {}, "pricing" => { "state" => "unknown" } }.freeze

  def row(name, number, owner: IDENTITY.user_public_id, complete: true)
    { "public_id" => "019b1000-0000-7000-8000-#{format("%012d", number)}", "handle" => name, "name" => name,
      "kind" => "agent", "display_name" => name, "agent_identifier" => "rho.test/#{name}", "steward_public_id" => "owner",
      "derived_from_public_id" => owner, "scope" => "steward", "description" => "The #{name} Bot.", "system_prompt" => "Answer #{name} questions.",
      "configuration" => { "tool_definitions" => [], "kernel_tools" => TOOLS.keys,
        "runner_executor_public_ids" => ["private-runner"], "runner_tool_names" => nil,
        "approval_mode" => "bypass", "approval_rules" => [{ "tool" => "*", "verdict" => "allow" }],
        "prompt_mechanism" => "default", "prompt_template" => nil, "compaction_policy" => nil,
        "default_model" => ("dev/text" if complete), "fallback_models" => [] } }
  end

  def ready(rows = [], **options)
    api = NexusDoubles::FakeAgentApi.new(user_public_id: IDENTITY.user_public_id, models: [MODEL], tools: CATALOG,
      named_agents: rows, **options)
    config = Rho::Config.from_hash({ "default_model" => "dev/text", "kernel_tools" => TOOLS.keys })
    daemon = member_ready(boot(config: config), api, identity: RUNNER_IDENTITY)
    FileUtils.mkdir_p(daemon.context.environment.root)
    [daemon, api]
  end

  def audience(api, bot, value)
    api.stock_store_entry("profile", namespace: "rho.bots", key: bot.fetch("public_id"),
      value: { "audience" => value, "home_workspace_public_id" => "ws-home" })
  end

  def saved(api, bot)
    api.store_entries_of("profile").find { |entry| entry.fetch("key") == bot.fetch("public_id") }&.fetch("value")
  end

  def put(daemon, path, body)
    response = request(daemon, :put, path, token: bearer(daemon), body: body)
    [response.code, JSON.parse(response.body)]
  end

  def test_switch_publishes_external_only_after_narrowing_without_publishing_bots_as_roles
    front = row("front", 1)
    helper = row("helper", 2)
    private_bot = row("private", 3)
    draft = row("draft", 4, complete: false)
    sibling = row("sibling", 5, owner: "another-rho")
    observed = []
    daemon, api = ready([front, helper, private_bot, draft, sibling], named_agent: lambda { |name, body|
      if name == "front"
        observed << [saved(api, front)&.fetch("audience", "owner") || "owner", body.fetch("configuration")]
      end
      :accept
    })
    audience(api, front, "owner")
    audience(api, helper, "external")
    audience(api, draft, "external")

    code, result = put(daemon, "/agents/settings", { agent_public_id: front.fetch("public_id"), audience: "external" })

    assert_equal "200", code, result.inspect
    assert_equal({ "agent_public_id" => front.fetch("public_id"), "audience" => "external", "home_workspace_public_id" => "ws-home",
                   "preset_public_id" => nil, "welcome_message" => nil, "subagent" => true }, result)
    assert_equal %w[owner external], observed.map(&:first)
    observed.each do |_published, policy|
      assert_equal "rules", policy.fetch("approval_mode")
      assert_empty policy.fetch("runner_executor_public_ids")
      assert_empty policy.fetch("runner_tool_names")
      assert_equal "subtree", policy.fetch("conversation_reach")
      rules = policy.fetch("approval_rules").select { |rule| rule["verdict"] == "allow" }
      assert_equal %w[worker planner explorer reviewer], rules.select { |rule| rule["path"] == "declaration" }.map { |rule| rule.fetch("match") }
      assert_equal [front.fetch("public_id"), helper.fetch("public_id"), draft.fetch("public_id")], rules.select { |rule| rule["path"] == "agent" }.map { |rule| rule.fetch("match") }
      assert rules.select { |rule| rule["path"] == "agent" }.all? { |rule| rule["tool"] == "send" }
      assert_equal Rho::BotPolicy::MEMORY_CONTEXT_LIMIT, policy.fetch("memory_context_limit")
      assert_equal %w[send spawn], policy.fetch("tool_definitions").map { |entry| entry.dig("function", "name") }.sort
    end
    assert_equal "external", daemon.context.list_named_definitions.fetch(:bots).find { |bot| bot.fetch(:name) == "front" }.fetch(:audience)
    assert_equal :unchanged, daemon.context.declare_profile, "roster descriptions and alias declarations stabilize after refresh"
  end

  def test_a_kernel_refusal_does_not_publish_the_external_audience
    bot = row("front", 1)
    refusal = CybrosAgent::Response.new(status: 422, headers: {},
      body: { "error" => { "code" => "validation_failed", "message" => "refused" } })
    daemon, api = ready([bot], named_agent: refusal)
    audience(api, bot, "owner")

    code, result = put(daemon, "/agents/settings", { agent_public_id: bot.fetch("public_id"), audience: "external" })

    assert_equal "422", code, result.inspect
    assert_equal "owner", saved(api, bot).fetch("audience")
    assert_empty api.store_entry_updates
  end

  def test_external_identity_cannot_become_private_through_settings_or_editing
    bot = row("front", 1)
    daemon, api = ready([bot])
    audience(api, bot, "external")

    [["/agents/settings", { agent_public_id: bot.fetch("public_id"), audience: "owner" }],
     ["/agents", { name: "front", description: "Edited.", audience: "owner" }]].each do |path, body|
      code, result = put(daemon, path, body)
      assert_equal "409", code, result.inspect
      assert_equal "bot_audience_fixed", result.dig("error", "code")
    end
    assert_equal "external", saved(api, bot).fetch("audience")
    assert_empty api.named_agent_declarations
  end

  def test_editing_an_external_bot_narrows_every_write_and_keeps_the_persona_single_authority
    bot = row("front", 1)
    daemon, api = ready([bot])
    audience(api, bot, "external")

    preset = create_preset(daemon, name: "Shared assistant", system_prompt: "One authored persona.", tools: nil)
    code, result = put(daemon, "/agents", { name: "front", description: "Edited.", preset_public_id: preset.fetch("public_id") })

    assert_equal "200", code, result.inspect
    api.named_agent_declarations.each do |_name, declaration|
      assert_includes declaration.fetch("system_prompt"), "One authored persona."
      assert_equal 1, declaration.fetch("system_prompt").scan("One authored persona.").length
      assert_equal "rules", declaration.dig("configuration", "approval_mode")
      assert_empty declaration.dig("configuration", "runner_executor_public_ids")
      assert_equal Rho::BotPolicy::MEMORY_CONTEXT_LIMIT, declaration.dig("configuration", "memory_context_limit")
    end
    assert_equal "external", saved(api, bot).fetch("audience")
  end

  def test_new_external_bot_is_narrowed_before_its_identity_is_published
    states = []
    daemon, api = ready([], named_agent: lambda { |_name, body|
      states << [api.store_entries_of("profile").select { |entry| entry.fetch("namespace") == "rho.bots" }.map { |entry| entry.fetch("value").fetch("audience", "owner") }, body.fetch("configuration")]
      :accept
    })

    code, result = put(daemon, "/agents", { name: "front", description: "Answers public questions.", audience: "external" })

    assert_equal "200", code, result.inspect
    assert_empty states.first.first
    assert_equal ["external"], states.last.first
    states.each do |_audiences, policy|
      assert_equal "rules", policy.fetch("approval_mode")
      assert_empty policy.fetch("runner_executor_public_ids")
    end
    rules = states.last.last.fetch("approval_rules").select { |rule| rule["verdict"] == "allow" }
    assert_equal %w[worker planner explorer reviewer], rules.select { |rule| rule["path"] == "declaration" }.map { |rule| rule.fetch("match") }
    assert_equal [result.fetch("agent").fetch("public_id")], rules.select { |rule| rule["path"] == "agent" }.map { |rule| rule.fetch("match") }
  end

  def test_external_bot_opens_without_a_runner_for_promptless_and_immediate_turns
    front = row("front", 1)
    private_bot = row("private", 2)
    daemon, api = ready([front, private_bot], trace: NexusDoubles::RUNNING_TRACE,
      workspaces: [{ public_id: "ws-home", name: "Public", dedicated: false }, { public_id: "ws-1", name: "Private", dedicated: false }])
    audience(api, front, "external")
    daemon.context.declare_profile
    api.stock_principals([front, private_bot].map do |bot|
      bot.slice("public_id", "handle", "kind", "display_name", "agent_identifier", "steward_public_id")
    end)

    response = request(daemon, :post, "/bots/current", token: bearer(daemon),
      body: { agent_public_id: front.fetch("public_id"), operation_id: "open-front" })
    assert_equal "200", response.code, response.body
    id = JSON.parse(response.body).dig("current", "public_id")
    assert_nil api.conversation_creates.last.dig("conversation", "default_runner_executor_public_id")
    assert_empty api.conversation_inputs
    [{}, { "default_runner_executor_public_id" => RUNNER_IDENTITY.runner_executor_public_id }].each do |fields|
      response = request(daemon, :post, "/say", token: bearer(daemon),
        body: fields.merge("public_id" => id, "text" => "Answer the visitor", "wait" => false))
      assert_equal "200", response.code, response.body
      assert_nil api.tool_assemblies.last.fetch("default_runner_executor_public_id")
      assert_nil JSON.parse(response.body).fetch("default_runner")
    end

    daemon.context.replace_bot_settings(agent_public_id: private_bot.fetch("public_id"), home_workspace_public_id: "ws-1")
    response = request(daemon, :post, "/bots/current", token: bearer(daemon),
      body: { agent_public_id: private_bot.fetch("public_id"), operation_id: "open-private" })
    assert_equal "200", response.code, response.body
    assert_equal RUNNER_IDENTITY.runner_executor_public_id, api.conversation_creates.last.dig("conversation", "default_runner_executor_public_id")
  end

  def test_a_bot_changed_to_external_clears_its_existing_runner_before_the_next_input
    front = row("front", 1)
    daemon, api = ready([front], trace: NexusDoubles::RUNNING_TRACE,
      workspaces: [{ public_id: "ws-1", name: "Home", dedicated: false }])
    daemon.context.declare_profile
    api.stock_principals([front.slice("public_id", "handle", "kind", "display_name", "agent_identifier", "steward_public_id")])
    daemon.context.replace_bot_settings(agent_public_id: front.fetch("public_id"), home_workspace_public_id: "ws-1")
    opened = request(daemon, :post, "/bots/current", token: bearer(daemon),
      body: { agent_public_id: front.fetch("public_id"), operation_id: "open-front" })
    assert_equal "200", opened.code, opened.body
    id = JSON.parse(opened.body).fetch("current").fetch("public_id")
    assert_equal RUNNER_IDENTITY.runner_executor_public_id, api.conversation_creates.last.dig("conversation", "default_runner_executor_public_id")
    code, result = put(daemon, "/agents/settings", { agent_public_id: front.fetch("public_id"), audience: "external" })
    assert_equal "200", code, result.inspect

    2.times do
      response = request(daemon, :post, "/say", token: bearer(daemon), body: { public_id: id, text: "Another question", delivery_mode: "queue", wait: false })
      assert_equal "200", response.code, response.body
      assert_nil api.tool_assemblies.last.fetch("default_runner_executor_public_id")
      assert_nil JSON.parse(response.body).fetch("default_runner")
    end
    assert_equal [[id, nil]], api.set_default_runners
    assert_equal 2, api.conversation_inputs.length
  end

  def test_importing_a_preset_does_not_change_an_external_bot_or_its_memory
    bot = row("front", 1)
    daemon, api = ready([bot])
    audience(api, bot, "external")
    api.stock_memory("profile", "agent/private-notes", "Only this identity owns these notes.")
    original = saved(api, bot).dup
    folder = File.join(daemon.context.environment.root, ".agents/agents")
    FileUtils.mkdir_p(folder)
    File.write(File.join(folder, "front.md"), "---\ndescription: Imported configuration.\nmodel: dev/text\n---\nImported persona.\n")

    response = request(daemon, :post, "/presets/import", token: bearer(daemon), body: { names: ["front"] })
    result = JSON.parse(response.body)

    assert_equal "200", response.code, result.inspect
    assert_equal ["front"], result.fetch("imported").map { |preset| preset.fetch("name") }
    assert_empty api.named_agent_declarations
    assert_empty api.memory_writes
    assert_equal original, saved(api, bot)
    assert_equal "external", daemon.context.list_named_definitions.fetch(:bots).first.fetch(:audience)
  end

  def test_invalid_audiences_are_refused_before_writing
    bot = row("front", 1)
    daemon, api = ready([bot])
    [nil, "public", "", []].each do |value|
      code, result = put(daemon, "/agents/settings", { agent_public_id: bot.fetch("public_id"), audience: value })
      assert_equal "400", code, result.inspect
    end
    assert_empty api.store_entry_creates
    assert_empty api.named_agent_declarations
  end

  def test_imported_identity_policy_is_rejected_without_changing_an_external_bot
    bot = row("front", 1)
    daemon, api = ready([bot])
    audience(api, bot, "external")
    content = JSON.generate("name" => "front", "description" => "Imported.", "model" => "dev/text", "audience" => "owner")

    response = request(daemon, :post, "/presets/import_document", token: bearer(daemon), body: { content: content, format: "json" })
    result = JSON.parse(response.body)

    assert_equal "400", response.code, result.inspect
    assert_includes result.dig("error", "message"), "audience"
    assert_equal "external", saved(api, bot).fetch("audience")
    assert_empty api.named_agent_declarations
  end

  def test_a_shared_preset_keeps_each_bots_instance_policy
    external = row("front", 1)
    owner = row("private", 2)
    daemon, api = ready([external, owner])
    audience(api, external, "external")
    audience(api, owner, "owner")
    preset = create_preset(daemon, name: "Shared policy", system_prompt: "Shared instructions.", tools: nil, conversation_reach: "workspace")
    [external, owner].each do |bot|
      code, result = put(daemon, "/agents", { name: bot.fetch("name"), description: bot.fetch("description"), preset_public_id: preset.fetch("public_id") })
      assert_equal "200", code, result.inspect
    end

    declarations = api.named_agent_declarations.to_h
    public_policy = declarations.fetch("front").fetch("configuration")
    private_policy = declarations.fetch("private").fetch("configuration")
    assert_equal preset.fetch("public_id"), saved(api, external).fetch("preset_public_id")
    assert_equal preset.fetch("public_id"), saved(api, owner).fetch("preset_public_id")
    assert_empty public_policy.fetch("runner_executor_public_ids")
    assert_equal Rho::BotPolicy::MEMORY_CONTEXT_LIMIT, public_policy.fetch("memory_context_limit")
    assert_equal "subtree", public_policy.fetch("conversation_reach")
    refute_empty private_policy.fetch("runner_executor_public_ids")
    assert_nil private_policy["memory_context_limit"]
    assert_equal "workspace", private_policy.fetch("conversation_reach")
  end

  def test_a_removed_external_identity_cannot_be_restored_as_a_private_bot
    bot = row("front", 1)
    daemon, api = ready([bot])
    audience(api, bot, "external")
    removed = daemon.context.remove_named_definition("front")
    assert_equal bot.fetch("public_id"), removed.fetch(:removed).fetch(:public_id)

    code, result = put(daemon, "/agents", { name: "front", description: "Private replacement." })

    assert_equal "409", code, result.inspect
    assert_equal "name_taken", result.dig("error", "code")
    assert_equal "external", saved(api, bot).fetch("audience")
    assert_empty daemon.context.list_named_definitions.fetch(:bots)
    assert api.named_agent_declarations.last.last.fetch("create_only")
  end

  private

    def create_preset(daemon, name:, **configuration)
      response = request(daemon, :post, "/presets", token: bearer(daemon), body: {
        name: name, description: "Reusable test configuration", configuration: { model: "dev/text" }.merge(configuration),
      })
      answer = JSON.parse(response.body)
      assert_equal "200", response.code, answer.inspect
      answer.fetch("presets").find { |preset| preset.fetch("name") == name }
    end
end
