module PromptCacheSettingsJourney
  include ModelProviderSettingsJourney

  private

    def configure_prompt_cache(screenshot:)
      snapshot = ModelCatalog.current
      definitions = snapshot.model_definitions.merge(
        "cache-flexible" => { "capabilities" => { "generation_parameters" => {
          "prompt_cache_ttl" => { "allowed_values" => %w[30m 12h] },
        } } },
        "cache-short" => { "capabilities" => { "generation_parameters" => {
          "prompt_cache_ttl" => { "allowed_values" => ["30m"], "default" => "30m" },
        } } }
      )
      ModelCatalog.stub(:current, snapshot.with(model_definitions: definitions)) do
        sign_in_for_model_settings(users(:owner))
        visit new_admin_model_provider_model_definition_url("test_api")
        assert_no_select "Prompt cache lifetime"
        select "cache-flexible", from: "Model definition"
        assert_select "Prompt cache lifetime", options: ["Use request or provider default", "30 minutes", "12 hours"], selected: "Use request or provider default"
        select "12 hours", from: "Prompt cache lifetime"
        select "cache-short", from: "Model definition"
        assert_select "Prompt cache lifetime", options: ["Use request or provider default", "30 minutes"], selected: "30 minutes"
        select "cache-flexible", from: "Model definition"
        assert_select "Prompt cache lifetime", selected: "Use request or provider default"
        fill_in "Model ID", with: "cache-ui"
        click_button "Save model"
        assert_current_path admin_model_provider_path("test_api")
        click_link "Edit test_api/cache-ui"
        assert_select "Prompt cache lifetime", selected: "Use request or provider default"
        select "12 hours", from: "Prompt cache lifetime"
        assert_no_horizontal_overflow
        save_model_settings_screenshot("ttl-#{screenshot}", full_page: true)
        click_button "Save model"
        assert_current_path admin_model_provider_path("test_api")
        click_link "Edit test_api/cache-ui"
        assert_select "Prompt cache lifetime", selected: "12 hours"
        select "Use request or provider default", from: "Prompt cache lifetime"
        click_button "Save model"
        assert_current_path admin_model_provider_path("test_api")
        click_link "Edit test_api/cache-ui"
        assert_select "Prompt cache lifetime", selected: "Use request or provider default"
        assert_no_horizontal_overflow
        policy = ModelProviderConfig.find_by!(account: accounts(:cybros), provider_id: "test_api")
        saved = policy.override_entries.fetch("test_api/cache-ui").fetch("model")
        assert_equal "cache-flexible", saved.fetch("inherit")
        assert_equal({ "default" => nil }, saved.dig("capabilities", "generation_parameters", "prompt_cache_ttl"))
      end
    end
end
