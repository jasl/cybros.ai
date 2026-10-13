require "application_system_test_case"

class WorkspaceMessagingJourneyTest < ApplicationSystemTestCase
  test "an owner selects allowed senders and switches between Public and Private" do
    run_messaging_journey(screenshot: "desktop")
  end

  test "messaging settings remain usable at a narrow viewport" do
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
      width: 390, height: 844, deviceScaleFactor: 1, mobile: true)
    run_messaging_journey(screenshot: "mobile-390")
  ensure
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end

  private

    def run_messaging_journey(screenshot:)
      workspace = workspaces(:shared)
      agent = users(:agent)
      sender = create_agent_member(display_name: "Research agent")
      agent_label = "#{agent.display_name} (@#{agent.handle})"
      sender_label = "#{sender.display_name} (@#{sender.handle})"

      visit new_session_url
      fill_in "Email", with: users(:owner).email
      fill_in "Password", with: "password"
      click_button "Sign in"
      assert_current_path root_path
      visit workspace_url(workspace)
      click_link "View messaging settings"

      assert_selector "h1", text: "Agent messaging"
      assert_text "Agents are Public by default"
      select agent_label, from: "Agent to configure"
      click_button "Choose agent"
      assert_checked_field "Public"
      choose "Private"
      check sender_label
      capture_layout(screenshot)
      save_messaging_settings

      assert_text "Agent messaging updated."
      within("[data-agent-id='#{agent.public_id}']") do
        assert_text "Private"
        assert_text sender_label
        assert_text "Itself"
      end
      choose "Public"
      save_messaging_settings
      assert_text "Agent messaging updated."
      assert_checked_field "Public"
      assert_checked_field sender_label
      assert_equal [sender.public_id], workspace.reload.messaging_policy.agents.first.allowed_sender_public_ids

      choose "Private"
      save_messaging_settings
      assert_text "Agent messaging updated."
      assert_checked_field sender_label
      uncheck sender_label
      save_messaging_settings
      assert_text "Agent messaging updated."
      within("[data-agent-id='#{agent.public_id}']") do
        assert_text "Itself"
        assert_no_text sender_label
      end
      assert_checked_field "Private"
      assert_empty workspace.reload.messaging_policy.agents.first.allowed_sender_public_ids
    end

    def save_messaging_settings
      previous_body = find("body", visible: :all).native
      click_button "Save messaging settings"
      # Every save redirects to the same page with the same notice. Wait for
      # its replacement before changing fields on the next form.
      assert_selector("body", visible: :all) { |body| body.native != previous_body }
    end

    def capture_layout(name)
      assert page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth"),
        "messaging settings must fit the viewport"
      directory = Rails.root.join("tmp/system-screenshots")
      FileUtils.mkdir_p(directory)
      page.save_screenshot(directory.join("nexus-workspace-messaging-#{name}.png"))
    end
end
