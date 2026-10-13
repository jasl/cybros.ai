require "test_helper"

class SessionsControllerTest < ActionDispatch::IntegrationTest
  setup { @identity = identities(:member) }

  test "new" do
    get new_session_path
    assert_response :success
  end

  test "new redirects to the dashboard when already signed in" do
    sign_in_as users(:member)

    get new_session_path
    assert_redirected_to root_path
  end

  test "create with valid credentials issues a usable session cookie" do
    assert_difference -> { Session.count }, +1 do
      post session_path, params: { email: @identity.email, password: "password" }
    end

    assert_redirected_to root_path
    assert cookies[:session_id].present?

    get root_path
    assert_response :success
    assert_select "h1", text: "Dashboard"
  end

  test "create with invalid credentials" do
    post session_path, params: { email: @identity.email, password: "wrong" }

    assert_redirected_to new_session_path
    assert cookies[:session_id].blank?
  end

  test "create for a suspended member is rejected with the generic message" do
    users(:member).update!(status: :suspended)

    assert_no_difference -> { Session.count } do
      post session_path, params: { email: @identity.email, password: "password" }
    end

    assert_redirected_to new_session_path
    assert_equal I18n.t("sessions.create.invalid_credentials"), flash[:alert]
  end

  test "create for a removed member is rejected with the generic message" do
    users(:member).remove

    assert_no_difference -> { Session.count } do
      post session_path, params: { email: @identity.email, password: "password" }
    end

    assert_redirected_to new_session_path
    assert_equal I18n.t("sessions.create.invalid_credentials"), flash[:alert]
  end

  test "create while the local-recovery fence is pending returns local_recovery_required" do
    @identity.update!(local_recovery_pending_at: Time.current)

    assert_no_difference -> { Session.count } do
      post session_path, params: { email: @identity.email, password: "password" }
    end

    assert_redirected_to new_session_path
    assert_equal I18n.t("sessions.create.local_recovery_required"), flash[:alert]
  end

  test "missing credentials are ordinary rejections" do
    [{ email: @identity.email }, { password: "password" }].each do |credentials|
      assert_no_difference -> { Session.count } do
        post session_path, params: credentials, as: :json
      end

      assert_redirected_to new_session_path
      assert_equal I18n.t("sessions.create.invalid_credentials"), flash[:alert]
    end
  end

  test "a non-string password is an ordinary rejection" do
    assert_no_difference -> { Session.count } do
      post session_path,
        params: { email: @identity.email, password: 123 },
        as: :json
    end

    assert_redirected_to new_session_path
    assert_equal I18n.t("sessions.create.invalid_credentials"), flash[:alert]
  end

  test "a stale authority snapshot stops authenticating without destroying the row" do
    sign_in_as users(:member)
    users(:member).increment!(:authority_generation)

    assert_no_difference -> { Session.count } do
      get root_path
    end

    assert_redirected_to new_session_path(return_to: root_path)
  end

  test "an unauthenticated mutation is not resumed as a GET after login" do
    patch settings_profile_path, params: { profile: { display_name: "X" } }
    assert_redirected_to new_session_path

    post session_path, params: { email: identities(:member).email, password: "password" }
    assert_redirected_to root_url
  end

  test "an interrupted mutation returns to its same-origin page without replaying the mutation" do
    patch settings_profile_path,
      params: { profile: { display_name: "X" }, return_to: settings_path }
    return_to = return_to_from(response.location)
    assert_equal settings_path, return_to

    post session_path, params: {
      email: identities(:member).email,
      password: "password",
      return_to: return_to,
    }

    assert_redirected_to settings_url
    assert_not_equal "X", users(:member).reload.display_name
  end

  test "an interrupted mutation falls back to its same-origin referrer" do
    patch settings_profile_path,
      params: { profile: { display_name: "X" } },
      headers: { "HTTP_REFERER" => settings_url }
    return_to = return_to_from(response.location)
    assert_equal settings_path, return_to

    post session_path, params: {
      email: identities(:member).email,
      password: "password",
      return_to: return_to,
    }

    assert_redirected_to settings_url
    assert_not_equal "X", users(:member).reload.display_name
  end

  test "signing in returns to the originally requested page" do
    get admin_users_path
    return_to = return_to_from(response.location)

    post session_path, params: {
      email: identities(:owner).email,
      password: "password",
      return_to: return_to,
    }
    assert_redirected_to admin_users_url
  end

  test "separate login pages keep separate return locations" do
    get admin_users_path
    admin_return_to = return_to_from(response.location)

    get oauth_device_path(user_code: "ABCD-EFGH")
    assert_not_includes response.filtered_location, "ABCD-EFGH"
    device_return_to = return_to_from(response.location)

    post session_path, params: {
      email: identities(:owner).email,
      password: "password",
      return_to: admin_return_to,
    }
    assert_redirected_to admin_users_url

    post session_path, params: {
      email: identities(:owner).email,
      password: "password",
      return_to: device_return_to,
    }
    assert_redirected_to oauth_device_url(user_code: "ABCD-EFGH")
  end

  test "an external return location is rejected" do
    post session_path, params: {
      email: identities(:member).email,
      password: "password",
      return_to: "https://example.net/phishing",
    }

    assert_redirected_to root_url
  end

  test "structured return locations are ignored" do
    [{ nested: settings_path }, [settings_path]].each do |return_to|
      post session_path, params: { email: @identity.email, password: "password", return_to: return_to }

      assert_redirected_to root_url
      delete session_path
    end
  end

  # `url_from` trusts the host, not the origin; an accepted location is carried as its path, so the
  # redirect lands on THIS origin, never:444.
  test "a same-host return location on another origin is resumed on this origin, never there" do
    post session_path, params: {
      email: identities(:member).email,
      password: "password",
      return_to: "https://www.example.com:444/settings",
    }

    assert_redirected_to settings_url
  end

  # The verdict is `url_from`'s (Rails' own open-redirect fence): a hostile
  # location of any spelling falls back to the dashboard.
  test "hostile return locations fall back to the dashboard" do
    ["//evil.example", "/\\evil", "/x\r\nSet-Cookie: a=b", "/x ", "javascript:alert(1)",
     "http://evil.example/x"].each do |hostile|
      post session_path, params: { email: @identity.email, password: "password", return_to: hostile }
      assert_redirected_to root_url, hostile.inspect
      delete session_path
    end
  end

  # Paths resume as given; a same-host absolute location resumes as its
  # path (accepted, where the old regex refused every absolute form); a raw
  # space is an invalid URI and is refused (the old regex let it through).
  test "accepted return locations are resumed as paths on this origin" do
    { "/settings" => settings_url,
      "/oauth/device?user_code=ABCD-EFGH" => oauth_device_url(user_code: "ABCD-EFGH"),
      "http://www.example.com/settings" => settings_url,
      "/a b" => root_url }.each do |given, destination|
      post session_path, params: { email: @identity.email, password: "password", return_to: given }
      assert_redirected_to destination, given.inspect
      delete session_path
    end
  end

  test "destroy signs out" do
    sign_in_as users(:member)

    assert_difference -> { Session.count }, -1 do
      delete session_path
    end

    assert_redirected_to new_session_path
    assert cookies[:session_id].blank?
  end

  private

    def return_to_from(location)
      Rack::Utils.parse_nested_query(URI(location).query).fetch("return_to")
    end
end
