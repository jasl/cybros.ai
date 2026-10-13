require "test_helper"

class ModelProviders::CodexAuthorization::ContinueSessionTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  AUTH = ModelProviders::CodexAuthorization

  setup do
    @account = accounts(:cybros)
    @policy = ModelProviders::EnableLane.call(account: @account, provider_id: AUTH::PROVIDER_ID,
      expected_lock_version: nil).policy
    @session = AUTH::AcceptSession.call(account: @account, issuing_user: users(:owner), kind: "device_start").session
  end

  test "a precise wake advances one phase and schedules its recorded next action" do
    now = Time.current
    delivery = AUTH::Transport::Delivery.new(status: 200,
      body: { device_auth_id: "device", user_code: "TEST-CODE", interval: "5" }.to_json, reason: nil)
    AUTH::Transport.stub(:perform, delivery) do
      due = AUTH::ContinueSession.call(@session.public_id, now: now)
      assert_in_delta now.to_f, due.to_f, 0.001
    end
    assert_equal "awaiting_user", @session.reload.progress
    assert_equal 1, @session.oauth_tasks.count

    pending = AUTH::Transport::Delivery.new(status: 403,
      body: { error: "authorization_pending" }.to_json, reason: nil)
    AUTH::Transport.stub(:perform, pending) do
      due = AUTH::ContinueSession.call(@session.public_id, now: now)
      assert_in_delta (now + 5).to_f, due.to_f, 0.001
    end
    assert_equal 2, @session.oauth_tasks.count
    assert_no_difference -> { ModelProviderOAuthTask.count } do
      assert_nil AUTH::ContinueSession.call(@session.public_id, now: now + 1)
    end
  end

  test "duplicate in-flight wakes disabled lanes missing and terminal sessions do not send" do
    AUTH::Claim.call(session: @session)
    assert_no_difference -> { ModelProviderOAuthTask.count } do
      assert_nil AUTH::ContinueSession.call(@session.public_id)
      assert_nil AUTH::ContinueSession.call(SecureRandom.uuid_v7)
      ModelProviders::DisableLane.call(account: @account, provider_id: AUTH::PROVIDER_ID,
        expected_lock_version: @policy.lock_version)
      assert_nil AUTH::ContinueSession.call(@session.public_id)
      @session.terminalize(state: "revoked", outcome: "operator_revoked")
      assert_nil AUTH::ContinueSession.call(@session.public_id)
    end
  end

  test "the shallow job re-enqueues only the same public session when its owner reports a next action" do
    due = 5.seconds.from_now
    AUTH::ContinueSession.stub(:call, ->(id) { assert_equal @session.public_id, id; due }) do
      assert_enqueued_with(job: ModelProviderOAuthSessions::AdvanceJob, args: [@session.public_id], at: due) do
        ModelProviderOAuthSessions::AdvanceJob.perform_now(@session.public_id)
      end
    end
    AUTH::ContinueSession.stub(:call, nil) do
      assert_no_enqueued_jobs { ModelProviderOAuthSessions::AdvanceJob.perform_now(@session.public_id) }
    end
  end
end
