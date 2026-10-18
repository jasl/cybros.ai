require "application_system_test_case"

class SettingsJourneyTest < ApplicationSystemTestCase
  test "settings navigate within one frame and render write errors as a full page" do
    member = users(:member)
    sign_in_directly(member)

    visit root_url
    visit settings_url
    assert_title "Settings · Nexus"

    within "turbo-frame#settings" do
      assert_field "Display name", with: member.display_name
      click_link "Email"
      assert_current_path settings_email_path
      assert_title "Settings · Nexus"
      fill_in "Email", with: "new@example.com"
      fill_in "Current password", with: "wrong"
      click_button "Change email"
    end

    assert_text "Current password is invalid"
    assert_field "Email", with: "new@example.com"
    assert_no_field "Display name"

    within "turbo-frame#settings" do
      click_link "Profile"
      assert_current_path settings_path
      assert_field "Display name", with: member.display_name
      assert_no_text "Current password is invalid"
    end
    page.go_back
    assert_current_path root_path
    assert_equal member.identity.email, member.identity.reload.email
  end

  test "a settings write refreshes the outer account shell" do
    member = users(:member)
    sign_in_directly(member)
    visit root_url
    within("aside") { click_link "Settings" }
    assert_text "Manage your profile, sign-in credentials, and active sessions."

    fill_in "Display name", with: "Renamed Member"
    click_button "Save"

    assert_text "Profile updated."
    open_user_menu
    within "aside details .dropdown-content" do
      assert_selector "p.font-medium", text: "Renamed Member", exact_text: true
      assert_no_selector "p.font-medium", text: member.display_name, exact_text: true
    end

    close_user_menu_by_outside_click
    within "turbo-frame#settings" do
      click_link "Email"
    end
    assert_no_text "Profile updated."
  end

  test "an expired session breaks out of the settings frame to sign in" do
    member = users(:member)
    sign_in_directly(member)
    visit settings_url
    member.identity.sessions.order(:id).last.destroy!

    within "turbo-frame#settings" do
      click_link "Email"
    end

    assert_current_path new_session_path(return_to: settings_email_path)
    assert_field "Email"
    assert_no_text "Content missing"
  end
end
