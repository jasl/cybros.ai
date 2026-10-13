require "test_helper"

# Multi-tab connection independence and resume behavior.
class OAuth::DeviceMultiTabTest < ActionDispatch::IntegrationTest
  setup { sign_in_as users(:owner) }

  VERIFIED_CONTEXT_COOKIE =
    OAuth::BrowserController::VERIFIED_GRANT_CONTEXT_COOKIE_NAME.to_s.freeze

  def mint(identifier)
    DeviceAuthorizations::Issue.call(
      account: accounts(:cybros), agent_identifier: identifier, agent_display_name: "Multi",
      requested_executor_display_name: "App").authorization
  end

  def verify(grant)
    post oauth_device_verification_path, params: { verification: { user_code: grant.formatted_user_code } }
    assert_redirected_to oauth_device_grant_path(grant.public_id)
  end

  test "two grants verified in one session stay independent and both addressable" do
    a = mint("install-a")
    b = mint("install-b")

    verify(a)
    verify(b)

    get oauth_device_grant_path(a.public_id)
    assert_response :success
    assert_select "p", text: a.formatted_user_code
    assert_select "body", text: /install-a/, count: 0

    get oauth_device_grant_path(b.public_id)
    assert_response :success
    assert_select "p", text: b.formatted_user_code
    assert_select "body", text: /install-b/, count: 0

    # Canceling one leaves the other pending.
    post oauth_device_grant_cancellation_path(a.public_id)
    assert a.reload.canceled?
    assert b.reload.pending?
  end

  test "concurrent first responses converge when their cookies are applied out of order" do
    grant = mint("install-first-context-race")
    initial_cookies = cookies.to_hash
    assert_empty verified_grant_cookie_names

    # Both requests start from the exact same pre-context cookie snapshot,
    # which is the server-observable state of concurrent first GETs.
    first = ActionDispatch::Integration::Session.new(Rails.application)
    delayed = ActionDispatch::Integration::Session.new(Rails.application)
    initial_cookies.each do |name, value|
      first.cookies[name] = value
      delayed.cookies[name] = value
    end
    first.get oauth_device_path
    delayed.get oauth_device_path
    assert_equal 200, first.response.status
    assert_equal 200, delayed.response.status

    first.post oauth_device_verification_path,
      params: { verification: { user_code: grant.formatted_user_code } }
    assert_equal 302, first.response.status

    # Apply the successful tab's cookie, then the delayed first GET's
    # Set-Cookie. Random first values would replace A with B and lose the
    # recorded capability; Session-derived values are identical.
    first.cookies.to_hash.each { |name, value| cookies[name] = value }
    delayed.cookies.to_hash.each { |name, value| cookies[name] = value }

    get oauth_device_grant_path(grant.public_id)
    assert_response :success
    assert_equal 1, grant.device_grant_verifications.count
    assert_equal [VERIFIED_CONTEXT_COOKIE], verified_grant_cookie_names
  end

  test "two tabs posting from one initial context cannot overwrite each other's grant capability" do
    a = mint("install-concurrent-a")
    b = mint("install-concurrent-b")
    get oauth_device_path
    assert_response :success
    initial_cookies = cookies.to_hash
    tab_a = ActionDispatch::Integration::Session.new(Rails.application)
    tab_b = ActionDispatch::Integration::Session.new(Rails.application)
    initial_cookies.each do |name, value|
      tab_a.cookies[name] = value
      tab_b.cookies[name] = value
    end

    tab_a.post oauth_device_verification_path,
      params: { verification: { user_code: a.formatted_user_code } }
    tab_b.post oauth_device_verification_path,
      params: { verification: { user_code: b.formatted_user_code } }

    tab_a.cookies.to_hash.each { |name, value| cookies[name] = value }
    tab_b.cookies.to_hash.each { |name, value| cookies[name] = value }

    get oauth_device_grant_path(a.public_id)
    assert_response :success
    get oauth_device_grant_path(b.public_id)
    assert_response :success

    assert_equal 2, DeviceGrantVerification.where(device_authorization: [a, b]).count
    assert_equal [VERIFIED_CONTEXT_COOKIE], verified_grant_cookie_names
  end

  test "many independently addressable grants keep exactly one browser context cookie" do
    grants = 12.times.map { |index| mint("install-bounded-#{index}") }

    assert_difference -> {
      DeviceGrantVerification.where(device_authorization: grants).count
    }, grants.length do
      grants.each_slice(6) do |slice|
        slice.each { |grant| verify(grant) }
        Rails.cache.clear
      end
    end

    grants.each do |grant|
      get oauth_device_grant_path(grant.public_id)
      assert_response :success
    end
    assert_equal [VERIFIED_CONTEXT_COOKIE], verified_grant_cookie_names
  end

  test "the browser-held grant context survives replacing the signed-in session" do
    grant = mint("install-session-replacement")
    verify(grant)

    sign_out
    sign_in_as users(:member)

    get oauth_device_grant_path(grant.public_id)
    assert_response :success
    assert_equal [VERIFIED_CONTEXT_COOKIE], verified_grant_cookie_names
  end

  test "a signed-out human following the complete URI resumes code entry after login" do
    grant = mint("install-resume")
    sign_out

    get oauth_device_path(user_code: grant.formatted_user_code)
    return_to = oauth_device_path(user_code: grant.formatted_user_code)
    assert_redirected_to new_session_path(return_to: return_to)

    post session_path, params: {
      email: users(:owner).email,
      password: "password",
      return_to: return_to,
    }
    assert_redirected_to oauth_device_url(user_code: grant.formatted_user_code)
  end

  test "an ordinary member reaches the ceremony (spec 01 D15 relaxed)" do
    sign_out
    sign_in_as users(:member)

    get oauth_device_path
    assert_response :success
  end

  private

    def verified_grant_cookie_names
      cookies.to_hash.keys.grep(/\Averified_device_grant(?:_|$)/).sort
    end
end
