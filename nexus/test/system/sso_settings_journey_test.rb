require "application_system_test_case"

class SsoSettingsJourneyTest < ApplicationSystemTestCase
  test "an administrator prepares a GitLab application using the configured callback" do
    sign_in_directly users(:owner)
    visit admin_sso_providers_path
    click_link "Add sign-in provider"
    fill_in "Display name", with: "Corporate GitLab"
    fill_in "Issuer or provider base URL", with: "https://gitlab.example.test"
    click_button "Save configuration"
    assert_selector "h1", text: "Corporate GitLab"
    provider = accounts(:cybros).sso_providers.find_by!(name: "Corporate GitLab")
    assert_text "/sso/providers/#{provider.public_id}/callback"
    assert_button "Test connection", disabled: true
    click_link "Edit configuration"
    fill_in "Client ID", with: "example-client"
    fill_in "Client secret", with: "example-secret"
    click_button "Save configuration"
    assert_button "Test connection"
    assert_button "Enable", disabled: true
  end
end

class MobileSsoSettingsJourneyTest < MobileSystemTestCase
  test "a member sees their retained session and protected last sign-in method" do
    user = users(:member)
    sign_in_directly user
    provider = user.account.sso_providers.create!(name: "Company identity", protocol: "oidc",
      issuer: "https://example.test", enabled: true, tested_at: Time.current)
    provider.sso_connections.create!(identity: user.identity, subject: "17", display_name: "Member")
    user.account.update!(sso_only: true)
    visit settings_sso_connections_path
    assert_selector "h2", text: "Sign-in methods"
    assert_text "Connected as Member"
    assert_button "Disconnect", disabled: true
    assert_text "This is your last sign-in method."
  end
end
