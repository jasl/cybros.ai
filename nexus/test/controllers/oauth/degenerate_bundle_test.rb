require "test_helper"

# An agent connection can lose its member authority between connecting and rotating (its steward is
# suspended). The lineage still rotates its transport half — that independence is the point of the
# plane split — so the bundle degenerates to one credential of the *other* plane than the one it
# started with. The response has to say so: a client that inferred the plane from the request it
# made would route a transport secret to the member plane and 401 on every call.
class OAuth::DegenerateBundleTest < ActionDispatch::IntegrationTest
  setup do
    @owner = users(:member)
  end

  def connect_agent_bundle
    post oauth_device_authorization_path, params: {
      client_id: OAuth::DEVICE_CLIENT_ID,
      agent_identifier: "degenerating", agent_display_name: "Degenerating",
      executor_display_name: "Client",
    }
    device_code = response.parsed_body.fetch("device_code")
    grant = DeviceAuthorization.find_by_device_code(device_code)
    DeviceAuthorizations::Connect.call(authorization: grant, connector: @owner)
    post oauth_token_path, params: {
      client_id: OAuth::DEVICE_CLIENT_ID,
      grant_type: OAuth::DEVICE_GRANT_TYPE, device_code: device_code,
    }
    response.parsed_body
  end

  test "an agent bundle that loses member authority rotates into a labeled transport credential" do
    bundle = connect_agent_bundle
    assert_equal "member", bundle["plane"]
    assert_equal :suspended, @owner.suspend

    post oauth_token_path, params: {
      client_id: OAuth::DEVICE_CLIENT_ID,
      grant_type: OAuth::REFRESH_GRANT_TYPE, refresh_token: bundle.fetch("refresh_token"),
    }

    assert_response :success
    rotated = response.parsed_body
    # The bundle degenerated, and the wire says which plane survived.
    assert_equal "executor_transport", rotated["plane"]
    assert_not rotated.key?("executor_access_token"),
      "a transport-led bundle has no second transport credential to accompany it"
    assert_nil AccessToken.authenticate_token(rotated.fetch("access_token")),
      "the surviving credential is not a member credential"
    assert AccessToken.authenticate_executor_token(rotated.fetch("access_token"))
  end

  test "the SDK labels the degenerate bundle from the wire rather than from its own request" do
    bundle = connect_agent_bundle
    @owner.suspend

    post oauth_token_path, params: {
      client_id: OAuth::DEVICE_CLIENT_ID,
      grant_type: OAuth::REFRESH_GRANT_TYPE, refresh_token: bundle.fetch("refresh_token"),
    }
    rotated = response.parsed_body

    # The shape the SDK parses: plane names the leading credential, so an
    # agent-branch host cannot mistake this for a member credential.
    assert_equal %w[access_token expires_in plane refresh_token token_type].sort,
      rotated.keys.sort
    assert_equal "executor_transport", rotated["plane"]
  end
end
