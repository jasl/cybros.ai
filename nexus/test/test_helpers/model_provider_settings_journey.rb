module ModelProviderSettingsJourney
  private

    def sign_in_for_model_settings(user)
      visit new_session_url
      fill_in "Email", with: user.email
      fill_in "Password", with: "password"
      click_button "Sign in"
      assert_text "Signed in as #{user.email}"
    end

    def configure_api_key_provider(screenshot:)
      sign_in_for_model_settings(users(:owner))
      visit settings_url
      within "main" do
        click_link "Model providers"
      end
      assert_title "Model providers · Nexus"
      assert_no_horizontal_overflow
      save_model_settings_screenshot("#{screenshot}-providers")
      click_link "Test API"
      assert_current_path admin_model_provider_path("test_api")
      within "#provider-models" do
        assert_link "Discover model IDs"
        assert_link "Add model"
        click_link "Test test_api/text"
      end
      assert_text "may incur provider charges"
      assert_no_horizontal_overflow
      within "nav[aria-label='Back']" do
        click_link "Test API"
      end
      assert_button "Make test_api/text visible", disabled: true
      assert_button "Hide test_api/text from agents", disabled: false
      assert_models_omit_provider_status
      assert_no_horizontal_overflow
      save_model_settings_screenshot("#{screenshot}-initial-disabled", full_page: true)

      assert_nil ModelProviderConfig.find_by(account: accounts(:cybros), provider_id: "test_api")
      click_button "Hide test_api/text from agents"
      assert_model_visibility("test_api/text", visible: false)
      assert_provider_enabled(false)
      assert_nil provider_credential
      page.refresh
      assert_model_visibility("test_api/text", visible: false)
      assert_models_omit_provider_status
      click_button "Make test_api/text visible"
      assert_model_visibility("test_api/text", visible: true)
      assert_provider_enabled(false)
      assert_nil provider_credential

      assert_field "API key", type: "password", with: ""
      fill_in "API key", with: "synthetic-browser-key"
      click_button "Save"
      assert_field "API key", type: "password", with: ""
      assert_current_path admin_model_provider_path("test_api")
      assert_provider_enabled(true)
      assert_models_omit_provider_status
      assert_equal "synthetic-browser-key", provider_credential.secret
      refute_includes page.html, "synthetic-browser-key"

      click_button "Disable provider"
      assert_provider_enabled(false)
      fill_in "API key", with: "replacement-browser-key"
      click_button "Update"
      assert_field "API key", type: "password", with: ""
      assert_current_path admin_model_provider_path("test_api")
      assert_provider_enabled(true)
      assert_equal "replacement-browser-key", provider_credential.secret
      refute_includes page.html, "replacement-browser-key"
      assert_no_horizontal_overflow
      save_model_settings_screenshot("#{screenshot}-api-key")

      result = ModelProviders::TestConnection::Result.new(outcome: :succeeded, duration_ms: 12, http_status: 200)
      ModelProviders::TestConnection.stub(:call, result) do
        click_link "Test test_api/text"
        click_button "Run connection test"
        assert_selector "[role=status]", text: "Connection succeeded."
        assert_no_horizontal_overflow
        save_model_settings_screenshot("#{screenshot}-model-test")
        within "nav[aria-label='Back']" do
          click_link "Test API"
        end
      end

      assert_no_button "Mark test_api/text invalid"
      unavailable = ModelProviders::TestConnection::Result.new(outcome: :model_not_found, duration_ms: 12, http_status: 404)
      ModelProviders::TestConnection.stub(:call, unavailable) do
        click_link "Test test_api/text"
        click_button "Run connection test"
        assert_text "This model is now marked invalid and hidden from agents."
        within "nav[aria-label='Back']" do
          click_link "Test API"
        end
      end
      within "li[data-model-ref='test_api/text']" do
        assert_text "Invalid · hidden from agents"
        assert_button "Make test_api/text visible", disabled: true
        assert_no_horizontal_overflow
        save_model_settings_screenshot("#{screenshot}-invalid-model", full_page: true)
        click_button "Clear invalid mark for test_api/text"
      end
      assert_model_visibility("test_api/text", visible: true)

      click_button "Hide test_api/text from agents"
      assert_model_visibility("test_api/text", visible: false)
      find_button("Hide test_api/alternate from agents").send_keys(:space)
      assert_model_visibility("test_api/alternate", visible: false)
      page.refresh
      assert_model_visibility("test_api/text", visible: false)
      assert_model_visibility("test_api/alternate", visible: false)
      click_button "Make test_api/text visible"
      assert_model_visibility("test_api/text", visible: true)
      find_button("Make test_api/alternate visible").send_keys(:enter)
      assert_model_visibility("test_api/alternate", visible: true)
      assert_no_horizontal_overflow
      save_model_settings_screenshot(screenshot)
      save_model_settings_screenshot("#{screenshot}-overview-full", full_page: true)

      click_button "Disable provider"
      assert_provider_enabled(false)
      assert_equal "replacement-browser-key", provider_credential.secret
      click_button "Hide test_api/text from agents"
      assert_model_visibility("test_api/text", visible: false)
      page.refresh
      assert_provider_enabled(false)
      assert_model_visibility("test_api/text", visible: false)
      assert_models_omit_provider_status

      confirm_through_dialog { click_button "Remove" }
      assert_text I18n.t("admin.model_providers.key_removed")
      assert_current_path admin_model_provider_path("test_api")
      assert_field "API key", type: "password", with: ""
      assert_nil provider_credential
      assert_no_button "Remove"
      assert_models_omit_provider_status
    end

    def assert_models_omit_provider_status
      within "section[aria-label='Provider models']" do
        assert_no_text "Provider disabled"
        assert_no_text "Credentials needed"
        assert_no_text "Sign-in required"
        assert_no_text "Available", exact: true
        assert_no_text "Enable this provider"
      end
    end

    def assert_provider_enabled(enabled)
      assert_current_path admin_model_provider_path("test_api")
      assert_button "Enable provider", disabled: enabled
      assert_button "Disable provider", disabled: !enabled
      assert_equal enabled.to_s, find_button("Enable provider", disabled: :all)["aria-pressed"]
      assert_equal (!enabled).to_s, find_button("Disable provider", disabled: :all)["aria-pressed"]
      assert_equal enabled, provider_policy.enabled?
    end

    def assert_model_visibility(ref, visible:)
      assert_current_path admin_model_provider_path("test_api")
      assert_button "Make #{ref} visible", disabled: visible
      assert_button "Hide #{ref} from agents", disabled: !visible
      assert_equal visible.to_s, find_button("Make #{ref} visible", disabled: :all)["aria-pressed"]
      assert_equal (!visible).to_s, find_button("Hide #{ref} from agents", disabled: :all)["aria-pressed"]
      hidden = provider_policy.model_overrides.fetch("hidden_models", [])
      assert_equal !visible, hidden.include?(ref)
      # The next keyboard action needs the completed Turbo visit's focus state.
      assert_no_selector "html[aria-busy='true']"
    end

    def provider_policy
      ModelProviderConfig.find_by!(account: accounts(:cybros), provider_id: "test_api")
    end

    def provider_credential
      ModelProviderCredential.find_by(account: accounts(:cybros), provider_id: "test_api")
    end

    def assert_no_horizontal_overflow
      assert page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth"),
        "the settings page must fit the viewport without horizontal scrolling"
    end

    def save_model_settings_screenshot(name, full_page: false)
      directory = Rails.root.join("tmp/system-screenshots")
      FileUtils.mkdir_p(directory)
      path = directory.join("nexus-model-settings-#{name}.png")
      if full_page
        browser = page.driver.browser
        size = browser.execute_cdp("Page.getLayoutMetrics").fetch("cssContentSize")
        capture = browser.execute_cdp("Page.captureScreenshot", format: "png", captureBeyondViewport: true,
          clip: { x: 0, y: 0, width: size.fetch("width"), height: size.fetch("height"), scale: 1 })
        File.binwrite(path, Base64.decode64(capture.fetch("data")))
      else
        page.save_screenshot(path)
      end
    end
end
