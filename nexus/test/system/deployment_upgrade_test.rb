require "application_system_test_case"
require_relative "../test_helpers/deployment_test_helper"

class DeploymentUpgradeTest < ApplicationSystemTestCase
  include DeploymentTestHelper

  test "an administrator inspects the selected release and recovers its saved result at desktop and narrow widths" do
    client = fake_deployment_client
    Nexus::Deployment::Client.stub(:new, client) do
      visit new_session_url
      fill_in "Email", with: users(:owner).email
      fill_in "Password", with: "password"
      click_button "Sign in"
      assert_text "Signed in as #{users(:owner).email}"
      within "nav[aria-label='Primary']" do
        assert_link "Administration"
        save_layout("console-administration")
        click_link "Administration"
      end
      assert_current_path admin_users_path
      click_link "System upgrade"
      assert_current_path admin_deployment_path

      assert_title "System upgrade · Nexus"
      assert_text "Image sources"
      assert_text "registry.example/nexus"
      assert_text "Agent applications are managed separately."
      assert_text "Upgrade checks"
      assert_text "Ready to upgrade"
      assert_text "Image storage needs an operator check."
      assert_button "Check for updates"
      assert_checked_field "Back up the database before upgrading"
      assert_button "Start upgrade", disabled: false
      assert_selector "input[type=hidden][name='candidate[release]'][value='2610080750']", visible: :all
      assert_equal [:status], client.calls.map { |call| call.fetch(:operation) }
      capture_layout("available")

      click_button "Check for updates"
      assert_no_text "Checking the configured image sources…"
      assert_button "Start upgrade", disabled: false
      assert client.calls.any? { |call| call.fetch(:operation) == :check }
      find_button("Start upgrade").send_keys(:enter)
      assert_selector "[data-deployment-target=phase]", text: "Preparing images"
      assert_text "In progress"
      assert_current_path admin_deployment_upgrade_path(OPERATION_ID)
      assert_equal true, client.calls.find { |call| call.fetch(:operation) == :upgrade }.fetch(:backup)
      assert_button "Start upgrade", disabled: true
      assert_selector "[role=log]", text: "Preparing images"
      capture_layout("running")

      client.back_up(deployment_backup)
      assert_text "Backing up the database"
      within "section[aria-labelledby=database-backup-heading]" do
        assert_text "Available on the installation host"
        assert_text "1,048,576 bytes"
        assert_text "database-only backup excludes uploaded files"
        assert_no_selector "a, form"
      end
      capture_layout("database-backup")

      client.complete
      assert_text "Upgrade complete"
      assert_text "Succeeded"
      assert_link "Reload Nexus"
      capture_layout("complete")
      page.refresh
      assert_text "Succeeded"
      assert_text "This release is already installed."
      assert_text "Available on the installation host"
      assert_no_button "Start upgrade"
      click_link "Reload Nexus"
      assert_current_path admin_deployment_path
      assert_text "This release is already installed."
      assert_button "Check for updates", disabled: false
      assert_equal 1, client.calls.count { |call| call.fetch(:operation) == :upgrade }
    end
  end

  test "an administrator skips backup after a matching release check using desktop and mobile controls" do
    [false, true].each do |mobile|
      client = fake_deployment_client
      Nexus::Deployment::Client.stub(:new, client) do
        visit new_session_url
        fill_in "Email", with: users(:owner).email
        fill_in "Password", with: "password"
        click_button "Sign in"
        assert_text "Signed in as #{users(:owner).email}"
        if mobile
          page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
            width: 390, height: 844, deviceScaleFactor: 1, mobile: true)
        end
        visit admin_deployment_path

        assert_checked_field "Back up the database before upgrading"
        uncheck "Back up the database before upgrading"
        assert_button "Start upgrade", disabled: true
        assert_text "Check for updates again to use this backup choice."
        click_button "Check for updates"
        assert_no_text "Checking the configured image sources…"
        assert_unchecked_field "Back up the database before upgrading"
        assert_text "Database backup is skipped for this upgrade."
        assert_no_selector "[data-preflight-check=installation_space]"
        assert_equal false, client.calls.find { |call| call.fetch(:operation) == :check }.fetch(:backup)
        assert_button "Start upgrade", disabled: false
        assert_no_overflow
        save_layout(mobile ? "skip-backup-mobile-390" : "skip-backup-desktop")

        click_button "Start upgrade"
        assert_current_path admin_deployment_upgrade_path(OPERATION_ID)
        assert_equal false, client.calls.find { |call| call.fetch(:operation) == :upgrade }.fetch(:backup)
        assert_text "Skipped for this upgrade"
        client.complete
        assert_text "Succeeded"
        page.refresh
        assert_text "Skipped for this upgrade"
        assert_no_text "No longer retained"
        assert_no_overflow
        save_layout(mobile ? "skipped-receipt-mobile-390" : "skipped-receipt-desktop")
        assert_empty page.driver.browser.logs.get(:browser).select { |entry| entry.level == "SEVERE" }
      end
    ensure
      page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
      Capybara.reset_sessions!
    end
  end

  test "blocked checks remain actionable at desktop and narrow widths without enabling upgrade" do
    client = fake_deployment_client
    client.state = client.state.with(preflight: Nexus::Deployment::Preflight.from_h(deployment_preflight(ready: false)))
    Nexus::Deployment::Client.stub(:new, client) do
      visit new_session_url
      fill_in "Email", with: users(:owner).email
      fill_in "Password", with: "password"
      click_button "Sign in"
      assert_text "Signed in as #{users(:owner).email}"
      visit admin_deployment_path

      within "section[aria-labelledby=upgrade-checks-heading]" do
        assert_text "Upgrade blocked"
        assert_text "Free space on the installation volume and check again."
        assert_text "Available: 1,048,576 bytes"
        assert_text "Required: 2,097,152 bytes"
      end
      assert_button "Start upgrade", disabled: true
      click_button "Check for updates"
      assert_no_text "Checking the configured image sources…"
      assert_text "Upgrade blocked"
      assert_button "Start upgrade", disabled: true
      capture_layout("blocked")
      refute client.calls.any? { |call| call.fetch(:operation) == :upgrade }
    end
  end

  test "a browser request without a saved receipt reconnects and recovers its status" do
    client = fake_deployment_client
    Nexus::Deployment::Client.stub(:new, client) do
      visit new_session_url
      fill_in "Email", with: users(:owner).email
      fill_in "Password", with: "password"
      click_button "Sign in"
      assert_text "Signed in as #{users(:owner).email}"
      page.execute_script("window.sessionStorage.setItem('nexus.deployment.pending', arguments[0])",
        { idempotency_key: IDEMPOTENCY_KEY, candidate: deployment_release, backup: false }.to_json)

      visit admin_deployment_path

      assert_text "No matching request is visible yet."
      assert_button "Check request status"
      assert_button "Retry the same request"
      assert_button "Start upgrade", disabled: true
      assert_unchecked_field "Back up the database before upgrading", disabled: true
      assert_equal [:status, :status], client.calls.map { |call| call.fetch(:operation) }
      click_button "Retry the same request"
      assert_current_path admin_deployment_upgrade_path(OPERATION_ID)
      upgrade = client.calls.find { |call| call.fetch(:operation) == :upgrade }
      assert_equal IDEMPOTENCY_KEY, upgrade.fetch(:idempotency_key)
      assert_equal false, upgrade.fetch(:backup)
      assert_text "Skipped for this upgrade"
      assert_empty page.driver.browser.logs.get(:browser).select { |entry| entry.level == "SEVERE" }
    end
  end

  test "a standalone installation explains the manual path without offering an upgrade" do
    client = Nexus::Deployment::Client.new(socket_path: nil)
    Nexus::Deployment::Client.stub(:new, client) do
      visit new_session_url
      fill_in "Email", with: users(:owner).email
      fill_in "Password", with: "password"
      click_button "Sign in"
      assert_text "Signed in as #{users(:owner).email}"
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
        width: 390, height: 844, deviceScaleFactor: 1, mobile: true)
      click_button "Open sidebar"
      assert_matches_style find(".drawer-side", visible: :all), opacity: "1"
      within "nav[aria-label='Primary']" do
        assert_link "Administration"
        save_layout("console-administration-mobile-390")
        click_link "Administration"
      end
      assert_current_path admin_users_path
      click_button "Open sidebar"
      click_link "System upgrade"
      assert_current_path admin_deployment_path

      assert_text "Online upgrade is not configured"
      assert_text "command-line upgrade method"
      assert_no_button "Check for updates"
      assert_no_button "Start upgrade"
      capture_layout("unsupported")
    end
  end

  private

    def capture_layout(state)
      assert_no_overflow
      save_layout(state)
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
        width: 390, height: 844, deviceScaleFactor: 1, mobile: true)
      assert_equal 390, page.evaluate_script("window.innerWidth")
      assert_matches_style find(".drawer-side", visible: :all), opacity: "0"
      assert_no_overflow
      save_layout("#{state}-mobile-390")
    ensure
      page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
      assert_matches_style find(".drawer-side", visible: :all), opacity: "1"
    end

    def assert_no_overflow
      assert page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth"),
        "the upgrade page must fit its viewport"
    end

    def save_layout(name)
      directory = Rails.root.join("tmp/system-screenshots")
      FileUtils.mkdir_p(directory)
      browser = page.driver.browser
      size = browser.execute_cdp("Page.getLayoutMetrics").fetch("cssContentSize")
      image = browser.execute_cdp("Page.captureScreenshot", format: "png", captureBeyondViewport: true,
        clip: { x: 0, y: 0, width: size.fetch("width"), height: size.fetch("height"), scale: 1 })
      File.binwrite(directory.join("nexus-deployment-#{name}.png"), Base64.decode64(image.fetch("data")))
    end
end
