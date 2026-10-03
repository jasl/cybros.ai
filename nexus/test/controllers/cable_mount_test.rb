require "test_helper"

# THE CABLE'S ADDRESS IS PART OF THE AGENT API, not an incidental default.
#
# The advertised versioned Cable path must be the mounted Rack endpoint. A mount-path change
# otherwise looks like an ordinary connection failure to clients and can leave HTTP API tests green.
class CableMountTest < ActionDispatch::IntegrationTest
  test "the cable answers inside the versioned agent API" do
    assert_equal "/agent_api/v1/cable", Rails.application.config.action_cable.mount_path

    # Mounted, and mounted as a Rack app rather than a controller — which is
    # what makes the assertion above about the real route and not about a
    # config value nothing reads.
    route = Rails.application.routes.routes.find { |r| r.path.spec.to_s.start_with?("/agent_api/v1/cable") }
    refute_nil route, "no route serves the cable's configured mount path"
    assert_kind_of ActionCable::Server::Base, route.app.app
  end

  # Member and executor credentials share the versioned Cable mount. The Rails default path
  # must not silently expose a second endpoint alongside it.
  test "the default mount is gone, so there is exactly one cable" do
    assert_nil Rails.application.routes.routes.find { |r| r.path.spec.to_s.start_with?("/cable") },
      "Rails' single-app default must not survive beside the namespaced mount"
  end
end
