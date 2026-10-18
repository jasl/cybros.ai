require "test_helper"

class PackageActivationTest < Minitest::Test
  include RhoTest::DaemonHarness

  def test_local_package_install_check_activate_replace_rollback_disable_and_restart
    daemon = boot(flags: { "api_only" => true })
    core = Rho::Core.new(home: daemon.home)
    first = core.manage_package(action: "install", path: source("first"))
    assert core.manage_package(action: "check", name: "personal", version: first.fetch("version")).fetch("passed")
    assert_equal "404", request(daemon, :get, "/personal", token: bearer(daemon)).code

    core.manage_package(action: "activate", name: "personal", version: first.fetch("version"), configuration: { "label" => "home" })
    assert_equal "first:home", value(daemon)
    first_name = "personal_read_#{first.fetch("version")[0, 12]}"
    assert_includes tools(daemon), first_name

    second = core.manage_package(action: "install", path: source("second"))
    core.manage_package(action: "activate", name: "personal", version: second.fetch("version"))
    assert_equal "second:home", value(daemon)
    refute_includes tools(daemon), first_name

    daemon.stop
    daemon = boot(flags: { "api_only" => true })
    core = Rho::Core.new(home: daemon.home)
    assert_equal "second:home", value(daemon)
    core.manage_package(action: "rollback", name: "personal")
    assert_equal "first:home", value(daemon)
    assert_includes tools(daemon), first_name
    core.manage_package(action: "disable", name: "personal")
    assert_equal "404", request(daemon, :get, "/personal", token: bearer(daemon)).code
    assert_empty core.packages.fetch("packages").select { |row| row.fetch("active") }
  end

  def test_candidate_startup_failure_retains_published_selection_and_running_instance
    daemon = boot(flags: { "api_only" => true })
    core = Rho::Core.new(home: daemon.home)
    first = core.manage_package(action: "install", path: source("first"))
    core.manage_package(action: "activate", name: "personal", version: first.fetch("version"))
    broken = core.manage_package(action: "install", path: source("broken", startup: 'raise "cannot start"'))

    result = core.manage_package(action: "activate", name: "personal", version: broken.fetch("version"))

    assert result.fetch("saved")
    refute result.fetch("applied")
    assert_match(/saved.*could not be applied/, result.fetch("warning"))
    assert_equal "first:", value(daemon)
    selected = core.packages.fetch("packages").find { |row| row.fetch("selected") }
    assert_equal broken.fetch("version"), selected.fetch("version")
    daemon.stop
    restarted = boot(flags: { "api_only" => true })
    assert_equal "404", request(restarted, :get, "/personal", token: bearer(restarted)).code
    assert_equal "200", request(restarted, :get, "/extensions", token: bearer(restarted)).code
  end

  def test_announcement_failure_reports_local_activation_and_keeps_it_across_restart
    daemon = boot
    core = Rho::Core.new(home: daemon.home)
    installed = core.manage_package(action: "install", path: source("local"))
    daemon.define_singleton_method(:publish_extension_announcements) do |_changes|
      raise Rho::ConfigurationError, "platform temporarily refused announcement"
    end

    result = core.manage_package(action: "activate", name: "personal", version: installed.fetch("version"))

    assert_equal installed.fetch("version"), result.fetch("active")
    assert_match(/Applied locally; platform announcement failed/, result.fetch("warning"))
    assert_equal "local:", value(daemon)
    assert_equal installed.fetch("version"), core.packages.fetch("packages").find { |row| row.fetch("active") }.fetch("version")
    daemon.stop
    assert_equal "local:", value(boot)
  end

  def test_restart_only_package_saves_replacement_and_disable_while_retaining_the_running_instance
    daemon = boot(flags: { "api_only" => true })
    core = Rho::Core.new(home: daemon.home)
    first = core.manage_package(action: "install", path: source("first", restart_only: true))
    core.manage_package(action: "activate", name: "personal", version: first.fetch("version"))
    second = core.manage_package(action: "install", path: source("second", restart_only: true))

    [{ action: "activate", version: second.fetch("version") }, { action: "disable" }].each do |operation|
      result = core.manage_package(name: "personal", **operation)
      assert result.fetch("saved")
      refute result.fetch("applied")
      assert result.fetch("restart_required")
      assert_equal "first:", value(daemon)
      assert_equal second.fetch("version"), core.packages.fetch("packages").find { |row| row.fetch("selected") }.fetch("version")
    end
    daemon.stop
    restarted = boot(flags: { "api_only" => true })
    assert_equal "404", request(restarted, :get, "/personal", token: bearer(restarted)).code
    Rho::Core.new(home: restarted.home).manage_package(action: "activate", name: "personal")
    assert_equal "second:", value(restarted)
  end

  def test_the_manager_can_configure_and_enable_a_uniquely_installed_package
    daemon = boot
    core = Rho::Core.new(home: daemon.home)
    path = source("managed")
    manifest_path = File.join(path, "rho-extension.json")
    manifest = JSON.parse(File.read(manifest_path)).merge("default_enabled" => true)
    File.write(manifest_path, JSON.generate(manifest))
    installed = core.manage_package(action: "install", path: path)
    row = core.extensions.fetch("plugins").find { |plugin| plugin.fetch("id") == "personal" }
    refute row.fetch("enabled"), "installing code must not activate it"
    refute row.fetch("active")
    core.configure_extension("personal", operations: [{ "op" => "set", "path" => ["label"], "value" => "configured" }])
    entry = Rho::Config.read(daemon.home.settings_path).dig("plugins", "personal")
    assert_equal({ "kind" => "package", "name" => "personal", "version" => installed.fetch("version") }, entry.fetch("source"))
    assert_equal "v1", entry.fetch("state_schema")
    refute entry.fetch("enabled")
    result = core.enable_extension("personal")
    assert result.fetch("applied")
    assert result.fetch("plugin").fetch("active")
    assert_equal "managed:configured", value(daemon)
    core.manage_package(action: "activate", name: "personal", version: installed.fetch("version"))
    assert_equal "managed:configured", value(daemon)
  end

  private

    def source(version, startup: "nil", restart_only: false)
      path = Dir.mktmpdir("candidate-", @root)
      File.write(File.join(path, "rho-extension.json"), JSON.generate(name: "personal", id: "personal", description: "Personal fixture", state_schema: "v1",
        restart_only: restart_only, configuration_schema: { "type" => "object", "properties" => { "label" => { "type" => "string" } } }))
      File.write(File.join(path, "extension.rb"), <<~RUBY)
        module Personal
          NAME = "personal"
          class Read
            NAME = "personal_read"
            DESCRIPTION = "Read personal data"
            SCHEMA = { "type" => "object", "properties" => {} }
            EFFECT_PROFILE = { "kind" => "read_only", "destructive" => false, "effect_scope" => "closed", "idempotency" => "intrinsic", "reconciliation" => "none" }
            def initialize(env:); end
            def call(args) = Rho::Runner::Result.ok("#{version}")
          end
          def self.register(api)
            api.restart_only if #{restart_only}
            api.on(:startup) { #{startup} }
            api.register_tool(Read, serves: :agent)
            label = api.configuration["label"].to_s
            api.register_route("GET", "/personal") { |_request, _ctx| [200, { "value" => "#{version}:" + label }] }
          end
        end
      RUBY
      path
    end

    def value(daemon)
      response = request(daemon, :get, "/personal", token: bearer(daemon))
      assert_equal "200", response.code, response.body
      JSON.parse(response.body).fetch("value")
    end

    def tools(daemon)
      daemon.context.inventory.flat_map { |extension| extension.fetch("tools").map { |tool| tool.fetch("name") } }
    end
end
