require "test_helper"

class SettingsTest < Minitest::Test
  include RhoTest::DaemonHarness

  def test_settings_report_loaded_channels_before_a_runner_is_placed_in_both_webui_modes
    %w[full agent].each do |mode|
      daemon = boot(root: File.join(@root, mode), config: Rho::Config.from_hash("mode" => mode))
      token = bearer(daemon)
      runner = JSON.parse(request(daemon, :get, "/runner", token: token).body)
      assert_nil runner.fetch("runner")

      response = request(daemon, :get, "/settings", token: token)
      assert_equal "200", response.code, response.body
      extensions = JSON.parse(response.body).fetch("extensions")
      assert_includes extensions.map { |entry| entry.fetch("name") }, "rho.ingress_telegram"
      assert_includes extensions.map { |entry| entry.fetch("name") }, "rho.webui"
      assert_equal "200", request(daemon, :get, "/telegram", token: token).code
      refute File.exist?(daemon.home.settings_path), "extension availability is a read-only projection"
    end
  end

  def test_settings_need_the_local_bearer_and_do_not_echo_secrets
    config = Rho::Config.from_hash("access_passphrase" => "private-console-phrase",
      "nexus_public_url" => "https://public.example/nexus")
    daemon = boot(config: config)
    assert_equal "401", request(daemon, :get, "/settings").code
    assert_equal "401", request(daemon, :patch, "/settings", body: { default_model: "other" }).code

    response = request(daemon, :get, "/settings", token: bearer(daemon))
    assert_equal "200", response.code
    body = JSON.parse(response.body)
    assert_equal "https://public.example/nexus/admin/model_providers", body.dig("nexus", "model_settings_url")
    assert_equal true, body.dig("configured", "access_passphrase")
    refute_includes response.body, "private-console-phrase"
    refute body.fetch("settings").key?("telegram")
    rejected = request(daemon, :patch, "/settings", token: bearer(daemon), body: { telegram: { owner_id: "123" } })
    assert_equal "422", rejected.code
    refute File.exist?(daemon.home.settings_path), "channel changes use the plugin's validated configuration route"
  end

  def test_save_persists_and_changes_the_existing_daemon_without_restarting_unchanged_extensions
    events = []
    extension = Module.new
    extension.const_set(:NAME, "test.settings_lifecycle")
    extension.define_singleton_method(:register) do |api|
      events << :registered
      api.on(:startup) { events << :started }
      api.on(:shutdown) { events << :stopped }
    end
    daemon = boot(extensions: Rho::Extensions::DEFAULT_EXTENSIONS + [extension])
    original = daemon.host.config
    endpoint = daemon.endpoint
    response = request(daemon, :patch, "/settings", token: bearer(daemon),
      body: { default_model: "local/changed", fallback_model: "local/fallback", bash_timeout_seconds: 45 })

    assert_equal "200", response.code, response.body
    assert_same original, daemon.context.config
    assert_equal "local/changed", original.default_model
    assert_equal "local/fallback", daemon.context.config.fallback_model
    assert_equal endpoint, daemon.endpoint
    assert_equal [:registered, :started], events
    saved = Rho::Config.load(daemon.home.settings_path, env: { "RHO_DEFAULT_MODEL" => "env/seed" })
    assert_equal "local/changed", saved.default_model
    assert_equal 45, saved.bash_timeout_seconds
    assert_equal 0o600, File.stat(daemon.home.settings_path).mode & 0o777
  end

  def test_invalid_changes_leave_the_file_and_runtime_unchanged
    daemon = boot
    core = Rho::Core.new(home: daemon.home)
    core.update_settings("default_model" => "dev/kept")
    before = File.read(daemon.home.settings_path)
    response = request(daemon, :patch, "/settings", token: bearer(daemon),
      body: { default_model: "dev/lost", tools_root: File.join(@root, "missing") })
    assert_equal "422", response.code, response.body
    assert_equal before, File.read(daemon.home.settings_path)
    assert_equal "dev/kept", daemon.context.config.default_model
    assert_equal "dev/kept", core.settings.dig("settings", "default_model")
  end

  def test_passphrase_changes_apply_to_the_existing_unlock_door_without_echoing_it
    daemon = boot(config: Rho::Config.from_hash("access_passphrase" => "old-test-passphrase"))
    core = Rho::Core.new(home: daemon.home)
    saved = core.update_settings("access_passphrase" => "new-test-passphrase")
    refute_includes JSON.generate(saved), "new-test-passphrase"
    unlocked = request(daemon, :post, "/unlock", body: { passphrase: "new-test-passphrase" })
    assert_equal "200", unlocked.code
    assert_equal bearer(daemon), JSON.parse(unlocked.body).fetch("bearer")
    assert_equal "401", request(daemon, :post, "/unlock", body: { passphrase: "old-test-passphrase" }).code

    core.update_settings("access_passphrase" => nil)
    refute core.settings.dig("configured", "access_passphrase")
    assert_equal "409", request(daemon, :post, "/unlock", body: { passphrase: "new-test-passphrase" }).code
  end

  def test_disconnected_status_does_not_pair_or_choose_a_model
    daemon = boot
    core = Rho::Core.new(home: daemon.home)
    body = core.settings_status
    assert_equal false, body.fetch("connected")
    assert_equal false, body.dig("model", "ready")
    assert_equal [], body.dig("model", "eligible")
    assert_nil daemon.lineage.connection
    refute File.exist?(daemon.home.settings_path)
  end

  def test_status_uses_member_model_catalog_without_inference_or_implicit_writes
    rows = [model("dev/tool"), model("dev/text", tools: false), model("dev/disabled", available: false)]
    api = NexusDoubles::FakeAgentApi.new(models: rows)
    daemon = boot(api_transport: api, config: Rho::Config.from_hash("default_model" => "dev/tool"))
    member_ready(daemon, api)
    response = request(daemon, :get, "/settings/status", token: bearer(daemon))
    assert_equal "200", response.code, response.body
    body = JSON.parse(response.body)
    assert_equal true, body.fetch("connected")
    assert_equal true, body.dig("model", "ready")
    assert_equal ["dev/tool"], body.dig("model", "eligible").map { |row| row.fetch("ref") }
    refute File.exist?(daemon.home.settings_path)
    assert_equal ["/agent_api/v1/models"], api.requests.map(&:first)
  end

  def test_disk_failure_does_not_publish_the_candidate
    home = Rho::Home.resolve(base_url: "http://example.test", root: @root).prepare
    config = Rho::Config::Current.new(Rho::Config.from_hash("default_model" => "dev/kept"))
    applied = []
    settings = Rho::Settings.new(home: home, config: config, apply: ->(*) { applied << true })
    home.define_singleton_method(:write_settings) { |_| raise Errno::ENOSPC }
    Async { assert_raises(Errno::ENOSPC) { settings.update({ "default_model" => "dev/lost" }) } }.wait
    assert_equal "dev/kept", config.default_model
    assert_empty applied
  end

  def test_apply_failure_reports_saved_state_and_accepts_an_explicit_retry
    home = Rho::Home.resolve(base_url: "http://example.test", root: @root).prepare
    config = Rho::Config::Current.new(Rho::Config.from_hash({}))
    attempts = 0
    settings = Rho::Settings.new(home: home, config: config, apply: ->(*) {
      attempts += 1
      raise Rho::ConnectionError, "synthetic" if attempts == 1
    })
    Async { assert_raises(Rho::Settings::ApplyError) { settings.update({ "default_model" => "dev/new" }) } }.wait
    assert_equal "dev/new", Rho::Config.read(home.settings_path).fetch("default_model")
    Async { settings.update({ "default_model" => "dev/new" }) }.wait
    assert_equal 2, attempts
  end

  def test_cli_offline_save_preserves_other_settings_and_clears_environment_seeds
    home = Rho::Home.resolve(base_url: "http://example.test", root: @root).prepare
    home.write_setting("runner", "saved-runner")
    Rho::Core.new(home: home).update_settings("fallback_model" => nil, "default_model" => "dev/saved")
    saved = Rho::Config.load(home.settings_path, env: { "RHO_FALLBACK_MODEL" => "env/seed" })
    assert_nil saved.fallback_model
    assert_equal "saved-runner", saved.runner
    assert_equal "dev/saved", saved.default_model
  end

  def test_saved_nested_settings_match_the_active_value_after_a_restart
    home = Rho::Home.resolve(base_url: "http://example.test", root: @root).prepare
    env = { "RHO_DEFAULT_MODEL" => "dev/default", "RHO_COMPACTION" => "delegate" }
    config = Rho::Config::Current.new(Rho::Config.load(home.settings_path, env: env))
    settings = Rho::Settings.new(home: home, config: config, apply: ->(*) { })
    Async { settings.update({ "compaction" => { "model" => "dev/summary" } }) }.wait

    assert_equal({ "mode" => "kernel", "model" => "dev/summary" }, config.compaction)
    assert_equal config.compaction, Rho::Config.load(home.settings_path, env: env).compaction
  end

  private

    def model(ref, tools: true, available: true)
      { "ref" => ref, "provider" => "dev", "workload" => "text_generation", "visible" => true,
        "available" => available, "capabilities" => { "tool_calls" => tools },
        "pricing" => { "state" => "cost_unknown" } }
    end
end
