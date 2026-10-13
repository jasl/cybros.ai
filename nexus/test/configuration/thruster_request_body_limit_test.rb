require "test_helper"

class ThrusterRequestBodyLimitTest < ActiveSupport::TestCase
  test "the shipped proxy caps requests just above the application upload bound" do
    dockerfile = Rails.root.join("Dockerfile").read
    configured = dockerfile.match(/MAX_REQUEST_BODY="(?<bytes>\d+)"/)

    assert configured, "the shipped Thruster path must reject oversized bodies before Rack"
    limit = configured[:bytes].to_i
    upload_bound = Nexus::SizeBounds.fetch(:upload_bound)
    assert_operator limit, :>, upload_bound
    assert_operator limit - upload_bound, :>=, 8.megabytes
    assert_operator limit - upload_bound, :<=, 16.megabytes
  end
end
