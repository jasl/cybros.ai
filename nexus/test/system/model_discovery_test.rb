require "application_system_test_case"
require_relative "../test_helpers/model_provider_settings_journey"

class ModelDiscoveryTest < ApplicationSystemTestCase
  include ModelProviderSettingsJourney

  setup do
    @alias_ref = "test_api/friendly-alias"
    @alias_id = "provider-team/aliased-model"
    @new_id = "provider-team/new-model-with-a-long-name-for-directory-layout"
    saved = ModelProviders::UpsertModelOverride.call(
      account: accounts(:cybros), provider_id: "test_api", model_ref: @alias_ref,
      model: { "model_id" => @alias_id, "display_name" => "Saved alias name" },
      validate_definition: true, expected_lock_version: nil
    )
    assert_predicate saved, :done?
    @directory = ModelProviders::DiscoverModels::Result.new(outcome: :discovered, models: [
      { id: "text", display_name: "Existing text model" },
      { id: @alias_id, display_name: "Upstream alias name" },
      { id: @new_id, display_name: "New directory model" },
    ])
  end

  test "discovery edits configured models and prefills new models on desktop" do
    verify_discovery_actions(screenshot: "desktop")
  end

  test "discovery actions and long model IDs remain usable at 390 pixels" do
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
      width: 390, height: 844, deviceScaleFactor: 1, mobile: true)

    verify_discovery_actions(screenshot: "mobile-390")
    assert_equal 390, page.evaluate_script("window.innerWidth")
  ensure
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end

  private

    def verify_discovery_actions(screenshot:)
      sign_in_for_model_settings(users(:owner))
      ModelProviders::DiscoverModels.stub(:call, @directory) do
        fetch_directory
        within "#model-directory li[data-model-id='text']" do
          assert_text "Added"
          assert_link "Edit test_api/text", href: admin_model_provider_model_definition_path("test_api", model: "test_api/text")
          assert_no_link "Add text"
          assert_no_link "Add model", exact: true
        end
        within "#model-directory li[data-model-id='#{@alias_id}']" do
          assert_text "Added"
          assert_link "Edit #{@alias_ref}", href: admin_model_provider_model_definition_path("test_api", model: @alias_ref)
          assert_no_link "Add #{@alias_id}"
          assert_no_link "Add model", exact: true
          assert_operator find("p", text: @alias_id, exact_text: true).native.size.width, :>=, 250
        end
        within "#model-directory li[data-model-id='#{@new_id}']" do
          assert_no_text "Added"
          assert_link "Add #{@new_id}"
          assert_no_link "Edit model", exact: true
        end
        assert_no_horizontal_overflow
        save_model_settings_screenshot("discovery-#{screenshot}", full_page: true)

        click_link "Edit #{@alias_ref}"
        assert_current_path admin_model_provider_model_definition_path("test_api", model: @alias_ref)
        assert_selector "h1", text: "Edit model"
        assert_field "Model ID", with: @alias_id
        assert_field "Display name", with: "Saved alias name"
        assert_no_horizontal_overflow
        save_model_settings_screenshot("discovery-alias-#{screenshot}")

        fetch_directory
        click_link "Add #{@new_id}"
        assert_selector "h1", text: "Add model"
        assert_field "Model ID", with: @new_id
        assert_field "Display name", with: "New directory model"
        assert_button "Save model"
        assert_no_horizontal_overflow
        save_model_settings_screenshot("discovery-new-#{screenshot}")
      end
    end

    def fetch_directory
      visit admin_model_provider_model_discovery_url("test_api")
      click_button "Fetch model IDs"
      assert_selector "#model-directory [role=status]", text: "Model directory synced."
    end
end
