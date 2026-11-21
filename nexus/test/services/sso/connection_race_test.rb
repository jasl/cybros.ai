require "test_helper"
require_relative "../../test_helpers/row_lock_test_helper"

class Sso::ConnectionRaceTest < ActiveSupport::TestCase
  include RowLockTestHelper
  uses_transaction :test_two_sessions_competing_for_one_subject_keep_the_winners_identity,
    :test_one_session_competing_to_connect_two_subjects_keeps_its_winning_subject

  setup do
    @provider = accounts(:cybros).sso_providers.create!(name: "Enterprise", protocol: "oidc",
      issuer: "https://enterprise.example.test", enabled: true, tested_at: Time.current)
    @sessions = []
  end

  teardown do
    @provider&.destroy!
    @sessions.each(&:destroy!)
  end

  test "two sessions competing for one subject keep the winners identity" do
    first = session_for(users(:owner))
    second = session_for(users(:member))
    confirmations = [attempt(first, "shared"), attempt(second, "shared")]

    assert_competing_connections(confirmations, refusal: :subject_in_use)
  end

  test "one session competing to connect two subjects keeps its winning subject" do
    session = session_for(users(:member))
    confirmations = [attempt(session, "one"), attempt(session, "two")]

    assert_competing_connections(confirmations, refusal: :already_connected)
  end

  private

    def session_for(user)
      create_browser_session(user.identity).tap { |session| @sessions << session }
    end

    def attempt(session, subject)
      @provider.sso_attempts.create!(purpose: "connect", phase: "confirming", session: session, subject: subject,
        state_digest: SecureRandom.hex(32), browser_digest: SecureRandom.hex(32), nonce: SecureRandom.hex(32),
        redirect_uri: "https://nexus.example.test/sso/providers/#{@provider.public_id}/callback",
        provider_version: @provider.lock_version, password_proved: true, expires_at: 5.minutes.from_now)
    end

    def assert_competing_connections(confirmations, refusal:)
      held = hold_row_lock(Account, @provider.account_id)
      calls = confirmations.map do |attempt|
        start_database_call do
          pending = SsoAttempt.find(attempt.id)
          Sso::Resolve.call(attempt: pending, session: pending.session, confirmed: true).outcome
        end
      end
      wait_until_waiting_on_lock(*calls.map(&:pid))
      release_row_lock(held)
      outcomes = calls.map { |call| finish_database_call(call) }
      assert_equal [:connected, refusal].sort, outcomes.sort
      winner = confirmations.fetch(outcomes.index(:connected))
      binding = @provider.sso_connections.sole
      assert_equal winner.session.identity_id, binding.identity_id
      assert_equal winner.subject, binding.subject
      refute SsoAttempt.exists?(sso_provider: @provider)
      @sessions.each { |session| assert_equal session, Session.find_usable(session.public_id) }
    ensure
      release_row_lock(held) if held&.thread&.alive?
      calls&.each { |call| stop_database_call(call) }
    end
end
