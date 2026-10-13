require "test_helper"

# C2-OAuth WP2: the semantic authorization session.
class ModelProviderOAuthSessionTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
    @user = users(:owner)
  end

  test "a device start is valid without a source credential" do
    assert_predicate build_device_start, :valid?
  end

  test "a refresh is valid only when it names the credential it rotates" do
    refresh = build_refresh

    assert_predicate refresh, :valid?

    refresh.source_credential_public_id = nil
    refresh.source_authorization_lineage_id = nil
    refresh.source_generation = nil

    # Without the triple a refresh could install over whatever happens to be
    # current when it lands, which is the ambiguity the fence prevents.
    refute_predicate refresh, :valid?
    assert_includes refresh.errors.attribute_names, :source_credential_public_id
  end

  test "the source triple is frozen whole or not at all" do
    session = build_device_start(
      source_credential_public_id: SecureRandom.uuid, source_authorization_lineage_id: nil,
      source_generation: nil
    )

    refute_predicate session, :valid?
    assert_includes session.errors.full_messages.join, "frozen whole or not at all"
  end

  test "progress and the next exchange belong to the session kind" do
    # A refresh has no human in it, so it can never await a user or exchange a
    # code — and a device start never refreshes.
    refute_predicate build_refresh(progress: "awaiting_user"), :valid?
    refute_predicate build_refresh(semantic_exchange_kind: "code_exchange"), :valid?
    refute_predicate build_device_start(progress: "refreshing"), :valid?
    refute_predicate build_device_start(semantic_exchange_kind: "token_refresh"), :valid?
    assert_predicate build_device_start(progress: "polling",
      semantic_exchange_kind: "device_token_poll"), :valid?
  end

  test "the polling window is set whole and only by a device start" do
    started = Time.current
    session = build_device_start(poll_started_at: started, authorization_deadline_at: nil)

    refute_predicate session, :valid?

    session.authorization_deadline_at = started + 900
    assert_predicate session, :valid?

    refute_predicate build_refresh(poll_started_at: started,
      authorization_deadline_at: started + 900), :valid?
    refute_predicate build_refresh(poll_interval_seconds: 5), :valid?
  end

  test "the authorization deadline is derived, never chosen" do
    started = Time.current

    assert_predicate build_device_start(poll_started_at: started,
      authorization_deadline_at: started + 900), :valid?
    # A free deadline column checked only for presence would let a caller widen
    # its own window.
    refute_predicate build_device_start(poll_started_at: started,
      authorization_deadline_at: started + 960), :valid?
    refute_predicate build_device_start(poll_started_at: started,
      authorization_deadline_at: started + 60), :valid?
  end

  test "the poll ordinal is bounded by what the frozen interval leaves in the window" do
    started = Time.current
    window = { poll_started_at: started, authorization_deadline_at: started + 900 }

    session = build_device_start(poll_interval_seconds: 5, semantic_exchange_ordinal: 180, **window)

    assert_equal 180, session.poll_ordinal_ceiling
    assert_predicate session, :valid?

    over = build_device_start(poll_interval_seconds: 5, semantic_exchange_ordinal: 181, **window)

    refute_predicate over, :valid?
    assert_includes over.errors.full_messages.join, "5-second interval"
  end

  test "the ceiling never costs a poll upstream would have made" do
    # Upstream polls at t=0 then every `interval` until 15 minutes elapse:
    # `floor(900 / interval) + 1` requests. Under ZERO-based ordinals the
    # `ceil(900 / interval)` polling ceiling admits exactly that when the
    # interval divides 900, and exactly one more when it does not. The
    # looseness authorizes nothing — the extra ordinal would be scheduled past
    # the deadline and refused by the strict comparison — but the floor
    # matters: one-based ordinals would COST a poll at every dividing interval.
    window = ModelProviderOAuthSession::AUTHORIZATION_WINDOW_SECONDS

    [1, 3, 5, 7, 11, 60, 450, 900].each do |interval|
      admitted = build_device_start(poll_interval_seconds: interval).poll_ordinal_ceiling + 1
      upstream = (window / interval) + 1

      assert_operator admitted, :>=, upstream, "interval #{interval} must not cost a poll"
      expected = (window % interval).zero? ? upstream : upstream + 1

      assert_equal expected, admitted, "interval #{interval}"
    end
  end

  test "the poll interval is bounded to the reviewed range" do
    assert_predicate build_device_start(poll_interval_seconds: 1), :valid?
    assert_predicate build_device_start(poll_interval_seconds: 900), :valid?
    # Out-of-range intervals must ADD an error, not raise on the way to one:
    # every validator still runs after the numericality check fails, so the
    # ceiling rule is reached with a zero it must refuse to divide by.
    refute_predicate build_device_start(poll_interval_seconds: 0), :valid?
    refute_predicate build_device_start(poll_interval_seconds: -5), :valid?
    refute_predicate build_device_start(poll_interval_seconds: 901), :valid?
    assert_nil build_device_start(poll_interval_seconds: 0).poll_ordinal_ceiling
  end

  test "a grant is stored whole and only where it can be spent" do
    whole = { authorization_code: "ac", code_challenge: "cc", code_verifier: "cv" }

    assert_predicate build_device_start(progress: "exchanging_code", **whole), :valid?
    refute_predicate build_device_start(progress: "exchanging_code",
      authorization_code: "ac", code_challenge: "cc"), :valid?
    # Not at polling: the grant does not exist before the poll produced it.
    refute_predicate build_device_start(progress: "polling", **whole), :valid?
    # Not on a terminal session: a stopped session must leave nothing spendable.
    refute_predicate build_device_start(progress: "exchanging_code", state: "completed", **whole),
      :valid?
  end

  test "the immutable acceptance facts raise on assignment after insert" do
    session = create_device_start

    %i[kind account_id provider_id authorization_lineage_id].each do |field|
      assert_raises(ActiveRecord::ReadonlyAttributeError, field.to_s) do
        session.update!(field => session.public_send(field))
      end
    end
  end

  test "the first terminal writer wins and the loser is told" do
    session = create_device_start(progress: "polling")

    won = session.terminalize(state: "completed", outcome: "authorized")
    lost = session.terminalize(state: "revoked", outcome: "operator_revoked")

    assert_equal "completed", won.state
    assert_nil lost
    assert_equal "completed", session.reload.state
  end

  test "terminalizing clears every live device fact and the whole grant" do
    session = create_device_start(
      progress: "exchanging_code", device_auth_id: "dev-1", user_code: "BCDF",
      verification_uri: ModelProviders::CodexAuthorization.verification_url,
      authorization_code: "ac", code_challenge: "cc", code_verifier: "cv"
    )

    session.terminalize(state: "failed", outcome: "provider_error", sanitized_reason: "http_500")

    assert_nil session.device_auth_id
    assert_nil session.user_code
    assert_nil session.verification_uri
    assert_nil session.authorization_code
    assert_nil session.code_challenge
    assert_nil session.code_verifier
    assert_nil session.next_action_at
    assert_equal "http_500", session.sanitized_reason
  end

  # `expirable?` and `may_install?` were model predicates restating rules whose
  # only consulted authority lives elsewhere, and nothing production ever
  # called them (2026-08-15). The rules themselves stay pinned where they are
  # enforced: the window sweep in sweeps_test, and the first-terminal race in
  # install_credential_test.

  test "the domain accepts every provider terminal outcome" do
    ModelProviderOAuthSession::PROVIDER_TERMINAL_OUTCOMES.each do |outcome|
      assert_predicate build_device_start(state: "failed", outcome: outcome), :valid?
    end
  end

  test "the device handle, user code, and grant are encrypted at rest" do
    session = create_device_start(
      progress: "exchanging_code", device_auth_id: "dev-secret", user_code: "BCDF",
      authorization_code: "ac-secret", code_challenge: "cc", code_verifier: "cv-secret"
    )

    stored = ModelProviderOAuthSession.connection.select_one(
      "SELECT device_auth_id, user_code, authorization_code, code_verifier " \
      "FROM model_provider_oauth_sessions WHERE id = #{session.id}"
    )

    refute_includes stored.values.join, "dev-secret"
    refute_includes stored.values.join, "ac-secret"
    refute_includes stored.values.join, "cv-secret"
  end

  private

    def build_device_start(**overrides)
      ModelProviderOAuthSession.new(
        account: @account, issuing_user: @user, provider_id: "codex_subscription",
        kind: "device_start", progress: "accepted",
        authorization_lineage_id: SecureRandom.uuid,
        **overrides
      )
    end

    def build_refresh(**overrides)
      build_device_start(
        kind: "token_refresh", progress: "accepted",
        source_credential_public_id: SecureRandom.uuid,
        source_authorization_lineage_id: SecureRandom.uuid,
        source_generation: 3,
        **overrides
      )
    end

    def create_device_start(**overrides) = build_device_start(**overrides).tap(&:save!)
end
