require "application_system_test_case"

module RetentionSettingsJourney
  def change_retention
    sign_in_directly(users(:owner))
    visit admin_retention_url
    assert_title "Retention settings · Nexus"
    assert_field "Keep execution details for (days)", with: "90"
    assert_text "Conversation text remains readable and searchable."

    fill_in "Keep execution details for (days)", with: "180"
    click_button "Save retention settings"
    assert_text "Retention settings saved."
    assert_field "Keep execution details for (days)", with: "180"

    fill_in "Keep execution details for (days)", with: ""
    click_button "Save retention settings"
    assert_text "Retention settings saved."
    assert_field "Keep execution details for (days)", with: ""
    assert_nil accounts(:cybros).reload.execution_details_retention_days
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
