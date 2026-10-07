require "test_helper"

class PackageInventoryFailureTest < Minitest::Test
  include RhoTest::DaemonHarness

  ID = "test.package_failure".freeze
  MISSING_GEM = "rho-missing-inventory-test-dependency".freeze

  def test_a_selected_package_with_a_missing_dependency_has_a_readable_schema_and_a_reason
    home, entry, marker = installed(dependencies: { MISSING_GEM => ">= 1" })
    home.write_settings("settings_version" => 1, "plugins" => { ID => entry })
    daemon = boot
    core = Rho::Core.new(home: home)
    row = plugin(core)

    assert row.fetch("enabled")
    refute row.fetch("active")
    assert row.fetch("configurable")
    assert_includes row.dig("readiness", "issues").join, MISSING_GEM
    assert_equal 1, row.dig("configuration", "value", "count")
    refute_path_exists marker
    assert_equal "chosen", core.update_settings("default_model" => "chosen").dig("settings", "default_model")
    core.disable_extension(ID)
    refute plugin(core).fetch("enabled")
    assert_equal entry.merge("enabled" => false), Rho::Config.read(home.settings_path).dig("plugins", ID)
    assert_equal "200", request(daemon, :get, "/settings", token: bearer(daemon)).code
  end

  def test_disabled_schema_discovery_does_not_activate_dependencies_or_evaluate_package_code
    home, entry, marker = installed(dependencies: { MISSING_GEM => ">= 1" })
    home.write_settings("settings_version" => 1, "plugins" => { ID => entry.merge("enabled" => false) })
    daemon = boot
    core = Rho::Core.new(home: home)

    2.times do
      row = plugin(core)
      assert row.fetch("configurable")
      assert_equal 1, row.dig("configuration", "value", "count")
      refute row.fetch("enabled")
      refute row.fetch("active")
    end
    refute_path_exists marker
    refute Gem.loaded_specs.key?(MISSING_GEM)
    assert_equal "200", request(daemon, :get, "/settings", token: bearer(daemon)).code
  end

  def test_a_malformed_saved_package_source_preserves_core_saves_and_can_be_disabled
    home, entry, = installed
    entry = entry.merge("source" => entry.fetch("source").merge("version" => "unavailable"))
    home.write_settings("settings_version" => 1, "plugins" => { ID => entry })
    daemon = boot
    core = Rho::Core.new(home: home)
    row = plugin(core)

    assert row.fetch("enabled")
    refute row.fetch("active")
    refute_empty row.dig("readiness", "issues")
    assert_equal "chosen", core.update_settings("default_model" => "chosen").dig("settings", "default_model")
    core.disable_extension(ID)
    refute plugin(core).fetch("enabled")
    assert_equal entry.merge("enabled" => false), Rho::Config.read(home.settings_path).dig("plugins", ID)
    assert_equal "200", request(daemon, :get, "/settings", token: bearer(daemon)).code
  end

  def test_a_factory_failure_remains_visible_and_does_not_block_unrelated_core_saves
    recovered = File.join(@root, "factory-recovered")
    home, entry, marker = installed(body: "raise 'synthetic factory secret' unless File.file?(#{recovered.inspect})")
    home.write_settings("settings_version" => 1, "plugins" => { ID => entry })
    daemon = boot
    core = Rho::Core.new(home: home)

    assert File.file?(marker)
    row = plugin(core)
    assert row.fetch("enabled")
    refute row.fetch("active")
    assert_includes row.dig("readiness", "issues"), "Plugin failed to load or start (RuntimeError)."
    refute_includes JSON.generate(row), "synthetic factory secret"
    assert_equal "chosen", core.update_settings("default_model" => "chosen").dig("settings", "default_model")
    assert_equal 1, File.readlines(marker).length, "an unrelated setting must not retry the failed factory"
    assert_includes plugin(core).dig("readiness", "issues"), "Plugin failed to load or start (RuntimeError)."
    File.write(recovered, "ready")
    result = core.enable_extension(ID)
    assert result.fetch("applied")
    assert plugin(core).fetch("active")
    assert_empty plugin(core).dig("readiness", "issues")
    assert_equal 2, File.readlines(marker).length, "explicit enable retries the recovered factory"
    core.disable_extension(ID)
    refute plugin(core).fetch("enabled")
    refute plugin(core).fetch("active")
    assert_equal "200", request(daemon, :get, "/settings", token: bearer(daemon)).code
  end

  private

    def installed(dependencies: {}, body: "nil")
      home = Rho::Home.resolve(base_url: "https://nexus.example", root: @root).prepare
      directory = Dir.mktmpdir("candidate-", @root)
      marker = File.join(@root, "evaluated")
      File.write(File.join(directory, "rho-extension.json"), JSON.generate(
        name: "failure", id: ID, dependencies: dependencies,
        configuration_schema: { type: "object", properties: { count: { type: "integer", default: 1 } } }))
      File.write(File.join(directory, "extension.rb"), <<~RUBY)
        File.open(#{marker.inspect}, "a") { |file| file.puts("evaluated") }
        module FailureProbe
          NAME = #{ID.inspect}
          def self.register(api)
            #{body}
          end
        end
      RUBY
      package = Rho::Packages.new(home: home).install(path: directory)
      entry = { "source" => { "kind" => "package", "name" => "failure", "version" => package.fetch(:version) },
        "enabled" => true, "configuration_version" => 1, "configuration" => { "count" => 1 }, "state_schema" => "none" }
      [home, entry, marker]
    end

    def plugin(core) = core.extensions.fetch("plugins").find { |row| row.fetch("id") == ID }
end
