require "test_helper"

# Resolution checks lane enablement and credential lifetime before exposing
# signing material to the provider-start path; inspection never renders it.
class ModelProviders::CredentialResolverTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
  end

  def enable_lane(provider_id)
    ModelProviders::EnableLane.call(
      account: @account, provider_id: provider_id,
      expected_lock_version: nil
    )
  end

  def resolve(provider_id: "openai_api", credential_lane: "api_key", deadline: 600, now: Time.current)
    ModelProviders::CredentialResolver.resolve(
      account: @account, provider_id: provider_id, credential_lane: credential_lane,
      total_execution_deadline_seconds: deadline, now: now
    )
  end

  test "a disabled or absent lane refuses before any credential question" do
    assert_equal :lane_disabled, resolve.outcome

    enable_lane("openai_api")
    policy = ModelProviderPolicy.find_by!(account: @account, provider_id: "openai_api")
    ModelProviders::DisableLane.call(
      account: @account, provider_id: "openai_api",
      expected_lock_version: policy.lock_version
    )
    assert_equal :lane_disabled, resolve.outcome
  end

  test "an enabled lane without material refuses no_credential; a lane mismatch is typed" do
    enable_lane("openai_api")
    assert_equal :no_credential, resolve.outcome

    ModelProviders::SetAPIKey.call(account: @account, provider_id: "openai_api", api_key: "sk-x")
    assert_equal :credential_kind_mismatch, resolve(credential_lane: "oauth_tokens").outcome
  end

  test "a usable api key resolves and the result never renders the secret" do
    enable_lane("openai_api")
    ModelProviders::SetAPIKey.call(account: @account, provider_id: "openai_api", api_key: "sk-secret-x")

    result = resolve
    assert_predicate result, :resolved?
    assert_equal "api_key", result.credential.material_kind
    assert_equal "sk-secret-x", result.credential.secret
    refute_includes result.inspect, "sk-secret-x"
  end

  test "a marked or under-horizon oauth pair refuses with its own outcomes" do
    enable_lane("codex_subscription")
    ModelProviders::InstallOAuthPair.call(
      account: @account, provider_id: "codex_subscription",
      access_token: "at", refresh_token: "rt", lineage_id: SecureRandom.uuid_v7,
      expected_generation: nil, expires_at: 10.minutes.from_now
    )

    short = resolve(provider_id: "codex_subscription", credential_lane: "oauth_tokens", deadline: 600)
    assert_equal :credential_unusable, short.outcome,
      "a 600s expiry horizon cannot cover 600s deadline + 300s skew (strict predicate)"

    credential = ModelProviderCredential.find_by!(account: @account, provider_id: "codex_subscription")
    ModelProviders::MarkReauthorizationRequired.call(
      account: @account, provider_id: "codex_subscription",
      lineage_id: credential.authorization_lineage_id, expected_generation: credential.generation,
      reason: "refresh_rejected"
    )
    assert_equal :reauthorization_required,
      resolve(provider_id: "codex_subscription", credential_lane: "oauth_tokens", deadline: 60).outcome
  end
end
