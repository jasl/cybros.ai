require "application_system_test_case"

class WorkspaceCreationJourneyTest < ApplicationSystemTestCase
  test "a member connects programs and creates private or Account-wide workspaces" do
    sign_in_directly(users(:member))
    run_creation_journey(screenshot: "desktop")
  end

  test "connection links and workspace creation work at a 390 pixel viewport" do
    sign_in_directly(users(:member))
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
      width: 390, height: 844, deviceScaleFactor: 1, mobile: true)

    run_creation_journey(screenshot: "mobile-390")
    assert_equal 390, page.evaluate_script("window.innerWidth")
  ensure
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end

  private

    def run_creation_journey(screenshot:)
      visit agents_url
      assert_selector "h1", text: "My agents"
      assert_link "Connect agent", href: oauth_device_path
      capture_layout("#{screenshot}-agents")
      click_link "Connect agent"
      assert_current_path oauth_device_path
      assert_field "Device code", with: ""

      visit runners_url
      assert_selector "h1", text: "My runners"
      assert_link "Connect runner", href: oauth_device_path
      capture_layout("#{screenshot}-runners")
      click_link "Connect runner"
      assert_current_path oauth_device_path
      assert_field "Device code", with: ""

      visit workspaces_url
      assert_link "New workspace"
      capture_layout("#{screenshot}-workspaces")
      click_link "New workspace"
      assert_current_path new_workspace_path
      assert_checked_field "Private"
      assert_unchecked_field "Account-wide"
      capture_layout("#{screenshot}-new-workspace")
      fill_in "Name", with: "Personal research"
      click_button "Create workspace"

      assert_text "Workspace created."
      private_workspace = Workspace.find_by!(name: "Personal research", owner: users(:member))
      assert_current_path workspace_path(private_workspace)
      assert_predicate private_workspace, :private?
      assert_nil private_workspace.agent_identifier
      assert_equal users(:member), private_workspace.creator
      assert_not private_workspace.data_accessible_by?(users(:owner))

      visit workspaces_url
      click_link "New workspace"
      choose "Account-wide"
      fill_in "Name", with: " "
      click_button "Create workspace"
      assert_text "Name can't be blank"
      assert_checked_field "Account-wide"
      assert_field "Name", with: " "
      capture_layout("#{screenshot}-workspace-error")
      fill_in "Name", with: "Shared research"
      click_button "Create workspace"

      assert_text "Workspace created."
      shared_workspace = Workspace.find_by!(name: "Shared research", owner: users(:member))
      assert_current_path workspace_path(shared_workspace)
      assert_predicate shared_workspace, :account_wide?
      assert shared_workspace.data_accessible_by?(users(:owner))
      assert_not shared_workspace.manageable_by?(users(:owner))
      assert_button "Archive"
      page.refresh
      assert_selector "h1", text: "Shared research"
      assert_text "Account-wide"
    end

    def capture_layout(name)
      assert page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth"),
        "the page must fit the viewport without horizontal scrolling"
      directory = Rails.root.join("tmp/system-screenshots")
      FileUtils.mkdir_p(directory)
      page.save_screenshot(directory.join("nexus-workspace-#{name}.png"))
    end
end
