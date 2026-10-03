require "test_helper"

class ModelProviders::CodexAuthorization::TerminalResultsTest < ActiveSupport::TestCase
  AUTH = ModelProviders::CodexAuthorization

  setup do
    @account = accounts(:cybros)
    ModelProviders::EnableLane.call(
      account: @account, provider_id: AUTH::PROVIDER_ID, expected_lock_version: nil
    )
  end

  test "an unsupported poll interval records the refusal and closes its device session" do
    session = accept_session("device_start")
    task = AUTH::Claim.call(session: session).task
    outcome = AUTH::Responses.user_code(
      status: 200,
      body: { "device_auth_id" => "device-handle", "user_code" => "ABCD-EFGH", "interval" => "901" }.to_json
    )

    result = AUTH::ApplyDeviceStart.call(
      session: session, task: task, outcome: outcome, normalized_status: "http_200"
    )

    assert_equal :failed, result.outcome
    assert_equal "failed", session.reload.state
    assert_equal "unsupported_poll_interval", session.outcome
    assert_nil session.next_action_at
    assert_nil session.device_auth_id
    assert_nil session.user_code
    assert_equal "answered", task.reload.state
    assert_equal "terminal_unsupported_poll_interval", task.result_kind
    assert_equal "http_200", task.normalized_status
    assert_predicate task.settled_at, :present?
    assert_nil ModelProviderCredential.find_by(account: @account, provider_id: AUTH::PROVIDER_ID)
  end

  test "an invalidated refresh token records the refusal and requires reauthorization" do
    credential = ModelProviderCredential.create!(
      account: @account, provider_id: AUTH::PROVIDER_ID, material_kind: "oauth_tokens",
      secret: "old-access", refresh_secret: "old-refresh",
      authorization_lineage_id: SecureRandom.uuid, generation: 2, expires_at: 1.hour.from_now
    )
    session = accept_session("token_refresh")
    task = AUTH::Claim.call(session: session).task
    outcome = AUTH::Responses.token_refresh(
      status: 400, body: { "error" => { "code" => "refresh_token_invalidated" } }.to_json
    )

    result = AUTH::InstallCredential.call(
      session: session, task: task, outcome: outcome, normalized_status: "http_400"
    )

    assert_equal :failed, result.outcome
    assert_equal "failed", session.reload.state
    assert_equal "refresh_token_invalidated", session.outcome
    assert_nil session.next_action_at
    assert_equal "answered", task.reload.state
    assert_equal "terminal_refresh_token_invalidated", task.result_kind
    assert_equal "http_400", task.normalized_status
    assert_predicate task.settled_at, :present?
    assert_predicate credential.reload, :reauthorization_required?
    assert_equal "refresh_token_invalidated", credential.reauthorization_reason
    assert_equal "old-access", credential.secret
    assert_equal "old-refresh", credential.refresh_secret
    assert_equal 2, credential.generation
  end

  private

    def accept_session(kind)
      AUTH::AcceptSession.call(account: @account, issuing_user: users(:owner), kind: kind).session
    end
end
