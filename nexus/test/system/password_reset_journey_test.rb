require "application_system_test_case"

class PasswordResetJourneyTest < ApplicationSystemTestCase
  test "password reset submits and restores the login document policy" do
    identity = identities(:member)
    visit edit_password_url(token: identity.password_reset_token)
    assert_selector "meta[name=referrer][content=no-referrer]", visible: :all
    fill_in "New password", with: "ResetPassword123!"
    fill_in "Repeat new password", with: "ResetPassword123!"
    click_button "Save"
    assert_current_path new_session_path
    assert_selector "meta[name=referrer][content=same-origin]", visible: :all
    assert_selector "meta[name=referrer]", count: 1, visible: :all
    assert identity.reload.authenticate("ResetPassword123!")
    fill_in "Email", with: identity.email
    fill_in "Password", with: "ResetPassword123!"
    click_button "Sign in"
    assert_selector "main h1", text: "Overview"
  end
end
