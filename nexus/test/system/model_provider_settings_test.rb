require "application_system_test_case"
require_relative "../test_helpers/model_provider_settings_journey"

class ModelProviderSettingsTest < ApplicationSystemTestCase
  include ModelProviderSettingsJourney

  test "an administrator manages provider access and model visibility from settings" do
    configure_api_key_provider(screenshot: "desktop")
  end

  test "account cost unit is configured once through the settings entry point" do
    sign_in_for_model_settings(users(:owner))
    visit settings_url
    within "main" do
      click_link "Cost unit"
    end
    assert_title "Cost unit · Nexus"
    assert_field "Cost unit", with: "USD"
    fill_in "Cost unit", with: "USD"
    confirm_through_dialog { click_button "Set cost unit" }

    assert_text "USD"
    assert_no_field "Cost unit"
    assert_no_button "Set cost unit"
    assert_equal "USD", accounts(:cybros).reload.cost_unit
    page.refresh
    assert_text "USD"
    assert_no_button "Set cost unit"
    save_model_settings_screenshot("cost-unit")
  end

  test "ordinary members cannot enter provider administration" do
    sign_in_for_model_settings(users(:member))
    assert_no_link "Configure model providers"
    visit settings_url
    within "main" do
      assert_no_link "Model providers"
      assert_no_link "Cost unit"
    end

    visit admin_model_providers_url
    assert_no_link "Test API"
    assert_no_selector "h1", text: "Model providers"
    visit admin_model_provider_api_key_url("test_api")
    assert_no_field "API key"
    assert_no_button "Save"
    assert_nil provider_credential
  end
end

class MobileModelProviderSettingsTest < MobileSystemTestCase
  include ModelProviderSettingsJourney

  setup do
    # Chrome's desktop window has a minimum width above a phone viewport.
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
      width: 390, height: 844, deviceScaleFactor: 1, mobile: true)
  end

  test "provider forms and model actions stay usable at 390 pixels" do
    configure_api_key_provider(screenshot: "mobile-390")
    assert_equal 390, page.evaluate_script("window.innerWidth")
  end
end
