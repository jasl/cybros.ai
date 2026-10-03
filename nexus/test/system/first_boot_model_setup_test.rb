require "application_system_test_case"
require_relative "../test_helpers/first_boot_model_setup_journey"

class FirstBootModelSetupTest < ApplicationSystemTestCase
  include FirstBootModelSetupJourney

  setup do
    Account.destroy_all
  end

  test "dashboard tasks disappear as the founding owner configures models and connects an agent" do
    configure_first_provider(screenshot: "desktop")
  end

  test "the dashboard remains usable before its setup tasks are complete" do
    found_installation
    visit workspaces_url
    assert_selector "h1", text: "Workspaces"
    visit root_url
    assert_selector "article[aria-label='Model provider setup']"
    assert_selector "article[aria-label='Agent connection']"
    assert_empty ModelProviderPolicy.where(account: Account.sole)
    assert_equal "USD", Account.sole.cost_unit

    visit setup_url
    assert_current_path root_path
    assert_equal 1, Account.count
  end

  test "advanced cost units expose validation errors and preserve the chosen value" do
    found_installation(screenshot: "desktop", cost_unit: "credits")
  end
end

class MobileFirstBootModelSetupTest < MobileSystemTestCase
  include FirstBootModelSetupJourney

  setup do
    Account.destroy_all
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
      width: 390, height: 844, deviceScaleFactor: 1, mobile: true)
  end

  test "first boot provider setup stays usable at 390 pixels" do
    configure_first_provider(screenshot: "mobile-390")
    assert_equal 390, page.evaluate_script("window.innerWidth")
  end

  test "advanced cost unit errors remain editable at 390 pixels" do
    found_installation(screenshot: "mobile-390", cost_unit: "credits")
  end
end
