require "test_helper"

class EnvironmentBindTest < Minitest::Test
  def test_environment_extension_announces_no_binding_delivery_tool
    loaded = Rho::Extensions.load(host: RhoTest.host, extensions: [Rho::Extensions::Environment])
    assert_predicate loaded, :ok?, loaded.failures.inspect
    refute_includes loaded.registry.names, "environment_bind"
    refute_includes Rho::Env::Extensions::Checkpoints::EXEMPT, "environment_bind"
  end
end
