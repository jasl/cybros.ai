require "application_system_test_case"
require_relative "../test_helpers/model_provider_settings_journey"
require_relative "../test_helpers/prompt_cache_settings_journey"

class ModelPromptCacheSettingsTest < ApplicationSystemTestCase
  include PromptCacheSettingsJourney

  test "administrator selects and clears the model prompt cache lifetime" do
    configure_prompt_cache(screenshot: "desktop")
  end
end

class MobileModelPromptCacheSettingsTest < MobileSystemTestCase
  include PromptCacheSettingsJourney

  test "prompt cache lifetime can be edited at 390 pixels" do
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
      width: 390, height: 844, deviceScaleFactor: 1, mobile: true)
    configure_prompt_cache(screenshot: "mobile-390")
  end
end
