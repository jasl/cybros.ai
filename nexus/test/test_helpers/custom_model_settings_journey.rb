module CustomModelSettingsJourney
  include ModelProviderSettingsJourney

  private

    def configure_inherited_model(screenshot:)
      snapshot = ModelCatalog.current
      definitions = {
        "compact-base" => {
          "capabilities" => {
            "limits" => { "combined_input_output_tokens" => 65_536, "output_tokens" => 4096 },
            "input_modalities" => ["image"], "tool_calls" => false, "streaming" => true,
            "reasoning" => { "efforts" => %w[low high], "default_effort" => "low", "disable_supported" => true,
              "default_enabled" => true },
          },
        },
        "wide-base" => {
          "capabilities" => {
            "limits" => { "combined_input_output_tokens" => 128_000, "output_tokens" => 8192 },
            "input_modalities" => [], "tool_calls" => true, "streaming" => false, "reasoning" => nil,
          },
        },
      }
      ModelCatalog.stub(:current, snapshot.with(model_definitions: snapshot.model_definitions.merge(definitions))) do
        edit_inherited_model(screenshot: screenshot)
      end
    end

    def edit_inherited_model(screenshot:)
      sign_in_for_model_settings(users(:owner))
      visit new_admin_model_provider_url
      fill_in "Provider ID", with: "local-inherited"
      fill_in "Base URL", with: "http://localhost:11434/v1"
      select "No authentication", from: "Authentication"
      click_button "Add provider"
      assert_current_path admin_model_provider_path("local-inherited")
      click_link "Add model"
      select "compact-base", from: "Model definition"
      fill_in "Model ID", with: "local/model"
      fill_in "Display name", with: "Local deployment"
      within "[data-model-definition-target='defaults']" do
        assert_text "65,536"
        assert_text "4,096"
        assert_text "Images"
        assert_text "Reasoning"
        assert_text "Can be disabled"
      end
      assert_field "Combined context window", with: "", placeholder: "65536"
      assert_field "Output token limit", with: "", placeholder: "4096"
      assert_inherited_limit_hint("output_tokens", "Inherited: 4,096")
      assert_select "Tool calls", selected: "Use model default (Disabled)"
      assert_select "Streaming", selected: "Use model default (Supported)"
      assert_field "Images", checked: true, disabled: true
      assert_no_horizontal_overflow
      save_model_settings_screenshot("inherited-#{screenshot}-defaults", full_page: true)

      fill_in "Combined context window", with: "32768"
      assert_field "Output token limit", with: "", placeholder: ""
      assert_inherited_limit_hint("output_tokens", "Model default: 4,096 (not inherited while context limits are overridden).")
      fill_in "Output token limit", with: "2048"
      fill_in "Combined context window", with: ""
      assert_field "Output token limit", with: "2048"
      assert_inherited_limit_hint("combined_input_output_tokens", "Model default: 65,536 (not inherited while context limits are overridden).")
      fill_in "Output token limit", with: ""
      assert_inherited_limit_hint("output_tokens", "Inherited: 4,096")

      fill_in "Combined context window", with: "32768"
      select "Disabled", from: "Tool calls"
      select "Choose deployment support", from: "Media support"
      uncheck "Images"
      select "wide-base", from: "Model definition"
      within "[data-model-definition-target='defaults']" do
        assert_text "128,000"
        assert_text "Text only (no media)"
        assert_text "Explicitly unset"
      end
      assert_field "Model ID", with: "local/model"
      assert_field "Display name", with: "Local deployment"
      assert_field "Combined context window", with: "32768"
      assert_select "Tool calls", selected: "Disabled"
      assert_field "Images", checked: false, disabled: false
      assert_inherited_limit_hint("output_tokens", "Model default: 8,192 (not inherited while context limits are overridden).")
      assert_no_horizontal_overflow
      save_model_settings_screenshot("inherited-#{screenshot}-model", full_page: true)
      click_button "Save model"
      assert_current_path admin_model_provider_path("local-inherited")
      assert_text "No cost estimate configured"
      ref = "local-inherited/local/model"
      saved = inherited_model_definition(ref)
      assert_equal "wide-base", saved.fetch("inherit")
      assert_equal({ "limits" => { "combined_input_output_tokens" => 32768 }, "tool_calls" => false,
        "input_modalities" => [] }, saved.fetch("capabilities"))
      assert_nil saved["pricing"]
      effective = ModelSelection::Resolver.effective_provider_catalog(accounts(:cybros), ModelCatalog.current, "local-inherited")
      assert_equal({ "combined_input_output_tokens" => 32768 }, effective.models.fetch(ref).dig("capabilities", "limits"))
      assert_equal [], effective.models.fetch(ref).dig("capabilities", "input_modalities")
      assert_equal false, effective.models.fetch(ref).dig("capabilities", "tool_calls")

      page.refresh
      click_link "Edit #{ref}"
      assert_select "Model definition", selected: "wide-base"
      assert_field "Combined context window", with: "32768"
      assert_field "Input token limit", with: ""
      assert_field "Output token limit", with: ""
      assert_select "Media support", selected: "Choose deployment support"
      assert_field "Images", checked: false, disabled: false
      assert_select "Tool calls", selected: "Disabled"
      assert_no_horizontal_overflow
      select "compact-base", from: "Model definition"
      assert_field "Images", checked: false, disabled: false
      fill_in "Display name", with: "Renamed local deployment"
      click_button "Save model"
      assert_current_path admin_model_provider_path("local-inherited")
      assert_equal saved.merge("inherit" => "compact-base", "display_name" => "Renamed local deployment"), inherited_model_definition(ref)
      page.refresh
      click_link "Edit #{ref}"
      assert_select "Model definition", selected: "compact-base"
      assert_field "Display name", with: "Renamed local deployment"
      save_model_settings_screenshot("inherited-#{screenshot}-edited", full_page: true)

      find_button("Use model limits").send_keys(:enter)
      assert_field "Combined context window", with: "", placeholder: "65536"
      assert_inherited_limit_hint("output_tokens", "Inherited: 4,096")
      select "Use model default (Disabled)", from: "Tool calls"
      select "Use model or protocol default", from: "Media support"
      assert_field "Images", checked: true, disabled: true
      click_button "Save model"
      assert_current_path admin_model_provider_path("local-inherited")
      assert_equal({ "model_id" => "local/model", "inherit" => "compact-base", "display_name" => "Renamed local deployment" },
        inherited_model_definition(ref))
      effective = ModelSelection::Resolver.effective_provider_catalog(accounts(:cybros), ModelCatalog.current, "local-inherited")
      assert_equal ["image"], effective.models.fetch(ref).dig("capabilities", "input_modalities")
      assert_equal({ "combined_input_output_tokens" => 65_536, "output_tokens" => 4096 }, effective.models.fetch(ref).dig("capabilities", "limits"))
      page.refresh
      click_link "Edit #{ref}"
      assert_field "Combined context window", with: ""
      assert_inherited_limit_hint("output_tokens", "Inherited: 4,096")
      assert_field "Images", checked: true, disabled: true
      assert_no_horizontal_overflow
      save_model_settings_screenshot("inherited-#{screenshot}-restored", full_page: true)
    end

    def assert_inherited_limit_hint(key, text)
      assert_selector "[data-model-definition-target='limitHint'][data-limit='#{key}']", exact_text: text
    end

    def inherited_model_definition(ref)
      ModelProviderConfig.find_by!(account: accounts(:cybros), provider_id: "local-inherited").override_entries.fetch(ref).fetch("model")
    end

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
      click_link "Discover model IDs"
      assert_button "Fetch model IDs"
      failure = ModelProviders::DiscoverModels::Result.new(outcome: :discovery_failed, models: [])
      ModelProviders::DiscoverModels.stub(:call, failure) do
        click_button "Fetch model IDs"
        assert_text "The provider's model directory could not be fetched."
        assert_text "Your existing models are unchanged."
      end
      click_link "Enter a model ID manually"
      assert_selector "h1", text: "Add model"
      assert_no_link "Discover model IDs"
      fill_in "Model ID", with: "my-team/long-model-name-for-a-local-endpoint"
      fill_in "Display name", with: "Local assistant"
      fill_in "Input token limit", with: "32768"
      select "Disabled", from: "Tool calls"
      assert_no_horizontal_overflow
      save_model_settings_screenshot("custom-#{screenshot}-model")
      click_button "Save model"
      assert_current_path admin_model_provider_path("local-browser")
      assert_text "local-browser/my-team/long-model-name-for-a-local-endpoint"
      click_button "Enable provider"
      assert_button "Enable provider", disabled: true
      assert_models_omit_provider_status
      within "#provider-models" do
        assert_button "Make local-browser/my-team/long-model-name-for-a-local-endpoint visible", disabled: true
        assert_button "Hide local-browser/my-team/long-model-name-for-a-local-endpoint from agents", disabled: false
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
      policy = ModelProviderConfig.find_by!(account: accounts(:cybros), provider_id: "local-browser")
      assert_predicate policy, :enabled?
      model = policy.override_entries.fetch("local-browser/my-team/long-model-name-for-a-local-endpoint").fetch("model")
      assert_equal "Renamed local assistant", model.fetch("display_name")
      assert_equal 32768, model.dig("capabilities", "limits", "input_tokens")
      assert_equal false, model.dig("capabilities", "tool_calls")
      assert_nil model["pricing"]
    end
end
