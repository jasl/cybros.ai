require "test_helper"
require "securerandom"
require "support/actor_provisioning"
require "support/contract_fixtures"
require "support/platform_http"
require "support/secret_hygiene"

# The Human-authorized removal lane: direct Platform HTTP through the test-local JSON helper, never
# CybrosAgent — the removal endpoint is deliberately outside the gem. A Human owner API Session
# bearer from POST /api/v1/session drives POST /api/v1/admin/users/{user_id}/removal: live Workspace
# ownership refuses removal with the transfer-first guard, explicit transfer unblocks it, and
# delete-first removal of the recipient succeeds.
class WorkspaceRemovalTest < Minitest::Test
  def setup
    @base_url = E2E.base_url
    @admin_pack = E2E::ContractFixtures.admin_users
    @sessions_pack = E2E::ContractFixtures.sessions
    @world = E2E::ActorProvisioning.world(@base_url)
    @http = E2E::PlatformHttp.new(@base_url)
  end

  def test_transfer_first_then_delete_first_removal_through_the_platform_api
    # This lane ends with both Humans removed, so the pair is its own: no
    # other lane holds their credentials, and nothing else has left a live
    # Workspace under them for the transfer-first guard to refuse over.
    source, recipient = @world.removal_pair
    source_client = CybrosAgent::Client.new(base_url: @base_url, credential: source.member_token)
    recipient_client = CybrosAgent::Client.new(base_url: @base_url, credential: recipient.member_token)
    bearer = obtain_owner_session_bearer

    # A fresh active Workspace used only by this guard scenario.
    guard = source_client.workspaces.create(
      name: "Removal guard #{SecureRandom.hex(4)}", idempotency_key: SecureRandom.uuid
    ).workspace
    assert_equal source.public_id, guard.owner.public_id

    # Live ownership blocks removal with the transfer-first conflict.
    refused = @http.post(removal_path(source.public_id), bearer: bearer)
    assert_equal 409, refused.status
    refusal_code = refused.body.dig("error", "code")
    assert_equal "workspace_ownership_transfer_required", refusal_code
    assert_includes @admin_pack.fetch("error_codes"), refusal_code,
      "observed guard code outside the contract pack's closed list"

    # The source's own member credential transfers the Workspace; the admin
    # never gains an ownership bypass.
    transferred = source_client.workspace(guard.public_id).transfer_ownership(
      target_user_public_id: recipient.public_id, lock_version: guard.lock_version
    )
    assert_equal recipient.public_id, transferred.owner.public_id

    # The retried removal now succeeds with the frozen Basic projection.
    removed = @http.post(removal_path(source.public_id), bearer: bearer)
    assert_equal 200, removed.status
    assert_equal @admin_pack.fetch("removal_envelope"), removed.body.keys
    projection = removed.body.fetch("user")
    assert_equal @admin_pack.fetch("user_projection").sort, projection.keys.sort
    assert_equal source.public_id, projection.fetch("public_id")
    expected = @admin_pack.fetch("valid_removal_fixture").fetch("user")
    %w[kind role status].each do |field|
      assert_equal expected.fetch(field), projection.fetch(field)
    end
    assert_equal source.display_name, projection.fetch("display_name")

    # Delete-first is the other exit: the recipient tombstones the received
    # Workspace with its own member credential, then removal proceeds
    # without clearing the tombstone's ownership anchor.
    current = recipient_client.workspaces.fetch(guard.public_id)
    deleted = recipient_client.workspace(guard.public_id).delete(lock_version: current.lock_version)
    assert_includes E2E::ContractFixtures.workspaces.fetch("visibility").fetch("tombstoned"), deleted.state

    recipient_removed = @http.post(removal_path(recipient.public_id), bearer: bearer)
    assert_equal 200, recipient_removed.status
    assert_equal "removed", recipient_removed.body.fetch("user").fetch("status")
    assert_equal recipient.public_id, recipient_removed.body.fetch("user").fetch("public_id")
  end

  private

  def removal_path(user_public_id)
    "/api/v1/admin/users/#{user_public_id}/removal"
  end

  # cmctl's future login path, driven directly: password authentication on
  # POST /api/v1/session reveals the API Session bearer exactly once.
  def obtain_owner_session_bearer
    response = @http.post(
      "/api/v1/session",
      body: { email: @world.owner_email, password: @world.owner_password }
    )
    assert_equal 201, response.status
    assert_equal @sessions_pack.dig("valid_create_fixture", "token_type"),
      response.body.fetch("token_type")
    token = response.body.fetch("token")
    assert token.start_with?("sk-cybros-session-v1-"), "the session bearer family is frozen"
    E2E::SecretHygiene.register(token)
  end
end
