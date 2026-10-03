module CustomModelSettingsJourney
  include ModelProviderSettingsJourney

  private

    def configure_custom_model(screenshot:)
      sign_in_for_model_settings(users(:owner))
      visit admin_model_providers_url
      click_link "Add provider"
      fill_in "Provider ID", with: "local-browser"
      fill_in "Display name", with: "Local browser models"
      fill_in "Base URL", with: "http://localhost:11434/v1"
      select "OpenAI-compatible Chat", from: "Protocol"
      select "No authentication", from: "Authentication"
      assert_no_horizontal_overflow
      save_model_settings_screenshot("custom-#{screenshot}-provider")
      click_button "Add provider"
      assert_current_path admin_model_provider_path("local-browser")
      assert_text "Local browser models"
      click_link "Add model"
      fill_in "Model ID", with: "my-team/long-model-name-for-a-local-endpoint"
      fill_in "Display name", with: "Local assistant"
      click_link "Discover model IDs"
      assert_button "Fetch model IDs"
      failure = ModelProviders::DiscoverModels::Result.new(outcome: :discovery_failed, models: [])
      ModelProviders::DiscoverModels.stub(:call, failure) do
        click_button "Fetch model IDs"
        assert_text "Model discovery did not complete"
      end
      assert_field "Model ID", with: "my-team/long-model-name-for-a-local-endpoint"
      assert_field "Display name", with: "Local assistant"
      find("summary", text: "Context and capabilities").click
      fill_in "Input token limit", with: "32768"
      select "Disabled", from: "Tool calls"
      assert_no_horizontal_overflow
      save_model_settings_screenshot("custom-#{screenshot}-model")
      click_button "Save model"
      assert_current_path admin_model_provider_path("local-browser")
      assert_text "local-browser/my-team/long-model-name-for-a-local-endpoint"
      click_button "Enable provider"
      within "#provider-models" do
        assert_text "Available"
      end
      assert_text "No cost estimate configured"
      click_link "Edit local-browser/my-team/long-model-name-for-a-local-endpoint"
      assert_field "Display name", with: "Local assistant"
      fill_in "Display name", with: "Renamed local assistant"
      click_button "Save model"
      assert_current_path admin_model_provider_path("local-browser")
      click_link "Edit connection"
      fill_in "Display name", with: "My local provider"
      click_button "Save connection"
      assert_text "My local provider"
      assert_no_horizontal_overflow
      save_model_settings_screenshot("custom-#{screenshot}-overview", full_page: true)
      policy = ModelProviderPolicy.find_by!(account: accounts(:cybros), provider_id: "local-browser")
      assert_predicate policy, :enabled?
      model = policy.override_entries.fetch("local-browser/my-team/long-model-name-for-a-local-endpoint").fetch("model")
      assert_equal "Renamed local assistant", model.fetch("display_name")
      assert_equal 32768, model.dig("capabilities", "limits", "input_tokens")
      assert_equal false, model.dig("capabilities", "tool_calls")
      assert_nil model["pricing"]
    end
end
