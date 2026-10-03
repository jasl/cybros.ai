require "test_helper"

# The narrow platform removal route: every credential family, role transition, self-target, owner
# target, the Workspace guard, and the scoped-target miss.
class API::V1::AdminUserRemovalsTest < ActionDispatch::IntegrationTest
  include AgentMembershipTestHelper

  test "an owner Session bearer removes an ordinary member" do
    post removal_path(users(:member)), headers: bearer(owner_session_secret), as: :json

    assert_response :success
    body = response.parsed_body["user"]
    assert_equal users(:member).public_id, body["public_id"]
    assert_equal %w[display_name kind public_id role status], body.keys.sort
    assert_equal "removed", body["status"]
    assert users(:member).reload.removed?
  end

  test "a live owner platform-plane token authorizes a removal" do
    platform = create_access_token_fixture(user: users(:owner), name: "Ops", plane: :platform)

    post removal_path(users(:member)), headers: bearer(platform.secret), as: :json

    assert_response :success
    assert_equal "removed", response.parsed_body.dig("user", "status")
    assert users(:member).reload.removed?
  end

  test "an agent member target is removable and the system user is unreachable" do
    post removal_path(users(:agent)), headers: bearer(owner_session_secret), as: :json
    assert_response :success
    assert users(:agent).reload.removed?

    post "/api/v1/admin/users/#{users(:system).public_id}/removal",
      headers: bearer(owner_session_secret), as: :json
    assert_response :not_found
  end

  test "the workspace ownership guard maps its own conflict" do
    post removal_path(users(:curator)), headers: bearer(owner_session_secret), as: :json

    assert_response :conflict
    assert_equal "workspace_ownership_transfer_required", response.parsed_body.dig("error", "code")
    assert users(:curator).reload.active?
  end

  # Suspension never consults ownership, so a suspended owner still answers with the transfer-first
  # guard, not a liveness conflict.
  test "a suspended owner's removal still answers the workspace ownership guard" do
    assert_equal :suspended, users(:curator).suspend

    post removal_path(users(:curator)), headers: bearer(owner_session_secret), as: :json

    assert_response :conflict
    assert_equal "workspace_ownership_transfer_required", response.parsed_body.dig("error", "code")
    assert users(:curator).reload.suspended?
  end

  test "an already-removed target conflicts as user_not_active" do
    assert_equal :removed, users(:member).remove

    post removal_path(users(:member)), headers: bearer(owner_session_secret), as: :json

    assert_response :conflict
    assert_equal "user_not_active", response.parsed_body.dig("error", "code")
  end

  test "self-targets split by role and the owner is protected from admins" do
    users(:member).change_role(to: :admin)
    admin_secret = api_session_secret(identities(:member))

    post removal_path(users(:member)), headers: bearer(admin_secret), as: :json
    assert_response :forbidden
    assert_equal "user_not_administrable", response.parsed_body.dig("error", "code")

    post removal_path(users(:owner)), headers: bearer(admin_secret), as: :json
    assert_response :forbidden
    assert_equal "installation_owner_protected", response.parsed_body.dig("error", "code")

    post removal_path(users(:owner)), headers: bearer(owner_session_secret), as: :json
    assert_response :conflict
    assert_equal "installation_owner", response.parsed_body.dig("error", "code")
  end

  test "a non-admin Human session is an honest administrator_required" do
    post removal_path(users(:agent)), headers: bearer(api_session_secret(identities(:member))), as: :json

    assert_response :forbidden
    assert_equal "administrator_required", response.parsed_body.dig("error", "code")
  end

  test "member-plane, executor, demoted, and absent credentials are 401" do
    post removal_path(users(:member)), as: :json
    assert_response :unauthorized

    member_token = create_access_token_fixture(user: users(:member), name: "M")
    post removal_path(users(:agent)), headers: bearer(member_token.secret), as: :json
    assert_response :unauthorized

    executor = task_executors(:address)
    transport = create_bound_credential(executor: executor, name: "T")
    post removal_path(users(:agent)), headers: bearer(transport.secret), as: :json
    assert_response :unauthorized

    users(:member).change_role(to: :admin)
    platform = create_access_token_fixture(user: users(:member), name: "P", plane: :platform)
    users(:member).reload.change_role(to: :member)
    post removal_path(users(:agent)), headers: bearer(platform.secret), as: :json
    assert_response :unauthorized
  end

  test "an unknown target public id is a scoped 404" do
    post "/api/v1/admin/users/#{SecureRandom.uuid_v7}/removal",
      headers: bearer(owner_session_secret), as: :json

    assert_response :not_found
  end

  private

    def removal_path(user)
      "/api/v1/admin/users/#{user.public_id}/removal"
    end

    def bearer(secret)
      { "Authorization" => "Bearer #{secret}" }
    end

    def owner_session_secret
      @owner_session_secret ||= api_session_secret(identities(:owner))
    end

    def api_session_secret(identity)
      result = Sessions::Start.call(
        source: Sessions::Start::Credentials.new(email: identity.email, password: "password"),
        kind: :api
      )
      raise "api session not authenticated: #{result.outcome}" unless result.outcome == :authenticated

      result.secret
    end
end
