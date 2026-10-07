require "application_system_test_case"
require_relative "../test_helpers/first_boot_model_setup_journey"

class SetupSecretTest < ApplicationSystemTestCase
  include FirstBootModelSetupJourney

  setup do
    Account.destroy_all
    @previous_setup_secret = ENV["NEXUS_SETUP_SECRET"]
    @setup_secret = "a" * 64
    ENV["NEXUS_SETUP_SECRET"] = @setup_secret
  end

  teardown do
    ENV["NEXUS_SETUP_SECRET"] = @previous_setup_secret
  end

  test "the installation link survives validation corrections without retaining the secret in the URL" do
    visit "#{setup_url}#setup_secret=#{@setup_secret}"
    assert_field "Setup secret", with: @setup_secret
    assert_nil URI.parse(page.current_url).fragment
    assert_first_boot_fits_viewport

    fill_founder_details
    fill_in "Repeat password", with: "mismatched confirmation"
    click_button "Create installation"

    assert_selector "[role=alert]", text: "Some fields need attention"
    assert_field "Setup secret", with: @setup_secret
    assert_nil URI.parse(page.current_url).fragment
    assert_equal 0, Account.count

    fill_founder_details
    click_button "Create installation"
    assert_setup_completed_without_secret
  end

  test "an incorrect installation secret remains editable at 390 pixels and cannot create the account" do
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
      width: 390, height: 844, deviceScaleFactor: 1, mobile: true)
    wrong_secret = "b" * 64
    visit "#{setup_url}#setup_secret=#{wrong_secret}"
    assert_field "Setup secret", with: wrong_secret
    assert_nil URI.parse(page.current_url).fragment
    assert_first_boot_fits_viewport

    fill_founder_details
    click_button "Create installation"

    assert_selector "[role=alert]", text: "The setup secret is incorrect."
    assert_field "Setup secret", with: wrong_secret
    assert_equal 0, Account.count
    assert_first_boot_fits_viewport

    fill_founder_details
    fill_in "Setup secret", with: @setup_secret
    click_button "Create installation"
    assert_setup_completed_without_secret
  end

  private

    def assert_setup_completed_without_secret
      assert_current_path root_path
      assert_selector "h1", text: "Dashboard"
      assert_equal "founder@first-boot.test", Account.sole.owner.email
      assert_no_field "Setup secret"
      refute_includes page.html, @setup_secret
      assert_nil URI.parse(page.current_url).fragment
      refute_includes page.evaluate_script("JSON.stringify(sessionStorage)"), @setup_secret
      refute_includes page.evaluate_script("JSON.stringify(localStorage)"), @setup_secret
    end
end
