require "test_helper"

class SettingsTest < Minitest::Test
  include RhoTest::DaemonHarness

  def test_inventory_reports_channels_before_a_runner_is_placed_in_both_webui_modes
    %w[full agent].each do |mode|
      daemon = boot(root: File.join(@root, mode), config: Rho::Config.from_hash({ "mode" => mode }))
      token = bearer(daemon)
      before = File.read(daemon.home.settings_path)
      runner = JSON.parse(request(daemon, :get, "/runner", token: token).body)
      assert_nil runner.fetch("runner")

      response = request(daemon, :get, "/extensions", token: token)
      assert_equal "200", response.code, response.body
      extensions = JSON.parse(response.body).fetch("plugins")
      assert_includes extensions.map { |entry| entry.fetch("id") }, "rho.ingress_telegram"
      assert_includes extensions.map { |entry| entry.fetch("id") }, "rho.webui"
      refute extensions.find { |entry| entry.fetch("id") == "rho.ingress_telegram" }.fetch("enabled")
      refute extensions.find { |entry| entry.fetch("id") == "rho.ingress_telegram" }.fetch("active")
      assert_equal before, File.read(daemon.home.settings_path), "extension availability is a read-only projection"
    end
  end

  def test_settings_need_a_bearer_and_do_not_echo_configured_secrets
    home = Rho::Home.resolve(base_url: "https://nexus.example", root: @root).prepare
    home.write_settings("settings_version" => 1, "nexus_public_url" => "https://public.example/nexus", "plugins" => {
      "rho.mcp" => { "enabled" => false, "configuration_version" => 1,
        "configuration" => { "servers" => { "private" => { "env" => { "TOKEN" => "private-tool-secret" } } } } },
    })
    daemon = boot
    before = File.read(daemon.home.settings_path)
    assert_equal "401", request(daemon, :get, "/settings").code
    assert_equal "401", request(daemon, :patch, "/settings", body: { default_model: "other" }).code

    response = request(daemon, :get, "/settings", token: bearer(daemon))
    assert_equal "200", response.code
    body = JSON.parse(response.body)
    assert_equal "https://public.example/nexus/admin/model_providers", body.dig("nexus", "model_settings_url")
    refute_includes response.body, "private-tool-secret"
    inventory = Rho::Core.new(home: daemon.home).extensions
    mcp = inventory.fetch("plugins").find { |entry| entry.fetch("id") == "rho.mcp" }
    assert_includes mcp.dig("configuration", "overrides", "servers").keys, "private"
    refute_includes JSON.generate(inventory), "private-tool-secret"
    refute body.fetch("settings").key?("telegram")
    rejected = request(daemon, :patch, "/settings", token: bearer(daemon), body: { telegram: { owner_id: "123" } })
    assert_equal "422", rejected.code
    assert_equal before, File.read(daemon.home.settings_path), "channel changes use the plugin's validated configuration route"
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
      body: { default_model: "local/changed", fallback_model: "local/fallback" })

    assert_equal "200", response.code, response.body
    response = request(daemon, :patch, "/extensions/rho.coding/configuration", token: bearer(daemon),
      body: { operations: [{ op: "set", path: ["bash_timeout_seconds"], value: 45 }] })
    assert_equal "200", response.code, response.body
    assert_same original, daemon.context.config
    assert_equal "local/changed", original.default_model
    assert_equal "local/fallback", daemon.context.config.fallback_model
    assert_equal endpoint, daemon.endpoint
    assert_equal [:registered, :started], events
    saved = Rho::Config.load(daemon.home.settings_path, env: { "RHO_DEFAULT_MODEL" => "env/seed" })
    assert_equal "local/changed", saved.default_model
    assert_equal 45, saved.plugin_configuration("rho.coding").fetch("bash_timeout_seconds")
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

  def test_browser_url_is_a_deployment_setting_and_cannot_be_changed_from_the_page
    daemon = boot(config: Rho::Config.from_hash({ "public_url" => "https://rho.example" }))
    before = File.read(daemon.home.settings_path)
    response = request(daemon, :patch, "/settings", token: bearer(daemon),
      body: { public_url: "https://different.example" })
    assert_equal "422", response.code
    assert_equal "https://rho.example", daemon.host.config.public_url
    assert_equal before, File.read(daemon.home.settings_path)
  end

  def test_disconnected_status_does_not_pair_or_choose_a_model
    daemon = boot
    core = Rho::Core.new(home: daemon.home)
    before = File.read(daemon.home.settings_path)
    body = core.settings_status
    assert_equal false, body.fetch("connected")
    assert_equal false, body.dig("model", "ready")
    assert_equal [], body.dig("model", "eligible")
    assert_nil daemon.lineage.connection
    assert_equal before, File.read(daemon.home.settings_path)
  end

  def test_status_uses_member_model_catalog_without_inference_or_implicit_writes
    rows = [model("dev/tool"), model("dev/text", tools: false), model("dev/disabled", available: false)]
    api = NexusDoubles::FakeAgentApi.new(models: rows)
    daemon = boot(api_transport: api, config: Rho::Config.from_hash({ "default_model" => "dev/tool" }))
    member_ready(daemon, api)
    before = File.read(daemon.home.settings_path)
    response = request(daemon, :get, "/settings/status", token: bearer(daemon))
    assert_equal "200", response.code, response.body
    body = JSON.parse(response.body)
    assert_equal true, body.fetch("connected")
    assert_equal true, body.dig("model", "ready")
    assert_equal ["dev/tool"], body.dig("model", "eligible").map { |row| row.fetch("ref") }
    assert_equal before, File.read(daemon.home.settings_path)
    assert_equal ["/agent_api/v1/models"], api.requests.map(&:first)
  end

  def test_disk_failure_does_not_publish_the_candidate
    home = Rho::Home.resolve(base_url: "http://example.test", root: @root).prepare
    config = Rho::Config::Current.new(Rho::Config.from_hash({ "default_model" => "dev/kept" }))
    applied = []
    settings = Rho::Settings.new(home: home, config: config, apply: ->(*) { applied << true })
    home.define_singleton_method(:write_settings) { |_| raise Errno::ENOSPC }
    Async { assert_raises(Errno::ENOSPC) { settings.update({ "default_model" => "dev/lost" }) } }.wait
    assert_equal "dev/kept", config.default_model
    assert_empty applied
  end

  def test_apply_failure_reports_saved_state_and_accepts_an_explicit_retry
    [Rho::ConnectionError, Rho::Settings::PreparationError].each do |failure|
      home = Rho::Home.resolve(base_url: "http://example.test", root: @root).prepare
      config = Rho::Config::Current.new(Rho::Config.from_hash({}))
      attempts = 0
      settings = Rho::Settings.new(home: home, config: config, apply: ->(*) {
        attempts += 1
        raise failure, "synthetic-secret" if attempts == 1
      })
      error = Async { assert_raises(Rho::Settings::ApplyError) { settings.update({ "default_model" => "dev/new" }) } }.wait
      assert_includes error.message, "Settings were saved"
      assert_includes error.message, "correct the issue"
      refute_includes error.message, "synthetic-secret"
      assert_nil error.cause
      assert_equal "dev/new", Rho::Config.read(home.settings_path).fetch("default_model")
      Async { settings.update({ "default_model" => "dev/new" }) }.wait
      assert_equal 2, attempts
    end
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
    env = { "RHO_DEFAULT_MODEL" => "dev/default" }
    config = Rho::Config::Current.new(Rho::Config.load(home.settings_path, env: env))
    settings = Rho::Settings.new(home: home, config: config, apply: ->(*) { })
    Async { settings.update_plugin("rho.compaction", operations: [{ "op" => "set", "path" => ["model"], "value" => "dev/summary" }]) }.wait

    assert_equal({ "mode" => "kernel", "model" => "dev/summary" }, config.plugin_configuration("rho.compaction"))
    assert_equal config.plugin_configuration("rho.compaction"), Rho::Config.load(home.settings_path, env: env).plugin_configuration("rho.compaction")
  end

  private

    def model(ref, tools: true, available: true)
      { "ref" => ref, "provider" => "dev", "workload" => "text_generation", "visible" => true,
        "available" => available, "capabilities" => { "tool_calls" => tools },
        "pricing" => { "state" => "cost_unknown" } }
    end
end
