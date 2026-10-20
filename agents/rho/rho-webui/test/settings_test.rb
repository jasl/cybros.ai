require "test_helper"
require "rho"
require "net/http"

class SettingsTest < Minitest::Test
  def test_the_bare_webui_installation_reports_its_absent_optional_channel_in_both_modes
    Dir.mktmpdir("rho-webui-settings") do |root|
      %w[full agent].each do |mode|
        daemon = Rho::Daemon.boot(
          home: Rho::Home.resolve(base_url: "https://nexus.example", root: File.join(root, mode)),
          config: Rho::Config.from_hash({ "mode" => mode })
        )
        begin
          token = Rho::StateFile.new(daemon.home.announcement_path).read.fetch("bearer")
          uri = URI.join(daemon.endpoint, "/settings")
          message = Net::HTTP::Get.new(uri)
          message["Authorization"] = "Bearer #{token}"
          response = Net::HTTP.start(uri.host, uri.port) { |http| http.request(message) }
          assert_equal "200", response.code, response.body
          settings = JSON.parse(response.body)
          names = settings.fetch("extensions").map { |entry| entry.fetch("name") }
          assert_includes names, "rho.webui"
          refute_includes names, "rho.ingress_telegram"
          assert settings.fetch("settings").key?("default_model")
        ensure
          daemon.stop
        end
      end
    end
  end

  def test_browser_ice_configuration_is_authenticated_uncached_and_redacted_from_settings
    Dir.mktmpdir("rho-webui-ice") do |root|
      servers = [{ "urls" => ["turn:relay.example:3478?transport=tcp"], "username" => "viewer", "credential" => "synthetic-browser-secret" }]
      daemon = Rho::Daemon.boot(
        home: Rho::Home.resolve(base_url: "https://nexus.example", root: root),
        config: Rho::Config.from_hash({ "mode" => "agent", "plugins" => {
          "rho.webui" => { "configuration" => { "ice_servers" => servers } },
        } })
      )
      begin
        token = Rho::StateFile.new(daemon.home.announcement_path).read.fetch("bearer")
        uri = URI.join(daemon.endpoint, "/realtime/ice_servers")
        Net::HTTP.start(uri.host, uri.port) do |http|
          assert_equal "401", http.request(Net::HTTP::Get.new(uri)).code
          request = Net::HTTP::Get.new(uri)
          request["Authorization"] = "Bearer #{token}"
          response = http.request(request)
          assert_equal "200", response.code, response.body
          assert_equal "no-store", response["cache-control"]
          assert_equal servers, JSON.parse(response.body).fetch("ice_servers")
          updated = [{ "urls" => ["turn:replacement.example:3478?transport=tcp"], "username" => "viewer", "credential" => "synthetic-rotated-secret" }]
          Rho::Core.new(home: daemon.home).configure_extension("rho.webui", operations: [
            { "op" => "set", "path" => ["ice_servers"], "value" => updated },
          ])
          response = http.request(request)
          assert_equal "200", response.code, response.body
          assert_equal updated, JSON.parse(response.body).fetch("ice_servers")
          request = Net::HTTP::Get.new(URI.join(daemon.endpoint, "/settings"))
          request["Authorization"] = "Bearer #{token}"
          response = http.request(request)
          assert_equal "200", response.code
          refute_includes response.body, "synthetic-browser-secret"
          refute_includes response.body, "synthetic-rotated-secret"
          refute_includes http.request(Net::HTTP::Get.new(URI.join(daemon.endpoint, "/"))).body, "synthetic-browser-secret"
        end
      ensure
        daemon.stop
      end
    end
  end
end
