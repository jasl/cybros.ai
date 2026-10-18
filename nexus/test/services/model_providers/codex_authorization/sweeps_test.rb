require "test_helper"

# Clock-driven authorization sweeps and the atomic local clear.
class ModelProviders::CodexAuthorization::SweepsTest < ActiveSupport::TestCase
  AUTH = ModelProviders::CodexAuthorization
  SWEEPS = AUTH::Sweeps

  setup do
    @account = accounts(:cybros)
    @policy = ModelProviders::EnableLane.call(
      account: @account, provider_id: "codex_subscription", expected_lock_version: nil
    ).policy
    @session = accept
  end

  test "the due sweep selects and does not act" do
    assert_includes SWEEPS.due, @session

    @session.update!(next_action_at: 1.hour.from_now)

    refute_includes SWEEPS.due, @session
    # Selecting is all it does: claiming is the transaction that decides, and a
    # sweep that dispatched too would be a second one.
    assert_equal 0, @session.reload.oauth_tasks.count
    assert_equal "pending", @session.state
  end

  test "disable revokes pending sessions while a new connection may run on a disabled lane" do
    disabled = ModelProviders::DisableLane.call(
      account: @account, provider_id: @policy.provider_id,
      expected_lock_version: @policy.lock_version
    )

    assert_predicate disabled, :done?
    refute_includes SWEEPS.due, @session
    assert_predicate @session.reload, :revoked?
    replacement = accept
    assert_includes SWEEPS.due, replacement
    refute_predicate @policy.reload, :enabled?

    enabled = ModelProviders::EnableLane.call(
      account: @account, provider_id: @policy.provider_id,
      expected_lock_version: disabled.policy.lock_version
    )

    assert_predicate enabled, :done?
    refute_includes SWEEPS.due, @session
    assert_includes SWEEPS.due, replacement
  end

  test "the expiry sweep closes a device start whose window has passed" do
    advance_to_polling
    deadline = @session.reload.authorization_deadline_at

    assert_equal 0, SWEEPS.expire_closed_windows(now: deadline - 1)
    assert_equal 1, SWEEPS.expire_closed_windows(now: deadline + 1)
    assert_equal "expired", @session.reload.state
    assert_equal "authorization_deadline_exceeded", @session.outcome
  end

  test "a refresh is never expired by the window sweep" do
    @session.terminalize(state: "revoked", outcome: "operator_revoked")
    install_credential
    refresh = AUTH::AcceptSession.call(
      account: @account, issuing_user: users(:owner), kind: "token_refresh"
    ).session

    # A refresh has no window, so nothing here can decide it is late.
    assert_equal 0, SWEEPS.expire_closed_windows(now: 1.year.from_now)
    assert_equal "pending", refresh.reload.state
  end

  # A SEALED DISPATCH ENDS THE SESSION, whatever its kind. The flow was already dead — sealing
  # blocks every successor claim — so waiting for the frozen window only delayed the admission while
  # the corpse held the lane's one live session slot and its place in the due queue. The successor
  # refusal is `session_not_pending`. The apply-side ambiguity paths still leave a device start
  # pending for its window, to be claimed again — that is a worker REPORTING the client's verdict, a
  # different fact from a worker that vanished.
  test "a stale dispatch seals as ambiguity, ends the session, and frees the lane" do
    task = AUTH::Claim.call(session: @session).task

    assert_equal 0, SWEEPS.seal_stale_dispatches(now: task.deadline_at - 1)
    assert_equal 1, SWEEPS.seal_stale_dispatches(now: task.deadline_at + 1)

    task.reload

    # The worker that owned it is gone and took any knowledge of whether the
    # request was sent, so this is ambiguity — never retry authority.
    assert_equal ModelProviderOAuthTask::SPENT, task.state
    assert_equal "dispatch_deadline_exceeded", task.normalized_status

    @session.reload
    assert_equal "failed", @session.state
    assert_equal "ambiguous_delivery", @session.outcome,
      "the dispatch was lost; the window did not pass — the outcome says which"
    assert_nil @session.user_code, "a dead flow leaves no renderable code behind"
    assert_equal :session_not_pending, AUTH::Claim.call(session: @session).outcome

    # THE SLOT FREES NOW, not at window close: the operator can start a fresh
    # device flow immediately instead of waiting out a corpse.
    replacement = AUTH::AcceptSession.call(
      account: @account, issuing_user: users(:owner), kind: "device_start"
    )
    assert_equal "pending", replacement.session.state
  end

  test "a stale device poll marks the credential it may have superseded" do
    @session.terminalize(state: "revoked", outcome: "operator_revoked")
    credential = install_credential
    session = AUTH::AcceptSession.call(
      account: @account, issuing_user: users(:owner), kind: "device_start"
    ).session
    advance_to_polling(session)
    task = AUTH::Claim.call(session: session).task

    assert_equal 1, SWEEPS.seal_stale_dispatches(now: task.deadline_at + 1)

    assert_equal ModelProviderOAuthTask::SPENT, task.reload.state
    assert_predicate credential.reload, :reauthorization_required?
    assert_equal "failed", session.reload.state,
      "the vanished worker ends the flow now, not the window later"
  end

  # A SEALED DISPATCH ENDS ITS SESSION, and for a refresh nothing else can. `expire_closed_windows`
  # covers device starts only — "a refresh has no window" — so a refresh Session whose dispatch the
  # sweep sealed stayed `pending` with no writer anywhere able to end it, while `due` selects
  # `.order(:next_action_at,:id).limit(100)` and kept handing it back at the head of a bounded queue
  # on every pass. That is a refresh-lane lockout, not an untidy row: the credential can never be
  # renewed again.
  def test_sealing_a_refresh_dispatch_ends_the_session_it_stranded
    # One live session per lane, so the setup's device start steps aside.
    @session.terminalize(state: "revoked", outcome: "operator_revoked")
    credential = install_credential
    refresh = AUTH::AcceptSession.call(
      account: @account, issuing_user: users(:owner), kind: "token_refresh"
    ).session
    task = AUTH::Claim.call(session: refresh).task

    assert_equal 1, SWEEPS.seal_stale_dispatches(now: task.deadline_at + 1)

    refresh.reload
    assert_equal "failed", refresh.state, "nothing else can ever end a refresh session"
    assert_equal "ambiguous_delivery", refresh.outcome,
      "the outcome the vocabulary already had and nothing had ever written"
    assert_nil refresh.next_action_at, "and it leaves the due queue it was holding the head of"
    assert_predicate credential.reload, :reauthorization_required?,
      "a possibly-sent refresh must not send the frozen token again"
    next_refresh = AUTH::AcceptSession.call(
      account: @account, issuing_user: users(:owner), kind: "token_refresh"
    )
    assert_equal :credential_not_refreshable, next_refresh.outcome
  end

  test "a refresh session, stale dispatch, and credential mark roll back together" do
    @session.terminalize(state: "revoked", outcome: "operator_revoked")
    credential = install_credential
    refresh = AUTH::AcceptSession.call(
      account: @account, issuing_user: users(:owner), kind: "token_refresh"
    ).session
    task = AUTH::Claim.call(session: refresh).task
    failure = Class.new(StandardError)
    credential_update_ran = false
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      sql = payload[:sql].to_s
      if sql.start_with?('UPDATE "model_provider_credentials"')
        credential_update_ran = true
        raise failure, "crash after credential mark"
      end
    end

    begin
      assert_raises(failure) do
        SWEEPS.seal_stale_dispatches(now: task.deadline_at + 1)
      end
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    assert credential_update_ran, "the injected crash must follow all three writes"
    assert_equal ModelProviderOAuthTask::DISPATCHING, task.reload.state
    assert_equal "pending", refresh.reload.state
    assert_not credential.reload.reauthorization_required?
  end

  test "retention deletes children before the parent and skips a live child" do
    task = AUTH::Claim.call(session: @session).task
    @session.terminalize(state: "revoked", outcome: "operator_revoked")

    # A dispatching child is a request that may still be in the air; deleting
    # its record would destroy the only proof it existed.
    assert_equal 0, SWEEPS.collect_terminal_sessions(before: 1.hour.from_now)[:collected]

    task.settle(
      state: ModelProviderOAuthTask::SPENT, normalized_status: "Errno::ECONNREFUSED",
      result_kind: "no_response"
    )

    assert_equal 1, SWEEPS.collect_terminal_sessions(before: 1.hour.from_now)[:collected]
    assert_equal 0, ModelProviderOAuthSession.where(id: @session.id).count
    assert_equal 0, ModelProviderOAuthTask.where(id: task.id).count
  end

  test "retention never collects a pending session" do
    @session.oauth_tasks.delete_all

    assert_equal 0, SWEEPS.collect_terminal_sessions(before: 1.hour.from_now)[:collected]
    assert_equal 1, ModelProviderOAuthSession.where(id: @session.id).count
  end

  # --- the atomic local clear ----------------------------------------------

  test "the clear revokes every live session and removes the credential" do
    credential = install_credential

    result = AUTH::ClearAuthorization.call(account: @account)

    assert_predicate result, :cleared?
    assert_equal 1, result.revoked_sessions
    assert_equal "revoked", @session.reload.state
    # Every terminal transition clears the live device facts, this one included.
    assert_nil @session.device_auth_id
    assert_equal 0, ModelProviderCredential.where(id: credential.id).count
  end

  test "the clear is local only and answers with no credential present" do
    result = AUTH::ClearAuthorization.call(account: @account)

    # An operator pressing disconnect gets a durable answer either way: what we
    # promise is that this deployment no longer holds the material.
    assert_predicate result, :cleared?
    assert_equal :not_found, result.cleared_credential
    assert_equal "revoked", @session.reload.state
  end

  test "the clear does not create a missing policy row" do
    @session.destroy!
    @policy.destroy!

    assert_no_difference -> { ModelProviderConfig.count } do
      result = AUTH::ClearAuthorization.call(account: @account)

      assert_predicate result, :cleared?
      assert_equal 0, result.revoked_sessions
      assert_equal :not_found, result.cleared_credential
    end
  end

  test "a session that already won its own terminal is left alone" do
    @session.terminalize(state: "completed", outcome: "authorized")

    result = AUTH::ClearAuthorization.call(account: @account)

    assert_equal 0, result.revoked_sessions
    # That writer already decided what this session was.
    assert_equal "completed", @session.reload.state
  end

  private

    def accept
      AUTH::AcceptSession.call(
        account: @account, issuing_user: users(:owner), kind: "device_start"
      ).session
    end

    def advance_to_polling(session = @session)
      task = AUTH::Claim.call(session: session).task
      AUTH::ApplyDeviceStart.call(
        session: session, task: task, normalized_status: "http_200",
        outcome: AUTH::Responses.user_code(
          status: 200,
          body: { "device_auth_id" => "d", "user_code" => "R20K-H1Q40", "interval" => "5" }.to_json
        )
      )
      session.reload
    end

    def install_credential
      ModelProviderCredential.create!(
        account: @account, provider_id: "codex_subscription", material_kind: "oauth_tokens",
        secret: "at-1", refresh_secret: "rt-1",
        authorization_lineage_id: SecureRandom.uuid, generation: 2,
        expires_at: 1.hour.from_now
      )
    end
end
