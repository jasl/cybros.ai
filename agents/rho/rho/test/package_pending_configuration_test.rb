require "test_helper"

class PackagePendingConfigurationTest < Minitest::Test
  include RhoTest::DaemonHarness

  ID = "test.pending_package".freeze

  def test_activating_a_package_preserves_a_path_plugins_pending_restart
    path = source("pending", id: ID, restart_only: true)
    FileUtils.copy_file(File.join(path, "rho-extension.json"), File.join(path, "extension.json"))
    home = Rho::Home.resolve(base_url: "https://nexus.example", root: @root).prepare
    home.write_settings("settings_version" => 1, "plugins" => {
      ID => { "source" => { "kind" => "path", "path" => File.join(path, "extension.rb") },
        "enabled" => true, "configuration_version" => 1, "configuration" => { "count" => 1 } },
    })
    assert_pending_configuration_is_preserved(boot)
  end

  def test_activating_a_package_preserves_another_packages_pending_restart
    daemon = boot
    core = Rho::Core.new(home: daemon.home)
    package = core.manage_package(action: "install", path: source("pending", id: ID, restart_only: true))
    core.manage_package(action: "activate", name: "pending", version: package.fetch("version"))
    assert_pending_configuration_is_preserved(daemon)
  end

  def test_activating_a_package_does_not_retry_another_packages_failed_configuration
    daemon = boot
    core = Rho::Core.new(home: daemon.home)
    package = core.manage_package(action: "install", path: source("pending", id: ID, reject_count: 2))
    core.manage_package(action: "activate", name: "pending", version: package.fetch("version"))
    assert_pending_configuration_is_preserved(daemon, rejected: true)
  end

  def test_a_pending_replacement_and_disable_report_the_version_that_is_still_running
    daemon = boot
    core = Rho::Core.new(home: daemon.home)
    first = core.manage_package(action: "install", path: source("pending", id: ID, restart_only: true))
    core.manage_package(action: "activate", name: "pending", version: first.fetch("version"))
    second = core.manage_package(action: "install", path: source("pending", id: ID, restart_only: true, reject_count: 99))

    result = core.manage_package(action: "activate", name: "pending", version: second.fetch("version"))
    refute result.fetch("applied")
    assert_equal second.fetch("version"), result.fetch("selected")
    assert_equal first.fetch("version"), result.fetch("active")
    rows = core.packages.fetch("packages")
    assert rows.find { |row| row.fetch("version") == first.fetch("version") }.fetch("active")
    pending = rows.find { |row| row.fetch("version") == second.fetch("version") }
    assert pending.fetch("selected")
    assert pending.fetch("enabled")
    refute pending.fetch("active")

    disabled = core.manage_package(action: "disable", name: "pending")
    refute disabled.fetch("applied")
    refute disabled.fetch("enabled")
    assert_equal first.fetch("version"), disabled.fetch("active")
    assert core.packages.fetch("packages").find { |row| row.fetch("version") == first.fetch("version") }.fetch("active")
  end

  def test_a_failed_factory_is_selected_and_enabled_but_never_reported_as_active
    daemon = boot
    core = Rho::Core.new(home: daemon.home)
    package = core.manage_package(action: "install", path: source("pending", id: ID, reject_count: 1))
    result = core.manage_package(action: "activate", name: "pending", version: package.fetch("version"))

    assert result.fetch("saved")
    refute result.fetch("applied")
    assert result.fetch("enabled")
    assert_nil result.fetch("active")
    row = core.packages.fetch("packages").find { |item| item.fetch("id") == ID }
    assert row.fetch("selected")
    assert row.fetch("enabled")
    refute row.fetch("active")
    plugin = core.extensions.fetch("plugins").find { |item| item.fetch("id") == ID }
    assert_includes plugin.dig("readiness", "issues"), "Plugin failed to load or start (RuntimeError)."
    assert_equal "chosen", core.update_settings("default_model" => "chosen").dig("settings", "default_model")
    plugin = core.extensions.fetch("plugins").find { |item| item.fetch("id") == ID }
    assert_includes plugin.dig("readiness", "issues"), "Plugin failed to load or start (RuntimeError)."
  end

  def test_a_failed_factory_replacement_reports_saved_changes_as_unapplied
    assert_failed_replacement_is_visible(reject_count: 2)
  end

  def test_a_failed_startup_replacement_reports_saved_changes_as_unapplied
    assert_failed_replacement_is_visible(startup: 'raise "Cannot start replacement"')
  end

  private

    def assert_failed_replacement_is_visible(reject_count: nil, startup: "nil")
      daemon = boot
      core = Rho::Core.new(home: daemon.home)
      first = core.manage_package(action: "install", path: source("pending", id: ID))
      core.manage_package(action: "activate", name: "pending", version: first.fetch("version"))
      assert core.extensions.fetch("plugins").find { |item| item.fetch("id") == ID }.dig("readiness", "ready")
      marker = File.join(@root, "replacement-attempts")
      broken = core.manage_package(action: "install", path: source("pending", id: ID,
        reject_count: reject_count, startup: startup, marker: marker))

      result = core.manage_package(action: "activate", name: "pending", version: broken.fetch("version"), configuration: { "count" => 2 })

      assert result.fetch("saved")
      refute result.fetch("applied")
      assert_equal first.fetch("version"), result.fetch("active")
      plugin = core.extensions.fetch("plugins").find { |item| item.fetch("id") == ID }
      assert plugin.fetch("enabled")
      assert plugin.fetch("active")
      assert_equal broken.fetch("version"), plugin.dig("source", "version")
      assert_equal first.fetch("version"), plugin.dig("active_source", "version")
      assert_equal 2, plugin.dig("configuration", "value", "count")
      refute plugin.dig("readiness", "ready")
      assert_includes plugin.dig("readiness", "issues"), "Saved changes have not been applied; the previous plugin instance is still running."
      assert_equal 1, value(daemon, ID)
      assert_equal ["registered\n"], File.readlines(marker)

      assert_equal "chosen", core.update_settings("default_model" => "chosen").dig("settings", "default_model")
      assert_equal 1, value(daemon, ID)
      assert_equal ["registered\n"], File.readlines(marker)
      refute core.extensions.fetch("plugins").find { |item| item.fetch("id") == ID }.dig("readiness", "ready")
    end

    def assert_pending_configuration_is_preserved(daemon, rejected: false)
      core = Rho::Core.new(home: daemon.home)
      if rejected
        assert_raises(Rho::Core::Refused) { core.configure_extension(ID, operations: [count(2)]) }
      else
        result = core.configure_extension(ID, operations: [count(2)])
        refute result.fetch("applied")
        assert result.fetch("restart_required")
      end
      assert_equal 1, value(daemon, ID)
      assert_equal 2, Rho::Config.read(daemon.home.settings_path).dig("plugins", ID, "configuration", "count")

      other = core.manage_package(action: "install", path: source("other", id: "test.other"))
      result = core.manage_package(action: "activate", name: "other", version: other.fetch("version"))

      assert result.fetch("applied"), result.inspect
      assert_equal 1, value(daemon, "test.other")
      assert_equal 1, value(daemon, ID)
      if rejected
        assert_raises(Rho::Core::Refused) { core.configure_extension(ID, operations: [count(2)]) }
      else
        repeated = core.configure_extension(ID, operations: [count(2)])
        refute repeated.fetch("applied")
        assert repeated.fetch("restart_required")
      end
      assert_equal 1, value(daemon, ID)
    end

    def source(name, id:, restart_only: false, reject_count: nil, startup: "nil", marker: nil)
      directory = Dir.mktmpdir("candidate-", @root)
      File.write(File.join(directory, "rho-extension.json"), JSON.generate(
        name: name, id: id, configuration_schema: { type: "object", properties: { count: { type: "integer", default: 1 } } }))
      File.write(File.join(directory, "extension.rb"), <<~RUBY)
        module Probe
          NAME = #{id.inspect}
          def self.register(api)
            File.open(#{marker.inspect}, "a") { |file| file.puts("registered") } if #{!marker.nil?}
            api.restart_only if #{restart_only}
            count = api.configuration.fetch("count")
            raise "Cannot prepare configured count" if count == #{reject_count.inspect}
            api.on(:startup) { #{startup} }
            api.register_route("GET", #{"/package-probe/#{id}".inspect}) { |_request, _ctx| [200, { count: count }] }
          end
        end
      RUBY
      directory
    end

    def value(daemon, id)
      response = request(daemon, :get, "/package-probe/#{id}", token: bearer(daemon))
      assert_equal "200", response.code, response.body
      JSON.parse(response.body).fetch("count")
    end

    def count(value) = { "op" => "set", "path" => ["count"], "value" => value }
end
