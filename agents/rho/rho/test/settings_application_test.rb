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

  private

    def assert_extension_survives_failed_apply
      extension = File.join(@root, "settings_probe.rb")
      File.write(extension, <<~RUBY)
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
      first_attempt = true
      api = NexusDoubles::FakeAgentApi.new(configuration: ->(_body) {
        if first_attempt
          first_attempt = false
          yield
        else
          :accept
        end
      })
      daemon = boot(config: Rho::Config.from_hash("kernel_tools" => [], "adaptations" => "off"),
        api_transport: api)
      member_ready(daemon, api)
      patch = { default_model: "dev/changed", extension_paths: [extension] }

      response = request(daemon, :patch, "/settings", token: bearer(daemon), body: patch)

      assert_equal "503", response.code, response.body
      assert_equal true, JSON.parse(response.body).dig("error", "saved")
      assert_equal "dev/changed", Rho::Config.read(daemon.home.settings_path).fetch("default_model")
      assert_equal ["started", "dev/changed"], extension_events(daemon)

      retry_response = request(daemon, :patch, "/settings", token: bearer(daemon), body: patch)

      assert_equal "200", retry_response.code, retry_response.body
      assert_equal ["started", "dev/changed", "dev/changed"], extension_events(daemon)
      assert_equal "dev/changed", api.configuration_declarations.last.dig("configuration", "default_model")
    end

    def extension_events(daemon)
      JSON.parse(request(daemon, :get, "/settings-probe", token: bearer(daemon)).body).fetch("events")
    end
end
