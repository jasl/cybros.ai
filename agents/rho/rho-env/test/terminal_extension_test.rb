require "test_helper"
require "rho/env/extensions/terminal"

class TerminalExtensionTest < Minitest::Test
  def test_published_network_configuration_registers_the_terminal
    loaded = load_terminal("advertised_ip" => "192.0.2.10", "udp_port_min" => 49160, "udp_port_max" => 49200)
    assert_predicate loaded, :ok?
    assert_equal ["terminal"], loaded.registry.names
  end

  def test_invalid_published_network_configuration_reports_repair_guidance
    [
      [{ "advertised_ip" => "host.example" }, "must be an IP address"],
      [{ "advertised_ip" => "192.0.2.0/24" }, "not a subnet"],
      [{ "udp_port_min" => 49200, "udp_port_max" => 49160 }, "minimum must not exceed"],
    ].each do |configuration, message|
      loaded = load_terminal(configuration)
      refute_predicate loaded, :ok?
      assert_includes loaded.failures.first.message, message
      assert_empty loaded.registry.names
    end
  end

  private

    def load_terminal(configuration)
      Rho::Env::Extensions::Loader.call(builtin: [Rho::Env::Extensions::Terminal],
        api_options: { configuration: { "executable" => RbConfig.ruby }.merge(configuration) })
    end
end
