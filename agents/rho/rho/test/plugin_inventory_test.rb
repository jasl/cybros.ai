require "test_helper"

class PluginInventoryTest < Minitest::Test
  include RhoTest::DaemonHarness

  ID = "test.inventory_probe".freeze

  def test_inventory_uses_the_running_mode_selected_by_a_launch_flag
    daemon = boot(flags: { mode: "runner" })
    row = plugin_row(daemon, "rho.webui")

    refute row.fetch("active")
    assert_includes row.fetch("readiness").fetch("issues"), "Unavailable in runner mode"
  end

  def test_startup_failure_is_visible_without_returning_the_exception_message
    path = write_plugin('api.on(:startup) { raise "synthetic secret in exception" }')
    seed(ID => path_entry(path))
    daemon = boot
    inventory = Rho::Core.new(home: daemon.home).extensions
    row = inventory.fetch("plugins").find { |plugin| plugin.fetch("id") == ID }

    assert row.fetch("enabled")
    refute row.fetch("active")
    assert_includes row.fetch("readiness").fetch("issues"), "Plugin failed to load or start (RuntimeError)."
    assert inventory.fetch("failures").any? { |failure| failure.fetch("id") == ID }
    refute_includes JSON.generate(inventory), "synthetic secret in exception"
  end

  def test_prerequisite_failure_keeps_management_available_and_surfaces_repair_guidance
    path = write_plugin('api.on(:startup) { raise Rho::Runner::Extensions::PrerequisiteError, "Install the test driver, then enable this plugin again." }')
    seed(ID => path_entry(path))
    daemon = boot
    row = plugin_row(daemon)

    assert row.fetch("enabled")
    refute row.fetch("active")
    assert_includes row.fetch("readiness").fetch("issues"), "Install the test driver, then enable this plugin again."
    assert_equal "200", request(daemon, :get, "/settings", token: bearer(daemon)).code
  end

  def test_failed_enable_retains_actionable_diagnostics_and_can_retry_after_repair
    path = write_plugin('api.on(:startup) { raise Rho::Runner::Extensions::PrerequisiteError, "Install the test driver, then enable this plugin again." }')
    seed(ID => path_entry(path).merge("enabled" => false))
    daemon = boot

    response = request(daemon, :post, "/extensions/#{ID}/enable", token: bearer(daemon), body: {})
    error = JSON.parse(response.body).fetch("error")

    assert_equal "503", response.code, response.body
    assert error.fetch("saved")
    refute error.fetch("applied")
    assert_equal "Install the test driver, then enable this plugin again.", error.fetch("message")
    refute plugin_row(daemon).fetch("active")
    assert_includes plugin_row(daemon).fetch("readiness").fetch("issues"), error.fetch("message")

    File.write(path, plugin_source('api.register_route("GET", "/inventory-probe") { |_request, _ctx| [200, { ready: true }] }'))
    response = request(daemon, :post, "/extensions/#{ID}/enable", token: bearer(daemon), body: {})

    assert_equal "200", response.code, response.body
    assert plugin_row(daemon).fetch("active")
    assert_empty plugin_row(daemon).fetch("readiness").fetch("issues")
    assert_equal "200", request(daemon, :get, "/inventory-probe", token: bearer(daemon)).code
  end

  def test_first_party_plugins_describe_their_purpose_even_when_disabled
    daemon = boot
    rows = Rho::Core.new(home: daemon.home).extensions.fetch("plugins")

    rows.each do |row|
      refute_empty row.fetch("description"), row.fetch("id")
      # Every shipped plugin names its place on the Plugins page; `other` is for manifests that say nothing.
      assert_includes Rho::Extensions::Catalog::CATEGORIES - ["other"], row.fetch("category"), row.fetch("id")
    end
    browser = rows.find { |row| row.fetch("id") == "rho.browser" }
    refute browser.fetch("active")
    assert_includes browser.fetch("description"), "Open websites"
    assert_equal "tools", browser.fetch("category")
    assert_equal "channels", rows.find { |row| row.fetch("id") == "rho.ingress_telegram" }.fetch("category")
  end

  def test_a_description_names_a_known_category_or_none
    source = { "kind" => "package", "name" => "notes" }
    described = Rho::Extensions::Catalog::Descriptor.from_h({ "id" => "personal.notes" }, source: source, directory: "/tmp")
    assert_equal "other", described.category
    error = assert_raises(Rho::ConfigurationError) do
      Rho::Extensions::Catalog::Descriptor.from_h({ "id" => "personal.notes", "category" => "widgets" }, source: source, directory: "/tmp")
    end
    assert_includes error.message, "invalid static description"
  end

  def test_prerequisite_failure_while_reconfiguring_keeps_previous_runtime_and_configuration
    path = write_plugin(<<~RUBY)
      fail_start = api.configuration.fetch("fail_start", false)
      api.on(:startup) do
        raise Rho::Runner::Extensions::PrerequisiteError, "Repair the test driver." if fail_start
      end
      api.register_route("GET", "/inventory-probe") { |_request, _ctx| [200, { fail_start: fail_start }] }
    RUBY
    RhoTest.described_extension(path, id: ID, schema: { "type" => "object", "properties" => {
      "fail_start" => { "type" => "boolean", "default" => false },
    } })
    seed(ID => path_entry(path))
    daemon = boot

    response = request(daemon, :patch, "/extensions/#{ID}/configuration", token: bearer(daemon),
      body: { operations: [{ op: "set", path: ["fail_start"], value: true }] })

    assert_equal "503", response.code, response.body
    assert JSON.parse(response.body).dig("error", "saved")
    refute JSON.parse(response.body).dig("error", "applied")
    assert plugin_row(daemon).fetch("active")
    assert Rho::Config.read(daemon.home.settings_path).dig("plugins", ID, "configuration", "fail_start")
    refute daemon.instance_variable_get(:@config).plugin_configuration(ID).fetch("fail_start")
    active = request(daemon, :get, "/inventory-probe", token: bearer(daemon))
    refute JSON.parse(active.body).fetch("fail_start")
    assert_includes plugin_row(daemon).fetch("readiness").fetch("issues"), "Repair the test driver."
  end

  def test_registration_prerequisite_failure_also_returns_actionable_guidance
    path = write_plugin('raise Rho::Runner::Extensions::PrerequisiteError, "Install the test runtime."')
    seed(ID => path_entry(path).merge("enabled" => false))
    daemon = boot

    response = request(daemon, :post, "/extensions/#{ID}/enable", token: bearer(daemon), body: {})

    assert_equal "503", response.code, response.body
    assert_equal "Install the test runtime.", JSON.parse(response.body).dig("error", "message")
    refute plugin_row(daemon).fetch("active")
    refute daemon.instance_variable_get(:@config).plugin_requested?(ID)
  end

  def test_web_tools_are_available_by_default_and_an_explicit_disable_survives_restart
    daemon = boot
    row = plugin_row(daemon, "rho.web_tools")

    assert row.fetch("default_enabled")
    assert row.fetch("enabled")
    assert row.fetch("active")
    assert_includes row.fetch("capabilities").fetch("tools"), "web_fetch"
    refute Rho::Config.read(daemon.home.settings_path).fetch("plugins").key?("rho.web_tools")

    result = Rho::Core.new(home: daemon.home).disable_extension("rho.web_tools")
    assert result.fetch("applied")
    refute plugin_row(daemon, "rho.web_tools").fetch("active")
    daemon.stop
    restarted = boot

    refute plugin_row(restarted, "rho.web_tools").fetch("enabled")
    refute plugin_row(restarted, "rho.web_tools").fetch("active")
  end

  def test_restart_only_source_replacement_shows_the_saved_and_running_versions
    home = Rho::Home.resolve(base_url: "https://nexus.example", root: @root)
    home.prepare
    packages = Rho::Packages.new(home: home)
    source = File.join(@root, "candidate")
    FileUtils.mkdir_p(source)
    File.write(File.join(source, "rho-extension.json"), JSON.generate(
      "name" => "inventory_probe", "id" => ID, "restart_only" => true,
      "configuration_schema" => { "type" => "object", "properties" => {} }
    ))
    File.write(File.join(source, "extension.rb"), plugin_source('api.register_route("GET", "/inventory-probe") { |_request, _ctx| [200, { version: "first" }] }'))
    first = packages.install(path: source).fetch(:version)
    packages.activate(name: "inventory_probe", version: first) { |_sources, persist| persist.call }
    daemon = boot
    core = Rho::Core.new(home: daemon.home)
    File.write(File.join(source, "extension.rb"), plugin_source('api.register_route("GET", "/inventory-probe") { |_request, _ctx| [200, { version: "second" }] }'))
    second = core.manage_package(action: "install", path: source).fetch("version")
    result = core.manage_package(action: "activate", name: "inventory_probe", version: second)

    assert result.fetch("saved")
    refute result.fetch("applied")
    row = plugin_row(daemon)
    assert row.fetch("active")
    assert row.fetch("restart_required")
    assert_equal second, row.fetch("source").fetch("version")
    assert_equal first, row.fetch("active_source").fetch("version")
    assert_equal "first", JSON.parse(request(daemon, :get, "/inventory-probe", token: bearer(daemon)).body).fetch("version")
  end

  def test_failed_status_callback_does_not_hide_inventory_or_misreport_a_saved_change
    path = write_plugin('api.describe_status { raise "synthetic status secret" }')
    seed(ID => path_entry(path))
    daemon = boot
    row = plugin_row(daemon)

    assert row.fetch("active")
    assert_includes row.fetch("readiness").fetch("issues"), "Plugin status could not be read (RuntimeError)."
    refute_includes JSON.generate(row), "synthetic status secret"
    result = Rho::Core.new(home: daemon.home).configure_extension(ID, operations: [])
    assert result.fetch("saved")
    assert result.fetch("applied")
  end

  def test_malformed_description_stays_visible_and_can_be_disabled_without_exposing_configuration
    path = write_plugin("raise 'must not run'")
    File.write(path.sub(/\.rb\z/, ".json"), "not json")
    entry = path_entry(path).merge("configuration" => { "unknown_secret" => "synthetic saved secret" })
    seed(ID => entry)
    daemon = boot
    row = plugin_row(daemon)

    assert row.fetch("enabled")
    refute row.fetch("configurable")
    refute row.fetch("active")
    refute_empty row.fetch("readiness").fetch("issues")
    refute_includes JSON.generate(row), "synthetic saved secret"
    result = Rho::Core.new(home: daemon.home).disable_extension(ID)
    assert result.fetch("saved")
    assert result.fetch("applied")
    refute plugin_row(daemon).fetch("enabled")
    assert_equal entry.fetch("configuration"), Rho::Config.read(daemon.home.settings_path).dig("plugins", ID, "configuration")
    assert_equal "200", request(daemon, :get, "/settings", token: bearer(daemon)).code
  end

  def test_a_running_extensions_browser_module_is_served_and_named_on_its_row
    seed(ID => path_entry(write_module_plugin))
    daemon = boot
    entry = plugin_row(daemon).fetch("capabilities").fetch("webui")
    response = get(daemon, entry)

    assert_match %r{\A/modules/test\.inventory_probe/\h{12}/index\.js\z}, entry
    assert_equal "200", response.code
    assert_equal "export function register(ui) {}\n", response.body
    assert_includes response["content-type"], "text/javascript"
    assert_nil plugin_row(daemon, "rho.webui").fetch("capabilities").fetch("webui")
  end

  def test_enabling_and_disabling_the_extension_mounts_and_unmounts_its_module
    seed(ID => path_entry(write_module_plugin).merge("enabled" => false))
    daemon = boot
    assert_nil plugin_row(daemon).fetch("capabilities").fetch("webui")

    response = request(daemon, :post, "/extensions/#{ID}/enable", token: bearer(daemon), body: {})
    assert_equal "200", response.code, response.body
    entry = JSON.parse(response.body).dig("plugin", "capabilities", "webui")
    assert_equal entry, plugin_row(daemon).fetch("capabilities").fetch("webui")
    assert_equal "200", get(daemon, entry).code

    response = request(daemon, :post, "/extensions/#{ID}/disable", token: bearer(daemon), body: {})
    assert_equal "200", response.code, response.body
    assert_nil JSON.parse(response.body).dig("plugin", "capabilities", "webui")
    assert_equal "404", get(daemon, entry).code
  end

  # THE KEY SEGMENT'S REASON TO EXIST: an open page caches ES modules by URL,
  # so another installed version must be another URL, and the old one must
  # stop answering.
  def test_activating_another_installed_version_moves_the_module_to_a_new_url
    daemon = boot
    core = Rho::Core.new(home: daemon.home)
    source = module_package("first")
    first = core.manage_package(action: "install", path: source).fetch("version")
    core.manage_package(action: "activate", name: "module_probe", version: first)
    first_entry = plugin_row(daemon, "test.module_probe").fetch("capabilities").fetch("webui")
    assert_equal %(export const version = "first";\n), get(daemon, first_entry).body

    File.write(File.join(source, "webui", "index.js"), %(export const version = "second";\n))
    second = core.manage_package(action: "install", path: source).fetch("version")
    assert core.manage_package(action: "activate", name: "module_probe", version: second).fetch("applied")
    second_entry = plugin_row(daemon, "test.module_probe").fetch("capabilities").fetch("webui")

    refute_equal first_entry, second_entry
    assert_equal "404", get(daemon, first_entry).code
    response = get(daemon, second_entry)
    assert_equal "200", response.code
    assert_equal %(export const version = "second";\n), response.body
  end

  def test_api_only_serves_no_module_url
    seed(ID => path_entry(write_module_plugin))
    daemon = boot(flags: { "api_only" => true })
    entry = plugin_row(daemon).fetch("capabilities").fetch("webui")

    assert_match %r{\A/modules/test\.inventory_probe/\h{12}/index\.js\z}, entry, "the running extension still names it"
    assert_equal "404", get(daemon, entry).code
  end

  def test_terminal_is_optional_and_missing_helper_reports_actionable_guidance
    daemon = boot
    row = plugin_row(daemon, "rho.terminal")
    refute row.fetch("enabled")
    refute row.fetch("active")
    response = request(daemon, :post, "/extensions/rho.terminal/enable", token: bearer(daemon), body: {})
    assert_equal "503", response.code, response.body
    assert_includes JSON.parse(response.body).dig("error", "message"), "transport helper"
    refute plugin_row(daemon, "rho.terminal").fetch("active")
  end

  def test_configured_terminal_registers_an_operator_tool_and_redacts_turn_credentials
    daemon = boot
    core = Rho::Core.new(home: daemon.home)
    core.configure_extension("rho.terminal", operations: [
      { "op" => "set", "path" => ["executable"], "value" => Rho::Runner::OwnedProcess.group_identity_guard },
      { "op" => "set", "path" => ["ice_servers"], "value" => [
        { "urls" => ["turn:relay.example:3478"], "username" => "test", "credential" => "synthetic-turn-secret" },
      ] },
    ])
    core.enable_extension("rho.terminal")
    row = plugin_row(daemon, "rho.terminal")
    assert row.fetch("active")
    assert_includes row.dig("capabilities", "tools"), "terminal"
    refute_includes JSON.generate(core.extensions), "synthetic-turn-secret"
    tool = daemon.instance_variable_get(:@loaded).registry.announcement.find { |entry| entry.fetch("name") == "terminal" }
    refute tool.key?("description")
    assert_equal "write", tool.dig("effect_profile", "kind")
  end

  private

    def plugin_row(daemon, id = ID)
      Rho::Core.new(home: daemon.home).extensions.fetch("plugins").find { |row| row.fetch("id") == id }
    end

    def write_plugin(body)
      path = File.join(@root, "inventory_probe.rb")
      File.write(path, plugin_source(body))
      RhoTest.described_extension(path, id: ID)
      path
    end

    def plugin_source(body)
      "module InventoryProbe\n  NAME = #{ID.inspect}\n  def self.register(api)\n    #{body}\n  end\nend\n"
    end

    # The probe with a browser module in a directory beside its file.
    def write_module_plugin
      directory = File.join(@root, "inventory_probe_webui")
      FileUtils.mkdir_p(directory)
      File.write(File.join(directory, "index.js"), "export function register(ui) {}\n")
      write_plugin('api.register_webui_module(root: File.join(__dir__, "inventory_probe_webui"))')
    end

    # A managed package source whose module answers which version it is.
    def module_package(version)
      source = Dir.mktmpdir("module-package-", @root)
      FileUtils.mkdir_p(File.join(source, "webui"))
      File.write(File.join(source, "rho-extension.json"), JSON.generate(name: "module_probe", id: "test.module_probe",
        description: "Module probe", configuration_schema: { "type" => "object", "properties" => {} }))
      File.write(File.join(source, "extension.rb"), <<~RUBY)
        module ModuleProbe
          NAME = "test.module_probe"
          def self.register(api) = api.register_webui_module(root: File.join(__dir__, "webui"))
        end
      RUBY
      File.write(File.join(source, "webui", "index.js"), %(export const version = "#{version}";\n))
      source
    end

    def path_entry(path)
      { "enabled" => true, "source" => { "kind" => "path", "path" => path },
        "configuration_version" => 1, "configuration" => {} }
    end

    def seed(plugins)
      home = Rho::Home.resolve(base_url: "https://nexus.example", root: @root)
      home.prepare
      home.write_settings("settings_version" => 1, "plugins" => plugins)
    end
end
