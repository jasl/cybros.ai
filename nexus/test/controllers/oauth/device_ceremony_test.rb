require "test_helper"

# The cookie-only verification/connection ceremony: any active human member, exposure budget per
# distinct browser context, browser-held reloadable connection, terminal safe states.
class OAuth::DeviceCeremonyTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as users(:owner)
    @mint = DeviceAuthorizations::Issue.call(
      account: accounts(:cybros),
      agent_identifier: "install-xyz",
      agent_display_name: "Helper",
      requested_executor_display_name: "Helper app",
    )
    @grant = @mint.authorization
  end

  def verify(code = @grant.formatted_user_code)
    post oauth_device_verification_path, params: { verification: { user_code: code } }
  end

  test "the ceremony requires a signed-in member and any active member reaches it" do
    sign_out
    get oauth_device_path
    assert_redirected_to new_session_path(return_to: oauth_device_path)
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_equal "no-referrer", response.headers["Referrer-Policy"]
    follow_redirect!
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_equal "no-referrer", response.headers["Referrer-Policy"]

    # A signed-in ordinary member reaches the ceremony (any active human member may connect).
    sign_in_as users(:member)
    get oauth_device_path
    assert_response :success
  end

  test "code entry verifies, charges one exposure, and reaches the reloadable connection" do
    get oauth_device_path
    assert_response :success
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_equal "no-referrer", response.headers["Referrer-Policy"]
    refute_match(/\bidentifier\b/i, response.body)
    assert_select "input[name='verification[user_code]'][autocomplete='one-time-code']"

    verify
    assert_redirected_to oauth_device_grant_path(@grant.public_id)
    assert_equal 1, @grant.reload.exposure_count

    follow_redirect!
    assert_response :success
    assert_select "p", text: @grant.formatted_user_code
    assert_select "p", text: "Agent program"
    assert_select "body", text: /install-xyz/, count: 0
    assert_select "h1", text: "Connect agent program"
    assert_select "body", text: /Helper/, count: 0
    assert_select "body", text: /Helper app/, count: 0

    # Reload and re-verify in the same session: no second charge.
    get oauth_device_grant_path(@grant.public_id)
    assert_response :success
    verify
    assert_equal 1, @grant.reload.exposure_count
  end

  test "an expired session returns code verification to its owning GET without submitting it" do
    return_to = oauth_device_path(user_code: @grant.formatted_user_code)
    get return_to
    assert_select "input[type=hidden][name=return_to][value=?]", return_to
    users(:owner).increment!(:authority_generation)

    post oauth_device_verification_path, params: {
      return_to: return_to,
      verification: { user_code: @grant.formatted_user_code },
    }

    assert_redirected_to new_session_path(return_to: return_to)
    assert_equal 0, @grant.reload.exposure_count

    post session_path, params: {
      email: identities(:owner).email,
      password: "password",
      return_to: return_to,
    }

    assert_redirected_to return_to
    follow_redirect!
    assert_select "input[name='verification[user_code]'][value=?]", @grant.formatted_user_code
    assert_equal 0, @grant.reload.exposure_count
  end

  test "lowercase and spaced entry resolve the same code" do
    verify(@grant.formatted_user_code.downcase.tr("-", " "))
    assert_redirected_to oauth_device_grant_path(@grant.public_id)
  end

  test "wrong and unknown codes share one non-oracular error" do
    verify("AAAA-BBBB")
    assert_response :unprocessable_entity
    assert_select "span", text: I18n.t("oauth.device.unknown_code")

    verify("not even a code")
    assert_response :unprocessable_entity
  end

  test "the connection context stays bound to the browser across signed-in sessions" do
    verify

    sign_out
    sign_in_as users(:owner)
    get oauth_device_grant_path(@grant.public_id)
    assert_response :success
    assert_select "p", text: @grant.formatted_user_code
  end

  test "a new browser context cannot verify after the exposure budget is exhausted" do
    DeviceAuthorization.where(id: @grant.id).update_all(exposure_count: DeviceAuthorization::EXPOSURE_BUDGET)

    verify
    assert_response :unprocessable_entity
    assert_equal DeviceAuthorization::EXPOSURE_BUDGET, @grant.reload.exposure_count
  end

  # A double-submitted Connect is the common way to reach:stale, and the page it lands on reads
  # "Connection ready" — so the generic no-longer-available alert used to contradict what the reader
  # was looking at.
  test "connecting an already-connected grant reports what actually happened" do
    verify
    post oauth_device_grant_connection_path(@mint.authorization.public_id)
    assert_equal I18n.t("oauth.device.connected", subject: "agent program"), flash[:notice]

    post oauth_device_grant_connection_path(@mint.authorization.public_id)

    assert_redirected_to oauth_device_grant_path(@mint.authorization.public_id)
    assert_equal I18n.t("oauth.device.connected", subject: "agent program"), flash[:notice]
    assert_nil flash[:alert]
  end

  test "an expired grant materializes and renders the terminal page" do
    verify

    travel_to(@grant.expires_at + 1.minute) do
      get oauth_device_grant_path(@grant.public_id)
      assert_response :success
      assert_select "p", text: /expired/
      assert @grant.reload.expired?
    end
  end

  test "an expired code no longer verifies" do
    DeviceAuthorization.where(id: @grant.id).update_all(expires_at: 1.minute.ago)

    verify
    assert_response :unprocessable_entity
    assert @grant.reload.expired?
  end

  test "an ordinary member connects; their profile materializes only at consume" do
    sign_out
    sign_in_as users(:member)
    verify
    follow_redirect!

    assert_no_difference -> { User.count } do
      post oauth_device_grant_connection_path(@grant.public_id)
    end
    assert @grant.reload.connected?
    assert_equal users(:member), @grant.connected_by
    assert_nil @grant.user

    assert_difference -> { User.where(kind: :agent).count }, 1 do
      assert_equal :minted, DeviceAuthorizations::Consume.call(authorization: @grant).outcome
    end
    assert_equal users(:member), @grant.reload.user.steward
  end

  test "a member cannot connect another member's instance identifier" do
    # The global instance key keeps the existing ownership.
    shared = DeviceAuthorizations::Issue.call(
      account: accounts(:cybros), agent_identifier: users(:agent).agent_identifier,
      agent_display_name: "Mine too",       requested_executor_display_name: "App").authorization

    sign_out
    sign_in_as users(:member)
    post oauth_device_verification_path, params: { verification: { user_code: shared.formatted_user_code } }
    follow_redirect!
    assert_select "p", text: /Connect only when it matches exactly/
    assert_select "body", text: /Fixture Agent/, count: 0

    assert_no_difference -> { User.count } do
      post oauth_device_grant_connection_path(shared.public_id)
    end

    assert_equal I18n.t("oauth.device.agent_already_bound"), flash[:alert]
    assert_predicate shared.reload, :pending?
    assert_nil shared.user
    assert_equal users(:owner), users(:agent).reload.steward
  end
end
