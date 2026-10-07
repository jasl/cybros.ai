require "test_helper"

# C2-OAuth WP3b: claim -> (no lock across IO) -> apply, for the two device-start
# phases that touch only the session.
class ModelProviders::CodexAuthorization::DeviceStartFlowTest < ActiveSupport::TestCase
  AUTH = ModelProviders::CodexAuthorization
  CLAIM = AUTH::Claim
  APPLY = AUTH::ApplyDeviceStart

  setup do
    @account = accounts(:cybros)
    ModelProviders::EnableLane.call(
      account: @account, provider_id: "codex_subscription", expected_lock_version: nil
    )
    @session = AUTH::AcceptSession.call(
      account: @account, issuing_user: users(:owner), kind: "device_start"
    ).session
  end

  # --- claiming ------------------------------------------------------------

  test "a claim records the dispatch before any byte leaves" do
    result = CLAIM.call(session: @session)

    assert_predicate result, :claimed?
    task = result.task

    assert_equal "user_code_request", task.exchange_kind
    assert_predicate task, :dispatching?
    assert_equal AUTH.user_code_url, result.prepared.url
    # The claim's deadline is bounded by the AUTHORIZATION WINDOW: no part of
    # a device start may outlive the window itself.
    assert_operator task.deadline_at, :<=,
      task.claimed_at + ModelProviderOAuthSession::AUTHORIZATION_WINDOW_SECONDS
  end

  test "a claim refuses while a sibling is still dispatching" do
    CLAIM.call(session: @session)

    assert_equal :exchange_in_flight, CLAIM.call(session: @session).outcome
  end

  test "a claim refuses a terminal session" do
    @session.terminalize(state: "revoked", outcome: "operator_revoked")

    assert_equal :session_not_pending, CLAIM.call(session: @session.reload).outcome
  end

  # --- a successor claim --------------------------------------------------

  # The row's state is the whole precondition: pending, inside the window,
  # no sibling dispatching. A step the client never answered is a spent task
  # and a pending session, and the flow resends it — a user-code request and
  # a poll commit nothing single-use (RFC 8628); a resent code exchange is
  # answered by the provider itself.
  test "a spent poll may be claimed again" do
    task = CLAIM.call(session: @session).task
    task.settle(
      state: ModelProviderOAuthTask::SPENT, normalized_status: "HTTPX::ReadTimeoutError",
      result_kind: "no_response"
    )

    reissued = CLAIM.call(session: @session.reload)

    assert_predicate reissued, :claimed?
    # A resend is a NEW ROW for the same step, so nothing numbers it — the two
    # tasks differ only by identity.
    assert_equal task.exchange_kind, reissued.task.exchange_kind
    assert_equal 2, @session.reload.oauth_tasks.count
  end

  # --- applying the user-code response -------------------------------------

  test "a user-code success freezes the window and readies the first poll" do
    task = CLAIM.call(session: @session).task
    started = Time.current

    APPLY.call(session: @session, task: task, normalized_status: "http_200", now: started,
      outcome: AUTH::Responses.user_code(status: 200, body: user_code_body))

    session = @session.reload

    assert_equal "awaiting_user", session.progress
    assert_equal 5, session.poll_interval_seconds
    assert_equal started.to_i, session.poll_started_at.to_i
    # Derived, never read from the response: one authority for the window.
    assert_equal (started + 900).to_i, session.authorization_deadline_at.to_i
    assert_equal AUTH.verification_url, session.verification_uri
    assert_equal "device_token_poll", session.semantic_exchange_kind
    assert_equal 0, session.semantic_exchange_ordinal
    assert_equal started.to_i, session.next_action_at.to_i
    assert_equal ModelProviderOAuthTask::ANSWERED, task.reload.state
  end

  test "a user-code terminal failure stops the session with the wire reason" do
    task = CLAIM.call(session: @session).task

    APPLY.call(session: @session, task: task, normalized_status: "http_404",
      outcome: AUTH::Responses.user_code(status: 404, body: ""))

    session = @session.reload

    assert_equal "failed", session.state
    assert_equal "device_code_not_enabled", session.outcome
    assert_nil session.device_auth_id
  end

  test "a user-code ambiguity leaves the session pending and marks no credential" do
    credential = install_credential
    session = AUTH::AcceptSession.call(
      account: @account, issuing_user: users(:owner), kind: "device_start", restart: true
    ).session
    task = CLAIM.call(session: session).task

    result = APPLY.call(session: session, task: task, normalized_status: "HTTPX::ReadTimeoutError", outcome: nil)

    assert_equal :ambiguous, result.outcome
    # It may have arrived, so the window decides rather than a guess.
    assert_equal "pending", session.reload.state
    assert_equal ModelProviderOAuthTask::SPENT, task.reload.state
    # A user-code request had not yet asked for anything about a credential,
    # so marking one would raise an alarm about a lane nothing touched.
    refute_predicate credential.reload, :reauthorization_required?
  end

  test "an ambiguous poll marks the exact credential the session froze" do
    credential = install_credential
    session = AUTH::AcceptSession.call(
      account: @account, issuing_user: users(:owner), kind: "device_start", restart: true
    ).session
    session = advance_to_polling(session)
    task = CLAIM.call(session: session).task

    APPLY.call(session: session, task: task, normalized_status: "HTTPX::ReadTimeoutError", outcome: nil)

    # An ambiguous poll may have completed an authorization upstream, which
    # would supersede the credential this session froze — so a human is told.
    assert_predicate credential.reload, :reauthorization_required?
    assert_equal "authorization_ambiguous", credential.reauthorization_reason
    assert_equal "pending", session.reload.state
  end

  test "the ambiguity mark is CAS-guarded to the frozen generation" do
    credential = install_credential
    session = AUTH::AcceptSession.call(
      account: @account, issuing_user: users(:owner), kind: "device_start", restart: true
    ).session
    session = advance_to_polling(session)
    task = CLAIM.call(session: session).task
    # The credential moved on after this session froze its triple.
    credential.update!(generation: credential.generation + 1)

    APPLY.call(session: session, task: task, normalized_status: "HTTPX::ReadTimeoutError", outcome: nil)

    # A credential that has since been replaced is a different credential, and
    # this observation says nothing about it.
    refute_predicate credential.reload, :reauthorization_required?
  end

  # --- applying polls ------------------------------------------------------

  test "a pending poll schedules the next protocol poll one interval later" do
    session = advance_to_polling
    task = CLAIM.call(session: session).task
    now = Time.current

    APPLY.call(session: session, task: task, normalized_status: "http_403", now: now,
      outcome: AUTH::Responses.device_token_poll(status: 403, body: ""))

    session.reload

    assert_equal "polling", session.progress
    # A NEW protocol poll, not a resend of an ambiguous one.
    assert_equal 1, session.semantic_exchange_ordinal
    assert_equal (now + 5).to_i, session.next_action_at.to_i
    assert_equal ModelProviderOAuthTask::ANSWERED, task.reload.state
  end

  test "a pending poll whose next slot falls outside the window expires the session" do
    session = advance_to_polling
    # The claim is taken NEAR the window end, not 300 seconds before the apply: a worker cannot
    # legitimately apply past its own claim's dispatch deadline, and since 2026-08-15 the apply
    # refuses to. The behaviour under test is the window closing, so the timeline has to be one the
    # window could actually produce.
    late_in_window = session.authorization_deadline_at - 2
    task = CLAIM.call(session: session, now: late_in_window).task

    APPLY.call(session: session, task: task, normalized_status: "http_403",
      now: late_in_window,
      outcome: AUTH::Responses.device_token_poll(status: 403, body: ""))

    session.reload

    # The window ends the session, not a retry counter.
    assert_equal "expired", session.state
    assert_equal "authorization_deadline_exceeded", session.outcome
  end

  test "a poll grant moves to the code exchange and installs nothing" do
    session = advance_to_polling
    task = CLAIM.call(session: session).task

    APPLY.call(session: session, task: task, normalized_status: "http_200",
      outcome: AUTH::Responses.device_token_poll(status: 200, body: grant_body))

    session.reload

    assert_equal "exchanging_code", session.progress
    assert_equal "code_exchange", session.semantic_exchange_kind
    assert_equal 0, session.semantic_exchange_ordinal
    assert_equal "ac-1", session.authorization_code
    # A grant is a coupon the exchange still has to spend: no credential yet.
    assert_equal 0, ModelProviderCredential.where(account_id: @account.id).count
    assert_equal "pending", session.state
  end

  test "a claim at or past the frozen window is refused before it can be sent" do
    session = advance_to_polling
    deadline = session.authorization_deadline_at

    # Exactly AT the deadline is late. The instant is passed explicitly rather
    # than travelled to, because travel truncates sub-second precision and
    # would test a moment just BEFORE the boundary instead of on it.
    assert_equal :authorization_deadline_exceeded,
      CLAIM.call(session: session, now: deadline).outcome
    assert_equal :authorization_deadline_exceeded,
      CLAIM.call(session: session, now: deadline + 1).outcome
    assert_predicate CLAIM.call(session: session, now: deadline - 1), :claimed?
  end

  test "a result cannot be applied twice or by a loser" do
    task = CLAIM.call(session: @session).task
    outcome = AUTH::Responses.user_code(status: 200, body: user_code_body)

    APPLY.call(session: @session, task: task, normalized_status: "http_200", outcome: outcome)
    second = APPLY.call(session: @session.reload, task: task, normalized_status: "http_200", outcome: outcome)

    assert_equal :stale, second.outcome
  end

  private

    def user_code_body
      { "device_auth_id" => "dev-1", "user_code" => "R20K-H1Q40", "interval" => "5" }.to_json
    end

    def grant_body
      { "authorization_code" => "ac-1", "code_challenge" => "cc-1",
        "code_verifier" => "cv-1" }.to_json
    end

    def advance_to_polling(session = @session)
      task = CLAIM.call(session: session).task
      APPLY.call(session: session, task: task, normalized_status: "http_200",
        outcome: AUTH::Responses.user_code(status: 200, body: user_code_body))
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
