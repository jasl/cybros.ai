require "test_helper"

class SettingsTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as users(:member)
  end

  test "the settings page requires authentication" do
    sign_out
    get settings_path
    assert_redirected_to new_session_path(return_to: settings_path)
  end

  test "settings starts with profile in one navigable frame" do
    get settings_path

    assert_response :success
    assert_select "title", text: "Settings · Nexus"
    assert_select "turbo-frame#settings[data-turbo-action='replace']" do
      assert_select "a[href=?][aria-current='page']", settings_path, text: "Profile"
      assert_select "a[href=?]", settings_email_path
      assert_select "a[href=?]", settings_password_path
      assert_select "a[href=?]", settings_sessions_path
      assert_select "input[name='profile[display_name]'][value=?]", users(:member).display_name
      assert_select "input[name='profile[handle]'][value=?]", "member"
      assert_select "form[action=?][data-turbo-frame='_top']", settings_profile_path
      assert_select "input[name='email[email]']", count: 0
      assert_select "input[name='password[password]']", count: 0
    end
  end

  test "a Turbo frame request still receives HTML with the settings frame" do
    get settings_path, headers: {
      "Accept" => "text/vnd.turbo-stream.html, text/html",
      "Turbo-Frame" => "settings",
    }

    assert_response :success
    assert_equal "text/html", response.media_type
    assert_select "turbo-frame#settings"
  end

  test "email editor renders inside the settings frame" do
    get settings_email_path

    assert_response :success
    assert_select "title", text: "Settings · Nexus"
    assert_select "turbo-frame#settings" do
      assert_select "a[href=?][aria-current='page']", settings_email_path, text: "Email"
      assert_select "input[name='email[email]'][value=?]", identities(:member).email
      assert_select "form[action=?][data-turbo-frame='_top']", settings_email_path
      assert_select "input[name='profile[display_name]']", count: 0
      assert_select "input[name='password[password]']", count: 0
    end
  end

  test "password editor renders inside the settings frame" do
    get settings_password_path

    assert_response :success
    assert_select "title", text: "Settings · Nexus"
    assert_select "turbo-frame#settings" do
      assert_select "a[href=?][aria-current='page']", settings_password_path, text: "Password"
      assert_select "input[name='password[password]']"
      assert_select "form[action=?][data-turbo-frame='_top']", settings_password_path
      assert_select "input[name='profile[display_name]']", count: 0
      assert_select "input[name='email[email]']", count: 0
    end
  end

  test "profile update changes the display name" do
    patch settings_profile_path, params: { profile: { display_name: "Renamed Member" } }

    assert_redirected_to settings_path
    assert_equal "Renamed Member", users(:member).reload.display_name
  end

  # THE HUMAN'S OWN HANDLE: chosen through the same profile door as the display name; normalized,
  # judged by the one format, unique in the account.
  test "profile update changes the handle; a taken or malformed one re-renders with a field error" do
    patch settings_profile_path, params: { profile: { display_name: "Member", handle: " Ada_L " } }

    assert_redirected_to settings_path
    assert_equal "ada_l", users(:member).reload.handle

    patch settings_profile_path, params: { profile: { display_name: "Member", handle: "owner" } }
    assert_response :unprocessable_entity
    assert_select "input[name='profile[handle]'][value='owner']"
    assert_select "p.field-error", text: /taken/
    assert_equal "ada_l", users(:member).reload.handle

    patch settings_profile_path, params: { profile: { display_name: "Member", handle: "no spaces!" } }
    assert_response :unprocessable_entity
    assert_select "p.field-error", text: /invalid/
  end

  test "a blank display name re-renders with a field error" do
    patch settings_profile_path, params: { profile: { display_name: "" } }

    assert_response :unprocessable_entity
    assert_select "turbo-frame#settings" do
      assert_select "p.field-error"
      assert_select "input[name='profile[display_name]'][value='']"
    end
    assert_select "aside summary span", text: users(:member).display_name
    assert_not_equal "", users(:member).reload.display_name

    get settings_profile_path
    assert_response :success
  end

  test "email change requires the current password" do
    patch settings_email_path, params: { email: { email: "new@example.com", current_password: "wrong" } }

    assert_response :unprocessable_entity
    assert_equal identities(:member).email, identities(:member).reload.email
    assert_select "turbo-frame#settings" do
      assert_select "input[name='email[email]'][value=?]", "new@example.com"
      assert_select "#email_current_password_errors"
    end
  end

  test "email change updates the address" do
    patch settings_email_path, params: { email: { email: "new@example.com", current_password: "password" } }

    assert_redirected_to settings_email_path
    identity = identities(:member).reload
    assert_equal "new@example.com", identity.email
  end

  test "email change rejects an address another identity owns" do
    patch settings_email_path, params: { email: { email: identities(:owner).email, current_password: "password" } }

    assert_response :unprocessable_entity
    assert_equal identities(:member).email, identities(:member).reload.email
  end

  test "email change rejects an address held by an invitation" do
    accounts(:cybros).invitations.create!(
      inviter: users(:owner), email: "invited-address@example.com"
    )

    patch settings_email_path, params: {
      email: {
        email: "invited-address@example.com",
        current_password: "password",
      },
    }

    assert_response :unprocessable_entity
    assert_equal identities(:member).email, identities(:member).reload.email
    assert_select "turbo-frame#settings" do
      assert_select "input[name='email[email]'][value=?]", "invited-address@example.com"
      assert_select "#email_email_errors p.field-error"
    end
  end

  test "password change replaces this session and fences every other one" do
    other_device = create_browser_session(identities(:member))
    original_session = Session.find_by!(public_id: parsed_cookies.signed[:session_id])

    # The presented session is consumed and replaced: net zero rows.
    assert_no_difference -> { Session.count } do
      patch settings_password_path, params: {
        password: { current_password: "password", password: "a brand new password", password_confirmation: "a brand new password" },
      }
    end

    assert_redirected_to settings_password_path
    identity = identities(:member).reload
    assert identity.authenticate("a brand new password")
    assert_equal 1, identity.credential_recovery_generation

    # This browser rides the replacement.
    replacement = Session.find_by!(public_id: parsed_cookies.signed[:session_id])
    assert_not_equal original_session.id, replacement.id
    assert replacement.usable?
    # The presented session was consumed (deleted); the other device's row
    # survives but is fenced by its stale generation snapshot.
    assert_nil Session.find_by(id: original_session.id)
    assert_not other_device.reload.usable?

    get settings_path
    assert_response :success
  end

  test "password change rejects a wrong current password without a state change" do
    assert_no_difference -> { Session.count } do
      patch settings_password_path, params: {
        password: { current_password: "wrong", password: "a brand new password", password_confirmation: "a brand new password" },
      }
    end

    assert_response :unprocessable_entity
    assert identities(:member).reload.authenticate("password")
    assert_select "turbo-frame#settings"
    assert_select "input[name='password[password]'][value]", count: 0
  end

  test "current-password verification is rate limited across sensitive settings commands" do
    10.times do
      patch settings_email_path, params: {
        email: { email: "new@example.com", current_password: "wrong" },
      }
      assert_response :unprocessable_entity
    end

    patch settings_password_path, params: {
      password: { current_password: "wrong", password: "a brand new password", password_confirmation: "a brand new password" },
    }

    assert_redirected_to settings_password_path
    assert_equal I18n.t("settings.current_password_rate_limited"), flash[:alert]
  end

  private

    def parsed_cookies
      ActionDispatch::Cookies::CookieJar.build(request, cookies.to_hash)
    end

  # THE COOLDOWN at the human's door: a name another member released within 14 days is refused with
  # the cooldown named; after it, free; one's own previous name at once; a swap waits out the
  # cooldown.
  test "a handle another member released within 14 days is refused naming the cooldown; free after; one's own at once; a swap waits" do
    curator = users(:curator)
    travel_to(3.days.ago) { curator.update!(handle: "keeper") }

    patch settings_profile_path, params: { profile: { handle: "curator" } }
    assert_response :unprocessable_entity
    assert_select "p.field-error", text: /14 days/
    assert_equal "member", users(:member).reload.handle

    travel 12.days
    patch settings_profile_path, params: { profile: { handle: "curator" } }
    assert_redirected_to settings_path
    assert_equal "curator", users(:member).reload.handle
    assert_equal({ "user_public_id" => users(:member).public_id, "old" => "member", "new" => "curator" },
      users(:member).conversation_event_items.sole.payload, "the human's door narrates handle_changed on the member")

    patch settings_profile_path, params: { profile: { handle: "member" } }
    assert_redirected_to settings_path
    assert_equal "member", users(:member).reload.handle, "the releaser retakes its own name at once"

    patch settings_profile_path, params: { profile: { handle: "keeper" } }
    assert_response :unprocessable_entity
    assert_select "p.field-error", text: /taken/
    curator.update!(handle: "tmp")
    patch settings_profile_path, params: { profile: { handle: "keeper" } }
    assert_response :unprocessable_entity
    assert_select "p.field-error", text: /14 days/
    assert_equal "member", users(:member).reload.handle
  end
end
