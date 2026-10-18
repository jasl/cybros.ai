require "application_system_test_case"

module McpAuthorizationSettingsJourney
  private

    def authorize_mcp_connection(viewport:)
      visit new_session_url
      fill_in "Email", with: users(:member).email
      fill_in "Password", with: "password"
      click_button "Sign in"
      assert_selector "main h1", text: "Overview"

      visit new_settings_mcp_connection_url
      fill_in "Name", with: "Research service"
      fill_in "External account label", with: "My research account"
      fill_in "Service URL", with: "https://research.example.test/mcp"
      select "OAuth browser sign-in", from: "Authentication"
      click_and_wait_for_connection_reload "Create connection"
      assert_text "Connection saved."
      assert_text "Authorize the service before discovering or calling tools."
      assert_no_link "Manage credential"

      start = ->(connection:, expected_lock_version:, redirect_uri:) do
        assert_equal 0, expected_lock_version
        authorization_result(connection, authorization_url: "#{redirect_uri}?code=fixture-code&state=fixture-state")
      end
      finish = ->(connection:, callback_params:) do
        assert_equal({ "code" => "fixture-code", "state" => "fixture-state" }, callback_params)
        connection.update!(oauth_data: McpConnection::OAuthData.new(
          tokens: { "access_token" => "synthetic-oauth-access", "token_type" => "Bearer" }, expires_at: 1.hour.from_now))
        authorization_result(connection)
      end
      McpConnections::OAuth::Start.stub(:call, start) do
        McpConnections::OAuth::Finish.stub(:call, finish) do
          click_and_wait_for_connection_reload "Authorize service"
          assert_text "Service authorized. Discover its tools to make them available."
          assert_text "The service is authorized."
        end
      end
      assert_no_text "synthetic-oauth-access"
      refute_includes page.html, "synthetic-oauth-access"

      tools = mcp_connections(:notes).tools_catalog
      client = Object.new
      client.define_singleton_method(:list_tools) { tools }
      Mcp::Client.stub(:open, ->(**, &block) { block.call(client) }) do
        click_and_wait_for_connection_reload "Discover tools"
        assert_text "Tool catalog refreshed."
      end
      assert_text "search"
      click_and_wait_for_connection_reload "Disconnect service"
      assert_text "Connection saved."
      assert_text "Authorize the service before discovering or calling tools."
      assert_text "search"
      assert_text "Revoke access at the external service separately."

      uncheck "Enabled"
      click_and_wait_for_connection_reload "Save connection"
      assert_button "Authorize service", disabled: true
      assert_text "Enable and save this connection before authorizing the service."
      assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=,
        page.evaluate_script("window.innerWidth"), "MCP authorization must fit the viewport"
      directory = Rails.root.join("tmp/system-screenshots")
      FileUtils.mkdir_p(directory)
      page.save_screenshot(directory.join("nexus-mcp-authorization-#{viewport}.png"))

      connection = users(:member).mcp_connections.find_by!(name: "Research service")
      assert_nil connection.oauth_data
      assert_equal tools, connection.tools_catalog
      assert_not connection.enabled?
    end

    def click_and_wait_for_connection_reload(label)
      # OAuth connection pages require a full reload, including same-URL redirects.
      previous_body = find("body", visible: :all).native
      click_button label
      assert_selector("body", visible: :all) { |body| body.native != previous_body }
    end

    def authorization_result(connection, authorization_url: nil)
      McpConnections::OAuth::Result.new(outcome: :saved, connection: connection,
        authorization_url: authorization_url, expires_at: nil, bearer_token: nil)
    end
end

class McpAuthorizationsSystemTest < ApplicationSystemTestCase
  include McpAuthorizationSettingsJourney

  test "the owner authorizes discovers tools and disconnects an OAuth service" do
    authorize_mcp_connection(viewport: "desktop")
  end
end

class MobileMcpAuthorizationsSystemTest < MobileSystemTestCase
  include McpAuthorizationSettingsJourney

  setup do
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
      width: 390, height: 844, deviceScaleFactor: 1, mobile: true)
  end

  test "OAuth connection management remains usable at a narrow viewport" do
    authorize_mcp_connection(viewport: "mobile-390")
  end
end
