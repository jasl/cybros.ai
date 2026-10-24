require "test_helper"

class DaemonDeploymentTest < Minitest::Test
  include RhoTest::DaemonHarness

  def test_upgrade_management_uses_the_core_authenticated_control_surface
    daemon = boot(config: application_config("extensions" => {}))
    [["GET", "/deployment"], ["POST", "/deployment/check"], ["POST", "/deployment/upgrade"],
      ["GET", "/deployment/receipt"], ["GET", "/deployment/log"]].each do |method, path|
      assert_equal "401", request(daemon, method.downcase.to_sym, path).code
    end
    response = request(daemon, :get, "/deployment", token: bearer(daemon))
    assert_equal "200", response.code
    assert_equal false, JSON.parse(response.body).fetch("supported")
    assert_equal "404", request(daemon, :post, "/deployment/resume", token: bearer(daemon)).code
  end
end
