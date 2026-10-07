require "test_helper"

class ForcedPasswordChangeTest < ActionDispatch::IntegrationTest
  setup do
    creation = accounts(:cybros).create_direct_member(
      display_name: "Newcomer",
      email: "newcomer@example.com",
      role: "member",
      password: "temporary password",
      password_confirmation: "temporary password"
    )
    @identity = creation.member.identity
    post session_url, params: { email: "newcomer@example.com", password: "temporary password" }
  end

  test "until the password changes only the password page and logout are reachable" do
    get root_path
    assert_redirected_to settings_password_path(return_to: root_path)
    get settings_path
    assert_redirected_to settings_password_path(return_to: settings_path)

    get settings_password_path
    assert_response :success

    delete session_path
    assert_redirected_to new_session_path
  end

  test "changing the password clears the gate" do
    patch settings_password_path, params: {
      password: { current_password: "temporary password", password: "their own password", password_confirmation: "their own password" },
    }
    assert_redirected_to settings_password_path
    assert_not @identity.reload.password_change_required?

    get root_path
    assert_response :success
  end

  test "changing the password returns to the page that was interrupted" do
    get settings_path
    assert_redirected_to settings_password_path(return_to: settings_path)

    patch settings_password_path, params: {
      return_to: settings_path,
      password: { current_password: "temporary password", password: "their own password", password_confirmation: "their own password" },
    }

    assert_redirected_to settings_url
    follow_redirect!
    assert_response :success
  end

  test "a device ceremony return target keeps the password gate private" do
    return_to = oauth_device_path(user_code: "ABCD-EFGH")

    get settings_password_path(return_to: return_to)

    assert_response :success
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_equal "no-referrer", response.headers["Referrer-Policy"]
  end

  test "a device ceremony stays private when the password gate session expires" do
    device_return_to = oauth_device_path(user_code: "ABCD-EFGH")
    password_gate = settings_password_path(return_to: device_return_to)
    @identity.user.increment!(:authority_generation)

    get password_gate
    assert_redirected_to new_session_path(return_to: password_gate)
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_equal "no-referrer", response.headers["Referrer-Policy"]

    follow_redirect!
    assert_response :success
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_equal "no-referrer", response.headers["Referrer-Policy"]

    post session_path, params: {
      email: @identity.email,
      password: "temporary password",
      return_to: password_gate,
    }
    assert_redirected_to password_gate
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_equal "no-referrer", response.headers["Referrer-Policy"]

    follow_redirect!
    assert_response :success
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_equal "no-referrer", response.headers["Referrer-Policy"]

    patch settings_password_path, params: {
      return_to: device_return_to,
      password: {
        current_password: "temporary password",
        password: "their own password",
        password_confirmation: "their own password",
      },
    }
    assert_redirected_to device_return_to
  end
end
