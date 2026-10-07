require "application_system_test_case"

class AuthenticationJourneyTest < ApplicationSystemTestCase
  setup do
    @user = users(:member)
  end

  test "history stays correct while signed in and after signing out" do
    visit root_url
    assert_field "Email"

    fill_in "Email", with: @user.email
    fill_in "Password", with: "password"
    click_button "Sign in"

    assert_text "Signed in as #{@user.email}"
    within "aside" do
      assert_link "Dashboard"
    end

    # The login page redirects authenticated visitors, so history back lands
    # on the dashboard again instead of a stale unauthenticated form.
    navigate_history(to: root_path) { page.go_back }
    assert_text "Signed in as #{@user.email}"

    navigate_history(to: root_path) { page.go_forward }
    assert_text "Signed in as #{@user.email}"

    open_user_menu
    click_button "Sign out"
    assert_field "Email"

    navigate_history(to: new_session_path(return_to: root_path)) { page.go_back }
    assert_field "Email"
    assert_no_text "Signed in as"
  end

  private

    def navigate_history(to:)
      # These redirects render the same text as the page we are leaving. Wait
      # for the replacement and Turbo's completed visit before reading that text.
      previous_body = find("body").native
      yield
      assert_selector("html:not([aria-busy]) > body") { |body| body.native != previous_body }
      assert_current_path to
    end
end
