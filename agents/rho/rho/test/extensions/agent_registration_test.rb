require "test_helper"
require "support/nexus_doubles"
require "support/daemon_harness"

class AgentRegistrationTest < Minitest::Test
  include RhoTest::DaemonHarness

  TEMPLATE = { "blocks" => [{ "type" => "slot", "slot" => "system_prompt" },
    { "type" => "history" }, { "type" => "input" }] }.freeze

  def definition
    Rho::Agents::Definition.new(name: "shared-room", description: "A shared room.", tools: %w[read ask],
      model: nil, body: "A shared conversation.", path: "<extension>", ignored_keys: [], prompt_template: TEMPLATE)
  end

  def extension(name, fail: false)
    row = definition
    Module.new do
      const_set(:NAME, name)
      define_singleton_method(:register) do |api|
        api.register_agent(row)
        raise "registration failed" if fail
      end
    end
  end

  def test_registered_definition_uses_the_same_sync_without_a_filesystem_root
    api = NexusDoubles::FakeAgentApi.new(user_public_id: IDENTITY.user_public_id)
    daemon = member_ready(boot(extensions: Rho::Extensions::DEFAULT_EXTENSIONS + [extension("rho.shared")]), api)
    daemon.context.define_singleton_method(:environment) { Rho::EnvironmentStore::Selection.new(root: nil, source: "unset") }

    assert_equal :declared, daemon.context.declare_profile
    declaration = api.named_agent_declarations.last.last
    assert_equal "assembly", declaration.dig("configuration", "prompt_mechanism")
    assert_equal TEMPLATE, declaration.dig("configuration", "prompt_template")
    assert_equal "A shared conversation.", declaration.fetch("system_prompt")
    assert_equal :declared, daemon.context.declare_profile
    response = request(daemon, :post, "/presets/import", token: bearer(daemon), body: {})
    assert_equal "200", response.code, response.body
    assert_empty JSON.parse(response.body).fetch("imported")
    assert_empty api.named_agent_deletes, "an import touches no extension-owned definition"
  end

  def test_registered_definition_without_a_model_inherits_the_request_model
    api = NexusDoubles::FakeAgentApi.new(user_public_id: IDENTITY.user_public_id, trace: NexusDoubles::RUNNING_TRACE)
    config = Rho::Config.from_hash({ "default_model" => "dev/mock-text-only" })
    daemon = member_ready(boot(config: config,
      extensions: Rho::Extensions::DEFAULT_EXTENSIONS + [extension("rho.shared")]), api)
    daemon.context.declare_profile
    rows = api.named_agents_listing.body.fetch("agents")
    api.stock_principals(rows.map { |row| row.slice("public_id", "handle", "kind", "display_name", "agent_identifier", "steward_public_id") })

    opened = request(daemon, :post, "/conversations", token: bearer(daemon), body: { agent: "@shared-room" })
    assert_equal "201", opened.code, opened.body
    assert_empty api.inputs, "the Telegram ingress opens its conversation before submitting a request"

    response = request(daemon, :post, "/conversations", token: bearer(daemon),
      body: { agent: "@shared-room", prompt: "Help in this shared room", model: "dev/mock-text" })
    assert_equal "201", response.code, response.body
    assert_equal "dev/mock-text", api.inputs.last.dig("input", "model", "model"),
      "an extension-owned profile with no fixed model inherits the explicit request"
  end

  def test_registered_definition_has_no_editable_home
    api = NexusDoubles::FakeAgentApi.new(user_public_id: IDENTITY.user_public_id)
    daemon = member_ready(boot(extensions: Rho::Extensions::DEFAULT_EXTENSIONS + [extension("rho.shared")]), api)
    daemon.context.declare_profile
    response = request(daemon, :get, "/agents", token: bearer(daemon))
    assert_equal "200", response.code, response.body
    row = JSON.parse(response.body).fetch("bots").find { |bot| bot.fetch("name") == "shared-room" }
    assert_equal true, row.fetch("registered")
    refute row.key?("home_workspace_public_id")

    response = request(daemon, :put, "/agents/settings", token: bearer(daemon),
      body: { agent_public_id: row.fetch("public_id"), home_workspace_public_id: nil })

    assert_equal "409", response.code, response.body
    assert_equal "registered_definition", JSON.parse(response.body).dig("error", "code")
    assert_empty api.store_entries_of("profile").select { |entry| entry.fetch("namespace") == "rho.bots" }
  end

  def test_failed_registration_contributes_no_definition_and_duplicate_owners_fail_loudly
    loaded = Rho::Extensions.load(host: RhoTest.host, extensions: [extension("rho.failed", fail: true)])
    assert_empty loaded.agents
    assert_equal ["registration failed"], loaded.failures.map(&:message)

    assert_raises(Rho::Runner::Extensions::RegistrationError) do
      Rho::Extensions.load(host: RhoTest.host, extensions: [extension("rho.first"), extension("rho.second")])
    end
  end

  def test_runner_mode_does_not_register_agents
    host = RhoTest.host.with(config: Rho::Config.from_hash({ "mode" => "runner" }))
    loaded = Rho::Extensions.load(host: host, extensions: [extension("rho.shared")])
    assert_empty loaded.agents
  end

  def test_preset_file_import_preserves_templates_without_shadowing_extension_definitions
    api = NexusDoubles::FakeAgentApi.new(user_public_id: IDENTITY.user_public_id)
    daemon = member_ready(boot(extensions: Rho::Extensions::DEFAULT_EXTENSIONS + [extension("rho.shared")]), api)
    daemon.context.declare_profile
    declarations = api.named_agent_declarations.dup
    directory = File.join(daemon.context.environment.root, ".agents/agents")
    FileUtils.mkdir_p(directory)
    path = File.join(directory, "shared-room.md")
    File.write(path, "---\ndescription: From disk.\nprompt_template:\n  blocks:\n    - type: history\n    - type: input\n---\nDisk body.\n")
    response = request(daemon, :post, "/presets/import", token: bearer(daemon), body: {})
    assert_equal "200", response.code, response.body
    imported = JSON.parse(response.body).fetch("imported").first
    assert_equal "shared-room", imported.fetch("name")
    assert_equal({ "blocks" => [{ "type" => "history" }, { "type" => "input" }] }, imported.dig("configuration", "prompt_template"))
    assert_equal "Disk body.\n", imported.dig("configuration", "system_prompt")
    assert_equal declarations, api.named_agent_declarations
    assert_equal :declared, daemon.context.declare_profile
    declarations = api.named_agent_declarations.dup

    File.write(path, "---\ndescription: Bad template.\nprompt_template: invalid\n---\n")
    response = request(daemon, :post, "/presets/import", token: bearer(daemon), body: {})
    assert_equal "200", response.code, response.body
    result = JSON.parse(response.body)
    assert_empty result.fetch("imported")
    assert_includes result.fetch("skipped").first.fetch("reason"), "/configuration/prompt_template"
    assert_equal declarations, api.named_agent_declarations
  end
end
