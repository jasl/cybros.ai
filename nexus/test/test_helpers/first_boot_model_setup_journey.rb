module FirstBootModelSetupJourney
  private

    def found_installation(screenshot: nil, cost_unit: nil)
      visit root_url
      assert_current_path setup_path
      assert_no_field "Cost unit"
      assert_field "Cost unit", with: "USD", visible: :all
      save_first_boot_screenshot("#{screenshot}-owner") if screenshot
      fill_founder_details
      if cost_unit
        find("summary", text: "Advanced options").click
        fill_in "Cost unit", with: "x" * (Account::COST_UNIT_MAX_LENGTH + 1)
        click_button "Create installation"
        assert_selector "[role=alert]", text: "Some fields need attention"
        assert_field "Cost unit", with: "x" * (Account::COST_UNIT_MAX_LENGTH + 1)
        assert_equal 0, Account.count
        assert_first_boot_fits_viewport
        save_first_boot_screenshot("#{screenshot}-owner-advanced-error") if screenshot
        fill_founder_details
        fill_in "Cost unit", with: cost_unit
      end
      click_button "Create installation"

      assert_current_path root_path
      assert_selector "h1", text: "Overview"
      assert_link "Configure model providers", href: admin_model_providers_path
      assert_link "Connect an Agent", href: agent_connection_path
      assert_equal "founder@first-boot.test", Account.sole.owner.email
      assert_equal cost_unit || "USD", Account.sole.cost_unit
    end

    def fill_founder_details
      fill_in "Installation name", with: "First boot installation"
      fill_in "Your name", with: "First owner"
      fill_in "Email", with: "founder@first-boot.test"
      fill_in "Password", with: "first boot browser password"
      fill_in "Repeat password", with: "first boot browser password"
    end

    def configure_first_provider(screenshot:)
      found_installation(screenshot: screenshot)
      assert_first_boot_fits_viewport
      save_first_boot_screenshot("#{screenshot}-dashboard-todos")
      click_link "Configure model providers"
      click_link "Test API"
      assert_current_path admin_model_provider_path("test_api")
      assert_field "API key", type: "password", with: ""
      assert_first_boot_fits_viewport
      save_first_boot_screenshot("#{screenshot}-provider-form")

      fill_in "API key", with: "synthetic-first-boot-key"
      click_button "Save"
      assert_current_path admin_model_provider_path("test_api")
      assert_field "API key", type: "password", with: ""
      assert_equal "USD", Account.sole.cost_unit
      assert_predicate first_boot_policy, :enabled?
      assert_equal "synthetic-first-boot-key", first_boot_credential.secret
      refute_includes page.html, first_boot_credential.secret

      visit root_url
      assert_no_link "Configure model providers"
      assert_link "Connect an Agent", href: agent_connection_path
      assert_first_boot_fits_viewport
      save_first_boot_screenshot("#{screenshot}-dashboard-models-ready")
      within("main") { click_link "Connect an Agent" }
      assert_current_path agent_connection_path
      assert_text "Connect an existing application"

      # The application completes its existing connection ceremony.
      connect_agent_session(steward: Account.sole.owner, agent_identifier: "first-boot-browser-agent")
      visit root_url
      assert_link "Agents · 1", href: agents_path
      assert_text "No work yet. Submit work from an application or SDK to see its results here."
      assert_selector "h1", text: "Overview"
      assert_first_boot_fits_viewport
      save_first_boot_screenshot("#{screenshot}-dashboard-complete")

      visit admin_model_provider_url("test_api")
      assert_field "API key", type: "password", with: ""
      assert_button "Remove"
      assert_equal "synthetic-first-boot-key", first_boot_credential.secret
      assert_equal "USD", Account.sole.cost_unit
    end

    def first_boot_policy
      ModelProviderConfig.find_by!(account: Account.sole, provider_id: "test_api")
    end

    def first_boot_credential
      ModelProviderCredential.find_by!(account: Account.sole, provider_id: "test_api")
    end

    def assert_first_boot_fits_viewport
      assert page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth"),
        "the first-boot flow must fit the viewport without horizontal scrolling"
    end

    def save_first_boot_screenshot(name)
      directory = Rails.root.join("tmp/system-screenshots")
      FileUtils.mkdir_p(directory)
      page.save_screenshot(directory.join("nexus-first-boot-#{name}.png"))
    end
end
