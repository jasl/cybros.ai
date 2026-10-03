require "test_helper"

# C2-OAuth WP4: token refresh and its failure taxonomy.
class ModelProviders::CodexAuthorization::RefreshTest < ActiveSupport::TestCase
  AUTH = ModelProviders::CodexAuthorization
  FAILURES = AUTH::RefreshFailures

  setup do
    @account = accounts(:cybros)
    ModelProviders::EnableLane.call(
      account: @account, provider_id: "codex_subscription", expected_lock_version: nil
    )
    @credential = install_credential
  end

  # --- alignment with the upstream classifier ------------------------------
  #
  # `manager.rs::classify_refresh_token_failure` at openai/codex `3711943d1`.
  # Each row below is that function's behavior, not an interpretation of it.

  test "the three named codes are permanent whatever the status" do
    {
      "refresh_token_expired" => :refresh_token_expired,
      "refresh_token_reused" => :refresh_token_reused,
      "refresh_token_invalidated" => :refresh_token_invalidated,
    }.each do |code, reason|
      body = { "error" => { "code" => code } }.to_json

      # Upstream: `reason != Other` makes it Permanent regardless of status, so
      # a 500 carrying a named code is still the end of that token.
      [400, 403, 500, 503].each do |status|
        assert_equal reason, FAILURES.classify(status: status, body: body), "#{code}/#{status}"
      end
    end
  end

  test "an unauthorized refresh is permanent even with nothing to read" do
    assert_equal :refresh_rejected, FAILURES.classify(status: 401, body: "")
    assert_equal :refresh_rejected, FAILURES.classify(status: 401, body: "not json")
  end

  test "an unrecognized failure is transient rather than fatal" do
    # Upstream logs it and returns Transient. Treating an unknown 500 as a dead
    # credential would send a human to reauthorize a token that still works.
    [500, 502, 503, 429, 400].each do |status|
      assert_nil FAILURES.classify(status: status, body: { "error" => { "code" => "nope" } }.to_json)
      assert_nil FAILURES.classify(status: status, body: "")
    end
  end

  test "the error code is read from all three shapes upstream accepts" do
    # `error` as an object with a code, `error` as a bare string, and a
    # top-level `code`. A provider that moves its code between them is not a
    # provider we stop understanding.
    assert_equal "refresh_token_reused",
      FAILURES.error_code({ "error" => { "code" => "refresh_token_reused" } }.to_json)
    assert_equal "refresh_token_reused",
      FAILURES.error_code({ "error" => "refresh_token_reused" }.to_json)
    assert_equal "refresh_token_reused",
      FAILURES.error_code({ "code" => "refresh_token_reused" }.to_json)
  end

  test "the code match is case-insensitive like upstream's" do
    body = { "error" => { "code" => "Refresh_Token_Expired" } }.to_json

    assert_equal :refresh_token_expired, FAILURES.classify(status: 400, body: body)
  end

  test "a malformed or non-object body yields no code" do
    ["", "   ", "not json", "[]", "12", '"text"'].each do |body|
      assert_nil FAILURES.error_code(body), body.inspect
    end
  end

  test "the observed lifetime and refresh floor are far larger than an hour" do
    # Measured live 2026-08-14: `expires_in` is 864000 (ten days) and
    # `earliest_refresh_at` lands nine days out. The bound has to admit that —
    # an hour-scale assumption would have refused every real credential.
    body = { "id_token" => "h.e30.s", "access_token" => "a", "refresh_token" => "r",
             "expires_in" => 864_000 }.to_json

    assert_equal 864_000,
      AUTH::Responses.code_exchange(status: 200, body: body).facts.fetch("expires_in_seconds")
  end

  test "the advisory refresh floor is not read" do
    # Measured live: refreshing IMMEDIATELY, nine days before
    # `earliest_refresh_at`, returned 200 and rotated the pair. The field is
    # scheduling advice the issuer does not enforce, so reading it would add a
    # second authority over when a refresh may run while the credential's own
    # expiry already answers that.
    body = { "id_token" => "h.e30.s", "access_token" => "a", "refresh_token" => "r",
             "expires_in" => 864_000, "earliest_refresh_at" => 1_787_483_370 }.to_json
    facts = AUTH::Responses.token_refresh(status: 200, body: body).facts

    refute_includes facts.keys, "earliest_refresh_at"
  end

  # --- the refresh flow ----------------------------------------------------

  test "a refresh spends the frozen credential's token and rotates the pair" do
    policy = ModelProviderPolicy.find_by!(account: @account, provider_id: "codex_subscription")
    version = policy.lock_version
    session = accept_refresh
    claim = AUTH::Claim.call(session: session)

    assert_equal AUTH.token_url, claim.prepared.url
    assert_equal "rt-old", JSON.parse(claim.prepared.body).fetch("refresh_token")

    result = AUTH::InstallCredential.call(
      session: session, task: claim.task, normalized_status: "http_200",
      outcome: AUTH::Responses.token_refresh(status: 200, body: token_body)
    )

    assert_predicate result, :installed?
    credential = @credential.reload

    assert_equal "at-new", credential.secret
    assert_equal "rt-new", credential.refresh_secret
    assert_predicate policy.reload, :enabled?
    assert_equal version, policy.lock_version
    # A refresh CONTINUES a credential, so the lineage is unchanged and the
    # generation advances.
    assert_equal session.authorization_lineage_id, credential.authorization_lineage_id
    assert_operator credential.generation, :>, session.source_generation
    assert_equal "completed", session.reload.state
  end

  test "a permanent refresh failure stops the session and disables that credential" do
    session = accept_refresh
    task = AUTH::Claim.call(session: session).task

    AUTH::InstallCredential.call(
      session: session, task: task, normalized_status: "http_400",
      outcome: AUTH::Responses.token_refresh(
        status: 400, body: { "error" => { "code" => "refresh_token_reused" } }.to_json
      )
    )

    assert_equal "failed", session.reload.state
    assert_equal "refresh_token_reused", session.outcome
    # The refresh token it just spent will not work again, so an unmarked row
    # would be a credential that silently cannot renew itself.
    assert_predicate @credential.reload, :reauthorization_required?
    assert_equal "refresh_token_reused", @credential.reauthorization_reason
  end

  # A transient failure ENDS the session, and a later refresh is a NEW session. It used to schedule
  # a retry the claim gate then refused forever — nothing reaps a refresh session and accept refuses
  # a new one while the old is pending, so one 503 killed automatic refresh for the lane until a
  # human ran a full device start.
  test "a transient refresh failure ends the session and marks nothing" do
    session = accept_refresh
    task = AUTH::Claim.call(session: session).task
    now = Time.current

    result = AUTH::InstallCredential.call(
      session: session, task: task, normalized_status: "http_503", now: now,
      outcome: AUTH::Responses.token_refresh(status: 503, body: "")
    )

    assert_equal :retryable, result.outcome
    assert_equal "failed", session.reload.state
    assert_nil session.next_action_at
    # Nothing is marked: a bad minute is not a dead credential, and the next
    # scheduled refresh accepts a fresh session over the same one.
    refute_predicate @credential.reload, :reauthorization_required?
    # The task is settled either way: the dispatch happened.
    assert_equal ModelProviderOAuthTask::ANSWERED, task.reload.state
  end

  test "a refresh whose frozen credential is gone refuses to claim" do
    session = accept_refresh
    @credential.update!(generation: @credential.generation + 1)

    # The token belongs to the generation this session froze. A rotated
    # credential's token is a different secret, and no older session was ever
    # about it.
    assert_raises(ActiveRecord::RecordNotFound) { AUTH::Claim.call(session: session) }
  end

  test "an ambiguous refresh closes the session, marks the credential, and leaves the pair whole" do
    session = accept_refresh
    task = AUTH::Claim.call(session: session).task

    AUTH::InstallCredential.call(session: session, task: task, normalized_status: "HTTPX::ReadTimeoutError", outcome: nil)

    assert_predicate @credential.reload, :reauthorization_required?
    # No old/new partial pair survives: nothing was rotated.
    assert_equal "rt-old", @credential.refresh_secret
    assert_equal "failed", session.reload.state
    assert_equal "ambiguous_delivery", session.outcome
    assert_equal "HTTPX::ReadTimeoutError", session.sanitized_reason, "the client's own word"
    assert_nil session.next_action_at
  end

  test "a late refresh closes the session without installing its response" do
    session = accept_refresh
    task = AUTH::Claim.call(session: session).task

    result = AUTH::InstallCredential.call(
      session: session, task: task, normalized_status: "http_200", now: task.deadline_at,
      outcome: AUTH::Responses.token_refresh(status: 200, body: token_body)
    )

    assert_equal :late, result.outcome
    assert_equal ModelProviderOAuthTask::SPENT, task.reload.state
    assert_equal "failed", session.reload.state
    assert_equal "ambiguous_delivery", session.outcome
    assert_equal "dispatch_deadline_exceeded", session.sanitized_reason
    assert_predicate @credential.reload, :reauthorization_required?
    assert_equal "at-old", @credential.secret
    assert_equal "rt-old", @credential.refresh_secret
  end

  private

    def accept_refresh
      AUTH::AcceptSession.call(
        account: @account, issuing_user: users(:owner), kind: "token_refresh"
      ).session
    end

    def token_body
      { "id_token" => "h.e30.s", "access_token" => "at-new", "refresh_token" => "rt-new",
        "expires_in" => 3600 }.to_json
    end

    def install_credential
      ModelProviderCredential.create!(
        account: @account, provider_id: "codex_subscription", material_kind: "oauth_tokens",
        secret: "at-old", refresh_secret: "rt-old",
        authorization_lineage_id: SecureRandom.uuid, generation: 2,
        expires_at: 1.hour.from_now
      )
    end
end
