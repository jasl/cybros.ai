require "test_helper"

# C2-OAuth WP3a: acceptance.
class ModelProviders::CodexAuthorization::AcceptSessionTest < ActiveSupport::TestCase
  ACCEPT = ModelProviders::CodexAuthorization::AcceptSession

  setup do
    @account = accounts(:cybros)
    @user = users(:owner)
    @policy = ModelProviders::EnableLane.call(
      account: @account, provider_id: "codex_subscription", expected_lock_version: nil
    ).policy
  end

  test "a device start creates a disabled policy anchor until authorization succeeds" do
    @policy.destroy!

    assert_difference -> { ModelProviderConfig.count }, 1 do
      assert_difference -> { ModelProviderOAuthSession.count }, 1 do
        result = ACCEPT.call(account: @account, issuing_user: @user, kind: "device_start")

        assert_predicate result, :accepted?
      end
    end
    refute_predicate ModelProviderConfig.find_by!(account: @account, provider_id: "codex_subscription"), :enabled?
  end

  test "a device start accepts without enabling a disabled lane" do
    ModelProviders::DisableLane.call(
      account: @account, provider_id: @policy.provider_id,
      expected_lock_version: @policy.lock_version
    )

    assert_difference -> { ModelProviderOAuthSession.count }, 1 do
      result = ACCEPT.call(account: @account, issuing_user: @user, kind: "device_start")

      assert_predicate result, :accepted?
    end
    refute_predicate @policy.reload, :enabled?
  end

  test "refresh still refuses missing and disabled policies without creating a session" do
    ModelProviders::DisableLane.call(account: @account, provider_id: @policy.provider_id,
      expected_lock_version: @policy.lock_version)
    assert_no_difference -> { ModelProviderOAuthSession.count } do
      assert_equal :provider_disabled, ACCEPT.call(account: @account, issuing_user: @user, kind: "token_refresh").outcome
      @policy.reload.destroy!
      assert_no_difference -> { ModelProviderConfig.count } do
        assert_equal :provider_disabled, ACCEPT.call(account: @account, issuing_user: @user, kind: "token_refresh").outcome
      end
    end
  end

  test "a device start creates a fresh lineage" do
    result = ACCEPT.call(account: @account, issuing_user: @user, kind: "device_start")

    assert_predicate result, :accepted?
    session = result.session

    assert_equal "pending", session.state
    assert_equal "accepted", session.progress
    assert_equal "user_code_request", session.semantic_exchange_kind
    assert_equal 0, session.semantic_exchange_ordinal
    assert session.authorization_lineage_id.present?
    # No credential exists, so the CAS target is three nulls rather than a
    # name for something that is not there.
    assert_nil session.source_credential_public_id
    assert_nil session.source_authorization_lineage_id
    assert_nil session.source_generation
  end

  test "a device start revokes the session in flight and takes its place" do
    first = ACCEPT.call(account: @account, issuing_user: @user, kind: "device_start").session

    second = ACCEPT.call(account: @account, issuing_user: @user, kind: "device_start", restart: true)

    assert_predicate second, :accepted?
    # A human who restarts authorization has decided; the predecessor stops so
    # that only the successor may publish a code or install credentials.
    assert_equal "revoked", first.reload.state
    assert_equal "superseded", first.outcome
    assert_equal 1, ModelProviderOAuthSession.nonterminal.count
    refute_equal first.authorization_lineage_id, second.session.authorization_lineage_id
  end

  test "a repeated start resumes only its issuer without resetting the live challenge" do
    first = ACCEPT.call(account: @account, issuing_user: @user, kind: "device_start").session
    first.update!(user_code: "SAME-CODE")
    assert_no_difference -> { ModelProviderOAuthSession.count } do
      resumed = ACCEPT.call(account: @account, issuing_user: @user, kind: "device_start")
      assert_predicate resumed, :accepted?
      assert_equal first.public_id, resumed.session.public_id
      assert_equal "SAME-CODE", resumed.session.user_code
      other = ACCEPT.call(account: @account, issuing_user: users(:member), kind: "device_start")
      assert_equal :oauth_session_in_progress, other.outcome
    end
  end

  test "a refresh refuses rather than cancelling a live authorization" do
    ACCEPT.call(account: @account, issuing_user: @user, kind: "device_start")

    result = ACCEPT.call(account: @account, issuing_user: @user, kind: "token_refresh")

    # The opposite of the device-start rule, and deliberately so: automatic
    # machinery must never cancel a human's authorization to rotate a token.
    assert_predicate result, :refused?
    assert_equal :oauth_session_in_progress, result.outcome
  end

  test "a refresh needs a refresh token and no reauthorization mark" do
    assert_equal :credential_not_refreshable,
      ACCEPT.call(account: @account, issuing_user: @user, kind: "token_refresh").outcome

    # The reachable "no refresh token" state is an api_key credential: the
    # oauth_tokens material validates that the pair is never half-present, so
    # a nil refresh token is not constructible there.
    api_key = install_credential(
      material_kind: "api_key", refresh_secret: nil, authorization_lineage_id: nil
    )

    assert_equal :credential_not_refreshable,
      ACCEPT.call(account: @account, issuing_user: @user, kind: "token_refresh").outcome

    api_key.destroy!
    install_credential(reauthorization_required: true)

    # A reauthorization mark says a human must act; rotating around it would
    # erase the one signal that says so.
    assert_equal :credential_not_refreshable,
      ACCEPT.call(account: @account, issuing_user: @user, kind: "token_refresh").outcome
  end

  test "a refresh copies the credential lineage exactly and is accepted while expired" do
    credential = install_credential(expires_at: 1.hour.ago)

    result = ACCEPT.call(account: @account, issuing_user: @user, kind: "token_refresh")

    assert_predicate result, :accepted?
    session = result.session
    # An expired access token is exactly what a refresh is for.
    assert_equal credential.authorization_lineage_id, session.authorization_lineage_id
    assert_equal credential.public_id, session.source_credential_public_id
    assert_equal credential.generation, session.source_generation
    assert_equal "token_refresh", session.semantic_exchange_kind
  end

  test "a device start with a current credential freezes it as the CAS target" do
    credential = install_credential

    session = ACCEPT.call(account: @account, issuing_user: @user, kind: "device_start").session

    assert_equal credential.public_id, session.source_credential_public_id
    assert_equal credential.generation, session.source_generation
    # The target is frozen for replacement checks; the lineage is NEW because
    # a device start mints rather than continues.
    refute_equal credential.authorization_lineage_id, session.authorization_lineage_id
    # And its refresh token was never read.
    assert_equal "rt-1", credential.reload.refresh_secret
  end

  test "the account is a singleton, so a cross-account issuer is unreachable" do
    # The schema permits one Account, so authorization-session acceptance carries no redundant
    # cross-account guard.
    assert_raises(ActiveRecord::RecordNotUnique) { Account.create!(name: "Other") }
  end

  # At most ONE dispatching task per provider lane, always. Two live requests
  # to the same lane are meaningless and conflict: the superseded one may
  # still be spending a code upstream while the replacement publishes another.
  #
  # A device start supersedes rather than refuses, so it is the one path that
  # can leave a task behind — the old session goes terminal and nothing else
  # would settle its in-flight request until the stale-dispatch sweep reached
  # its deadline, up to a full execution deadline later.
  test "superseding a session settles the request it left in flight" do
    first = ACCEPT.call(account: @account, issuing_user: @user, kind: "device_start").session
    in_flight = ModelProviders::CodexAuthorization::Claim.call(session: first).task

    assert_predicate in_flight, :dispatching?

    ACCEPT.call(account: @account, issuing_user: @user, kind: "device_start", restart: true)

    assert_equal ModelProviderOAuthTask::SPENT, in_flight.reload.state
    assert_equal 0, ModelProviderOAuthTask.dispatching.count
  end

  private

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
