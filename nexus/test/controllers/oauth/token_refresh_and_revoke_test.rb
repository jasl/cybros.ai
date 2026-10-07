require "test_helper"

# The refresh_token grant on /oauth/token and RFC 7009 /oauth/revoke.
class OAuth::TokenRefreshAndRevokeTest < ActionDispatch::IntegrationTest
  setup do
    @owner = users(:owner)
    member = accounts(:cybros).users.create!(kind: :agent, role: :member, steward: @owner, display_name: "Wire agent", agent_identifier: "install-wire")
    executor = member.task_executors.create!(account: member.account, executor_kind: :agent_application, display_name: "Wire app")
    family = RefreshTokenFamily.create!(
      account: member.account,
      user: member,
      access_token_name: "Device pairing",
      task_executor: executor,
      credential_epoch: executor.credential_epoch,
      user_authority_generation: member.authority_generation,
      last_used_at: Time.current
    )
    access = member.access_tokens.create!(
      refresh_token_family: family,
      credential_plane: :executor_transport,
      name: "Device pairing", source: :oauth_device,
      lookup_id: SecureRandom.base58(24), secret_digest: "seed", expires_at: AccessToken::OAUTH_TTL.from_now,
      task_executor: executor, credential_epoch: executor.credential_epoch, user_authority_generation: member.authority_generation
    )
    @family = RefreshTokens::Issue.call(refresh_token_family: family, access_token: access)
  end

  def post_token(params)
    post oauth_token_path, params: { client_id: OAuth::DEVICE_CLIENT_ID }.merge(params)
  end

  # A Branch B connection driven the way a runner drives it — request over
  # the wire in the only shape the contract permits (no `scope`, no agent
  # fields), browser connect, poll — so the refresh below rotates exactly
  # what the wire handed the client (docs/oauth/device-flow.md, Branch B).
  def consume_runner_bundle(identifier: "install-runner")
    post oauth_device_authorization_path, params: {
      client_id: OAuth::DEVICE_CLIENT_ID,
      registration_identifier: identifier,
      runner_display_name: "Workshop laptop",
    }
    assert_response :success

    device_code = response.parsed_body.fetch("device_code")
    authorization = DeviceAuthorization.find_by_device_code(device_code)
    DeviceAuthorizations::Connect.call(
      authorization: authorization,
      connector: @owner,
      expected_live_runner:
        DeviceAuthorizations::Connect::ABSENT_LIVE_RUNNER
    )
    post_token(grant_type: OAuth::DEVICE_GRANT_TYPE, device_code: device_code)
    assert_response :success
    response.parsed_body
  end

  # The combined shape A+B driven over the wire the way rho in full mode
  # drives it: one request, both claim sets, browser connect, poll — the body
  # carries the agent bundle and the nested runner lineage.
  def consume_combined_bundle(identifier: "rho")
    member = accounts(:cybros).users.create!(
      kind: :agent, role: :member, steward: @owner, display_name: "rho", agent_identifier: identifier
    )
    post oauth_device_authorization_path, params: {
      client_id: OAuth::DEVICE_CLIENT_ID,
      agent_identifier: identifier,
      agent_display_name: "rho",
      executor_display_name: "rho on laptop",
      registration_identifier: identifier,
      runner_display_name: "rho on laptop",
    }
    assert_response :success

    device_code = response.parsed_body.fetch("device_code")
    authorization = DeviceAuthorization.find_by_device_code(device_code)
    assert_equal :connected,
      DeviceAuthorizations::Connect.call(authorization: authorization, connector: @owner).outcome
    assert_equal member, authorization.reload.user
    post_token(grant_type: OAuth::DEVICE_GRANT_TYPE, device_code: device_code)
    assert_response :success
    response.parsed_body
  end

  test "the refresh_token grant rotates and returns the whole bundle" do
    post_token(grant_type: OAuth::REFRESH_GRANT_TYPE, refresh_token: @family.secret)

    assert_response :success
    body = response.parsed_body
    assert body["access_token"].start_with?("sk-cybros-api-v1-")
    assert body["refresh_token"].start_with?("rt-cybros-api-v1-")
    assert_equal 1_209_600, body["expires_in"]
    assert_not body.key?("runner"), "a rotation is per family and never carries a runner half"

    # A lineage that issued a delivery address reissues both planes, and each secret answers only
    # its own.
    assert body["executor_access_token"].start_with?("sk-cybros-api-v1-")
    assert_not_equal body["access_token"], body["executor_access_token"]
    assert AccessToken.authenticate_token(body["access_token"])
    assert_nil AccessToken.authenticate_executor_token(body["access_token"])
    assert AccessToken.authenticate_executor_token(body["executor_access_token"])
    assert_nil AccessToken.authenticate_token(body["executor_access_token"])
  end

  # "A live runner rotates and revokes its own credential"
  # (docs/oauth/device-flow.md, Branch B). Both grants hand a runner the same
  # single-plane bundle: the transport credential leads, nothing accompanies.
  test "a runner lineage refreshes into the same wire shape its consume returned" do
    consumed = consume_runner_bundle
    runner = @owner.managed_executors.sole

    post_token(grant_type: OAuth::REFRESH_GRANT_TYPE, refresh_token: consumed["refresh_token"])

    assert_response :success
    assert_equal "no-store", response.headers["Cache-Control"]
    body = response.parsed_body
    assert body["access_token"].start_with?("sk-cybros-api-v1-")
    assert body["refresh_token"].start_with?("rt-cybros-api-v1-")
    assert_equal "Bearer", body["token_type"]
    assert_equal 1_209_600, body["expires_in"]
    # A runner is not a principal, so no member credential accompanies it.
    assert_not body.key?("executor_access_token")

    assert_not_equal consumed["access_token"], body["access_token"]
    assert_nil AccessToken.authenticate_token(body["access_token"]),
      "the reissued credential must be rejected on the member plane"
    transport = AccessToken.authenticate_executor_token(body["access_token"])
    assert_equal runner, transport.task_executor
    assert_equal runner.credential_epoch, transport.credential_epoch

    # The chain continues, and the presented token is spent.
    post_token(grant_type: OAuth::REFRESH_GRANT_TYPE, refresh_token: body["refresh_token"])
    assert_response :success
    post_token(grant_type: OAuth::REFRESH_GRANT_TYPE, refresh_token: consumed["refresh_token"])
    assert_equal "invalid_grant", response.parsed_body["error"]
  end

  # Each lineage of a combined grant rotates and dies on its own refresh
  # token: the agent's rotation never re-carries the runner half, and
  # revoking one half leaves the other live.
  test "a combined grant's agent lineage rotates without the runner half" do
    consumed = consume_combined_bundle

    post_token(grant_type: OAuth::REFRESH_GRANT_TYPE, refresh_token: consumed["refresh_token"])

    assert_response :success
    body = response.parsed_body
    assert_equal "member", body["plane"]
    assert body["executor_access_token"].start_with?("sk-cybros-api-v1-")
    assert_not body.key?("runner")
    # The runner credential the consume handed out is untouched by that rotation.
    assert AccessToken.authenticate_executor_token(consumed.dig("runner", "access_token"))
  end

  test "revoking the runner half's refresh token leaves the agent lineage live, and the reverse" do
    consumed = consume_combined_bundle

    post oauth_revoke_path,
      params: { client_id: OAuth::DEVICE_CLIENT_ID, token: consumed.dig("runner", "refresh_token") }
    assert_response :ok
    assert_nil AccessToken.authenticate_executor_token(consumed.dig("runner", "access_token")),
      "the runner family died with its refresh token"
    assert AccessToken.authenticate_token(consumed["access_token"]), "the agent lineage is live"
    post_token(grant_type: OAuth::REFRESH_GRANT_TYPE, refresh_token: consumed["refresh_token"])
    assert_response :success, "the agent lineage still rotates"
    rotated = response.parsed_body

    assert_equal "member", rotated["plane"]

    second = consume_combined_bundle(identifier: "rho-two")
    post oauth_revoke_path, params: { client_id: OAuth::DEVICE_CLIENT_ID, token: second["refresh_token"] }
    assert_response :ok
    assert_nil AccessToken.authenticate_token(second["access_token"]), "the agent family died"
    assert AccessToken.authenticate_executor_token(second.dig("runner", "access_token")),
      "the runner lineage is live"
    post_token(grant_type: OAuth::REFRESH_GRANT_TYPE, refresh_token: second.dig("runner", "refresh_token"))
    assert_response :success, "the runner lineage still rotates"
    assert_equal "executor_transport", response.parsed_body["plane"]
  end

  test "revoking a runner's access token severs its lineage but keeps the machine" do
    consumed = consume_runner_bundle
    runner = @owner.managed_executors.sole

    post oauth_revoke_path, params: { client_id: OAuth::DEVICE_CLIENT_ID, token: consumed["access_token"] }
    assert_response :ok
    assert response.body.blank?

    post_token(grant_type: OAuth::REFRESH_GRANT_TYPE, refresh_token: consumed["refresh_token"])
    assert_equal "invalid_grant", response.parsed_body["error"]
    assert_nil AccessToken.authenticate_executor_token(consumed["access_token"])
    # Revocation ends the credential lineage, not the machine: the runner
    # reconnects under the same registration_identifier.
    assert_predicate runner.reload, :active?
  end

  test "revoking a runner's refresh token severs its lineage" do
    consumed = consume_runner_bundle
    rotated = nil

    post_token(grant_type: OAuth::REFRESH_GRANT_TYPE, refresh_token: consumed["refresh_token"])
    rotated = response.parsed_body

    post oauth_revoke_path, params: { client_id: OAuth::DEVICE_CLIENT_ID, token: rotated["refresh_token"] }
    assert_response :ok

    post_token(grant_type: OAuth::REFRESH_GRANT_TYPE, refresh_token: rotated["refresh_token"])
    assert_equal "invalid_grant", response.parsed_body["error"]
    assert_nil AccessToken.authenticate_executor_token(rotated["access_token"])
    assert_predicate @owner.managed_executors.sole, :active?
  end

  test "a supplied scope is accepted and ignored: rotation never negotiates" do
    post_token(grant_type: OAuth::REFRESH_GRANT_TYPE, refresh_token: @family.secret, scope: "api")

    assert_response :success
    assert_not response.parsed_body.key?("scope")
  end

  test "reuse of a superseded token is invalid_grant and fences the family" do
    post_token(grant_type: OAuth::REFRESH_GRANT_TYPE, refresh_token: @family.secret)
    fresh_refresh = response.parsed_body["refresh_token"]

    post_token(grant_type: OAuth::REFRESH_GRANT_TYPE, refresh_token: @family.secret)
    assert_equal "invalid_grant", response.parsed_body["error"]

    # The successor is also dead now.
    post_token(grant_type: OAuth::REFRESH_GRANT_TYPE, refresh_token: fresh_refresh)
    assert_equal "invalid_grant", response.parsed_body["error"]
  end

  test "an unknown or malformed refresh token is invalid_grant" do
    post_token(grant_type: OAuth::REFRESH_GRANT_TYPE, refresh_token: "rt-cybros-api-v1-aaaaaaaaaaaaaaaaaaaaaaaa.bbbb")
    assert_equal "invalid_grant", response.parsed_body["error"]
  end

  test "revoke of a refresh token kills its family with a silent 200" do
    live = RefreshTokens::Rotate.call(presented: @family.token)

    post oauth_revoke_path, params: { client_id: OAuth::DEVICE_CLIENT_ID, token: live.refresh_secret }
    assert_response :ok
    assert response.body.blank?

    assert_nil AccessToken.authenticate_token(live.access_secret)
    post_token(grant_type: OAuth::REFRESH_GRANT_TYPE, refresh_token: live.refresh_secret)
    assert_equal "invalid_grant", response.parsed_body["error"]
  end

  test "revoke of a refresh token disconnects only its member-token sockets" do
    live = RefreshTokens::Rotate.call(presented: @family.token)
    disconnected = nil

    RealtimeConnections::Disconnect.stub(
      :credentials,
      ->(tokens, reconnect: true) { disconnected = [tokens.map(&:id), reconnect] }
    ) do
      post oauth_revoke_path,
        params: { client_id: OAuth::DEVICE_CLIENT_ID, token: live.refresh_secret }
    end

    assert_response :ok
    assert_equal [[live.access_token.id], true], disconnected
  end

  test "revoke of an oauth access token cascades to its minting family" do
    live = RefreshTokens::Rotate.call(presented: @family.token)

    post oauth_revoke_path, params: { client_id: OAuth::DEVICE_CLIENT_ID, token: live.access_secret }
    assert_response :ok

    post_token(grant_type: OAuth::REFRESH_GRANT_TYPE, refresh_token: live.refresh_secret)
    assert_equal "invalid_grant", response.parsed_body["error"]
  end

  test "revoke accepts and ignores a scalar token_type_hint" do
    post oauth_revoke_path, params: {
      client_id: OAuth::DEVICE_CLIENT_ID,
      token: @family.secret,
      token_type_hint: "access_token",
    }

    assert_response :ok
    assert response.body.blank?
    assert_predicate @family.token.refresh_token_family.reload, :revoked?
  end

  test "revoke rejects a non-scalar or duplicated token_type_hint" do
    post oauth_revoke_path, params: {
      client_id: OAuth::DEVICE_CLIENT_ID,
      token: @family.secret,
      token_type_hint: ["refresh_token"],
    }
    assert_equal "invalid_request", response.parsed_body["error"]
    assert_not @family.token.refresh_token_family.reload.revoked?

    post "#{oauth_revoke_path}?token_type_hint=refresh_token", params: {
      client_id: OAuth::DEVICE_CLIENT_ID,
      token: @family.secret,
      token_type_hint: "refresh_token",
    }
    assert_equal "invalid_request", response.parsed_body["error"]
    assert_not @family.token.refresh_token_family.reload.revoked?
  end

  test "revoke is a silent 200 for an unknown token and enforces the client" do
    post oauth_revoke_path, params: { client_id: OAuth::DEVICE_CLIENT_ID, token: "whatever" }
    assert_response :ok

    post oauth_revoke_path, params: { client_id: "nope", token: "whatever" }
    assert_equal "invalid_client", response.parsed_body["error"]

    post oauth_revoke_path, params: { client_id: OAuth::DEVICE_CLIENT_ID }
    assert_equal "invalid_request", response.parsed_body["error"]
  end
end
