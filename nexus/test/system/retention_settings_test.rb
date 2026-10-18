require "application_system_test_case"

module RetentionSettingsJourney
  def change_retention
    sign_in_directly(users(:owner))
    visit admin_retention_url
    assert_title "Retention settings · Nexus"
    assert_field "Keep execution details for (days)", with: "90"
    assert_text "Conversation text remains readable and searchable."

    fill_in "Keep execution details for (days)", with: "180"
    save_retention_settings
    assert_text "Retention settings saved."
    assert_field "Keep execution details for (days)", with: "180"
    assert_equal 180, accounts(:cybros).reload.execution_details_retention_days

    fill_in "Keep execution details for (days)", with: ""
    save_retention_settings
    assert_text "Retention settings saved."
    assert_field "Keep execution details for (days)", with: ""
    assert_nil accounts(:cybros).reload.execution_details_retention_days
  end

  private

    def save_retention_settings
      previous_body = find("body", visible: :all).native
      click_button "Save retention settings"
      # Both saves return the same notice and the fields already hold the typed
      # values. Wait for the returned page before treating either as saved.
      assert_selector("body", visible: :all) { |body| body.native != previous_body }
    end
end

class RetentionSettingsTest < ApplicationSystemTestCase
  include RetentionSettingsJourney

  test "an administrator changes retention on desktop" do
    change_retention
  end
end

class RetentionSettingsMobileTest < MobileSystemTestCase
  include RetentionSettingsJourney

  test "an administrator changes retention on a narrow screen" do
    change_retention
    assert page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth")
  end
end
