require "test_helper"

class Admin::UsersControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as users(:owner)
    @member = users(:member)
  end

  test "every admin user surface requires an admin" do
    sign_out
    sign_in_as @member

    get admin_users_path
    assert_response :forbidden
    get admin_user_path(@member.public_id)
    assert_response :forbidden
    get new_admin_user_path
    assert_response :forbidden
    post admin_users_path, params: { user: { display_name: "X", email: "x@example.com", role: "member", password: "p", password_confirmation: "p" } }
    assert_response :forbidden
    patch admin_user_role_path(@member.public_id), params: { role: { role: "admin" } }
    assert_response :forbidden
    post admin_user_suspension_path(@member.public_id)
    assert_response :forbidden
    post admin_user_activation_path(@member.public_id)
    assert_response :forbidden
    post admin_user_removal_path(@member.public_id)
    assert_response :forbidden
    post admin_user_restoration_path(@member.public_id)
    assert_response :forbidden
    post admin_user_ownership_transfer_path(@member.public_id)
    assert_response :forbidden
  end

  test "an out-of-vocabulary role is rejected, never coerced" do
    patch admin_user_role_path(@member.public_id), params: { role: { role: "owner" } }

    assert_redirected_to admin_user_path(@member.public_id)
    assert_equal I18n.t("admin.users.invalid_role"), flash[:alert]
    assert_equal "member", @member.reload.role
  end

  test "a removed membership refuses role changes with the not-active alert" do
    @member.remove

    patch admin_user_role_path(@member.public_id), params: { role: { role: "admin" } }
    assert_equal I18n.t("admin.users.not_active"), flash[:alert]
    assert_equal "member", @member.reload.role
  end

  test "reactivating an active member reports not suspended" do
    post admin_user_activation_path(@member.public_id)
    assert_equal I18n.t("admin.users.not_suspended"), flash[:alert]
  end

  test "transferring to a non-admin reports ineligibility" do
    post admin_user_ownership_transfer_path(@member.public_id)
    assert_equal I18n.t("admin.users.target_not_eligible"), flash[:alert]
    assert_equal "owner", users(:owner).reload.role
  end

  test "an admin viewing their own page sees the self explanation" do
    @member.change_role(to: :admin)
    sign_out
    sign_in_as @member.reload

    get admin_user_path(@member.public_id)
    assert_select "p", text: /cannot administer your own membership/
  end

  test "a removed member keeps their email on index and show and offers restore" do
    @member.remove

    get admin_users_path
    assert_select "td", text: "member@example.com"

    get admin_user_path(@member.public_id)
    assert_select "dl" do
      assert_select "dt", text: "Email"
      assert_select "dd", text: "member@example.com"
    end
    assert_select "p", text: /This membership is removed/
    assert_select "form[action=?]", admin_user_restoration_path(@member.public_id)
    assert_select "form[action=?]", admin_user_suspension_path(@member.public_id), count: 0
  end

  test "show renders membership facts and commands" do
    get admin_user_path(@member.public_id)
    assert_response :success
    assert_select "h1", text: @member.display_name
    assert_select "form[action=?]", admin_user_suspension_path(@member.public_id)
    assert_select "button[data-turbo-confirm]", text: "Suspend"
    assert_select "button[data-turbo-confirm]", text: "Remove"
  end

  test "Agent removal copy explains immediate credential revocation and background force stop" do
    agent = users(:agent)

    get admin_user_path(agent.public_id)

    assert_response :success
    assert_select "p", text: /Revokes the agent's access and credentials immediately/
    assert_select "p", text: /force-stops related conversations in the background/
    assert_select "p", text: /email address|sign-in/i, count: 0
  end

  test "removed Agent restore copy requires reconnecting without replacing the registration" do
    agent = users(:agent)
    agent.remove

    get admin_user_path(agent.public_id)

    assert_response :success
    assert_select "p", text: /access and credentials are revoked immediately/
    assert_select "p", text: /registration is retained for reconnecting/
    assert_select "p", text: /Restores the agent profile.*Old credentials remain invalid/
    assert_select "p", text: /reconnect the program to resume access/
    assert_select "p", text: /take over|mint a new credential/i, count: 0
    assert_select "p", text: /email address|sign-in/i, count: 0
  end

  test "the owner's own page explains protection instead of rendering commands" do
    get admin_user_path(users(:owner).public_id)
    assert_response :success
    assert_select "form[action=?]", admin_user_suspension_path(users(:owner).public_id), count: 0
    assert_select "p", text: /The owner cannot be administered/
  end

  test "a member outside the account or the system user is not found" do
    get admin_user_path(users(:system).public_id)
    assert_response :not_found
  end

  test "role change round-trips" do
    patch admin_user_role_path(@member.public_id), params: { role: { role: "admin" } }
    assert_redirected_to admin_user_path(@member.public_id)
    assert_equal "admin", @member.reload.role
  end

  test "suspension fences the member's session and reactivation restores sign-in" do
    other_session = create_browser_session(identities(:member))

    post admin_user_suspension_path(@member.public_id)
    assert_redirected_to admin_user_path(@member.public_id)
    assert @member.reload.suspended?
    assert_not other_session.reload.usable?

    post admin_user_activation_path(@member.public_id)
    assert @member.reload.active?
  end

  test "removal blocks later commands until restore reopens access" do
    post admin_user_removal_path(@member.public_id)
    assert @member.reload.removed?
    assert_equal I18n.t("admin.users.removed"), flash[:notice]

    post admin_user_suspension_path(@member.public_id)
    assert_equal I18n.t("admin.users.not_active"), flash[:alert]

    post admin_user_restoration_path(@member.public_id)
    assert @member.reload.active?
    assert_equal I18n.t("admin.users.restored"), flash[:notice]
  end

  test "restoring an active member reports not removed" do
    post admin_user_restoration_path(@member.public_id)
    assert_equal I18n.t("admin.users.not_removed"), flash[:alert]
  end

  # A Human who still owns a live workspace must transfer or delete it before removal. Suspension
  # does not release ownership, so the response must preserve the transfer-first explanation.
  test "removal blocked by owned workspaces guides transfer-first, even for a suspended owner" do
    curator = users(:curator)

    post admin_user_removal_path(curator.public_id)
    assert_redirected_to admin_user_path(curator.public_id)
    assert_equal I18n.t("admin.users.workspace_ownership_transfer_required"), flash[:alert]
    assert_predicate curator.reload, :active?

    post admin_user_suspension_path(curator.public_id)
    assert_predicate curator.reload, :suspended?, "suspend is never ownership-blocked"

    post admin_user_removal_path(curator.public_id)
    assert_equal I18n.t("admin.users.workspace_ownership_transfer_required"), flash[:alert]
    assert_match(/reactivate them only when it is safe/i, flash[:alert])
    assert_match(/keep the suspension as the security fence/i, flash[:alert])
    assert_match(/removal remains blocked/i, flash[:alert])
    assert_predicate curator.reload, :suspended?
  end

  test "an admin cannot administer the owner" do
    @member.change_role(to: :admin)
    sign_out
    sign_in_as @member.reload

    post admin_user_suspension_path(users(:owner).public_id)
    assert_redirected_to admin_user_path(users(:owner).public_id)
    assert_equal I18n.t("admin.users.not_administrable"), flash[:alert]
    assert users(:owner).reload.active?
  end

  test "ownership transfer is owner-only and swaps roles" do
    @member.change_role(to: :admin)

    post admin_user_ownership_transfer_path(@member.public_id)
    assert_redirected_to admin_user_path(@member.public_id)
    assert_equal "owner", @member.reload.role
    assert_equal "admin", users(:owner).reload.role
  end

  test "an admin attempting transfer is refused" do
    @member.change_role(to: :admin)
    sign_out
    sign_in_as @member.reload

    post admin_user_ownership_transfer_path(users(:owner).public_id)
    assert_equal I18n.t("admin.users.owner_required"), flash[:alert]
    assert_equal "owner", users(:owner).reload.role
  end

  test "direct create builds the member and rejects an invitation-held email" do
    get new_admin_user_path
    assert_select "header nav[aria-label=Back] a[href=?]", admin_users_path, text: "Members"
    assert_difference -> { User.count }, +1 do
      post admin_users_path, params: {
        user: { display_name: "Newcomer", email: "newcomer@example.com", role: "member",
                password: "temporary password", password_confirmation: "temporary password" },
      }
    end
    created = Identity.find_by!(email: "newcomer@example.com")
    assert created.password_change_required?
    assert_redirected_to admin_user_path(created.user.public_id)
    follow_redirect!
    assert_select "header nav[aria-label=Back] a[href=?]", admin_users_path, text: "Members"

    accounts(:cybros).invitations.create!(inviter: users(:owner), email: "held@example.com")
    assert_no_difference -> { User.count } do
      post admin_users_path, params: {
        user: { display_name: "Held", email: "held@example.com", role: "member",
                password: "temporary password", password_confirmation: "temporary password" },
      }
    end
    assert_response :unprocessable_entity
  end

  test "direct create renders validation errors with typed values preserved" do
    post admin_users_path, params: {
      user: { display_name: "Short", email: "short@example.com", role: "member",
              password: "short", password_confirmation: "short" },
    }

    assert_response :unprocessable_entity
    assert_select "input[name='user[display_name]'][value='Short']"
    assert_select "p.field-error"
  end
end
