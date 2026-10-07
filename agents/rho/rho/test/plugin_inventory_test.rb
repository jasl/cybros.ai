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
