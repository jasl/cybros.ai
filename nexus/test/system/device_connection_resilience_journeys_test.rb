require "application_system_test_case"

module DeviceConnectionResilienceTestHelper
  private

  # An agent connection always names the address it wants, so these journeys carry it by default
  # rather than opting in per test.
  def request_connection(agent_identifier:, agent_display_name:,
                         executor_display_name: "Journey app")
    machine_session.post oauth_device_authorization_path, params: {
      client_id: OAuth::DEVICE_CLIENT_ID,
      agent_identifier: agent_identifier,
      agent_display_name: agent_display_name,
      executor_display_name: executor_display_name,
    }.compact

    assert_equal 200, machine_session.response.status
    assert_equal "no-store", machine_session.response.headers["Cache-Control"]
    machine_session.response.parsed_body
  end

  def connection_grant(pairing)
    DeviceAuthorization.find_by_device_code(pairing.fetch("device_code")).tap do |grant|
      assert grant
    end
  end

  def review_connection(pairing)
    visit URI(pairing.fetch("verification_uri_complete")).request_uri
    assert_field "Device code", with: pairing.fetch("user_code")

    click_button "Continue"
    assert_text "Connect agent program"
    assert_text pairing.fetch("user_code")
  end

  def machine_session
    @machine_session ||= ActionDispatch::Integration::Session.new(Rails.application)
  end
end

class MobileDeviceConnectionConnectionJourneyTest < MobileSystemTestCase
  include DeviceConnectionResilienceTestHelper

  test "the connection confirmation stays usable at phone width" do
    pairing = request_connection(
      agent_identifier: "mobile-confirmation",
      agent_display_name: "Mobile confirmation"
    )
    sign_in_directly(users(:owner))

    review_connection(pairing)

    assert_text pairing.fetch("user_code")
    connect = find_button("Connect")
    cancel = find_button("Cancel")
    assert_control_within_viewport(connect)
    assert_control_within_viewport(cancel)

    document_width = page.evaluate_script("document.documentElement.scrollWidth")
    viewport_width = page.evaluate_script("document.documentElement.clientWidth")
    overflowing_elements = page.evaluate_script(<<~JAVASCRIPT)
      (() => {
        const viewportWidth = document.documentElement.clientWidth
        return [...document.querySelectorAll("body *")]
          .filter((element) => {
            const rect = element.getBoundingClientRect()
            return rect.right > viewportWidth + 0.5
          })
          .slice(0, 8)
          .map((element) => ({
            tag: element.tagName,
            classes: element.className,
            right: element.getBoundingClientRect().right,
            text: element.textContent.trim().slice(0, 80),
          }))
      })()
    JAVASCRIPT
    assert_operator document_width, :<=, viewport_width,
      "elements beyond the viewport: #{overflowing_elements.inspect}"

    click_button "Connect"
    within "section[aria-label='Connection status']" do
      assert_text "Connection ready", count: 1
      assert_no_selector "[role=alert]"
      assert_matches_style find("p", text: "Nothing is saved"), hyphens: "none"
      assert_control_within_viewport(find_button("Cancel connection"))
      assert_control_within_viewport(find_link("Back to code entry"))
      click_button "Cancel connection"
    end

    assert_text "This connection was canceled", count: 1
    assert_no_selector "[role=alert]"
    assert_no_button "Cancel connection"
    click_link "Back to code entry"
    assert_field "Device code"
  end

  private

    def assert_control_within_viewport(control)
      bounds = page.evaluate_script(<<~JAVASCRIPT, control)
        (() => {
          const rect = arguments[0].getBoundingClientRect()
          return { left: rect.left, right: rect.right }
        })()
      JAVASCRIPT
      viewport_width = page.evaluate_script("document.documentElement.clientWidth")

      assert_operator bounds.fetch("left"), :>=, 0
      assert_operator bounds.fetch("right"), :<=, viewport_width
    end
end

