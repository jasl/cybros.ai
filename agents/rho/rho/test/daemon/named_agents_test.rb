require "test_helper"
require "support/nexus_doubles"
require "support/daemon_harness"

# THE DECLARE EDGE'S BOTS HALF (refreshed / digest-gated / force / N + 1 requests), over the fake kernel:
# at every edge the daemon reads `GET profile/agents` and PUTs each of its
# own rows REFRESHED under its live declaration — the row's own policy, the
# parent's runners, approval and compaction — never a file; files are an
# import. The roster rides the turn lead while the system guideline stays
# fixed. Ordinary inputs share a declaration cache; explicit refreshes write again.
class DaemonNamedAgentsTest < Minitest::Test
  include RhoTest::DaemonHarness

  CONFIGURATION = {
    "tool_definitions" => [], "kernel_tools" => [], "runner_executor_public_ids" => [], "runner_tool_names" => nil, "mcp_tools" => [],
    "approval_mode" => "bypass", "approval_rules" => nil, "prompt_mechanism" => "default", "prompt_template" => nil,
    "compaction_policy" => nil, "default_model" => nil, "fallback_models" => [],
  }.freeze
  SIBLING = {
    "public_id" => "na-sib", "handle" => "docs", "kind" => "agent", "name" => "docs", "display_name" => "docs",
    "agent_identifier" => "rho.19c0aa77/docs", "steward_public_id" => "0199-steward", "scope" => "steward",
    "description" => "Writes the docs for a change and answers with the paths it wrote",
    "derived_from_public_id" => "0199-rho-b", "system_prompt" => nil,
    "configuration" => CONFIGURATION.merge("default_model" => "dev/mock-text"),
  }.freeze
  RHO_B = { "public_id" => "0199-rho-b", "handle" => "rho-b", "kind" => "agent", "display_name" => "rho on b",
            "agent_identifier" => "rho.19c0aa77", "steward_public_id" => "0199-steward" }.freeze
  MODELS = [
    { "ref" => "dev/mock-text", "provider" => "dev", "workload" => "text_generation", "visible" => true, "available" => true,
      "unavailable_reason" => nil, "capabilities" => { "tool_calls" => true }, "pricing" => { "state" => "unknown" } },
    { "ref" => "dev/mock-text-only", "provider" => "dev", "workload" => "text_generation", "visible" => true, "available" => true,
      "unavailable_reason" => nil, "capabilities" => {}, "pricing" => { "state" => "unknown" } },
  ].freeze

  # An own bot as the kernel holds it: this daemon's row (`derived_from_public_id`),
  # the reviewer's policy — two runner tools, a model, a persona — under a
  # stale runner id the edge replaces.
  def own_row(name = "reviewer", **fields)
    { "public_id" => "na-#{name}", "handle" => name, "kind" => "agent", "name" => name, "display_name" => name,
      "agent_identifier" => "rho.fake/#{name}", "steward_public_id" => "0199-steward", "scope" => "steward",
      "description" => "Reviews a diff for defects.", "derived_from_public_id" => IDENTITY.user_public_id,
      "system_prompt" => "You review. REVIEWER-BODY-7",
      "configuration" => CONFIGURATION.merge("runner_executor_public_ids" => ["stale-runner"], "runner_tool_names" => %w[read grep],
        "default_model" => "dev/mock-text") }.merge(fields)
  end

  # The fake's own profile is this daemon's identity, so the rows it mints
  # read as this daemon's own (`derived_from_public_id`).
  def fake(**options) = NexusDoubles::FakeAgentApi.new(user_public_id: IDENTITY.user_public_id, models: MODELS, tools: NexusDoubles::KERNEL_CATALOG, **options)

  # The installation supplies the default model and available kernel tools;
  # automatic recovery has no candidates unless a list is configured.
  DEFAULT_MODEL = "dev/mock-text-only".freeze
  def config = Rho::Config.from_hash({ "default_model" => DEFAULT_MODEL, "kernel_tools" => NexusDoubles::KERNEL_TOOLS.keys })

  def ready(api)
    daemon = member_ready(boot(config: config), api, identity: RUNNER_IDENTITY)
    FileUtils.mkdir_p(root(daemon))
    daemon
  end

  def root(daemon) = daemon.context.environment.root

  def write_definition(daemon, name, text, directory: ".agents/agents")
    dir = File.join(root(daemon), directory)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "#{name}.md"), text, encoding: "UTF-8")
    File.join(dir, "#{name}.md")
  end

  REVIEWER = "---\ndescription: Reviews a diff for defects.\ntools: read, grep\nmodel: dev/mock-text\n---\nYou review. REVIEWER-BODY-7\n".freeze
  DOCS = "---\ndescription: Writes the docs.\ntools: []\nmodel: dev/mock-text-only\n---\n".freeze
  UNSET = "---\ndescription: Has no model yet.\n---\nSomeday.\n".freeze

  def slot_writes(api) = api.prompt_document_writes.select { |slot, _| slot == "system_prompt" }.map { |_, body| body.dig("prompt_document", "content") }

  def declarations(api) = api.named_agent_declarations.map { |name, body| [name, body.fetch("scope")] }

  def log(daemon) = File.read(daemon.home.log_path, encoding: Encoding::UTF_8)

  def request_paths(api) = api.requests.map(&:first)


  def catalog(daemon)
    daemon.context.agent_presets { |presets| presets }
  end

  def select(daemon, name: "Reviewer", configuration: {})
    entry = catalog(daemon).create(name: name, description: "Review work", configuration: configuration)
    daemon.context.agent_presets do |_presets, client|
      Rho::BotSettings.new(store: -> { client.profile.store_entries }, agent_public_id: "na-reviewer")
        .replace(preset_public_id: entry.public_id)
    end
    entry
  end

  def test_edge_refreshes_the_preset_projection_without_reading_files_or_making_bots_spawn_targets
    api = fake(named_agents: [own_row])
    daemon = ready(api)
    select(daemon, configuration: { "model" => "dev/mock-text", "system_prompt" => "PRESET-BODY", "runner_tool_names" => %w[read grep] })
    write_definition(daemon, "fresh", DOCS)
    before = api.requests.length

    assert_equal :declared, daemon.context.declare_profile
    assert_equal [["reviewer", "steward"]], declarations(api)
    row = api.named_agent_declarations.to_h.fetch("reviewer")
    assert_equal [RUNNER_IDENTITY.runner_executor_public_id], row.dig("configuration", "runner_executor_public_ids")
    assert_equal %w[read grep], row.dig("configuration", "runner_tool_names")
    assert_equal "dev/mock-text", row.dig("configuration", "default_model")
    assert_empty row.dig("configuration", "fallback_models"), "no implicit fallback to the instance default"
    assert_includes row.fetch("system_prompt"), "#{Rho::RunDeclaration::GUIDELINE}\n\nPRESET-BODY"
    refute_includes row.fetch("system_prompt"), "REVIEWER-BODY-7", "User configuration is no longer authored policy"
    assert_equal "Reviews a diff for defects.", row.fetch("description")
    assert_equal %w[worker planner explorer reviewer], api.configuration_declarations.last.dig("configuration", "delegation_catalog").map { |entry| entry.fetch("name") }
    named = request_paths(api).drop(before).select { |path| path.include?("/profile/agents") }
    assert_equal ["/agent_api/v1/profile/agents", "/agent_api/v1/profile/agents/reviewer"], named
    assert_equal :declared, daemon.context.declare_profile
    assert_equal 2, api.named_agent_declarations.length
    assert_equal 2, api.configuration_declarations.length
  end

  def test_projection_narrows_the_presets_tools_to_the_installation
    api = fake(named_agents: [own_row])
    daemon = ready(api)
    select(daemon, configuration: { "tools" => ["nexus.graph.delegate_task", "nexus.not.served", "mcp__gone__lookup"], "runner_tool_names" => [] })
    daemon.context.declare_profile
    configuration = api.named_agent_declarations.to_h.fetch("reviewer").fetch("configuration")
    assert_empty configuration.fetch("tool_definitions")
    assert_equal ["nexus.graph.delegate_task"], configuration.fetch("kernel_tools")
    assert_empty configuration.fetch("runner_tool_names")
  end

  def test_owner_bot_and_its_roles_keep_selected_application_tools_while_external_policy_removes_them
    api = fake(named_agents: [own_row])
    daemon = ready(api)
    select(daemon, configuration: { "tools" => ["list_extensions"], "runner_tool_names" => [] })
    daemon.context.declare_profile
    configuration = api.named_agent_declarations.to_h.fetch("reviewer").fetch("configuration")

    assert_equal ["list_extensions"], configuration.fetch("tool_definitions").map { |entry| entry.dig("function", "name") }
    configuration.fetch("delegation_catalog").each do |entry|
      assert_includes entry.dig("declaration", "tool_definitions").map { |tool| tool.dig("function", "name") }, "list_extensions"
    end

    daemon.context.replace_bot_settings(agent_public_id: "na-reviewer", audience: "external")
    external = api.named_agent_declarations.to_h.fetch("reviewer").fetch("configuration")
    assert_empty external.fetch("tool_definitions")
    external.fetch("delegation_catalog").each do |entry|
      tools = entry.dig("declaration", "tool_definitions")
      assert tools.all? { |tool| Rho::BotPolicy::KERNEL_TOOLS.include?(tool["canonical"]) }
    end
  end

  def test_seed_presets_create_no_user_and_the_main_prompt_uses_selected_configuration
    api = fake
    daemon = ready(api)
    assert_equal :declared, daemon.context.declare_profile
    assert_equal 6, catalog(daemon).list.length
    assert_empty api.named_agent_declarations
    assert_equal %w[worker planner explorer reviewer], api.configuration_declarations.last.dig("configuration", "delegation_catalog").map { |entry| entry.fetch("name") }
    assert_equal 1, slot_writes(api).length
    assert_includes slot_writes(api).first, "#{Rho::RunDeclaration::GUIDELINE}\n\n#{Rho::AgentPresets::SEEDS.first.dig("configuration", "system_prompt")}"
    refute_includes slot_writes(api).first, "by @handle"
  end

  def test_siblings_are_listed_as_other_applications_identities_but_never_spawn_targets
    api = fake(named_agents: [SIBLING, own_row], principals: [RHO_B])
    daemon = ready(api)
    daemon.context.declare_profile
    listing = daemon.context.list_named_agents
    assert_equal %w[reviewer docs], listing.fetch(:bots).map { |row| row.fetch(:name) }
    assert_equal "rho-b", listing.fetch(:bots).last.fetch(:from)
    assert_equal %w[worker planner explorer reviewer], api.configuration_declarations.last.dig("configuration", "delegation_catalog").map { |entry| entry.fetch("name") }
    assert_equal ["reviewer"], api.named_agent_declarations.map(&:first)
  end

  def test_bot_creation_selects_default_preset_and_later_preset_edits_keep_its_identity
    api = fake
    daemon = ready(api)
    bot = daemon.context.declare_named_agent(name: "writer", description: "Writes docs", welcome_message: "Welcome")
    assert_equal Rho::Extensions::Compaction::INSTRUCTIONS, api.named_agent_declarations.first.last["summarizer"]
    selected = catalog(daemon).fetch(catalog(daemon).default_bot_preset_public_id)
    listed = daemon.context.list_named_agents.fetch(:bots).first
    assert_equal selected.public_id, listed.fetch(:preset_public_id)
    assert_equal "Welcome", listed.fetch(:welcome_message)
    assert_equal DEFAULT_MODEL, bot.configuration.default_model
    catalog(daemon).replace(selected.public_id, name: selected.name, description: selected.description,
      configuration: { "model" => "dev/mock-text", "system_prompt" => "Changed assistant", "fallback_models" => ["dev/mock-text-only"] })
    assert_equal :declared, daemon.context.declare_profile
    changed = daemon.context.list_named_agents.fetch(:bots).first
    assert_equal bot.public_id, changed.fetch(:public_id)
    assert_equal "dev/mock-text", changed.fetch(:model)
    assert_equal ["dev/mock-text-only"], changed.fetch(:configuration).fetch(:fallback_models)
    assert_includes changed.fetch(:system_prompt), "Changed assistant"
  end

  def test_named_summary_prompt_changes_redeclare_and_disabling_clears_it
    RhoTest::LocalRows.write(File.join(@root, "adaptations"), "summary", models: ["bot-summary"],
      summarizer_prompt: "Keep the Bot summary facts.")
    api = fake(named_agents: [own_row])
    daemon = ready(api)
    select(daemon, configuration: { "compaction_policy" => { "mode" => "kernel", "model" => "dev/bot-summary" } })
    assert_equal :declared, daemon.context.declare_profile
    assert_equal "Keep the Bot summary facts.", api.named_agent_declarations.last.last["summarizer"]
    original = api.configuration_declarations.last
    before = api.named_agent_declarations.length
    directory = File.join(@root, "next-adaptations")
    RhoTest::LocalRows.write(directory, "summary", models: ["bot-summary"],
      summarizer_prompt: "Keep the updated Bot summary facts.")

    response = request(daemon, :patch, "/settings", token: bearer(daemon), body: { adaptations_dir: directory })

    assert_equal "200", response.code, response.body
    assert_equal before + 1, api.named_agent_declarations.length
    assert_equal "Keep the updated Bot summary facts.", api.named_agent_declarations.last.last["summarizer"]
    assert_equal original, api.configuration_declarations.last, "only the named prompt changed"
    assert_equal :declared, daemon.context.declare_profile

    response = request(daemon, :post, "/extensions/rho.compaction/disable", token: bearer(daemon), body: {})

    assert_equal "200", response.code, response.body
    row = api.named_agent_declarations.last.last
    assert_equal({ "mode" => "off" }, row.dig("configuration", "compaction_policy"))
    assert_nil row["summarizer"]
  end

  def test_unknown_preset_is_refused_without_creating_or_replacing_identity
    api = fake
    daemon = ready(api)
    refused = daemon.context.declare_named_agent(name: "writer", description: "Writes", preset_public_id: "missing")
    assert_equal "malformed_body", refused.code
    assert_empty api.named_agent_declarations
  end

  def test_a_bot_uses_its_preset_model_and_explicit_request_overrides_are_preserved
    api = fake(named_agents: [own_row], trace: NexusDoubles::RUNNING_TRACE,
      workspaces: [{ public_id: "ws-1", name: "Home", dedicated: false }])
    daemon = ready(api)
    select(daemon, configuration: { "model" => "dev/mock-text" })
    daemon.context.declare_profile
    api.stock_principals(api.named_agents_listing.body.fetch("agents").map { |row| row.slice("public_id", "handle", "kind", "display_name", "agent_identifier", "steward_public_id") })
    daemon.context.replace_bot_settings(agent_public_id: "na-reviewer", home_workspace_public_id: "ws-1")
    opened = request(daemon, :post, "/bots/current", token: bearer(daemon),
      body: { agent_public_id: "na-reviewer", operation_id: "open-reviewer" })
    assert_equal "200", opened.code, opened.body
    current = JSON.parse(opened.body).fetch("current")
    assert_equal "na-reviewer", api.conversation_creates.last.dig("conversation", "answering_user_public_id")
    [nil, "dev/mock-text-only"].each do |model|
      response = request(daemon, :post, "/say", token: bearer(daemon),
        body: { public_id: current.fetch("public_id"), text: "Review", model: model, wait: false }.compact)
      assert_equal "200", response.code, response.body
      input = api.inputs.last.fetch("input")
      assert_equal model || "dev/mock-text", input.dig("model", "model")
      assert_equal model ? "explicit" : "default", input.dig("model_selection", "source")
      assert_equal "dev/mock-text", input.dig("agent_configuration", "default_model")
    end
  end

  def test_directory_import_creates_only_presets_without_substitution_or_live_file_authority
    api = fake
    daemon = ready(api)
    write_definition(daemon, "reviewer", REVIEWER)
    write_definition(daemon, "newmodel", "---\ndescription: Unavailable choice\nmodel: dev/not-currently-offered\n---\nExact choice\n")
    write_definition(daemon, "broken", "---\ndescription: Missing closing frontmatter")
    response = request(daemon, :post, "/presets/import", token: bearer(daemon), body: {})
    assert_equal "200", response.code, response.body
    outcome = JSON.parse(response.body)
    assert_equal %w[newmodel reviewer], outcome.fetch("imported").map { |row| row.fetch("name") }.sort
    assert_equal "dev/not-currently-offered", outcome.fetch("imported").find { |row| row.fetch("name") == "newmodel" }.dig("configuration", "model")
    assert_equal 1, outcome.fetch("skipped").length
    assert_empty api.named_agent_declarations
    write_definition(daemon, "reviewer", DOCS)
    daemon.context.declare_profile
    imported = catalog(daemon).fetch(outcome.fetch("imported").find { |entry| entry.fetch("name") == "reviewer" }.fetch("public_id"))
    assert_includes imported.configuration.fetch("system_prompt"), "REVIEWER-BODY-7"
    assert_empty api.named_agent_declarations
  end

  def test_directory_import_narrows_by_name_and_reports_missing_names
    api = fake
    daemon = ready(api)
    write_definition(daemon, "reviewer", REVIEWER)
    write_definition(daemon, "docs", DOCS)
    response = request(daemon, :post, "/presets/import", token: bearer(daemon), body: { names: %w[docs nobody] })
    assert_equal "200", response.code, response.body
    outcome = JSON.parse(response.body)
    assert_equal ["docs"], outcome.fetch("imported").map { |row| row.fetch("name") }
    assert_equal ["nobody"], outcome.fetch("missing")
    assert_empty api.named_agent_declarations
  end

  def test_repoint_does_not_create_or_modify_bot_identities
    api = fake
    daemon = ready(api)
    daemon.context.declare_profile
    checkout = File.join(@root, "checkout")
    FileUtils.mkdir_p(File.join(checkout, ".agents/agents"))
    File.write(File.join(checkout, ".agents/agents/reviewer.md"), REVIEWER)
    selection = daemon.context.repoint_tools(checkout)
    assert_equal File.realpath(checkout), File.realpath(selection.root)
    assert_empty api.named_agent_declarations
    assert_equal %w[worker planner explorer reviewer], api.configuration_declarations.last.dig("configuration", "delegation_catalog").map { |entry| entry.fetch("name") }
    assert_empty daemon.context.list_named_agents.fetch(:bots)
  end

  def test_a_refused_door_refuses_the_edge_and_the_next_edge_tries_again
    api = fake(named_agents: [own_row])
    daemon = ready(api)
    refusing = Object.new
    refusing.define_singleton_method(:call) do |path, **options|
      if path == "/agent_api/v1/profile/agents"
        CybrosAgent::Response.new(status: 503, headers: {}, body: { "error" => { "code" => "unavailable", "message" => "later" } })
      else
        api.call(path, **options)
      end
    end
    daemon.wire.api_transport = refusing

    outcome = daemon.context.declare_profile
    assert_kind_of Rho::Daemon::HostFollowers::Refused, outcome
    assert_empty api.configuration_declarations, "the plan is read before anything is written"

    daemon.wire.api_transport = api
    assert_equal :declared, daemon.context.declare_profile
    assert_equal ["reviewer"], api.named_agent_declarations.map(&:first)
  end

  def test_a_kernel_refusal_of_one_row_costs_that_row_alone
    refusal = CybrosAgent::Response.new(status: 422, headers: {},
      body: { "error" => { "code" => "validation_failed", "message" => "default_model sonnet is not authorized" } })
    api = fake(named_agents: [own_row, own_row("strong", "configuration" => CONFIGURATION.merge("default_model" => "sonnet"))],
      named_agent: ->(name, _body) { name == "strong" ? refusal : :accept })
    daemon = ready(api)

    assert_equal :declared, daemon.context.declare_profile

    assert_equal %w[reviewer strong], api.named_agent_declarations.map(&:first)
    assert_equal %w[worker planner explorer reviewer], api.configuration_declarations.last.dig("configuration", "delegation_catalog").map { |entry| entry.fetch("name") }
    assert_match(/event=agents\.declaration_failed name=strong code=validation_failed/, log(daemon))
    assert_match(/event=agents\.declared declared=1 failed=1/, log(daemon))
  end

  def test_a_failed_main_declaration_never_publishes_named_rows_and_is_retried
    answer = CybrosAgent::Response.new(status: 413, headers: {},
      body: { "error" => { "code" => "envelope_bound", "message" => "Declaration too large" } })
    api = fake(configuration: ->(_body) { answer }, named_agents: [own_row("reviewer"), own_row("writer")])
    daemon = ready(api)

    2.times do
      outcome = daemon.context.declare_profile
      assert_kind_of Rho::Daemon::HostFollowers::Refused, outcome
      assert_equal "envelope_bound", outcome.code
    end
    assert_nil daemon.host_followers.declared_models
    assert_empty api.named_agent_declarations
    assert_equal 2, api.configuration_declarations.length

    answer = :accept
    assert_equal :declared, daemon.context.declare_profile
    assert_equal %w[reviewer writer], daemon.host_followers.named_edge.declared
    assert_equal DEFAULT_MODEL, daemon.host_followers.declared_models.fetch(:default_model)
  end

  def test_runner_refresh_redeclares_successfully_cached_main_and_named_rows_after_an_external_declaration_change
    api = fake(named_agents: [own_row])
    daemon = ready(api)
    assert_equal :declared, daemon.context.declare_profile
    main = api.declared_configuration.dup
    named = api.own_named_agent("reviewer").fetch("configuration").dup

    api.declared_configuration["default_model"] = "previous/declaration-main"
    api.own_named_agent("reviewer").fetch("configuration")["default_model"] = "previous/declaration-named"

    response = request(daemon, :get, "/runners", token: bearer(daemon))

    assert_equal "200", response.code, response.body
    assert_equal 2, api.configuration_declarations.length
    assert_equal 2, api.named_agent_declarations.length
    assert_equal main, api.declared_configuration
    assert_equal named, api.own_named_agent("reviewer").fetch("configuration")
    assert_equal "na-reviewer", api.own_named_agent("reviewer").fetch("public_id")
  end

  def test_ordinary_input_selection_keeps_the_successful_declaration_cache
    api = fake(named_agents: [own_row])
    daemon = ready(api)
    assert_equal :declared, daemon.context.declare_profile

    2.times do
      selected = daemon.context.member_plane(require_workspace: false) do |client, *|
        names = daemon.host_followers.conversation_tool_names("c-1", client.workspace("ws-1"), client: client)
        assert_includes names, "code"
        daemon.context.execution_selection(client, body: {})
      end
      assert_equal DEFAULT_MODEL, selected.fetch(:agent_configuration).fetch("default_model")
    end

    assert_equal 1, api.configuration_declarations.length
    assert_equal 1, api.named_agent_declarations.length
  end

  def test_explicit_bot_policy_edits_refuse_before_persisting_settings_when_publication_fails
    refusal = CybrosAgent::Response.new(status: 409, headers: {},
      body: { "error" => { "code" => "concurrent_write", "message" => "Retry declaration" } })
    api = fake(named_agents: [own_row("reviewer")], named_agent: refusal)
    daemon = ready(api)
    assert_equal :declared, daemon.context.declare_profile
    before_updates = api.store_entry_updates.length

    response = request(daemon, :put, "/agents/settings", token: bearer(daemon),
      body: { agent_public_id: "na-reviewer", audience: "external" })
    assert_equal "409", response.code, response.body
    assert_equal "concurrent_write", JSON.parse(response.body).dig("error", "code")
    assert_equal before_updates, api.store_entry_updates.length

    response = request(daemon, :put, "/agents", token: bearer(daemon),
      body: { name: "reviewer", description: "Changed", audience: "external" })
    assert_equal "409", response.code, response.body
    assert_equal "concurrent_write", JSON.parse(response.body).dig("error", "code")
    assert_equal before_updates, api.store_entry_updates.length
    assert_equal "Reviews a diff for defects.", api.own_named_agent("reviewer").fetch("description")
  end

  def test_inline_bot_execution_keeps_its_application_owned_preset
    api = fake(named_agents: [own_row], trace: NexusDoubles::RUNNING_TRACE,
      workspaces: [{ public_id: "ws-1", name: "Home", dedicated: false }])
    daemon = ready(api)
    select(daemon, configuration: { "model" => "dev/mock-text" })
    assert_equal :declared, daemon.context.declare_profile
    api.stock_principals(api.named_agents_listing.body.fetch("agents").map do |row|
      row.slice("public_id", "handle", "kind", "display_name", "agent_identifier", "steward_public_id")
    end)
    daemon.context.replace_bot_settings(agent_public_id: "na-reviewer", home_workspace_public_id: "ws-1")
    opened = request(daemon, :post, "/bots/current", token: bearer(daemon),
      body: { agent_public_id: "na-reviewer", operation_id: "preset-reviewer" })
    assert_equal "200", opened.code, opened.body
    response = request(daemon, :post, "/say", token: bearer(daemon), body: {
      public_id: JSON.parse(opened.body).dig("current", "public_id"), text: "Review", wait: false,
    })
    assert_equal "200", response.code, response.body
    assert_equal "dev/mock-text", api.inputs.last.dig("input", "agent_configuration", "default_model")
  end

  def test_preset_tool_choices_include_application_tools_and_the_runners_served_tools
    api = fake
    daemon = ready(api)
    daemon.context.declare_profile

    choices = daemon.context.list_preset_tools.fetch(:tools)
    kernel = choices.select { |row| row[:kind] == "kernel" }
    assert_equal [{ name: "delegate_task", canonical: "nexus.graph.delegate_task", kind: "kernel", description: "the delegate_task verb" }], kernel
    application = choices.select { |row| row[:kind] == "agent" }
    assert_includes application.map { |row| row[:name] }, "list_extensions"
    runner = choices.select { |row| row[:kind] == "runner" }
    assert_includes runner.map { |row| row[:name] }, "read"
    assert_includes runner.map { |row| row[:name] }, "grep"
    refute_includes runner.map { |row| row[:name] }, "environment_bind", "an operator-only internal is never offered"
    assert runner.all? { |row| row[:description] }, "every served tool carries its line: #{runner.inspect}"
    assert_equal runner.map { |row| row[:name] }, runner.map { |row| row[:name] }.sort
  end

  def test_rm_removes_the_own_row_and_the_edge_does_not_restore_it
    api = fake(named_agents: [SIBLING, own_row], principals: [RHO_B])
    daemon = ready(api)
    write_definition(daemon, "reviewer", REVIEWER)
    daemon.context.declare_profile

    answer = daemon.context.remove_named_agent("reviewer")
    assert_equal "reviewer", answer.dig(:removed, :handle)
    assert_equal "na-reviewer", answer.dig(:removed, :public_id)
    assert_equal ["reviewer"], api.named_agent_deletes
    assert_match(/event=agents\.removed name=reviewer handle=reviewer scope=steward/, log(daemon))

    sibling = daemon.context.remove_named_agent("docs")
    assert_kind_of Rho::Daemon::Refusal, sibling
    assert_equal [404, "published_by_sibling", "docs is @rho-b's bot; the steward removes it on the agents page"],
      [sibling.status, sibling.code, sibling.message]

    unknown = daemon.context.remove_named_agent("nobody")
    assert_equal [404, "not_found"], [unknown.status, unknown.code]

    assert_equal %w[worker planner explorer reviewer], api.configuration_declarations.last.dig("configuration", "delegation_catalog").map { |entry| entry.fetch("name") }
    assert_equal :declared, daemon.context.declare_profile
    assert_equal 1, api.named_agent_declarations.length, "no file restores a removed row"
  end

  def test_an_unconnected_daemon_refuses_the_verbs
    daemon = boot

    assert_equal "member_plane_unavailable", daemon.context.list_named_agents.code
    assert_equal "member_plane_unavailable", daemon.context.remove_named_agent("x").code
    assert_equal "member_plane_unavailable", daemon.context.declare_named_agent(name: "x", description: "X.").code
  end
end
