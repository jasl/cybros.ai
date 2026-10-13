require "test_helper"

class SettingsWorkPresetsTest < Minitest::Test
  include RhoTest::DaemonHarness

  def presets(daemon) = daemon.context.agent_presets { |catalog| catalog }

  def replace_main(daemon, **configuration)
    catalog = presets(daemon)
    main = catalog.fetch(catalog.main_preset_public_id)
    catalog.replace(main.public_id, name: main.name, description: main.description, configuration: configuration.transform_keys(&:to_s))
  end

  def main_prompt(text)
    [Rho::RunDeclaration::GUIDELINE, text, Rho::RoleDeclarations.guidance(Rho::AgentPresets::SEEDS.filter_map { |entry| entry["role"] })].reject(&:empty?).join("\n\n")
  end

  def test_prompt_authorship_is_not_an_offline_instance_setting
    home = Rho::Home.resolve(base_url: "https://nexus.example", root: @root).prepare
    core = Rho::Core.new(home: home)
    %w[work_preset base_prompt custom_instructions].each do |key|
      assert_raises(Rho::ConfigurationError) { core.update_settings(key => "text") }
      refute core.settings.fetch("settings").key?(key)
    end
  end

  def test_main_preset_publishes_one_document_and_leaves_other_preset_bots_and_persona_alone
    api = NexusDoubles::FakeAgentApi.new(user_public_id: IDENTITY.user_public_id)
    daemon = member_ready(boot(realtime_factory: ->(*) { nil }), api, identity: RUNNER_IDENTITY)
    bot_preset = presets(daemon).create(name: "Reviewer", description: "Reviews changes", configuration: { "system_prompt" => "Named reviewer body." })
    daemon.context.declare_named_definition(name: "reviewer", description: "Reviews changes", preset_public_id: bot_preset.public_id)
    before = api.configuration_declarations.last
    declared = api.configuration_declarations.length
    bot = api.named_agent_declarations.last
    text = "  多行\n    Keep.\n"
    replace_main(daemon, system_prompt: text)

    assert_equal :declared, daemon.context.declare_profile
    assert_equal declared + 1, api.configuration_declarations.length
    after = api.configuration_declarations.last
    assert_equal main_prompt(text), after.dig("prompt_documents", "system_prompt", "content")
    assert_equal before.fetch("configuration"), after.fetch("configuration")
    assert_equal bot, api.named_agent_declarations.last
    refute api.prompt_document_writes.any? { |slot, _| slot == "persona" }
    assert_equal :unchanged, daemon.context.declare_profile
    assert_equal declared + 1, api.configuration_declarations.length

    replace_main(daemon, system_prompt: "")
    assert_equal :declared, daemon.context.declare_profile
    assert_equal main_prompt(""), api.configuration_declarations.last.dig("prompt_documents", "system_prompt", "content")
  end

  def test_invalid_preset_prompt_leaves_stored_and_published_documents_unchanged
    api = NexusDoubles::FakeAgentApi.new
    daemon = member_ready(boot(realtime_factory: ->(*) { nil }), api)
    assert_equal :declared, daemon.context.declare_profile
    catalog = presets(daemon)
    main = catalog.fetch(catalog.main_preset_public_id)
    published = api.configuration_declarations.dup

    [false, "界" * 30_000].each do |value|
      response = request(daemon, :put, "/presets", token: bearer(daemon),
        body: { public_id: main.public_id, name: main.name, description: main.description, configuration: { system_prompt: value } })
      assert_equal "400", response.code, response.body
      assert_equal main.to_h, catalog.fetch(main.public_id).to_h
      assert_equal published, api.configuration_declarations
    end
  end

  def test_failed_publication_keeps_saved_preset_and_retries_the_same_compiled_document
    attempts = 0
    api = NexusDoubles::FakeAgentApi.new(configuration: ->(_body) {
      attempts += 1
      attempts == 2 ? CybrosAgent::Response.new(status: 422, headers: {},
        body: { "error" => { "code" => "validation_failed", "message" => "Synthetic refusal" } }) : :accept
    })
    daemon = member_ready(boot(realtime_factory: ->(*) { nil }), api)
    assert_equal :declared, daemon.context.declare_profile
    original = api.prompt_document_writes.dup
    saved = replace_main(daemon, system_prompt: "Replacement\n\nMore")

    refused = daemon.context.declare_profile
    assert_equal "validation_failed", refused.code
    assert_equal saved.to_h, presets(daemon).fetch(saved.public_id).to_h
    assert_equal original, api.prompt_document_writes
    assert_equal :declared, daemon.context.declare_profile
    assert_equal 3, attempts
    assert_equal api.configuration_declarations[-2], api.configuration_declarations.last
    assert_equal main_prompt("Replacement\n\nMore"), api.prompt_document_writes.last.last.dig("prompt_document", "content")
  end

  def test_raw_runs_use_selected_preset_on_local_and_remote_runners_and_keep_request_overrides
    api = NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::RUNNING_TRACE,
      executors: [NexusDoubles.remote_runner("remote")])
    daemon = member_ready(boot(realtime_factory: ->(*) { nil }), api, identity: RUNNER_IDENTITY)
    replace_main(daemon, system_prompt: "Saved base\n\nSaved extra")
    capturing_spawns(daemon) do
      [RUNNER_IDENTITY.runner_executor_public_id, "remote"].each do |runner|
        [nil, "Explicit request"].each do |override|
          response = request(daemon, :post, "/runs", token: bearer(daemon),
            body: { prompt: "Work", model: "dev/model", default_runner_executor_public_id: runner,
              instructions: override, live: false })
          assert_equal "201", response.code, response.body
          instructions = api.run_creates.last.dig("run", "steps", 0, "model", "instructions")
          if override
            assert instructions.start_with?(override)
            refute_includes instructions, "Saved base"
            refute_includes instructions, "Saved extra"
          else
            assert instructions.start_with?(main_prompt("Saved base\n\nSaved extra"))
            assert_includes instructions, "Conversation kind: standalone."
          end
        end
      end
    end
  end
end
