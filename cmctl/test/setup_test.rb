require_relative "test_helper"

class SetupTest < OperatorTest
  class Terminal < StringIO
    def tty? = true
    def noecho
      yield self
    end
  end

  def test_first_run_configures_key_and_provider_without_requiring_prices_or_saving_admin_credentials
    saved_session
    before = File.read(File.join(@home, "session.json"))
    sign_in_answers
    providers_answer(configured: false)
    provider_answer(configured: true)
    provider_answer(configured: true)
    provider_answer(configured: true, enabled: true, lock_version: 0)
    models_answer
    sign_out_answer

    assert run_setup("owner@example.test\n password-secret \n1\nprovider-secret\nn\n")
    assert_equal " password-secret ", request_for(:post, "/session").fetch(:body).fetch("password")
    assert_equal before, File.read(File.join(@home, "session.json"))
    assert_equal ["session.json"], Dir.children(@home)
    assert_equal "provider-secret", request_for(:put, "/api_key").fetch(:body).dig("command", "api_key")
    assert_equal true, request_for(:put, "/lane").fetch(:body).dig("command", "enabled")
    assert_empty @transport.requests.select { |request| request.fetch(:path).end_with?("/cost_unit") }
    assert_revoke_last
    %w[password-secret provider-secret synthetic-session-secret].each do |secret|
      refute_includes @output.string, secret
      refute_includes @error.string, secret
    end
    assert_includes @output.string, "No paid model request"
  end

  def test_rerun_keeps_existing_cost_unit_key_and_enabled_lane
    sign_in_answers
    providers_answer(configured: true, enabled: true)
    provider_answer(configured: true, enabled: true)
    models_answer
    sign_out_answer

    assert run_setup("owner@example.test\npassword\n1\n1\nn\n")
    assert_empty @transport.requests.select { |request| request.fetch(:method) == :put }
    assert_empty @transport.requests.select { |request| request.fetch(:path).end_with?("/cost_unit") }
    assert_revoke_last
  end

  def test_non_admin_login_is_revoked_before_any_provider_read_or_write
    sign_in_answers(role: "member")
    sign_out_answer

    error = assert_raises(CybrosControl::Error) { run_setup("member@example.test\npassword\n") }
    assert_includes error.message, "administrator"
    assert_equal 3, @transport.requests.length
    assert_revoke_last
    refute @config.present?
  end

  def test_interrupt_after_a_completed_key_write_keeps_the_write_and_revokes_login
    sign_in_answers
    providers_answer(configured: false)
    provider_answer(configured: true)
    provider_answer(configured: true, enabled: true)
    sign_out_answer

    assert_raises(CybrosControl::Cancelled) { run_setup("owner@example.test\npassword\n1\nnew-key\n") }
    assert request_for(:put, "/api_key")
    assert_revoke_last
    assert_equal 1, @transport.requests.count { |request| request.fetch(:path).end_with?("/api_key") }
  end

  def test_conflicting_lane_write_is_not_retried_and_the_login_is_revoked
    sign_in_answers
    providers_answer(configured: true)
    provider_answer(configured: true, lock_version: 2)
    @transport.answer(409, { "error" => { "code" => "stale_object", "message" => "untrusted-secret" } })
    sign_out_answer

    assert_raises(CybrosAgent::Api::Conflict) { run_setup("owner@example.test\npassword\n1\n1\n") }
    assert_equal 2, request_for(:put, "/lane").fetch(:body).dig("command", "expected_lock_version")
    assert_equal 1, @transport.requests.count { |request| request.fetch(:path).end_with?("/lane") }
    refute_includes @output.string, "untrusted-secret"
    assert_revoke_last
  end

  def test_failed_logout_is_reported_without_claiming_revocation_or_printing_the_token
    sign_in_answers
    providers_answer
    models_answer
    @transport.answer(503, nil)

    assert run_setup("owner@example.test\npassword\n2\nn\n")
    assert_includes @error.string, "Could not revoke"
    refute_includes @error.string, TOKEN
    refute @config.present?
  end

  def test_pending_subscription_is_resumed_without_another_start
    subscription_answers
    authorization_answer(session: oauth_session)
    session_answer(oauth_session)
    session_answer(oauth_session.merge("state" => "completed", "outcome" => "authorized", "user_code" => nil))
    models_answer
    sign_out_answer

    assert run_setup("owner@example.test\npassword\n1\nn\n")
    assert_includes @output.string, "Enter code: ABCD-EFGH"
    assert_equal 1, @output.string.scan("Enter code:").length
    assert_includes @output.string, "Subscription connected"
    assert_empty @transport.requests.select { |request| request.fetch(:method) == :post && request.fetch(:path).end_with?("/authorization") }
    assert_revoke_last
  end

  def test_another_administrators_pending_login_is_preserved_by_default
    subscription_answers
    authorization_answer(session: oauth_session.merge("owned_by_current_user" => false, "user_code" => nil))
    models_answer
    sign_out_answer

    assert run_setup("owner@example.test\npassword\n1\n\nn\n")
    assert_empty @transport.requests.select { |request| request.fetch(:method) == :post && request.fetch(:path).end_with?("/authorization") }
    refute_includes @output.string, "Enter code:"
  end

  def test_fresh_subscription_starts_once_then_reads_status_until_complete
    subscription_answers
    authorization_answer(state: "missing", session: nil)
    @transport.answer(202, { "authorization_session" => oauth_session.merge("user_code" => nil) })
    session_answer(oauth_session)
    session_answer(oauth_session.merge("state" => "completed", "outcome" => "authorized"))
    models_answer
    sign_out_answer

    assert run_setup("owner@example.test\npassword\n1\nn\n")
    writes = @transport.requests.select { |request| request.fetch(:method) == :post && request.fetch(:path).end_with?("/authorization") }
    assert_equal 1, writes.length
    assert_equal false, writes.first.fetch(:body).dig("command", "restart")
    assert_includes @output.string, "Enter code: ABCD-EFGH"
  end

  def test_expired_provider_login_exits_with_resume_guidance_and_revokes_human_login
    subscription_answers
    authorization_answer(session: oauth_session)
    session_answer(oauth_session.merge("state" => "expired", "outcome" => "authorization_deadline_exceeded", "user_code" => nil))
    sign_out_answer

    error = assert_raises(CybrosControl::Error) { run_setup("owner@example.test\npassword\n1\n") }
    assert_includes error.message, "authorization_deadline_exceeded"
    assert_revoke_last
  end

  def test_explicit_reauthorization_waits_for_its_session_even_when_an_old_credential_exists
    subscription_answers
    authorization_answer(state: "authorized", session: nil)
    @transport.answer(202, { "authorization_session" => oauth_session })
    session_answer(oauth_session)
    session_answer(oauth_session.merge("state" => "completed", "outcome" => "authorized"))
    models_answer
    sign_out_answer

    assert run_setup("owner@example.test\npassword\n1\n2\nn\n")
    assert_equal true, request_for(:post, "/authorization").fetch(:body).dig("command", "restart")
    reads = @transport.requests.select { |request| request.fetch(:path).end_with?("/sessions/auth-1") }
    assert_equal 2, reads.length
    assert_includes @output.string, "Subscription connected"
  end

  def test_failed_start_response_is_not_automatically_reposted
    subscription_answers
    authorization_answer(state: "missing", session: nil)
    @transport.answer(503, nil)
    sign_out_answer

    assert_raises(CybrosAgent::Error) { run_setup("owner@example.test\npassword\n1\n") }
    assert_equal 1, @transport.requests.count { |request| request.fetch(:path).end_with?("/authorization") && request.fetch(:method) == :post }
    assert_revoke_last
  end

  def test_available_models_without_prices_are_reported_as_usable
    sign_in_answers
    providers_answer
    @transport.answer(200, { "models" => [{ "ref" => "example/chat", "provider" => "example", "workload" => "text_generation",
      "available" => true, "visible" => true, "capabilities" => { "tool_calls" => true }, "pricing" => { "state" => "cost_unknown" } }] })
    sign_out_answer

    assert run_setup("owner@example.test\npassword\n2\nn\n")
    assert_includes @output.string, "Available tool-calling models: 1"
  end

  def test_setup_refuses_a_pipe_before_authentication_and_leaves_saved_cmctl_session_alone
    saved_session
    assert_equal 2, run_cli("setup", "--url", "http://localhost:3000", input: "owner@example.test\npassword\n")
    assert_empty @transport.requests
    assert_equal TOKEN, @config.read.token
    assert_includes @error.string, "interactive terminal"
  end

  private

    def run_setup(input)
      @output = Terminal.new
      @error = StringIO.new
      CybrosControl::Setup.new(url: "http://localhost:3000", input: Terminal.new(input), output: @output, error: @error,
        sessions: ->(url) { CybrosAgent::Sessions.new(base_url: url, transport: @transport) },
        clients: ->(url, token) { CybrosAgent::PlatformClient.new(base_url: url, credential: token, transport: @transport) },
        sleeper: ->(_seconds) { }).run
    end

    def sign_in_answers(role: "owner")
      @transport.answer(201, { "token" => TOKEN, "token_type" => "Bearer", "session" => SESSION })
      @transport.answer(200, profile(role: role))
    end

    def providers_answer(**fields)
      @transport.answer(200, { "model_providers" => [lane.merge(fields.transform_keys(&:to_s))] })
    end

    def provider_answer(**fields)
      @transport.answer(200, { "model_provider" => lane.merge(fields.transform_keys(&:to_s)) })
    end

    def subscription_answers
      sign_in_answers
        providers_answer(credentials: "oauth_tokens", configured: false, enabled: true)
      provider_answer(credentials: "oauth_tokens", configured: false, enabled: true)
    end

    def oauth_session
      { "public_id" => "auth-1", "kind" => "device_start", "state" => "pending", "progress" => "awaiting_user",
        "outcome" => nil, "expires_at" => "2026-10-01T00:00:00Z", "verification_uri" => "https://auth.openai.com/codex/device",
        "user_code" => "ABCD-EFGH", "owned_by_current_user" => true }
    end

    def authorization_answer(state: "pending", session:)
      @transport.answer(200, { "authorization" => { "provider_id" => "example", "state" => state, "expires_at" => nil, "session" => session } })
    end

    def models_answer
      @transport.answer(200, { "models" => [] })
    end

    def session_answer(session)
      @transport.answer(200, { "authorization_session" => session })
    end

    def sign_out_answer
      @transport.answer(200, { "revoked" => true })
    end

    def request_for(method, suffix)
      @transport.requests.find { |request| request.fetch(:method) == method && request.fetch(:path).end_with?(suffix) } ||
        flunk("Missing #{method} request to #{suffix}")
    end

    def assert_revoke_last
      assert_equal :delete, @transport.requests.last.fetch(:method)
      assert_equal "/api/v1/session", @transport.requests.last.fetch(:path)
    end
end
