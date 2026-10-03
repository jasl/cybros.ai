require "test_helper"

class ModelProviderOAuthSessions::AdvanceJobTest < ActiveJob::TestCase
  AUTH = ModelProviders::CodexAuthorization

  # Preserve HTTPX's real response semantics: a received 403 has an HTTPError
  # even though it is the ordinary pending answer in the device ceremony.
  class ProviderClient
    def initialize(replies)
      @replies = replies
      @responses = []
    end

    attr_reader :responses

    def post(url, headers:, body:)
      status, document = @replies.shift || raise("unexpected provider request")
      request = HTTPX::Session.new.build_request("POST", url, headers: headers, body: body)
      response = HTTPX::Response.new(request, status, "1.1", { "content-type" => "application/json" })
      response << document.to_json
      @responses << response
      response
    end

    def close
      @responses.each(&:close)
    end
  end

  setup do
    @account = accounts(:cybros)
    ModelProviders::EnableLane.call(account: @account, provider_id: AUTH::PROVIDER_ID,
      expected_lock_version: nil)
    @session = AUTH::AcceptSession.call(account: @account, issuing_user: users(:owner), kind: "device_start").session
  end

  teardown do
    @client&.close
  end

  test "queued continuation advances through pending grant and credential exchange" do
    now = Time.current.change(usec: 0)
    travel_to now
    @session.update!(next_action_at: now)
    @client = ProviderClient.new([
      [200, { device_auth_id: "device", user_code: "TEST-CODE", interval: "5" }],
      [403, { error: "authorization_pending" }],
      [200, { authorization_code: "code", code_challenge: "challenge", code_verifier: "verifier" }],
      [200, { id_token: "h.e30.s", access_token: "access", refresh_token: "refresh", expires_in: 3600 }],
    ])

    AUTH::Transport.stub(:default_client, @client) do
      perform_enqueued_jobs(only: ModelProviderOAuthSessions::AdvanceJob, at: now) do
        ModelProviderOAuthSessions::AdvanceJob.perform_later(@session.public_id)
      end

      assert_equal "polling", @session.reload.progress
      assert_equal now + 5, @session.next_action_at
      assert_equal %w[user_code_issued authorization_pending], @session.oauth_tasks.order(:id).pluck(:result_kind)
      assert_enqueued_with(job: ModelProviderOAuthSessions::AdvanceJob, args: [@session.public_id], at: now + 5)
      assert_equal 0, ModelProviderCredential.count

      travel 5.seconds
      # Flush the recorded future job while also performing the successors
      # it enqueues; the blockless helper alone takes only the current queue.
      perform_enqueued_jobs(only: ModelProviderOAuthSessions::AdvanceJob) do
        perform_enqueued_jobs(only: ModelProviderOAuthSessions::AdvanceJob)
      end
    end

    assert_predicate @session.reload, :completed?
    assert_equal "authorized", @session.outcome
    assert_equal "access", ModelProviderCredential.sole.secret
    assert_equal %w[user_code_request device_token_poll device_token_poll code_exchange],
      @session.oauth_tasks.order(:id).pluck(:exchange_kind)
    assert_empty @session.oauth_tasks.dispatching
    assert_no_enqueued_jobs(only: ModelProviderOAuthSessions::AdvanceJob)
    assert_equal 4, @client.responses.length
  end

  test "a received unsupported device response fails without scheduling another request" do
    @client = ProviderClient.new([[404, { error: "not_enabled" }]])

    AUTH::Transport.stub(:default_client, @client) do
      perform_enqueued_jobs(only: ModelProviderOAuthSessions::AdvanceJob) do
        ModelProviderOAuthSessions::AdvanceJob.perform_later(@session.public_id)
      end
    end

    assert_predicate @session.reload, :failed?
    assert_equal "device_code_not_enabled", @session.outcome
    assert_equal "http_404", @session.oauth_tasks.sole.normalized_status
    assert_equal 0, ModelProviderCredential.count
    assert_no_enqueued_jobs(only: ModelProviderOAuthSessions::AdvanceJob)
    assert_equal 1, @client.responses.length
  end

  test "recurring recovery restores the precise chain after a busy wake" do
    claim = AUTH::Claim.call(session: @session)
    assert_predicate claim, :claimed?
    assert_no_enqueued_jobs do
      ModelProviderOAuthSessions::AdvanceJob.perform_now(@session.public_id)
    end
    assert_equal 1, @session.oauth_tasks.count

    # The overlapping worker lands its claimed response after the busy wake
    # exits. Recovery must continue this row without waiting a minute per phase.
    AUTH::ApplyDeviceStart.call(session: @session, task: claim.task,
      outcome: AUTH::Responses.user_code(status: 200,
        body: { device_auth_id: "device", user_code: "TEST-CODE", interval: "5" }.to_json),
      normalized_status: "http_200")
    @client = ProviderClient.new([
      [200, { authorization_code: "code", code_challenge: "challenge", code_verifier: "verifier" }],
      [200, { id_token: "h.e30.s", access_token: "access", refresh_token: "refresh", expires_in: 3600 }],
    ])

    AUTH::Transport.stub(:default_client, @client) do
      perform_enqueued_jobs(only: ModelProviderOAuthSessions::AdvanceJob) do
        ModelProviderOAuthSessions::AdvanceDueJob.perform_now
      end
    end

    assert_predicate @session.reload, :completed?
    assert_equal "authorized", @session.outcome
    assert_equal "access", ModelProviderCredential.sole.secret
    assert_equal %w[user_code_request device_token_poll code_exchange],
      @session.oauth_tasks.order(:id).pluck(:exchange_kind)
    assert_empty @session.oauth_tasks.dispatching
    assert_no_enqueued_jobs(only: ModelProviderOAuthSessions::AdvanceJob)
    assert_equal 2, @client.responses.length
  end
end
