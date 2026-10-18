require "application_system_test_case"

module McpConnectionSettingsJourney
  private

    def manage_mcp_connection(viewport:)
      visit new_session_url
      fill_in "Email", with: users(:member).email
      fill_in "Password", with: "password"
      click_button "Sign in"
      assert_selector "main h1", text: "Overview"

      visit settings_url
      within "main" do
        click_link "MCP connections"
      end
      click_link "New connection"
      fill_in "Name", with: "Research notes"
      fill_in "External account label", with: "My research account"
      fill_in "Service URL", with: "https://research.example.test/mcp"
      select "OAuth browser sign-in", from: "Authentication"
      assert_no_field "Bearer token"
      assert_text "Create the connection, then choose Authorize service"
      select "No authentication", from: "Authentication"
      assert_no_field "Bearer token"
      select "Static Bearer token", from: "Authentication"
      fill_in "Bearer token", with: "synthetic-mcp-browser-secret"
      click_button "Create connection"
      assert_text "Connection saved."
      assert_selector "h2", text: "Research notes"
      assert_no_text "synthetic-mcp-browser-secret"
      refute_includes page.html, "synthetic-mcp-browser-secret"

      tools = mcp_connections(:notes).tools_catalog
      client = Object.new
      client.define_singleton_method(:list_tools) { tools }
      Mcp::Client.stub(:open, ->(**, &block) { block.call(client) }) do
        click_button "Discover tools"
        assert_text "Tool catalog refreshed."
      end
      assert_text "Available tools"
      assert_text "search"
      assert_text "Discovered tools are available to your agents."
      assert_no_link "Manage Agent access"
      assert_no_selector "input[name='mcp_connection[allowed_tool_names][]']"

      click_link "Manage credential"
      assert_field "Bearer token", with: ""
      fill_in "Bearer token", with: "synthetic-mcp-browser-replacement"
      click_button "Replace token"
      assert_text "Connection saved."
      refute_includes page.html, "synthetic-mcp-browser-replacement"
      click_link "Manage credential"
      click_button "Clear stored token"
      assert_text "Add a Bearer token before discovering or calling tools."
      assert_button "Discover tools", disabled: true

      uncheck "Enabled"
      click_button "Save connection"
      assert_unchecked_field "Enabled"
      assert_text "search"
      assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=,
        page.evaluate_script("window.innerWidth"), "MCP settings must fit the viewport"
      directory = Rails.root.join("tmp/system-screenshots")
      FileUtils.mkdir_p(directory)
      page.save_screenshot(directory.join("nexus-mcp-connections-#{viewport}.png"))

      connection = users(:member).mcp_connections.find_by!(name: "Research notes")
      assert_equal tools, connection.tools_catalog
      assert_nil connection.bearer_token
      assert_not connection.enabled?
    end
end

class McpConnectionsSystemTest < ApplicationSystemTestCase
  include McpConnectionSettingsJourney

  test "a Human connects a service discovers its default tools and clears its credential" do
    manage_mcp_connection(viewport: "desktop")
  end
end

class MobileMcpConnectionsSystemTest < MobileSystemTestCase
  include McpConnectionSettingsJourney

  setup do
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
      width: 390, height: 844, deviceScaleFactor: 1, mobile: true)
  end

  test "connection management remains usable at a narrow viewport" do
    manage_mcp_connection(viewport: "mobile-390")
  end
end
