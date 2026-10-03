require "application_system_test_case"
require_relative "../test_helpers/model_provider_settings_journey"
require_relative "../test_helpers/custom_model_settings_journey"

class CustomModelSettingsTest < ApplicationSystemTestCase
  include CustomModelSettingsJourney

  test "an administrator adds and edits a provider and model without pricing" do
    configure_custom_model(screenshot: "desktop")
  end
end

class MobileCustomModelSettingsTest < MobileSystemTestCase
  include CustomModelSettingsJourney

  setup do
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
      width: 390, height: 844, deviceScaleFactor: 1, mobile: true)
  end

  test "custom provider and model forms preserve manual entry at 390 pixels" do
    configure_custom_model(screenshot: "mobile-390")
    assert_equal 390, page.evaluate_script("window.innerWidth")
  end
end
