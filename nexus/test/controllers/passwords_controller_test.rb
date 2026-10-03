require "test_helper"

class PasswordsControllerTest < ActionDispatch::IntegrationTest
  setup { @identity = identities(:member) }

  test "new" do
    get new_password_path
    assert_response :success
    assert_capability_page_response
    assert_select "form"
  end

  test "new explains unavailability instead of a form when mail is disabled" do
    ApplicationMailer.stub(:delivery_configured?, false) do
      get new_password_path
    end

    assert_response :success
    assert_capability_page_response
    assert_select "input[name='email']", count: 0
    assert_select "[role='alert']", text: /no outbound mail/
  end

  test "the consume rate limit rejects the eleventh attempt in the window" do
    11.times { |i| get edit_password_path(token: "guess-#{i}") }

    assert_redirected_to new_password_path
    assert_capability_response_headers
    assert_equal I18n.t("passwords.create.rate_limited"), flash[:alert]
  end

  test "the request rate limit rejects the eleventh attempt in the window" do
    11.times { post passwords_path, params: { email: "someone@example.com" } }

    assert_redirected_to new_password_path
    assert_capability_response_headers
    assert_equal I18n.t("passwords.create.rate_limited"), flash[:alert]
  end

  test "request for an eligible address schedules one reset mail" do
    assert_enqueued_email_with PasswordsMailer, :reset, args: [@identity] do
      post passwords_path, params: { email: @identity.email }
    end

    assert_redirected_to new_session_path
    assert_capability_response_headers
    assert_equal I18n.t("passwords.create.sent"), flash[:notice]
  end

  test "request response stays generic when Solid Queue cannot enqueue the reset mail" do
    delivery = Object.new
    error = SolidQueue::Job::EnqueueError.new("queue unavailable")
    reports = []
    delivery.define_singleton_method(:deliver_later) { raise error }

    Rails.error.stub(:report, ->(reported, handled:) { reports << [reported, handled] }) do
      PasswordsMailer.stub(:reset, delivery) do
        post passwords_path, params: { email: @identity.email }
      end
    end

    assert_redirected_to new_session_path
    assert_capability_response_headers
    assert_equal I18n.t("passwords.create.sent"), flash[:notice]
    assert_equal [[error, true]], reports
  end

  test "request responses are identical for unknown, ineligible, and mail-disabled addresses" do
    ApplicationMailer.stub(:delivery_configured?, false) do
      assert_no_enqueued_emails do
        post passwords_path, params: { email: @identity.email }
      end
      assert_redirected_to new_session_path
      assert_capability_response_headers
      assert_equal I18n.t("passwords.create.sent"), flash[:notice]
    end
  end

  test "request responses are identical for unknown and ineligible addresses" do
    assert_no_enqueued_emails do
      post passwords_path, params: { email: "unknown@example.com" }
    end
    assert_redirected_to new_session_path
    assert_capability_response_headers
    assert_equal I18n.t("passwords.create.sent"), flash[:notice]

    users(:member).update!(status: :suspended)
    assert_no_enqueued_emails do
      post passwords_path, params: { email: @identity.email }
    end
    assert_redirected_to new_session_path
    assert_capability_response_headers
    assert_equal I18n.t("passwords.create.sent"), flash[:notice]
  end

  test "edit with a valid token" do
    get edit_password_path(token: @identity.password_reset_token)
    assert_response :success
    assert_capability_page_response
  end

  test "edit with an invalid token" do
    get edit_password_path(token: "invalid token")
    assert_redirected_to new_password_path
    assert_capability_response_headers
  end

  test "edit for an ineligible identity fails safely" do
    token = @identity.password_reset_token
    users(:member).update!(status: :suspended)

    get edit_password_path(token: token)
    assert_redirected_to new_password_path
    assert_capability_response_headers
  end

  test "an expired token fails safely" do
    token = @identity.password_reset_token

    travel 16.minutes do
      get edit_password_path(token: token)
      assert_redirected_to new_password_path
      assert_capability_response_headers
    end
  end

  test "the reset token never travels in a route path segment" do
    email = PasswordsMailer.reset(@identity)

    [email.text_part.body.to_s, email.html_part.body.to_s].each do |body|
      assert_match "/passwords/edit?token=", body
    end
  end

  test "update changes the password, advances the recovery generation, and fences earlier sessions" do
    sign_in_as users(:member)
    token = @identity.password_reset_token

    assert_changes -> { @identity.reload.credential_recovery_generation }, from: 0, to: 1 do
      put passwords_path, params: { token: token, password: "a brand new password", password_confirmation: "a brand new password" }
    end
    assert_redirected_to new_session_path
    assert_capability_response_headers

    assert @identity.reload.authenticate("a brand new password")
    assert_nil Identity.find_by_password_reset_token(token)

    # The pre-reset session cookie no longer authenticates.
    get root_path
    assert_redirected_to new_session_path(return_to: root_path)
  end

  test "update with non matching passwords changes nothing" do
    token = @identity.password_reset_token

    assert_no_changes -> { @identity.reload.credential_recovery_generation } do
      put passwords_path, params: { token: token, password: "a brand new password", password_confirmation: "different" }
    end

    assert_response :unprocessable_entity
    assert_capability_page_response
    assert_select "input[name='token'][value=?]", token
    assert_select "input[name='password_confirmation'][aria-invalid='true'][aria-describedby='password_confirmation_errors']"
    assert_select "#password_confirmation_errors p.field-error"
    assert @identity.reload.authenticate("password")
  end

  private

    def assert_capability_page_response
      assert_capability_response_headers
      assert_select "meta[name='turbo-cache-control'][content='no-cache']", visible: false
    end

    def assert_capability_response_headers
      assert_equal "no-store", response.headers["Cache-Control"]
      assert_equal "no-referrer", response.headers["Referrer-Policy"]
    end
end
