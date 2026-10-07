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
    assert_equal :unchanged, daemon.context.declare_profile
    daemon.context.sync_named_definitions
    assert_empty api.named_agent_deletes, "sync retains the extension-owned definition"
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

  def test_file_templates_are_parsed_and_extension_names_cannot_be_shadowed_by_files
    directory = File.join(@root, ".agents/agents")
    FileUtils.mkdir_p(directory)
    path = File.join(directory, "shared-room.md")
    File.write(path, "---\ndescription: From disk.\nprompt_template:\n  blocks:\n    - type: history\n    - type: input\n---\nDisk body.\n")
    parsed = Rho::Agents.parse(path)
    assert_equal({ "blocks" => [{ "type" => "history" }, { "type" => "input" }] }, parsed.prompt_template)
    scan = Rho::Agents.scan(root: @root, definitions: [definition])
    assert_equal [definition], scan.definitions
    assert_equal 1, scan.skipped.length

    File.write(path, "---\ndescription: Bad template.\nprompt_template: invalid\n---\n")
    assert_equal "prompt_template must be an object", Rho::Agents.parse(path).reason
  end
end
