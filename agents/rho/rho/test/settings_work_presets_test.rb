require "test_helper"

class SettingsWorkPresetsTest < Minitest::Test
  include RhoTest::DaemonHarness

  def test_offline_settings_round_trip_literal_text_and_restore_the_builtin_prompt
    home = Rho::Home.resolve(base_url: "https://nexus.example", root: @root).prepare
    core = Rho::Core.new(home: home)
    patch = { "work_preset" => "compact", "base_prompt" => "  Base.\n", "custom_instructions" => "  多行\n    Keep.\n" }

    assert_equal patch, core.update_settings(patch).fetch("settings").slice(*patch.keys)
    assert_equal patch, core.settings.fetch("settings").slice(*patch.keys)
    saved = Rho::Config.load(home.settings_path, env: {}, home: home)
    assert_equal "  Base.\n\n\n  多行\n    Keep.\n", saved.system_prompt

    core.update_settings("base_prompt" => "")
    assert_equal "", core.settings.dig("settings", "base_prompt")
    core.update_settings("base_prompt" => nil)
    restored = Rho::Config.load(home.settings_path, env: {}, home: home)
    assert_equal "#{Rho::WorkPresets::COMPACT}\n\n#{patch.fetch("custom_instructions")}", restored.system_prompt
  end

  def test_prompt_only_settings_publish_one_main_document_and_leave_named_agents_and_persona_alone
    api = NexusDoubles::FakeAgentApi.new(user_public_id: IDENTITY.user_public_id)
    daemon = member_ready(boot, api, identity: RUNNER_IDENTITY)
    directory = File.join(daemon.context.environment.root, ".agents", "agents")
    FileUtils.mkdir_p(directory)
    File.write(File.join(directory, "reviewer.md"), "---\ndescription: Reviews changes.\ntools: read, grep\n---\nNamed reviewer body.\n")
    assert_equal :declared, daemon.context.declare_profile
    before = api.configuration_declarations.last
    named = api.named_agent_declarations.last
    patch = { work_preset: "compact", custom_instructions: "  Extra.\n" }

    response = request(daemon, :patch, "/settings", token: bearer(daemon), body: patch)

    assert_equal "200", response.code, response.body
    assert_equal "compact", JSON.parse(response.body).dig("settings", "work_preset")
    assert_equal 2, api.configuration_declarations.length
    after = api.configuration_declarations.last
    assert_equal "#{Rho::WorkPresets::COMPACT}\n\n  Extra.\n", after.dig("prompt_documents", "system_prompt", "content")
    assert_equal before.fetch("configuration"), after.fetch("configuration"), "preset changes no tools, template, models or compaction"
    assert_equal Rho::RunDeclaration::GUIDELINE, before.dig("prompt_documents", "system_prompt", "content")
    assert_equal named, api.named_agent_declarations.last
    assert_equal "Named reviewer body.", api.named_agent_declarations.last.last.fetch("system_prompt")
    refute api.prompt_document_writes.any? { |slot, _| slot == "persona" }

    repeat = request(daemon, :patch, "/settings", token: bearer(daemon), body: patch)
    assert_equal "200", repeat.code, repeat.body
    assert_equal 2, api.configuration_declarations.length, "identical content is not published again"
    assert_equal :unchanged, daemon.context.declare_profile

    empty = request(daemon, :patch, "/settings", token: bearer(daemon), body: { base_prompt: "", custom_instructions: nil })
    assert_equal "200", empty.code, empty.body
    assert_equal "", api.configuration_declarations.last.dig("prompt_documents", "system_prompt", "content")
    restored = request(daemon, :patch, "/settings", token: bearer(daemon), body: { base_prompt: nil })
    assert_equal "200", restored.code, restored.body
    assert_equal Rho::WorkPresets::COMPACT, api.configuration_declarations.last.dig("prompt_documents", "system_prompt", "content")
  end

  def test_invalid_prompt_settings_leave_saved_runtime_and_published_documents_unchanged
    api = NexusDoubles::FakeAgentApi.new
    daemon = member_ready(boot, api)
    assert_equal :declared, daemon.context.declare_profile
    saved = File.read(daemon.home.settings_path)
    published = api.configuration_declarations.dup

    [{ work_preset: "other" }, { custom_instructions: false }, { custom_instructions: "界" * 20_000 }].each do |patch|
      response = request(daemon, :patch, "/settings", token: bearer(daemon), body: patch)
      assert_equal "422", response.code, response.body
      assert_equal "settings_invalid", JSON.parse(response.body).dig("error", "code")
      assert_equal saved, File.read(daemon.home.settings_path)
      assert_equal "standard", daemon.context.config.work_preset
      assert_equal Rho::RunDeclaration::GUIDELINE, daemon.context.config.system_prompt
      assert_equal published, api.configuration_declarations
    end
  end

  def test_a_failed_prompt_publication_keeps_saved_settings_and_retries_the_full_document
    attempts = 0
    api = NexusDoubles::FakeAgentApi.new(configuration: ->(_body) {
      attempts += 1
      attempts == 2 ? CybrosAgent::Response.new(status: 422, headers: {},
        body: { "error" => { "code" => "validation_failed", "message" => "Synthetic refusal" } }) : :accept
    })
    daemon = member_ready(boot, api)
    assert_equal :declared, daemon.context.declare_profile
    patch = { base_prompt: "Replacement", custom_instructions: "More" }

    refused = request(daemon, :patch, "/settings", token: bearer(daemon), body: patch)

    assert_equal "503", refused.code, refused.body
    error = JSON.parse(refused.body).fetch("error")
    assert error.fetch("saved")
    assert error.fetch("applied")
    refute error.fetch("published")
    assert_equal "Replacement", Rho::Config.read(daemon.home.settings_path).fetch("base_prompt")
    assert_equal "Replacement\n\nMore", daemon.context.config.system_prompt
    assert_equal [Rho::RunDeclaration::GUIDELINE], api.prompt_document_writes.filter_map { |slot, body| body.dig("prompt_document", "content") if slot == "system_prompt" }

    retried = request(daemon, :patch, "/settings", token: bearer(daemon), body: patch)

    assert_equal "200", retried.code, retried.body
    assert_equal 3, attempts
    assert_equal api.configuration_declarations[-2], api.configuration_declarations.last
    assert_equal "Replacement\n\nMore", api.prompt_document_writes.last.last.dig("prompt_document", "content")
  end

  def test_raw_runs_use_the_saved_prompt_on_local_and_remote_runners_and_keep_request_overrides
    api = NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::RUNNING_TRACE,
      executors: [NexusDoubles.remote_runner("remote")])
    daemon = member_ready(boot(config: Rho::Config.from_hash({ "base_prompt" => "Saved base", "custom_instructions" => "Saved extra" })), api,
      identity: RUNNER_IDENTITY)
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
            assert instructions.start_with?("Saved base\n\nSaved extra\n\nConversation kind: standalone.")
          end
        end
      end
    end
  end
end
