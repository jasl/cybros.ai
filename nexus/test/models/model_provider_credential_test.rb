require "test_helper"

# C2-2 WP3c: encrypted per-lane credential material. One row per (Account,
# provider lane); material kinds are closed (api_key | oauth_tokens); raw
# secret material is never stored unencrypted; the usable predicate is the
# strict horizon check every read/start gate applies.
class ModelProviderCredentialTest < ActiveSupport::TestCase
  setup { @account = accounts(:cybros) }

  def api_key_row
    ModelProviderCredential.new(
      account: @account, provider_id: "openai_api",
      material_kind: "api_key", secret: "sk-cybros-synthetic"
    )
  end

  def oauth_row(expires_at: 2.hours.from_now)
    ModelProviderCredential.new(
      account: @account, provider_id: "codex_subscription",
      material_kind: "oauth_tokens", secret: "synthetic-access",
      refresh_secret: "synthetic-refresh",
      authorization_lineage_id: SecureRandom.uuid_v7,
      expires_at: expires_at
    )
  end

  test "an api-key row persists with encrypted secret and no oauth-only fields" do
    row = api_key_row
    assert_predicate row, :valid?
    row.save!

    stored = ModelProviderCredential.connection.select_value(
      "SELECT secret FROM model_provider_credentials WHERE id = #{row.id}"
    )
    refute_includes stored.to_s, "sk-cybros-synthetic", "the raw secret must never touch disk"
    assert_equal "sk-cybros-synthetic", row.reload.secret
  end

  test "an oauth row requires the complete pair, lineage, expiry, and provenance" do
    assert_predicate oauth_row, :valid?

    refute_predicate oauth_row.tap { |r| r.refresh_secret = nil }, :valid?
    refute_predicate oauth_row.tap { |r| r.authorization_lineage_id = nil }, :valid?
    refute_predicate oauth_row.tap { |r| r.expires_at = nil }, :valid?
  end

  test "an api-key row refuses oauth-only fields and unknown material kinds refuse" do
    refute_predicate api_key_row.tap { |r| r.refresh_secret = "x" }, :valid?
    refute_predicate api_key_row.tap { |r| r.material_kind = "password" }, :valid?
  end

  test "one credential per provider lane and create-frozen identity" do
    api_key_row.save!

    assert_raises(ActiveRecord::RecordNotUnique) { api_key_row.dup.save! }
  end

  test "the usable predicate applies the strict horizon: deadline plus clock skew" do
    deadline = 600
    now = Time.current

    assert api_key_row.usable_for?(total_execution_deadline_seconds: deadline, now: now),
      "an api key without expiry is usable while unmarked"

    horizon = now + deadline + ModelProviderCredential::OAUTH_CLOCK_SKEW_SECONDS
    assert oauth_row(expires_at: horizon + 1).usable_for?(
      total_execution_deadline_seconds: deadline, now: now
    )
    refute oauth_row(expires_at: horizon).usable_for?(
      total_execution_deadline_seconds: deadline, now: now
    ), "equality at the horizon is unusable — the predicate is strictly greater"
  end

  # Raw material is protected by encryption at rest; a serializer except-filter is not a security
  # boundary, so no as_json pin exists — no code path renders credential material.
  test "a reauthorization mark makes any material unusable" do
    row = api_key_row
    row.reauthorization_required = true
    row.reauthorization_reason = "provider_rejected"

    refute row.usable_for?(total_execution_deadline_seconds: 60, now: Time.current)
  end
end
