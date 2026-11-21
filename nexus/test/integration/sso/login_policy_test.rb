require "test_helper"

class EnterpriseLoginPolicyTest < ActionDispatch::IntegrationTest
  setup do
    @account = accounts(:cybros)
    @member = users(:member)
    @identity = @member.identity
    @provider = @account.sso_providers.create!(name: "Staff", protocol: "oidc",
      issuer: "https://staff.example.test", enabled: true, tested_at: Time.current)
    @account.users.active.where(kind: :human).each do |user|
      @provider.sso_connections.create!(identity: user.identity, subject: user.public_id)
    end
  end

  test "SSO-only rejects new password logins, keeps issued sessions, and honors member suspension" do
    sign_in_as @member
    post api_v1_session_path, params: { email: @identity.email, password: "password" }, as: :json
    assert_response :created
    headers = { "Authorization" => "Bearer #{response.parsed_body.fetch("token")}" }
    require_sso
    get settings_tokens_path
    assert_response :success
    assert_select "input[name='token[current_password]']", count: 0
    get api_v1_session_path, headers: headers
    assert_response :success
    assert_no_difference -> { Session.count } do
      [@identity.email, "unknown@example.test"].each do |email|
        post api_v1_session_path, params: { email: email, password: "password" }, as: :json
        assert_response :forbidden
        assert_equal "sso_required", response.parsed_body.dig("error", "code")
      end
      open_session do |guest|
        guest.post session_path, params: { email: @identity.email, password: "password" }
        guest.assert_redirected_to new_session_path
      end
    end
    assert_equal :suspended, @member.suspend
    get api_v1_session_path, headers: headers
    assert_response :unauthorized
    get settings_tokens_path
    assert_redirected_to new_session_path(return_to: settings_tokens_path)
  end

  test "old password reset links and direct password invitation submissions obey the new policy" do
    token = @identity.password_reset_token
    invitation = @account.invitations.create!(email: "invited@example.test", inviter: users(:owner), role: :member)
    require_sso
    assert_no_changes -> { @identity.reload.password_digest } do
      put passwords_path, params: { token: token, password: "new password", password_confirmation: "new password" }
      assert_redirected_to new_password_path
    end
    assert_equal :not_recoverable, MemberRecoveryAuthorizations::Issue.call(user: @member).outcome
    assert_no_difference [-> { Identity.count }, -> { Invitation.count }, -> { Session.count }] do
      post join_path, params: { token: invitation.acceptance_token,
        acceptance: { display_name: "Invitee", password: "new password", password_confirmation: "new password" } }
      assert_response :unprocessable_entity
    end
    assert_select "form[action=?]", sso_start_path(@provider)
    assert_select "input[type=password]", count: 0
  end

  test "a reconnection capability cannot set a password, including in mixed mode" do
    recovery = MemberRecoveryAuthorizations::Issue.call(user: @member, purpose: :sso_connection, lost_sso_provider: @provider)
    assert_equal :issued, recovery.outcome
    assert_no_changes -> { @identity.reload.password_digest } do
      put passwords_path, params: { token: recovery.secret, password: "new password", password_confirmation: "new password" }
      assert_redirected_to new_password_path
    end
    assert recovery.authorization.reload.consumable?
    assert @identity.reload.local_recovery_pending?
  end

  test "requesting SSO recovery without any enabled provider leaves a working password intact" do
    assert @provider.set_enabled(false, expected_version: @provider.lock_version)
    assert_equal :not_recoverable, MemberRecoveryAuthorizations::Issue.call(user: @member, purpose: :sso_connection).outcome
    assert_not @identity.reload.local_recovery_pending?
    sign_in_as @member
  end

  test "a suspended member without an allowed method requires explicit restoration for reconnection" do
    assert_equal :suspended, @member.suspend
    @identity.sso_connections.sole.destroy!
    require_sso
    assert_equal :login_method_required, @member.reactivate
    assert @member.reload.suspended?
    assert_equal :restored_for_recovery, @member.reactivate(reconnect: true)
    assert @member.reload.active?
    assert @identity.reload.local_recovery_pending?
    assert_equal :issued, MemberRecoveryAuthorizations::Issue.call(user: @member, purpose: :sso_connection).outcome
  end

  private

    def require_sso
      assert SsoProvider.set_policy(@account, sso_only: true)
    end
end
