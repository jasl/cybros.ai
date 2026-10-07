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
end
