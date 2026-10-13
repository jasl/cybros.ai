require "application_system_test_case"

class DeviceConnectionMappingJourneysTest < ApplicationSystemTestCase
  test "device connection survives refresh and browser back-forward history" do
    pairing = request_connection
    grant = DeviceAuthorization.find_by_device_code(pairing.fetch("device_code"))
    assert grant

    review_connection(pairing)
    assert_current_path oauth_device_grant_path(grant.public_id)
    assert_equal 1, grant.reload.exposure_count

    page.refresh
    assert_current_path oauth_device_grant_path(grant.public_id)
    assert_text pairing.fetch("user_code")
    assert_equal 1, grant.reload.exposure_count

    page.go_back
    assert_text "Connect a device"
    assert_field "Device code", with: pairing.fetch("user_code")

    page.go_forward
    assert_current_path oauth_device_grant_path(grant.public_id)
    assert_text "Connect agent program"
    assert_text pairing.fetch("user_code")
    assert_equal 1, grant.reload.exposure_count
  end

  private

    def request_connection
      machine_session.post oauth_device_authorization_path, params: {
        client_id: OAuth::DEVICE_CLIENT_ID,
        agent_identifier: "history-program-installation",
        agent_display_name: "History program",
        executor_display_name: "Journey app",
      }

      assert_equal 200, machine_session.response.status
      assert_equal "no-store", machine_session.response.headers["Cache-Control"]
      machine_session.response.parsed_body
    end

    def review_connection(pairing)
      sign_in_directly(users(:owner))
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
