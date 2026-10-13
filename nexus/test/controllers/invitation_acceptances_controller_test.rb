require "test_helper"

class InvitationAcceptancesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @invitation = accounts(:cybros).invitations.create!(
      inviter: users(:owner), email: "invited@example.com"
    )
  end

  test "a valid link renders the acceptance form with the fixed email and role" do
    get join_path(token: @invitation.acceptance_token)

    assert_response :success
    assert_capability_page_response
    assert_select "h1", /Join/
    assert_select "p", /invited@example.com/
  end

  test "a garbage or missing token renders the generic invalid page" do
    get join_path(token: "garbage")
    assert_response :not_found
    assert_capability_page_response

    get join_path
    assert_response :not_found
    assert_capability_page_response
  end

  test "an expired invitation renders the generic invalid page" do
    token = @invitation.acceptance_token

    travel Invitation::VALIDITY_PERIOD + 1.minute do
      get join_path(token: token)
      assert_response :not_found
      assert_capability_page_response
    end
  end

  test "an invitation at its exact expiry renders the generic invalid page" do
    travel_to @invitation.expires_at, with_usec: true do
      get join_path(token: @invitation.acceptance_token)

      assert_response :not_found
      assert_capability_page_response
    end
  end

  test "acceptance creates the member, signs them in, and lands on the dashboard" do
    assert_difference [-> { Identity.count }, -> { User.count }], +1 do
      assert_difference -> { Invitation.count }, -1 do
        post join_path, params: acceptance_params
      end
    end

    assert_redirected_to root_path
    assert_capability_response_headers
    assert cookies[:session_id].present?

    get root_path
    assert_response :success
  end

  test "acceptance does not inherit another page's login return location" do
    get settings_path
    assert_redirected_to new_session_path(return_to: settings_path)

    post join_path, params: acceptance_params
    assert_redirected_to root_path

    accepted_identity = Identity.find_by!(email: @invitation.email)
    accepted_identity.sessions.delete_all

    post session_path, params: { email: accepted_identity.email, password: "long enough password" }
    assert_redirected_to root_path
  end

  test "a validation failure re-renders the form with field errors" do
    assert_no_difference -> { Identity.count } do
      post join_path, params: acceptance_params(password_confirmation: "different")
    end

    assert_response :unprocessable_entity
    assert_capability_page_response
    assert_select "p.field-error"
    assert_select "input[name='acceptance[display_name]'][value=?]", "Invited"
    assert_select "input[name='acceptance[password_confirmation]'][aria-invalid='true'][aria-describedby='acceptance_password_confirmation_errors']"
    assert_select "#acceptance_password_confirmation_errors p.field-error"
    assert_select "input[name='acceptance[display_name]'][aria-invalid='false']:not([aria-describedby])"
  end

  test "acceptance for an email that became a member points to sign in and keeps the row" do
    identity = accounts(:cybros).identities.create!(
      email: "invited@example.com",
      password: "long enough password", password_confirmation: "long enough password"
    )
    accounts(:cybros).users.create!(kind: :human, role: :member, identity: identity, display_name: "Registered")

    assert_no_difference -> { Invitation.count } do
      post join_path, params: acceptance_params
    end

    assert_redirected_to new_session_path
    assert_capability_response_headers
    assert_equal I18n.t("invitation_acceptances.create.member_already_exists"), flash[:alert]
  end

  test "a consumed link is gone for the loser of a double submit" do
    post join_path, params: acceptance_params
    assert_redirected_to root_path

    post join_path, params: acceptance_params
    assert_response :not_found
    assert_capability_page_response
  end

  test "rate limiting keeps the invitation capability in the retry location" do
    token = @invitation.acceptance_token

    10.times do
      post join_path, params: acceptance_params(password_confirmation: "different")
      assert_response :unprocessable_entity
    end

    post join_path, params: acceptance_params(password_confirmation: "different")

    assert_redirected_to join_path(token: token)
    assert_capability_response_headers
    assert_equal I18n.t("invitation_acceptances.create.rate_limited"), flash[:alert]

    post join_path, params: acceptance_params.merge(token: { nested: "invalid" })

    assert_response :redirect
    assert_capability_response_headers
    assert_match "/join?token=", response.location
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

    def acceptance_params(**overrides)
      {
        token: @invitation.acceptance_token,
        acceptance: {
          display_name: "Invited",
          password: "long enough password",
          password_confirmation: "long enough password",
        }.merge(overrides),
      }
    end
end
