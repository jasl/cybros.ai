require "test_helper"

# Installation status is derived from the current credential and pending session.
class ModelProviders::CodexAuthorization::StatusTest < ActiveSupport::TestCase
  AUTH = ModelProviders::CodexAuthorization
  STATUS = AUTH::Status

  setup do
    @account = accounts(:cybros)
    ModelProviders::EnableLane.call(
      account: @account, provider_id: "codex_subscription", expected_lock_version: nil
    )
  end

  test "nothing installed and nothing in flight reads as missing" do
    assert_equal "missing", STATUS.for(account: @account).state
  end

  test "an authorization under way with nothing installed reads as pending" do
    session = accept

    projection = STATUS.for(account: @account)

    assert_equal "pending", projection.state
    # The public locator is the session's own; the private task has no public id
    # and is never a locator.
    assert_equal session.public_id, projection.session_public_id
  end

  test "the verification uri is rendered while a human still owes a code" do
    session = accept
    advance_to_awaiting_user(session)

    assert_equal AUTH.verification_url, STATUS.for(account: @account).verification_uri

    session.terminalize(state: "revoked", outcome: "operator_revoked")

    # Cleared with every other live device fact on terminalization.
    assert_nil STATUS.for(account: @account).verification_uri
  end

  test "an installed credential reads as authorized even while a refresh is in flight" do
    credential = install_credential

    assert_equal "authorized", STATUS.for(account: @account).state
    assert_equal credential.expires_at.to_i, STATUS.for(account: @account).expires_at.to_i

    AUTH::AcceptSession.call(
      account: @account, issuing_user: users(:owner), kind: "token_refresh"
    )

    # Reporting `pending` here would flap the lane to "not ready" on every
    # rotation. Installation status does not promise enough token lifetime
    # for a particular model request.
    assert_equal "authorized", STATUS.for(account: @account).state
  end

  test "a marked credential wins over everything" do
    credential = install_credential
    credential.update!(reauthorization_required: true, reauthorization_reason: "refresh_token_reused")
    accept

    # That mark is the one signal saying a human must act, so nothing hides it.
    assert_equal "reauthorization_required", STATUS.for(account: @account).state
  end

  test "an expired credential still reads authorized because expiry is a candidate question" do
    install_credential(expires_at: 1.hour.ago)

    # Whether the remaining life clears a profile deadline is the exact-
    # candidate predicate's question; reaching that boundary MASKS a candidate
    # without persisting anything, and folding it in here would let a read
    # imply a mark.
    assert_equal "authorized", STATUS.for(account: @account).state
  end

  test "reading never writes" do
    install_credential
    session = accept

    5.times { STATUS.for(account: @account) }

    # The CAS-mark writers are the verified 401, invalid-refresh, and
    # possibly-sent ambiguity owners. A GET must never join them.
    refute_predicate ModelProviderCredential.sole, :reauthorization_required?
    assert_equal "pending", session.reload.state
    assert_equal 0, session.oauth_tasks.count
  end

  test "the derived state names what the lane actually is" do
    assert_equal "missing", STATUS.for(account: @account).state
    install_credential

    assert_equal "authorized", STATUS.for(account: @account).state
  end

  private

    def accept
      AUTH::AcceptSession.call(
        account: @account, issuing_user: users(:owner), kind: "device_start"
      ).session
    end

    def advance_to_awaiting_user(session)
      task = AUTH::Claim.call(session: session).task
      AUTH::ApplyDeviceStart.call(
        session: session, task: task, normalized_status: "http_200",
        outcome: AUTH::Responses.user_code(
          status: 200,
          body: { "device_auth_id" => "d", "user_code" => "RAWE-NUA2L", "interval" => "5" }.to_json
        )
      )
      session.reload
    end

    def install_credential(**overrides)
      ModelProviderCredential.create!(
        account: @account, provider_id: "codex_subscription", material_kind: "oauth_tokens",
        secret: "at-1", refresh_secret: "rt-1",
        authorization_lineage_id: SecureRandom.uuid, generation: 2,
        expires_at: 1.hour.from_now,
        **overrides
      )
    end
end
