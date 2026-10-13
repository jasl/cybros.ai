require "test_helper"
require "tmpdir"
require "yaml"

# Bot identity routes and reusable Preset authoring stay separate at the
# daemon facade. The CLI tests exercise the same distinct route families.
class AgentsExtensionTest < Minitest::Test
  include RhoTest::DaemonHarness

  CONFIGURATION = {
    "tool_definitions" => [], "kernel_tools" => [], "runner_executor_public_ids" => [], "runner_tool_names" => nil,
    "approval_mode" => "bypass", "approval_rules" => nil, "prompt_mechanism" => "default", "prompt_template" => nil,
    "compaction_policy" => nil, "default_model" => nil, "fallback_models" => [],
  }.freeze
  SIBLING = {
    "public_id" => "na-sib", "handle" => "docs-2", "kind" => "agent", "name" => "docs", "display_name" => "docs",
    "agent_identifier" => "rho.19c0aa77/docs", "steward_public_id" => "0199-steward", "scope" => "steward",
    "description" => "Writes the docs for a change and answers with the paths it wrote",
    "derived_from_public_id" => "0199-rho-b", "system_prompt" => nil,
    "configuration" => CONFIGURATION.merge("default_model" => "dev/text"),
  }.freeze
  RHO_B = { "public_id" => "0199-rho-b", "handle" => "rho-b", "kind" => "agent", "display_name" => "rho on b",
            "agent_identifier" => "rho.19c0aa77", "steward_public_id" => "0199-steward" }.freeze
  MODELS = [{ "ref" => "dev/text", "provider" => "dev", "workload" => "text_generation", "visible" => true, "available" => true,
              "unavailable_reason" => nil, "capabilities" => {}, "pricing" => { "state" => "unknown" } },
            { "ref" => "dev/fallback", "provider" => "dev", "workload" => "text_generation", "visible" => true, "available" => true,
              "unavailable_reason" => nil, "capabilities" => {}, "pricing" => { "state" => "unknown" } }].freeze
  REVIEWER = "---\ndescription: Reviews a diff for defects.\ntools: read, grep\nmodel: dev/text\n---\nYou review.\n".freeze
  PROMPT_TEMPLATE = {
    "blocks" => [{ "type" => "slot", "slot" => "system_prompt" },
                 { "type" => "inline", "role" => "system", "text" => "Use the {{tone}} review style." },
                 { "type" => "history" }, { "type" => "input" }],
    "variables" => { "tone" => "brief" },
  }.freeze

  def fake(**options) = NexusDoubles::FakeAgentApi.new(user_public_id: IDENTITY.user_public_id, models: MODELS, **options)

  def ready(api, config: Rho::Config.from_hash({ "default_model" => "dev/text" }))
    daemon = member_ready(boot(config: config, realtime_factory: ->(*) { nil }), api, identity: RUNNER_IDENTITY)
    FileUtils.mkdir_p(daemon.context.environment.root)
    daemon
  end

  def write_definition(daemon, name, text, directory: ".agents/agents")
    dir = File.join(daemon.context.environment.root, directory)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "#{name}.md"), text, encoding: "UTF-8")
    File.join(dir, "#{name}.md")
  end

  def call(daemon, verb, path, body: nil)
    response = request(daemon, verb, path, token: bearer(daemon), body: body)
    [response.code, JSON.parse(response.body)]
  end


  def preset(daemon, **configuration)
    daemon.context.agent_presets do |catalog|
      catalog.create(name: "Review configuration", description: "Reviews changes", configuration: configuration.transform_keys(&:to_s))
    end
  end

  def test_routes_require_bearer_and_configuration_import_is_owned_by_presets
    daemon = boot
    { get: %w[/agents /presets /presets/tools /presets/export],
      post: %w[/agents/rm /agents/duplicate /presets /presets/import /presets/import_document /presets/rm /presets/duplicate],
      put: %w[/agents /agents/settings /presets /presets/defaults /presets/role], delete: %w[/presets/role] }.each do |verb, paths|
      paths.each { |path| assert_equal "401", request(daemon, verb, path, body: verb == :get ? nil : {}).code, path }
    end
    assert_includes Rho::Extensions::DEFAULT_EXTENSIONS, Rho::Extensions::Agents
    assert_equal %w[agents bots presets], Rho::Extensions.load(host: RhoTest.host).commands.select { |c| c.extension == "rho.agents" }.map(&:name)
  end

  def test_bot_listing_contains_identity_and_selected_preset_without_file_import_state
    api = fake(named_agents: [SIBLING], principals: [RHO_B])
    daemon = ready(api)
    selected = preset(daemon, model: "dev/text", system_prompt: "Review carefully", tools: [], runner_tool_names: %w[read grep])
    code, created = call(daemon, :put, "/agents", body: { name: "reviewer", display_name: "Review Bot", description: "Reviews changes",
      preset_public_id: selected.public_id, welcome_message: "Welcome" })
    assert_equal "200", code, created.inspect
    code, document = call(daemon, :get, "/agents")
    assert_equal "200", code
    assert_equal ["bots"], document.keys
    bot, sibling = document.fetch("bots")
    assert_equal ["reviewer", "Review Bot", selected.public_id, selected.name, "Welcome", "owner"],
      bot.values_at("name", "display_name", "preset_public_id", "preset_name", "welcome_message", "audience")
    assert_equal %w[grep read], bot.fetch("tools")
    assert_equal "dev/text", bot.fetch("model")
    assert_equal "available", bot.fetch("model_standing")
    assert_includes bot.fetch("system_prompt"), "Review carefully"
    assert_equal created.dig("agent", "public_id"), bot.fetch("public_id")
    assert_equal "rho-b", sibling.fetch("from")
    refute sibling.key?("preset_public_id")
  end

  def test_bot_subagent_is_saved_on_create_and_updates_and_defaults_to_enabled
    daemon = ready(fake)
    code, created = call(daemon, :put, "/agents", body: { name: "writer", description: "Writes", subagent: false })
    assert_equal "200", code, created.inspect
    id = created.dig("agent", "public_id")
    assert_equal false, call(daemon, :get, "/agents").last.dig("bots", 0, "subagent")
    code, saved = call(daemon, :put, "/agents/settings", body: { agent_public_id: id, subagent: true })
    assert_equal "200", code, saved.inspect
    assert_equal true, saved.fetch("subagent")
    call(daemon, :put, "/agents", body: { name: "writer", description: "Writes more", subagent: false })
    call(daemon, :put, "/agents", body: { name: "writer", description: "Writes again" })
    assert_equal false, call(daemon, :get, "/agents").last.dig("bots", 0, "subagent")
    call(daemon, :put, "/agents", body: { name: "default", description: "Default Bot" })
    assert_equal true, call(daemon, :get, "/agents").last.fetch("bots").find { |bot| bot.fetch("name") == "default" }.fetch("subagent")
  end

  def test_bot_subagent_rejects_non_booleans_without_changing_settings_and_duplicates_its_value
    daemon = ready(fake)
    _, created = call(daemon, :put, "/agents", body: { name: "writer", description: "Writes", subagent: false })
    id = created.dig("agent", "public_id")
    [nil, "false", 0, [], {}].each do |value|
      code, saved = call(daemon, :put, "/agents/settings", body: { agent_public_id: id, subagent: value })
      assert_equal "400", code, saved.inspect
      code, saved = call(daemon, :put, "/agents", body: { name: "writer", description: "Writes", subagent: value })
      assert_equal "400", code, saved.inspect
    end
    assert_equal false, call(daemon, :get, "/agents").last.dig("bots", 0, "subagent")
    code, copied = call(daemon, :post, "/agents/duplicate", body: { source_name: "writer", name: "copy" })
    assert_equal "200", code, copied.inspect
    assert_equal false, call(daemon, :get, "/agents").last.fetch("bots").find { |bot| bot.fetch("name") == "copy" }.fetch("subagent")
  end

  def test_identity_write_rejects_policy_and_malformed_fields_before_creating_a_user
    api = fake
    daemon = ready(api)
    [{ name: "Writer!", description: "Writes" }, { name: "writer", description: "" },
     { name: "writer", description: "Writes", audience: "public" },
     *[1, false, [], {}].map { |value| { name: "writer", description: "Writes", welcome_message: value } },
     *%w[system_prompt model tools runner_tool_names fallback_models prompt_template].map { |key| { name: "writer", description: "Writes", key => nil } }].each do |body|
      code, document = call(daemon, :put, "/agents", body: body)
      assert_equal "400", code, document.inspect
    end
    assert_empty api.named_agent_declarations
  end

  def test_malformed_welcome_messages_leave_existing_bot_settings_unchanged
    api = fake
    daemon = ready(api)
    _, created = call(daemon, :put, "/agents", body: { name: "writer", description: "Writes", welcome_message: "Hello" })
    id = created.dig("agent", "public_id")
    before = call(daemon, :get, "/agents").last.fetch("bots")
    declarations = api.named_agent_declarations.dup

    [1, false, [], {}].each do |value|
      code, document = call(daemon, :put, "/agents/settings", body: { agent_public_id: id, welcome_message: value })
      assert_equal "400", code, document.inspect
      assert_equal "welcome_message must be a string or null", document.dig("error", "message")
    end

    assert_equal before, call(daemon, :get, "/agents").last.fetch("bots")
    assert_equal declarations, api.named_agent_declarations
    code, saved = call(daemon, :put, "/agents/settings", body: { agent_public_id: id, welcome_message: nil })
    assert_equal "200", code, saved.inspect
    assert_nil saved.fetch("welcome_message")
  end

  def test_identity_refusal_and_removal_keep_the_kernel_result
    refusal = CybrosAgent::Response.new(status: 422, headers: {}, body: { "error" => { "code" => "validation_failed", "message" => "Rejected" } })
    api = fake(named_agent: ->(name, _body) { name == "bad" ? refusal : :accept })
    daemon = ready(api)
    code, document = call(daemon, :put, "/agents", body: { name: "bad", description: "Rejected" })
    assert_equal "422", code
    assert_equal "validation_failed", document.dig("error", "code")
    code, created = call(daemon, :put, "/agents", body: { name: "writer", description: "Writes" })
    assert_equal "200", code, created.inspect
    code, removed = call(daemon, :post, "/agents/rm", body: { name: "writer" })
    assert_equal "200", code
    assert_equal created.dig("agent", "public_id"), removed.dig("removed", "public_id")
    assert_equal "400", call(daemon, :post, "/agents/rm", body: {}).first
    assert_equal "404", call(daemon, :post, "/agents/rm", body: { name: "nobody" }).first
  end

  def test_preset_configuration_replacement_retains_template_and_explicit_null_inherits_the_installation
    api = fake
    daemon = ready(api)
    selected = preset(daemon, prompt_template: PROMPT_TEMPLATE)
    call(daemon, :put, "/agents", body: { name: "writer", description: "Writes", preset_public_id: selected.public_id })
    fields = { public_id: selected.public_id, name: selected.name, description: selected.description }
    code, document = call(daemon, :put, "/presets", body: fields.merge(configuration: selected.configuration.merge("system_prompt" => "Changed")))
    assert_equal "200", code, document.inspect
    assert_equal PROMPT_TEMPLATE, call(daemon, :get, "/agents").last.dig("bots", 0, "configuration", "prompt_template")
    code, document = call(daemon, :put, "/presets", body: fields.merge(configuration: { prompt_template: nil }))
    assert_equal "200", code
    assert_nil document.fetch("presets").find { |row| row.fetch("public_id") == selected.public_id }.dig("configuration", "prompt_template")
    assert_equal Rho::RunDeclaration::PROMPT_TEMPLATE, call(daemon, :get, "/agents").last.dig("bots", 0, "configuration", "prompt_template")
    code, document = call(daemon, :put, "/presets", body: fields.merge(configuration: { prompt_template: "invalid" }))
    assert_equal "400", code
    assert_equal Rho::RunDeclaration::PROMPT_TEMPLATE, call(daemon, :get, "/agents").last.dig("bots", 0, "configuration", "prompt_template")
  end

  def test_home_and_welcome_updates_do_not_change_the_preset_or_identity_projection
    api = fake(workspaces: [{ public_id: "ws-a", name: "A", dedicated: false }, { public_id: "ws-b", name: "B", dedicated: false }])
    daemon = ready(api)
    selected = preset(daemon, model: "dev/text")
    _, created = call(daemon, :put, "/agents", body: { name: "writer", description: "Writes", preset_public_id: selected.public_id })
    id = created.dig("agent", "public_id")
    before = api.named_agent_declarations.dup
    ["ws-a", "ws-b", nil].each do |home|
      code, saved = call(daemon, :put, "/agents/settings", body: { agent_public_id: id, home_workspace_public_id: home, welcome_message: "Hi" })
      assert_equal "200", code, saved.inspect
      assert_equal({ "agent_public_id" => id, "home_workspace_public_id" => home, "audience" => "owner", "preset_public_id" => selected.public_id, "welcome_message" => "Hi", "subagent" => true }, saved)
      bot = call(daemon, :get, "/agents").last.fetch("bots").first
      assert_equal [id, selected.public_id, home, "Hi"], bot.values_at("public_id", "preset_public_id", "home_workspace_public_id", "welcome_message")
    end
    assert_equal before, api.named_agent_declarations
  end

  def test_in_use_preset_cannot_be_removed_and_switching_reference_keeps_bot_identity
    api = fake
    daemon = ready(api)
    first = preset(daemon, model: "dev/text")
    second = preset(daemon, model: "dev/fallback")
    _, created = call(daemon, :put, "/agents", body: { name: "writer", description: "Writes", preset_public_id: first.public_id })
    id = created.dig("agent", "public_id")
    code, document = call(daemon, :post, "/presets/rm", body: { public_id: first.public_id })
    assert_equal "400", code
    assert_includes document.dig("error", "message"), "in use by Bot"
    code, saved = call(daemon, :put, "/agents/settings", body: { agent_public_id: id, preset_public_id: second.public_id })
    assert_equal "200", code, saved.inspect
    bot = call(daemon, :get, "/agents").last.fetch("bots").first
    assert_equal [id, second.public_id, "dev/fallback"], bot.values_at("public_id", "preset_public_id", "model")
    assert_equal "200", call(daemon, :post, "/presets/rm", body: { public_id: first.public_id }).first
  end
  def test_get_presets_tools_lists_kernel_application_and_runner_choices
    api = fake(tools: NexusDoubles::KERNEL_CATALOG)
    daemon = ready(api, config: Rho::Config.from_hash({ "default_model" => "dev/text", "kernel_tools" => NexusDoubles::KERNEL_TOOLS.keys }))

    code, document = call(daemon, :get, "/presets/tools")

    assert_equal "200", code, document.inspect
    tools = document.fetch("tools")
    assert_equal({ "name" => "delegate_task", "canonical" => "nexus.graph.delegate_task", "kind" => "kernel", "description" => "the delegate_task verb" }, tools.first)
    read = tools.find { |row| row["name"] == "read" }
    assert_equal "runner", read.fetch("kind")
    assert read.fetch("description")
    assert_equal "agent", tools.find { |row| row["name"] == "todo_write" }.fetch("kind")
  end

  def test_preset_tool_choices_keep_kernel_aliases_and_application_tools_independent_of_a_saved_selection
    aliases = CybrosAgent::ModelAdaptations.load.presets.preset("claude").aliases
    anchor = aliases.first.dig("recut", "anchor")
    catalog = NexusDoubles::KERNEL_CATALOG.map do |row|
      row.fetch("canonical_name") == "nexus.graph.delegate_task" ? row.merge("template" => "Delegate a task.\n\n#{anchor}") : row
    end
    daemon = ready(fake(tools: catalog), config: Rho::Config.from_hash({ "default_model" => "dev/text", "adaptations" => "claude",
      "kernel_tools" => NexusDoubles::KERNEL_TOOLS.keys }))
    daemon.context.agent_presets do |presets|
      main = presets.fetch(presets.main_preset_public_id)
      presets.replace(main.public_id, name: main.name, description: main.description, configuration: { "tools" => [], "runner_tool_names" => [] })
    end

    code, document = call(daemon, :get, "/presets/tools")

    assert_equal "200", code, document.inspect
    tools = document.fetch("tools").to_h { |row| [row.fetch("name"), row] }
    assert_equal ["kernel", "nexus.graph.delegate_task"], tools.fetch("Agent").values_at("kind", "canonical")
    refute tools.key?("delegate_task"), "the replacement alias is the selectable callable"
    assert_equal "agent", tools.fetch("todo_write").fetch("kind")
    assert_equal "runner", tools.fetch("read").fetch("kind")
  end

  def test_bot_settings_require_explicit_home_and_refuse_unavailable_or_foreign_targets
    own = SIBLING.merge("public_id" => "na-own", "derived_from_public_id" => IDENTITY.user_public_id)
    api = fake(named_agents: [own, SIBLING], workspaces: [{ public_id: "ws-foreign", name: "Foreign", own: false }])
    api.stock_store_entry("profile", namespace: "rho.bots", key: "na-own", value: { "home_workspace_public_id" => "ws-saved" })
    daemon = ready(api)

    [{ agent_public_id: "na-own" }, { home_workspace_public_id: nil },
     { agent_public_id: "na-own", home_workspace_public_id: "" },
     { agent_public_id: "na-own", home_workspace_public_id: nil, outward_im_allowed: true }].each do |body|
      code, document = call(daemon, :put, "/agents/settings", body: body)
      assert_equal "400", code, document.inspect
    end
    ["na-unknown", SIBLING.fetch("public_id"), IDENTITY.user_public_id].each do |public_id|
      code, document = call(daemon, :put, "/agents/settings", body: { agent_public_id: public_id, home_workspace_public_id: nil })
      assert_equal "404", code, document.inspect
      assert_equal "not_found", document.dig("error", "code")
    end
    code, document = call(daemon, :put, "/agents/settings", body: { agent_public_id: "na-own", home_workspace_public_id: "ws-foreign" })
    assert_equal "422", code, document.inspect
    assert_equal "workspace_unavailable", document.dig("error", "code")
    code, document = call(daemon, :put, "/agents/settings", body: { agent_public_id: "na-own", home_workspace_public_id: "ws-unknown" })
    assert_equal "404", code, document.inspect
    assert_equal({ "home_workspace_public_id" => "ws-saved" }, api.store_entries_of("profile").first.fetch("value"))
    assert_empty api.store_entry_creates
    assert_empty api.store_entry_updates
  end

  def test_bot_settings_do_not_require_the_daemons_adopted_workspace
    own = SIBLING.merge("public_id" => "na-own", "derived_from_public_id" => IDENTITY.user_public_id)
    api = fake(named_agents: [own], workspaces: [{ public_id: "ws-home", name: "Home", dedicated: false }])
    daemon = ready(api)
    _workspace, about = daemon.lineage.member_plane_snapshot
    daemon.lineage.commit_workspace(about, Rho::Daemon::Lineage::Workspace.pending)

    code, document = call(daemon, :put, "/agents/settings", body: { agent_public_id: "na-own", home_workspace_public_id: "ws-home" })

    assert_equal "200", code, document.inspect
    assert_equal "ws-home", document.fetch("home_workspace_public_id")
  end

  class VerbsTest < Minitest::Test
    include RhoTest::CliHarness
    def agents(*args) = Rho::Extensions::Agents::Commands.agents(cli, args, {})
    def presets(*args) = Rho::Extensions::Agents::Commands.presets(cli, args, {})

    def test_lists_bots_separately_from_presets_and_roles
      announce(endpoint: routed_endpoint("GET /agents" => [[200, { "bots" => [{ "handle" => "helper", "name" => "helper", "display_name" => "Helper", "preset_name" => "Adjutant" }] }]]))
      agents(nil)
      assert_equal ["Bots", "  @helper  Helper  Preset: Adjutant"], @out.string.lines.map(&:chomp)
    end

    def test_empty_bot_listing
      announce(endpoint: routed_endpoint("GET /agents" => [[200, { "bots" => [] }]]))
      agents(nil)
      assert_equal ["Bots", "  (none)"], @out.string.lines.map(&:chomp)
    end

    def test_import_and_export_use_the_preset_doors
      seen = []
      content = "---\nname: reviewer\ndescription: Review\n---\nReview carefully\n"
      announce(endpoint: recording_routed_endpoint(seen,
        "POST /presets/import_document" => [[200, { "presets" => [] }]],
        "POST /presets/import" => [[200, { "imported" => [{ "name" => "reviewer" }], "skipped" => [], "missing" => [] }]],
        "GET /presets/export?public_id=p-1&format=md" => [[200, { "content" => content }]]))
      Dir.mktmpdir("rho-preset-document-") do |directory|
        path = File.join(directory, "reviewer.md")
        File.write(path, content)
        presets("import-file", path)
      end
      presets("import", "reviewer")
      presets("export", "p-1", "md")
      assert_equal "Preset imported\nimported: 1  skipped: 0\n#{content}", @out.string
      assert_equal({ "content" => content, "format" => "md", "filename" => "reviewer.md" }, JSON.parse(seen.grep(%r{\APOST /presets/import_document}).first.partition("\r\n\r\n").last))
      assert_equal({ "names" => ["reviewer"] }, JSON.parse(seen.grep(%r{\APOST /presets/import }).first.partition("\r\n\r\n").last))
    end

    def test_duplicate_and_remove_use_identity_doors_and_relay_refusal
      seen = []
      announce(endpoint: recording_routed_endpoint(seen,
        "POST /agents/duplicate" => [[200, { "agent" => { "handle" => "copy" } }]],
        "POST /agents/rm" => [[200, { "removed" => { "handle" => "copy" } }], [404, { "error" => { "message" => "Bot missing" } }]]))
      agents("duplicate", "helper", "copy", "owner")
      agents("rm", "copy")
      assert_equal "Bot missing", assert_raises(Rho::Error) { agents("rm", "missing") }.message
      assert_equal ["created: @copy", "removed: @copy"], @out.string.lines.map(&:chomp)
      posted = seen.grep(%r{\APOST /agents/duplicate }).first
      assert_equal({ "source_name" => "helper", "name" => "copy", "audience" => "owner" }, JSON.parse(posted.partition("\r\n\r\n").last))
    end

    def test_verbs_require_arguments_and_do_not_treat_imports_as_identities
      assert_equal "agents rm needs NAME", assert_raises(Rho::Error) { agents("rm") }.message
      assert_match(/use presets/, assert_raises(Rho::Error) { agents("import") }.message)
      assert_equal "presets export needs PUBLIC_ID", assert_raises(Rho::Error) { presets("export") }.message
      assert_equal "presets import-file needs FILE", assert_raises(Rho::Error) { presets("import-file") }.message
    end
  end
end
