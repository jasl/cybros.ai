require "test_helper"

class Admin::InvitationsControllerTest < ActionDispatch::IntegrationTest
  include ActiveRecord::Assertions::QueryAssertions

  setup do
    sign_in_as users(:owner)
  end

  test "index renders the invitation list" do
    invitation = create_invitation

    get admin_invitations_path
    assert_response :success
    assert_select "[data-invitation-id='#{invitation.public_id}']", text: /#{Regexp.escape(invitation.email)}/
  end

  test "index renders a page without a redundant invitation existence query" do
    create_invitation

    assert_no_queries_match(/SELECT 1 AS one FROM "invitations"/) do
      get admin_invitations_path
    end

    assert_response :success
  end

  test "create schedules one email and records the delivery request" do
    assert_difference -> { Invitation.count }, +1 do
      assert_enqueued_emails 1 do
        post admin_invitations_path, params: { invitation: { email: "new@example.com", role: "member" } }
      end
    end

    assert_redirected_to admin_invitations_path
    invitation = Invitation.find_by!(email: "new@example.com")
    assert invitation.last_delivery_requested_at.present?
    assert_equal users(:owner), invitation.inviter
  end

  test "create with a registered email redirects with an alert and schedules nothing" do
    assert_no_difference -> { Invitation.count } do
      assert_no_enqueued_emails do
        post admin_invitations_path, params: { invitation: { email: "member@example.com", role: "member" } }
      end
    end

    assert_redirected_to admin_invitations_path
    assert_equal "Email already belongs to a member", flash[:alert]
  end

  test "create with an already invited email redirects with an alert" do
    create_invitation

    assert_no_difference -> { Invitation.count } do
      post admin_invitations_path, params: { invitation: { email: "invited@example.com", role: "member" } }
    end

    assert_redirected_to admin_invitations_path
    assert_equal "Email has already been taken", flash[:alert]
  end

  test "create without mail succeeds link-only: no email, no delivery request recorded" do
    ApplicationMailer.stub(:delivery_configured?, false) do
      assert_difference -> { Invitation.count }, +1 do
        assert_no_enqueued_emails do
          post admin_invitations_path, params: { invitation: { email: "new@example.com", role: "member" } }
        end
      end
    end

    assert_redirected_to admin_invitations_path
    assert_equal I18n.t("admin.invitations.create.link_only"), flash[:notice]

    invitation = Invitation.find_by!(email: "new@example.com")
    assert_nil invitation.last_delivery_requested_at
    assert_in_delta Invitation::VALIDITY_PERIOD.from_now, invitation.expires_at, 5.seconds
  end

  test "every invitation reveals a working acceptance link" do
    invitation = create_invitation

    get admin_invitations_path
    assert_select "[data-invitation-id='#{invitation.public_id}'] [data-controller='clipboard']" do
      assert_select "input[readonly][value=?]", join_url(token: invitation.acceptance_token)
      assert_select "button[data-action='clipboard#copy']", text: "Copy"
    end
    assert_select "[popover]", count: 0

    # The revealed link is the same authority the mail carries.
    assert_equal invitation, Invitation.find_by_acceptance_token(invitation.acceptance_token)
  end

  test "invitation links follow the direct request origin without a configured domain" do
    invitation = create_invitation
    host! "192.168.1.20:8443"
    post session_path, params: {
      email: users(:owner).email,
      password: "password",
    }
    assert cookies[:session_id].present?

    get admin_invitations_path

    field = css_select("input[readonly]").sole
    assert_equal(
      "http://192.168.1.20:8443#{join_path(token: invitation.acceptance_token)}",
      field["value"]
    )
  end

  test "a configured domain origin overrides the invitation request origin" do
    invitation = create_invitation
    host! "untrusted.example:8443"
    post session_path, params: {
      email: users(:owner).email,
      password: "password",
    }
    assert cookies[:session_id].present?

    with_route_url_options(
      { host: "nexus.example", protocol: "https", port: 443 }
    ) do
      get admin_invitations_path

      field = css_select("input[readonly]").sole
      assert_equal(
        "https://nexus.example#{join_path(token: invitation.acceptance_token)}",
        field["value"]
      )
    end
  end

  test "destroy revokes the invitation and its links" do
    invitation = create_invitation
    token = invitation.acceptance_token

    assert_difference -> { Invitation.count }, -1 do
      delete admin_invitation_path(invitation)
    end

    assert_redirected_to admin_invitations_path
    assert_nil Invitation.find_by_acceptance_token(token)
  end

  test "resend after the interval renews and schedules one email" do
    invitation = create_invitation

    travel Invitation::RESEND_INTERVAL + 1.second do
      assert_enqueued_emails 1 do
        post admin_invitation_resend_path(invitation)
      end
    end

    assert_redirected_to admin_invitations_path
    assert_equal I18n.t("admin.invitations.resend.requested"), flash[:notice]
  end

  test "resend inside the interval schedules nothing and reports the remaining wait" do
    invitation = create_invitation

    assert_no_enqueued_emails do
      post admin_invitation_resend_path(invitation)
    end

    assert_redirected_to admin_invitations_path
    assert flash[:alert].present?
  end

  test "an enqueue failure after create leaves the invitation and cooldown in place" do
    InvitationMailer.stub(:acceptance, ->(*) { raise "queue down" }) do
      assert_difference -> { Invitation.count }, +1 do
        assert_raises RuntimeError do
          post admin_invitations_path, params: { invitation: { email: "new@example.com", role: "member" } }
        end
      end
    end

    invitation = Invitation.find_by!(email: "new@example.com")
    assert invitation.last_delivery_requested_at.present?
  end

  test "resend for an email that became a member reports member_already_exists" do
    invitation = create_invitation
    identity = accounts(:cybros).identities.create!(email: invitation.email, password: "long enough password", password_confirmation: "long enough password")
    accounts(:cybros).users.create!(kind: :human, role: :member, identity: identity, display_name: "Registered")

    travel Invitation::RESEND_INTERVAL + 1.second do
      assert_no_enqueued_emails do
        post admin_invitation_resend_path(invitation)
      end
    end

    assert_equal I18n.t("admin.invitations.member_already_exists"), flash[:alert]
  end

  test "resend while mail is known-disabled changes nothing" do
    invitation = create_invitation

    travel Invitation::RESEND_INTERVAL + 1.second do
      ApplicationMailer.stub(:delivery_configured?, false) do
        assert_no_changes -> { invitation.reload.expires_at } do
          post admin_invitation_resend_path(invitation)
        end
      end
    end

    assert_equal I18n.t("admin.invitations.mail_delivery_unavailable"), flash[:alert]
  end

  test "the list renders the cooldown countdown for a fresh invitation" do
    create_invitation

    get admin_invitations_path
    assert_select "[data-controller='countdown']"
    assert_select "button[disabled]", text: /Resend in \d+s/
  end

  test "the list renders expired state and an enabled resend after the cooldown" do
    invitation = create_invitation
    invitation.update!(expires_at: 2.days.ago, last_delivery_requested_at: 9.days.ago)

    get admin_invitations_path(filter: "all")
    assert_select "[data-invitation-id='#{invitation.public_id}']" do
      assert_select "span.badge", text: "Expired"
      assert_select "button[disabled]", text: "Expired"
      assert_select "p", text: "Resend before sharing this link."
    end
    assert_select "form[action='#{admin_invitation_resend_path(invitation)}'] button:not([disabled])"
  end

  test "known-disabled mail keeps the create form and labels a link-only invitation as unsent" do
    invitation = nil
    ApplicationMailer.stub(:delivery_configured?, false) do
      invitation = create_invitation
      get admin_invitations_path
    end

    assert_select "input[name='invitation[email]']"
    assert_select "[data-invitation-id='#{invitation.public_id}']" do
      assert_select "input[readonly][value=?]", join_url(token: invitation.acceptance_token)
      assert_select "span.badge", text: "Link only"
      assert_select "form[action='#{admin_invitation_resend_path(invitation)}'] button[disabled]", text: "Send email"
    end
    assert_select "p", text: /share each unexpired\s+invitation's link manually/
  end

  test "an expired link explains replacement when mail is unavailable" do
    invitation = create_invitation
    invitation.update!(expires_at: 1.day.ago)

    ApplicationMailer.stub(:delivery_configured?, false) do
      get admin_invitations_path(filter: "all")
    end

    assert_select "[data-invitation-id='#{invitation.public_id}']" do
      assert_select "input[readonly][value=?]", join_url(token: invitation.acceptance_token)
      assert_select "button[disabled]", text: "Expired"
      assert_select "button[data-action='clipboard#copy']", count: 0
      assert_select "p", text: "Revoke and create a replacement before sharing."
    end
  end

  test "pending invitations are the default and exclude expired rows" do
    pending_invitation = create_invitation
    expired_invitation = accounts(:cybros).invitations.create!(
      inviter: users(:owner), email: "expired@example.com", expires_at: 1.day.ago
    )

    get admin_invitations_path

    assert_select "[data-invitation-id='#{pending_invitation.public_id}']"
    assert_select "[data-invitation-id='#{expired_invitation.public_id}']", count: 0
    assert_select "nav[aria-label='Invitation filters'] a[aria-current='page']", text: "Pending", count: 1
  end

  test "all invitations include expired rows" do
    pending_invitation = create_invitation
    expired_invitation = accounts(:cybros).invitations.create!(
      inviter: users(:owner), email: "expired@example.com", expires_at: 1.day.ago
    )

    get admin_invitations_path(filter: "all")

    assert_select "[data-invitation-id='#{pending_invitation.public_id}']"
    assert_select "[data-invitation-id='#{expired_invitation.public_id}']"
    assert_select "nav[aria-label='Invitation filters'] a[aria-current='page']", text: "All", count: 1
  end

  test "the all-invitations list paginates every invitation instead of truncating" do
    created_at = 1.hour.ago
    oldest_invitation = nil
    26.times do |number|
      invitation = accounts(:cybros).invitations.create!(
        inviter: users(:owner),
        email: format("page-%02d@example.com", number),
        expires_at: 1.day.ago,
        created_at: created_at,
        updated_at: created_at
      )
      oldest_invitation = invitation if number.zero?
    end

    get admin_invitations_path, query: { filter: "all", view: "compact" }
    assert_response :success
    assert_select "[data-invitation-id]", count: 25
    assert_select "[data-invitation-id='#{oldest_invitation.public_id}']", count: 0
    assert_select "p", text: "Showing 1–25 of 26 invitations"
    assert_select "nav[aria-label='Invitations pages'] .join"
    assert_select "nav[aria-label='Invitations pages'] a", text: "2" do |links|
      query = Rack::Utils.parse_query(URI.parse(links.first["href"]).query)
      assert_equal({ "filter" => "all", "page" => "2", "view" => "compact" }, query)
    end

    get admin_invitations_path(filter: "all", page: 2)
    assert_response :success
    assert_select "[data-invitation-id]", count: 1
    assert_select "[data-invitation-id='#{oldest_invitation.public_id}']"
    assert_select "p", text: "Showing 26–26 of 26 invitations"
  end

  test "an empty pending filter explains where expired invitations went" do
    invitation = create_invitation
    invitation.update!(expires_at: 1.day.ago)

    get admin_invitations_path

    assert_response :success
    assert_select "p", text: /No pending invitations/
    assert_select "a[href='#{admin_invitations_path(filter: "all")}']", text: "All"
  end

  test "invitation commands only resolve rows in the account by public id" do
    delete admin_invitation_path(SecureRandom.uuid_v7)
    assert_response :not_found
  end

  private

    def create_invitation
      accounts(:cybros).invitations.create!(
        inviter: users(:owner), email: "invited@example.com"
      )
    end

    def with_route_url_options(options)
      previous = Rails.application.routes.default_url_options.dup
      Rails.application.routes.default_url_options = options.dup
      yield
    ensure
      Rails.application.routes.default_url_options = previous
    end
end
