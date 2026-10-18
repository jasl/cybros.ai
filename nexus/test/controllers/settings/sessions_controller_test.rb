require "test_helper"

class Settings::SessionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as users(:member)
  end

  test "index requires authentication" do
    sign_out
    get settings_sessions_path

    assert_redirected_to new_session_path(return_to: settings_sessions_path)
  end

  test "index shows the current session as logout and other sessions as revocable" do
    other_device = create_browser_session(identities(:member), user_agent: "Mozilla/5.0 Firefox/128.0")
    current = current_session

    get settings_sessions_path

    assert_response :success
    assert_select "h2", text: "Active sessions"
    assert_select "tr[data-session-id='#{current.public_id}']" do
      assert_select "span.badge", text: "This device"
      assert_select "form[action=?][data-turbo-frame='_top'] button", session_path, text: "Log out"
      assert_select "form[action=?]", settings_session_path(current.public_id), count: 0
    end
    assert_select "tr[data-session-id='#{other_device.public_id}']" do
      assert_select "form[action=?][data-turbo-frame='_top'] button", settings_session_path(other_device.public_id), text: "Revoke"
    end
  end

  test "api sessions expose their public ids so the exact bearer can be revoked" do
    issued = []

    freeze_time do
      2.times do
        post api_v1_session_path,
          params: { email: identities(:member).email, password: "password" },
          as: :json

        assert_response :created
        body = response.parsed_body
        issued << { public_id: body.dig("session", "public_id"), secret: body.fetch("token") }
      end
    end

    assert_not_equal issued.first.fetch(:public_id), issued.second.fetch(:public_id)

    get settings_sessions_path

    assert_response :success
    assert_select "p", text: "Review browser and API sessions signed in to your account and revoke access you no longer need."
    issued.each do |credential|
      public_id = credential.fetch(:public_id)
      target = "API session #{public_id}"

      assert_select "tr[data-session-id='#{public_id}']" do
        assert_select "span.font-medium", text: "API session"
        assert_select "code", text: public_id
        assert_select "button[aria-label=?][data-turbo-confirm=?]",
          "Revoke #{target}",
          "Revoke #{target}? Clients using this session lose access immediately."
      end
    end

    lost, replacement = issued
    delete settings_session_path(lost.fetch(:public_id))

    assert_redirected_to settings_sessions_path
    assert_nil Session.authenticate_api_token(lost.fetch(:secret))
    assert_equal replacement.fetch(:public_id), Session.authenticate_api_token(replacement.fetch(:secret)).public_id
  end

  test "active sessions are paginated and the current session remains reachable" do
    10.times { |number| create_browser_session(identities(:member), user_agent: "Browser #{number}") }

    get settings_sessions_path
    assert_response :success
    assert_select "tbody tr", count: 10
    assert_select "span.badge", text: "This device", count: 0
    assert_select "nav[aria-label='Active sessions pages']"
    assert_select "a[href=?]", settings_sessions_path(page: 2), text: "2"

    get settings_sessions_path(page: 2)
    assert_response :success
    assert_select "span.badge", text: "This device"
  end

  test "revoking another session removes it and stays signed in" do
    other_device = create_browser_session(identities(:member), user_agent: "Mozilla/5.0 Firefox/128.0")

    assert_difference -> { Session.count }, -1 do
      delete settings_session_path(other_device.public_id)
    end

    assert_redirected_to settings_sessions_path
    assert_nil Session.find_by(id: other_device.id)

    get settings_sessions_path
    assert_response :success
  end

  test "the current session cannot be revoked through the session-management endpoint" do
    current = current_session

    assert_no_difference -> { Session.count } do
      delete settings_session_path(current.public_id)
    end

    assert_response :not_found
    get settings_sessions_path
    assert_response :success
  end

  test "a session belonging to another identity is not revocable" do
    foreign = create_browser_session(identities(:owner))

    assert_no_difference -> { Session.count } do
      delete settings_session_path(foreign.public_id)
    end
    assert_response :not_found
  end

  private

    def current_session
      Session.find_by!(public_id: parsed_cookies.signed[:session_id])
    end

    def parsed_cookies
      ActionDispatch::Cookies::CookieJar.build(request, cookies.to_hash)
    end
end
