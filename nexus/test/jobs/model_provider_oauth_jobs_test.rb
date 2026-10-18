require "test_helper"

# The clock-driven OAuth jobs do not hold authority:
# each wakes an owner that decides for itself, so running late, twice, or not
# at all changes WHEN work happens and never WHAT happens.
class ModelProviderOAuthJobsTest < ActiveSupport::TestCase
  AUTH = ModelProviders::CodexAuthorization
  REFRESH = ModelProviderOAuthSessions::RefreshDueJob

  setup do
    @account = accounts(:cybros)
    @policy = ModelProviders::EnableLane.call(
      account: @account, provider_id: "codex_subscription", expected_lock_version: nil
    ).policy
  end

  # A transient refresh failure ends its session, so the
  # next attempt comes from the clock rather than from a retry counter.
  test "a credential inside the refresh lead gets a refresh session" do
    credential = install_credential(expires_in: 20.minutes)

    assert_difference -> { ModelProviderOAuthSession.count }, 1 do
      REFRESH.perform_now
    end

    session = ModelProviderOAuthSession.order(:id).last

    assert_equal "token_refresh", session.kind
    assert_equal credential.authorization_lineage_id, session.source_authorization_lineage_id
  end

  test "a credential with room to spare is left alone" do
    install_credential(expires_in: 6.hours)

    assert_no_difference -> { ModelProviderOAuthSession.count } do
      REFRESH.perform_now
    end
  end

  # The job adds no capability: AcceptSession still owns the refusal, so a
  # second run while the first session is live creates nothing.
  test "a second run while a session is live creates nothing" do
    install_credential(expires_in: 20.minutes)
    REFRESH.perform_now

    assert_no_difference -> { ModelProviderOAuthSession.count } do
      REFRESH.perform_now
    end
  end

  # A lane that needs a human is not a lane to wake every few minutes.
  test "a marked credential is not refreshed on a timer" do
    credential = install_credential(expires_in: 20.minutes)
    credential.update!(reauthorization_required: true, reauthorization_reason: "operator")

    assert_no_difference -> { ModelProviderOAuthSession.count } do
      REFRESH.perform_now
    end
  end

  test "a disabled lane is not refreshed on a timer" do
    install_credential(expires_in: 20.minutes)
    ModelProviders::DisableLane.call(
      account: @account, provider_id: @policy.provider_id,
      expected_lock_version: @policy.lock_version
    )

    assert_no_difference -> { ModelProviderOAuthSession.count } do
      REFRESH.perform_now
    end
  end

  private

    def install_credential(expires_in:)
      ModelProviderCredential.create!(
        account: @account, provider_id: "codex_subscription", material_kind: "oauth_tokens",
        secret: "at", refresh_secret: "rt",
        authorization_lineage_id: SecureRandom.uuid, generation: 0,
        expires_at: Time.current + expires_in
      )
    end
end
