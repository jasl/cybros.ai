require "application_system_test_case"

module ResourceManagementJourney
  extend ActiveSupport::Concern

  included do
    test "Agent and Runner management share a usable connection and credential journey" do
      human = users(:member)
      agent = human.build_agent(display_name: "Application#{"x" * 80}").tap(&:save!)
      # A nonmatching row makes the count below wait for the filtered response.
      human.build_agent(display_name: "Another application").save!
      sign_in_directly(human)
      visit agents_url
      assert_link "Connect agent", href: agent_connection_path
      fill_in "Search Agents", with: "@#{agent.handle}"
      select "Active", from: "Status"
      click_button "Filter"
      assert_selector "[data-agent-id]", count: 1
      find_link(agent.display_name).send_keys(:enter)
      assert_current_path agent_path(agent)
      assert_text "Overview"
      assert_text "Management"
      assert_resource_page_width
      page.save_screenshot(Rails.root.join("tmp/screenshots/agent-management-#{page.evaluate_script("document.documentElement.clientWidth")}.png"))
      visit runners_url
      click_link "Connect runner"
      assert_current_path runner_connection_path
      assert_link "I have a device code"
      assert_no_link text: /Create private Runner/
      runner = connect_runner(manager: human, display_name: "Runner#{"y" * 80}").executor_access_token.executor
      visit runners_url
      click_link runner.display_name
      assert_current_path runner_path(runner)
      assert_text "Ready"
      assert_resource_page_width
      page.save_screenshot(Rails.root.join("tmp/screenshots/runner-management-#{page.evaluate_script("document.documentElement.clientWidth")}.png"))
      click_link "View 0 related runs"
      assert_current_path runner_runs_path(runner)
      click_link "Reset"
      assert_current_path runner_runs_path(runner)
      find_link(runner.display_name, exact: true).click
      confirm_through_dialog { click_button "Revoke credentials" }
      assert_current_path runner_path(runner)
      assert_text "No credential"
      confirm_through_dialog { click_button "Remove connection" }
      assert_current_path runner_path(runner)
      assert_text "Revoked"
      assert_no_button "Remove connection"
      assert_resource_page_width
    end
  end

  private

    def assert_resource_page_width
      assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=,
        page.evaluate_script("document.documentElement.clientWidth") + 1
    end
end

class ResourceManagementJourneyTest < ApplicationSystemTestCase
  include ResourceManagementJourney
end

class NarrowResourceManagementJourneyTest < ApplicationSystemTestCase
  include ResourceManagementJourney

  setup do
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
      width: 390, height: 844, deviceScaleFactor: 1, mobile: false)
  end
end
