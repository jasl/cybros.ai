require "test_helper"

# C2-OAuth WP3c: the credential suffix.
class ModelProviders::CodexAuthorization::InstallCredentialTest < ActiveSupport::TestCase
  AUTH = ModelProviders::CodexAuthorization
  INSTALL = AUTH::InstallCredential

  setup do
    @account = accounts(:cybros)
    @session = AUTH::AcceptSession.call(
      account: @account, issuing_user: users(:owner), kind: "device_start"
    ).session
    advance_to_code_exchange
    @policy = ModelProviderPolicy.find_by!(account: @account, provider_id: "codex_subscription")
  end

  test "a complete exchange installs the pair and completes the session" do
    task = AUTH::Claim.call(session: @session).task
    now = Time.current

    result = INSTALL.call(session: @session, task: task, normalized_status: "http_200", now: now,
      outcome: AUTH::Responses.code_exchange(status: 200, body: token_body))

    assert_predicate result, :installed?
    session = @session.reload

    assert_equal "completed", session.state
    assert_equal "authorized", session.outcome
    # Every terminal transition clears the live device facts and the grant.
    assert_nil session.authorization_code
    assert_nil session.user_code

    credential = ModelProviderCredential.find_by(account_id: @account.id)

    assert_equal "oauth_tokens", credential.material_kind
    assert_equal "at-live", credential.secret
    assert_equal "rt-live", credential.refresh_secret
    assert_equal session.authorization_lineage_id, credential.authorization_lineage_id
    # The issuer's relative lifetime, converted against the injected clock —
    # never a worker's, and never a guessed default.
    assert_equal (now + 3600).to_i, credential.expires_at.to_i
    assert_equal "acct_live_1", credential.provider_account_identity
    assert_predicate @policy.reload, :enabled?
  end

  test "a response without a usable expiry installs nothing" do
    task = AUTH::Claim.call(session: @session).task
    outcome = AUTH::Responses.code_exchange(
      status: 200, body: JSON.parse(token_body).except("expires_in").to_json
    )

    # Nexus never guesses a default TTL: a token that cannot say when it dies
    # is a token we cannot schedule a refresh for.
    assert_predicate outcome, :terminal?
    assert_equal :unusable_expiry, outcome.error

    INSTALL.call(session: @session, task: task, normalized_status: "http_200", outcome: outcome)

    assert_equal "failed", @session.reload.state
    assert_equal 0, ModelProviderCredential.count
    refute_predicate @policy.reload, :enabled?
  end

  test "an implausible lifetime is refused rather than kept for a decade" do
    %w[0 -1].each do |value|
      body = JSON.parse(token_body).merge("expires_in" => Integer(value)).to_json

      assert_equal :unusable_expiry, AUTH::Responses.code_exchange(status: 200, body: body).error
    end
    over = JSON.parse(token_body).merge("expires_in" => 31_536_001).to_json

    assert_equal :unusable_expiry, AUTH::Responses.code_exchange(status: 200, body: over).error
    # And the string spelling the poll interval uses is NOT accepted here: the
    # same response mixes both, so neither rule may be reused for the other.
    string_form = JSON.parse(token_body).merge("expires_in" => "3600").to_json

    assert_equal :unusable_expiry,
      AUTH::Responses.code_exchange(status: 200, body: string_form).error
  end

  test "an exchange failure stops the session and leaves no partial pair" do
    task = AUTH::Claim.call(session: @session).task

    INSTALL.call(session: @session, task: task, normalized_status: "http_400",
      outcome: AUTH::Responses.code_exchange(status: 400, body: ""))

    assert_equal "failed", @session.reload.state
    assert_equal 0, ModelProviderCredential.count
    refute_predicate @policy.reload, :enabled?
  end

  test "disable after dispatch prevents a late success from installing or enabling" do
    task = AUTH::Claim.call(session: @session).task
    result = ModelProviders::DisableLane.call(account: @account, provider_id: @policy.provider_id,
      expected_lock_version: @policy.lock_version)
    assert_predicate result, :done?

    result = INSTALL.call(session: @session, task: task, normalized_status: "http_200",
      outcome: AUTH::Responses.code_exchange(status: 200, body: token_body))

    assert_equal :stale, result.outcome
    assert_predicate @session.reload, :revoked?
    refute_predicate @policy.reload, :enabled?
    assert_equal 0, ModelProviderCredential.count
  end

  test "clear after dispatch prevents a late success from installing or enabling" do
    task = AUTH::Claim.call(session: @session).task
    AUTH::ClearAuthorization.call(account: @account)

    result = INSTALL.call(session: @session, task: task, normalized_status: "http_200",
      outcome: AUTH::Responses.code_exchange(status: 200, body: token_body))

    assert_equal :stale, result.outcome
    refute_predicate @policy.reload, :enabled?
    assert_equal 0, ModelProviderCredential.count
  end

  test "an ambiguous exchange marks the frozen credential and installs nothing" do
    credential = install_existing
    session = AUTH::AcceptSession.call(
      account: @account, issuing_user: users(:owner), kind: "device_start", restart: true
    ).session
    advance_to_code_exchange(session)
    task = AUTH::Claim.call(session: session).task

    result = INSTALL.call(session: session, task: task, normalized_status: "HTTPX::ReadTimeoutError", outcome: nil)

    assert_equal :ambiguous, result.outcome
    # The exchange may have spent its single-use grant upstream, so the
    # credential this session froze may already be superseded.
    assert_predicate credential.reload, :reauthorization_required?
    assert_equal "pending", session.reload.state
  end

  # A reauthorization-marked or missing-refresh credential requires a NEW DEVICE START rather than
  # another refresh — so a device start landing on an existing row is the ordinary recovery path,
  # not an edge case. It CASes on the triple it froze at accept time, writes its own new lineage,
  # and advances the generation so no earlier claim can match again.
  test "a device start replaces the credential it froze at accept" do
    existing = install_existing
    session = AUTH::AcceptSession.call(
      account: @account, issuing_user: users(:owner), kind: "device_start", restart: true
    ).session
    advance_to_code_exchange(session)
    task = AUTH::Claim.call(session: session).task

    result = INSTALL.call(session: session, task: task, normalized_status: "http_200",
      outcome: AUTH::Responses.code_exchange(status: 200, body: token_body))

    assert_predicate result, :installed?
    credential = existing.reload

    assert_equal "at-live", credential.secret
    assert_equal "rt-live", credential.refresh_secret
    assert_equal session.authorization_lineage_id, credential.authorization_lineage_id
    assert_equal 3, credential.generation
    refute_predicate credential, :reauthorization_required?
    assert_equal "completed", session.reload.state
  end

  # The CAS is the point: a credential replaced between accept and install is
  # a different credential, and this session's authorization says nothing
  # about it.
  test "a device start whose frozen credential was replaced installs nothing" do
    existing = install_existing
    session = AUTH::AcceptSession.call(
      account: @account, issuing_user: users(:owner), kind: "device_start", restart: true
    ).session
    advance_to_code_exchange(session)
    task = AUTH::Claim.call(session: session).task
    existing.update!(generation: existing.generation + 1)

    result = INSTALL.call(session: session, task: task, normalized_status: "http_200",
      outcome: AUTH::Responses.code_exchange(status: 200, body: token_body))

    assert_equal :stale, result.outcome
    assert_equal "old-at", existing.reload.secret
    refute_predicate @policy.reload, :enabled?
  end

  # Only `now < deadline_at` may apply a result. The response is real and its lateness is recorded —
  # but the claim that authorized the request has lapsed, so nothing reaches Session or Credential,
  # and the task settles SPENT rather than answered: the bytes demonstrably went out and the step
  # did not advance, so it is never sent again.
  test "a response arriving past its claim deadline is spent and installs nothing" do
    credential = install_existing
    session = AUTH::AcceptSession.call(
      account: @account, issuing_user: users(:owner), kind: "device_start", restart: true
    ).session
    advance_to_code_exchange(session)
    task = AUTH::Claim.call(session: session).task

    result = INSTALL.call(session: session, task: task, normalized_status: "http_200",
      now: task.deadline_at,
      outcome: AUTH::Responses.code_exchange(status: 200, body: token_body))

    assert_equal :late, result.outcome
    assert_equal ModelProviderOAuthTask::SPENT, task.reload.state
    assert_equal "dispatch_deadline_exceeded", task.normalized_status
    assert_equal "late_response", task.result_kind
    assert_equal "old-at", credential.reload.secret
    # The exchange may have spent its single-use grant upstream, so the frozen
    # triple is marked and the session's own window, not this worker, decides.
    assert_predicate credential, :reauthorization_required?
    assert_equal "pending", session.reload.state
  end

  test "a session that lost the first-terminal race installs nothing" do
    task = AUTH::Claim.call(session: @session).task
    # A revoke landed while the exchange was on the wire.
    @session.terminalize(state: "revoked", outcome: "operator_revoked")

    result = INSTALL.call(session: @session.reload, task: task, normalized_status: "http_200",
      outcome: AUTH::Responses.code_exchange(status: 200, body: token_body))

    assert_equal :stale, result.outcome
    assert_equal "revoked", @session.reload.state
    assert_equal 0, ModelProviderCredential.count
  end

  private

    def token_body
      { "id_token" => id_token, "access_token" => "at-live", "refresh_token" => "rt-live",
        "expires_in" => 3600, "token_type" => "Bearer" }.to_json
    end

    def id_token
      claims = Base64.urlsafe_encode64(
        { "https://api.openai.com/auth" => { "chatgpt_account_id" => "acct_live_1" } }.to_json,
        padding: false
      )
      "header.#{claims}.signature"
    end

    def advance_to_code_exchange(session = @session)
      task = AUTH::Claim.call(session: session).task
      AUTH::ApplyDeviceStart.call(session: session, task: task, normalized_status: "http_200",
        outcome: AUTH::Responses.user_code(
          status: 200,
          body: { "device_auth_id" => "d", "user_code" => "R20K-H1Q40", "interval" => "5" }.to_json
        ))
      poll = AUTH::Claim.call(session: session.reload).task
      AUTH::ApplyDeviceStart.call(session: session, task: poll, normalized_status: "http_200",
        outcome: AUTH::Responses.device_token_poll(
          status: 200,
          body: { "authorization_code" => "ac", "code_challenge" => "cc",
                  "code_verifier" => "cv" }.to_json
        ))
      session.reload
    end

    def install_existing
      ModelProviderCredential.create!(
        account: @account, provider_id: "codex_subscription", material_kind: "oauth_tokens",
        secret: "old-at", refresh_secret: "old-rt",
        authorization_lineage_id: SecureRandom.uuid, generation: 2,
        expires_at: 1.hour.from_now
      )
    end
end