class InterleavedDeviceConnectionWindowsJourneyTest < ApplicationSystemTestCase
  include DeviceConnectionResilienceTestHelper

  test "two browser windows keep their verified grants and decisions independent" do
    pairing_a = request_connection(
      agent_identifier: "window-a-installation",
      agent_display_name: "Window A program"
    )
    pairing_b = request_connection(
      agent_identifier: "window-b-installation",
      agent_display_name: "Window B program"
    )
    grant_a = connection_grant(pairing_a)
    grant_b = connection_grant(pairing_b)
    sign_in_directly(users(:owner))

    review_connection(pairing_a)
    window_a = current_window
    window_b = window_opened_by do
      page.execute_script("window.open('about:blank', '_blank')")
    end

    within_window(window_b) do
      review_connection(pairing_b)
      assert_no_text pairing_a.fetch("user_code")
      click_button "Cancel"
      assert_text "No credential was shared"
    end

    assert grant_b.reload.canceled?
    assert grant_a.reload.pending?

    within_window(window_a) do
      assert_current_path oauth_device_grant_path(grant_a.public_id)
      assert_text pairing_a.fetch("user_code")
      assert_button "Connect"
      click_button "Connect"
      assert_text "Connection ready"
    end

    assert grant_a.reload.connected?
    assert grant_b.reload.canceled?
  ensure
    window_b&.close
  end
end

class DeviceConnectionBrowserRecoveryJourneyTest < ApplicationSystemTestCase
  include DeviceConnectionResilienceTestHelper

  test "a forced password change returns to the complete verification URI" do
    pairing = request_connection(
      agent_identifier: "forced-change-installation",
      agent_display_name: "Forced change program"
    )
    creation = accounts(:cybros).create_direct_member(
      display_name: "Temporary member",
      email: "temporary-member@example.com",
      role: "member",
      password: "temporary password",
      password_confirmation: "temporary password"
    )

    visit URI(pairing.fetch("verification_uri_complete")).request_uri
    fill_in "Email", with: creation.member.email
    fill_in "Password", with: "temporary password"
    click_button "Sign in"

    assert_text I18n.t("sessions.password_change_required")
    fill_in "Current password", with: "temporary password"
    fill_in "New password", with: "their own password"
    fill_in "Repeat new password", with: "their own password"
    click_button "Change password"

    assert_current_path URI(pairing.fetch("verification_uri_complete")).request_uri
    assert_field "Device code", with: pairing.fetch("user_code")
  end

  test "two signed-out windows resume their own complete verification URI" do
    pairing_a = request_connection(
      agent_identifier: "signed-out-window-a",
      agent_display_name: "Signed-out window A"
    )
    pairing_b = request_connection(
      agent_identifier: "signed-out-window-b",
      agent_display_name: "Signed-out window B"
    )

    visit URI(pairing_a.fetch("verification_uri_complete")).request_uri
    fill_in "Email", with: users(:owner).email
    fill_in "Password", with: "password"
    window_a = current_window
    window_b = window_opened_by do
      page.execute_script("window.open('about:blank', '_blank')")
    end

    within_window(window_b) do
      visit URI(pairing_b.fetch("verification_uri_complete")).request_uri
      fill_in "Email", with: users(:owner).email
      fill_in "Password", with: "password"
      click_button "Sign in"
      assert_field "Device code", with: pairing_b.fetch("user_code")
      assert_no_field "Device code", with: pairing_a.fetch("user_code")
    end

    within_window(window_a) do
      click_button "Sign in"
      assert_field "Device code", with: pairing_a.fetch("user_code")
      assert_no_field "Device code", with: pairing_b.fetch("user_code")
    end
  ensure
    window_b&.close
  end

  test "an unknown code can be corrected without affecting the real grant" do
    pairing = request_connection(
      agent_identifier: "corrected-code-installation",
      agent_display_name: "Corrected-code program"
    )
    grant = connection_grant(pairing)
    sign_in_directly(users(:owner))
    visit oauth_device_url

    fill_in "Device code", with: "AAAA-BBBB"
    click_button "Continue"
    assert_text I18n.t("oauth.device.unknown_code")
    assert grant.reload.pending?
    assert_equal 0, grant.exposure_count

    fill_in "Device code", with: pairing.fetch("user_code")
    click_button "Continue"
    assert_text "Connect agent program"
    assert_text pairing.fetch("user_code")
    assert_equal 1, grant.reload.exposure_count
  end
end
