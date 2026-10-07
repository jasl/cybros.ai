require "test_helper"

class SettingsApplicationTest < Minitest::Test
  include RhoTest::DaemonHarness

  def test_refused_declaration_starts_new_extensions_and_an_explicit_retry_reuses_them
    assert_extension_survives_failed_apply do
      CybrosAgent::Response.new(status: 422, headers: {},
        body: { "error" => { "code" => "validation_failed", "message" => "Synthetic refusal" } })
    end
  end

  def test_raised_declaration_error_starts_new_extensions_and_an_explicit_retry_reuses_them
    assert_extension_survives_failed_apply { raise IOError, "Synthetic transport failure" }
  end

  def test_changing_the_coding_agent_preference_replaces_its_extension_without_changing_rhos_model
    descriptor = JSON.parse(File.read(File.expand_path("../../rho-t3/rho-extension.json", __dir__)))
    extension = write_extension("coding_preference", descriptor: descriptor, body: <<~RUBY)
      module CodingPreference
        NAME = "rho.t3"
        def self.register(api)
          preference = api.configuration["default_agent"]
          api.register_route("GET", "/coding-preference") { |_request, _ctx| [200, { default_agent: preference }] }
        end
      end
    RUBY
    initial = { "url" => "http://localhost:3773", "project_id" => "project", "default_agent" => "Codex" }
    seed("default_model" => "fixture/main", "fallback_model" => "fixture/fallback", "plugins" => {
      "rho.t3" => path_entry(extension, enabled: true, configuration: initial),
    })
    daemon = boot
    token = bearer(daemon)
    assert_equal "Codex", JSON.parse(request(daemon, :get, "/coding-preference", token: token).body).fetch("default_agent")

    response = request(daemon, :patch, "/extensions/rho.t3/configuration", token: token,
      body: { operations: [{ op: "set", path: ["default_agent"], value: "Claude Code" }] })

    assert_equal "200", response.code, response.body
    assert_equal "Claude Code", JSON.parse(request(daemon, :get, "/coding-preference", token: token).body).fetch("default_agent")
    assert_equal initial.merge("default_agent" => "Claude Code"), Rho::Config.read(daemon.home.settings_path).dig("plugins", "rho.t3", "configuration")
    assert_equal "fixture/main", daemon.context.config.default_model
    assert_equal "fixture/fallback", daemon.context.config.fallback_model
  end

  def test_restart_only_removal_reports_saved_settings_and_preserves_the_instance_until_restart
    id = "test.exclusive_settings_probe"
    extension = write_extension("exclusive_settings_probe", descriptor: descriptor(id).merge("restart_only" => true), body: <<~RUBY)
      module ExclusiveSettingsProbe
        NAME = "test.exclusive_settings_probe"
        def self.register(api)
          api.restart_only
          api.register_route("GET", "/exclusive-settings-probe") { |_request, _ctx| [200, { running: true }] }
        end
      end
    RUBY
    seed("api_only" => true, "plugins" => { id => path_entry(extension, enabled: true) })
    daemon = boot

    response = request(daemon, :post, "/extensions/#{id}/disable", token: bearer(daemon), body: {})

    assert_equal "200", response.code, response.body
    result = JSON.parse(response.body)
    assert_equal true, result.fetch("saved")
    refute result.fetch("applied")
    refute result.fetch("published")
    assert result.fetch("restart_required")
    assert_includes result.fetch("message"), "Settings were saved"
    assert_match(/restart/i, result.fetch("message"))
    refute_includes result.fetch("message"), "try saving again"
    refute Rho::Config.read(daemon.home.settings_path).dig("plugins", id, "enabled")
    row = Rho::Core.new(home: daemon.home).extensions.fetch("plugins").find { |plugin| plugin.fetch("id") == id }
    refute row.fetch("enabled")
    assert row.fetch("active")
    assert row.fetch("restart_required")
    assert_equal "200", request(daemon, :get, "/exclusive-settings-probe", token: bearer(daemon)).code

    daemon.stop
    restarted = boot
    assert_equal "404", request(restarted, :get, "/exclusive-settings-probe", token: bearer(restarted)).code
  end

  private

    def assert_extension_survives_failed_apply
      id = "test.settings_probe"
      extension = write_extension("settings_probe", descriptor: descriptor(id), body: <<~RUBY)
        module SettingsProbe
          NAME = "test.settings_probe"
          def self.register(api)
            events = []
            api.on(:startup) { events << "started" }
            api.on(:configuration_change) { |config| events << config.default_model }
            api.register_route("GET", "/settings-probe") { |_request, _ctx| [200, { events: events }] }
          end
        end
      RUBY
      seed("kernel_tools" => [], "adaptations" => "off", "default_model" => "dev/changed",
        "plugins" => { id => path_entry(extension, enabled: false) })
      first_attempt = true
      api = NexusDoubles::FakeAgentApi.new(configuration: ->(_body) {
        if first_attempt
          first_attempt = false
          yield
        else
          :accept
        end
      })
      daemon = boot(api_transport: api)
      member_ready(daemon, api)
      patch = { operations: [], enabled: true }

      response = request(daemon, :patch, "/extensions/#{id}/configuration", token: bearer(daemon), body: patch)

      assert_equal "503", response.code, response.body
      assert_equal true, JSON.parse(response.body).dig("error", "saved")
      assert Rho::Config.read(daemon.home.settings_path).dig("plugins", id, "enabled")
      assert_equal "dev/changed", Rho::Config.read(daemon.home.settings_path).fetch("default_model")
      assert_equal ["started", "dev/changed"], extension_events(daemon)

      retry_response = request(daemon, :patch, "/extensions/#{id}/configuration", token: bearer(daemon), body: patch)

      assert_equal "200", retry_response.code, retry_response.body
      assert_equal ["started", "dev/changed", "dev/changed"], extension_events(daemon)
      assert_equal "dev/changed", api.configuration_declarations.last.dig("configuration", "default_model")
    end

    def descriptor(id)
      { "id" => id, "default_enabled" => false, "configuration_version" => 1,
        "configuration_schema" => { "type" => "object", "properties" => {} } }
    end

    def write_extension(name, descriptor:, body:)
      path = File.join(@root, "#{name}.rb")
      File.write(path, body)
      File.write(path.sub(/\.rb\z/, ".json"), JSON.generate(descriptor))
      path
    end

    def path_entry(path, enabled:, configuration: {})
      { "source" => { "kind" => "path", "path" => path }, "enabled" => enabled,
        "configuration_version" => 1, "configuration" => configuration }
    end

    def seed(document)
      home = Rho::Home.resolve(base_url: "https://nexus.example", root: @root).prepare
      home.write_settings({ "settings_version" => 1, "plugins" => {} }.merge(document))
    end

    def extension_events(daemon)
      JSON.parse(request(daemon, :get, "/settings-probe", token: bearer(daemon)).body).fetch("events")
    end
end
