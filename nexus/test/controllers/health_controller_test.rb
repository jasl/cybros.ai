require "test_helper"
require "minitest/mock"

class HealthControllerTest < ActionDispatch::IntegrationTest
  test "readiness passes while the catalog runtime is healthy" do
    get rails_health_check_url
    assert_response :ok
  end

  test "readiness fails while the catalog is unavailable" do
    ModelCatalog.stub(:ready?, false) do
      get rails_health_check_url
      assert_response :service_unavailable
    end
  end
end
