require "test_helper"

class LocalRecoveryTest < ActionDispatch::IntegrationTest
  setup do
    @member = users(:member)
    @identity = identities(:member)
    @mint = MemberRecoveryAuthorizations::Issue.call(user: @member)
  end

  test "login while the fence is pending reports local recovery" do
    post session_url, params: { email: @identity.email, password: "password" }

    assert_redirected_to new_session_path
    assert_equal I18n.t("sessions.create.local_recovery_required"), flash[:alert]
  end

  test "the public form renders for a current recovery secret" do
    get edit_password_path(token: @mint.secret)
    assert_response :success
  end

  test "a removed target's secret fails before rendering the form" do
    @member.remove

    get edit_password_path(token: @mint.secret)

    assert_redirected_to new_password_path
    assert_equal I18n.t("passwords.invalid_token"), flash[:alert]
  end

  test "a suspended target's secret fails before rendering the form" do
    @member.suspend

    get edit_password_path(token: @mint.secret)

    assert_redirected_to new_password_path
    assert_equal I18n.t("passwords.invalid_token"), flash[:alert]
  end

  test "consuming the secret changes the password, clears the fence, and creates no session" do
    assert_no_difference -> { Session.count } do
      put passwords_path, params: {
        token: @mint.secret, password: "a brand new password", password_confirmation: "a brand new password",
      }
    end

    assert_redirected_to new_session_path
    @identity.reload
    assert_not @identity.local_recovery_pending?
    assert @identity.authenticate("a brand new password")

    post session_url, params: { email: @identity.email, password: "a brand new password" }
    assert_redirected_to root_url
  end

  test "a superseded secret renders the same safe failure as an invalid token" do
    MemberRecoveryAuthorizations::Issue.call(user: @member)

    get edit_password_path(token: @mint.secret)
    assert_redirected_to new_password_path
    assert_equal I18n.t("passwords.invalid_token"), flash[:alert]
  end

  test "an unknown recovery-prefixed secret fails safely" do
    get edit_password_path(token: "rc-cybros-unknown")
    assert_redirected_to new_password_path
  end

  test "an emailed reset token cannot clear a pending fence" do
    token = @identity.password_reset_token

    get edit_password_path(token: token)
    assert_redirected_to new_password_path
    assert @identity.reload.local_recovery_pending?
  end
end
