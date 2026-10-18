require "test_helper"
require_relative "../../../test_helpers/row_lock_test_helper"

# C2-OAuth: the transport's verdict and the one-step advance.
class ModelProviders::CodexAuthorization::AdvanceTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include RowLockTestHelper

  AUTH = ModelProviders::CodexAuthorization
  TRANSPORT = AUTH::Transport

  uses_transaction :test_a_disable_committed_before_claim_blocks_provider_IO

  # Stands in for HTTPX: answers with a response value or an error-shaped one,
  # exactly as HTTPX does rather than by raising.
  class FakeClient
    Response = Data.define(:status, :body, :error)

    def initialize(status: nil, body: nil, error: nil)
      @response = Response.new(status: status, body: body.to_s, error: error)
    end

    attr_reader :sent

    def post(url, headers:, body:)
      @sent = { url: url, headers: headers, body: body }
      @response
    end
  end

  setup do
    @account = accounts(:cybros)
    @policy_existed = ModelProviderConfig.exists?(
      account: @account, provider_id: AUTH::PROVIDER_ID
    )
    @policy = ModelProviders::EnableLane.call(
      account: @account, provider_id: "codex_subscription", expected_lock_version: nil
    ).policy
    @session = AUTH::AcceptSession.call(
      account: @account, issuing_user: users(:owner), kind: "device_start"
    ).session
  end

  # --- the transport's verdict -------------------------------------------

  # The HTTP client's verdict, consumed once: it answered, or it did not and
  # its own error class is the record. No allowlist of class names stands
  # between the client and the row.
  test "a client error is recorded under the client's own class name" do
    error = Class.new(StandardError)
    error.define_singleton_method(:name) { "HTTPX::ConnectTimeoutError" }

    outcome = perform(error: error.new("timed out"))

    refute_predicate outcome, :responded?
    assert_equal "HTTPX::ConnectTimeoutError", outcome.reason
  end

  test "a claim already past its deadline sends nothing" do
    outcome = TRANSPORT.perform(
      prepared: AUTH::Requests.user_code_request,
      deadline_at: Time.current, now: Time.current + 1, client: FakeClient.new(status: 200)
    )

    refute_predicate outcome, :responded?
    assert_equal ModelProviders::CodexAuthorization::InstallCredential::LATE_STATUS, outcome.reason
  end

  # --- the advance ---------------------------------------------------------

  test "one advance claims, sends, and applies" do
    client = FakeClient.new(status: 200, body: user_code_body)

    result = AUTH::Advance.call(session: @session, client: client)

    assert_predicate result, :advanced?
    assert_equal AUTH.user_code_url, client.sent.fetch(:url)
    session = @session.reload

    assert_equal "awaiting_user", session.progress
    assert_equal ModelProviderOAuthTask::ANSWERED, result.task.reload.state
  end

  test "a disabled lane refuses before a task or provider request" do
    ModelProviders::DisableLane.call(
      account: @account, provider_id: @policy.provider_id,
      expected_lock_version: @policy.lock_version
    )
    client = FakeClient.new(status: 200, body: user_code_body)

    assert_no_difference -> { ModelProviderOAuthTask.count } do
      result = AUTH::Advance.call(session: @session, client: client)

      assert_equal :session_not_pending, result.outcome
    end
    assert_nil client.sent
  end

  test "a disable committed before claim blocks provider IO" do
    count = ModelProviderOAuthTask.count
    held = hold_row_lock(
      ModelProviderConfig, @policy.id,
      before_commit: ->(policy) {
        ModelProviders::DisableLane.call(account: @account, provider_id: policy.provider_id,
          expected_lock_version: policy.lock_version)
      }
    )
    call = start_database_call { AUTH::Claim.call(session: @session.reload) }

    wait_until_waiting_on_lock(call.pid)
    release_row_lock(held)
    held = nil
    result = finish_database_call(call)
    call = nil

    assert_equal :session_not_pending, result.outcome
    assert_equal count, ModelProviderOAuthTask.count
  ensure
    release_row_lock(held) if held
    stop_database_call(call) if call
    ModelProviderOAuthTask.where(model_provider_oauth_session_id: @session.id).delete_all
    ModelProviderOAuthSession.where(id: @session.id).delete_all
    if @policy_existed
      ModelProviderConfig.where(id: @policy.id).update_all(enabled: true)
    else
      ModelProviderConfig.where(id: @policy.id).delete_all
    end
  end

  # An unanswered step is a spent task on a still-pending session; the next
  # Advance claims a new row for the same step because the flow says a
  # user-code request is resendable (RFC 8628), never because a class name
  # was recognised.
  test "an unanswered user_code_request is resent by the next Advance" do
    refused = Class.new(StandardError)
    refused.define_singleton_method(:name) { "Errno::ECONNREFUSED" }

    result = AUTH::Advance.call(session: @session, client: FakeClient.new(error: refused.new))

    assert_equal :ambiguous, result.outcome
    task = result.task.reload

    assert_equal ModelProviderOAuthTask::SPENT, task.state
    assert_equal "Errno::ECONNREFUSED", task.normalized_status, "the client's verdict, not a restatement"
    assert_equal "pending", @session.reload.state

    retried = AUTH::Advance.call(
      session: @session.reload, client: FakeClient.new(status: 200, body: user_code_body)
    )

    assert_predicate retried, :advanced?
    assert_equal 2, @session.reload.oauth_tasks.count
  end

  test "the advance routes the installing phases to the credential suffix" do
    walk_to_code_exchange

    result = AUTH::Advance.call(
      session: @session.reload, client: FakeClient.new(status: 200, body: token_body)
    )

    assert_equal :installed, result.outcome
    assert_equal 1, ModelProviderCredential.where(account_id: @account.id).count
  end

  test "the due job wakes the precise continuation of the session it selected" do
    assert_enqueued_with(job: ModelProviderOAuthSessions::AdvanceJob, args: [@session.public_id]) do
      ModelProviderOAuthSessions::AdvanceDueJob.perform_now
    end
    assert_empty @session.oauth_tasks
  end

  private

    def perform(error:)
      TRANSPORT.perform(
        prepared: AUTH::Requests.user_code_request,
        deadline_at: 1.minute.from_now, client: FakeClient.new(error: error)
      )
    end

    def walk_to_code_exchange
      AUTH::Advance.call(session: @session, client: FakeClient.new(status: 200, body: user_code_body))
      AUTH::Advance.call(session: @session.reload, client: FakeClient.new(status: 200, body: grant_body))
    end

    def user_code_body
      { "device_auth_id" => "d", "user_code" => "RAWE-NUA2L", "interval" => "5" }.to_json
    end

    def grant_body
      { "authorization_code" => "ac", "code_challenge" => "cc", "code_verifier" => "cv" }.to_json
    end

    def token_body
      { "id_token" => "h.e30.s", "access_token" => "at", "refresh_token" => "rt",
        "expires_in" => 864_000 }.to_json
    end
end
