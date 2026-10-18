require "application_system_test_case"

class InvitationAdministrationTest < ApplicationSystemTestCase
  test "invitation card focus order follows its visual rows" do
    invitation = accounts(:cybros).invitations.create!(
      inviter: users(:owner),
      email: "focus-order@example.com",
      last_delivery_requested_at: Invitation::RESEND_INTERVAL.ago - 1.second
    )
    sign_in_directly(users(:owner))

    visit admin_invitations_url

    focusable_tops = page.evaluate_script(<<~JAVASCRIPT)
      Array.from(document.querySelector("[data-invitation-id='#{invitation.public_id}']").querySelectorAll("a[href], button:not([disabled]), input:not([disabled])"))
        .filter((element) => element.getClientRects().length > 0)
        .map((element) => Math.round(element.getBoundingClientRect().top))
    JAVASCRIPT

    assert_equal focusable_tops.sort, focusable_tops
  end
end

class MobileInvitationAdministrationTest < MobileSystemTestCase
  test "invitation administration stays usable at phone width" do
    pending_invitation = accounts(:cybros).invitations.create!(inviter: users(:owner), email: "pending@example.com")
    accounts(:cybros).invitations.create!(
      inviter: users(:owner), email: "expired@example.com", expires_at: 1.day.ago
    )
    sign_in_directly(users(:owner))

    visit admin_invitations_url
    assert_field "Email"
    assert_text "pending@example.com"
    assert_no_text "expired@example.com"
    assert_button "Revoke"

    invitation_right = page.evaluate_script(<<~JAVASCRIPT)
      document.querySelector("[data-invitation-id='#{pending_invitation.public_id}']").getBoundingClientRect().right
    JAVASCRIPT
    viewport_width = page.evaluate_script("document.documentElement.clientWidth")
    assert_operator invitation_right, :<=, viewport_width

    within("nav[aria-label='Invitation filters']") do
      assert_link "Pending"
      click_link "All"
    end
    assert_text "expired@example.com"

    document_width = page.evaluate_script("document.documentElement.scrollWidth")
    viewport_width = page.evaluate_script("document.documentElement.clientWidth")
    assert_operator document_width, :<=, viewport_width
  end
end

class MobileInvitationAcceptanceTest < MobileSystemTestCase
  test "long invitation identity text stays within the phone viewport" do
    account = accounts(:cybros)
    account.update!(name: "N" * Account::NAME_MAX_LENGTH)
    email = "#{"a" * 64}@#{"b" * 63}.#{"c" * 63}.#{"d" * 57}.com"
    invitation = account.invitations.create!(inviter: users(:owner), email: email)

    visit join_url(token: invitation.acceptance_token)

    document_width = page.evaluate_script("document.documentElement.scrollWidth")
    viewport_width = page.evaluate_script("document.documentElement.clientWidth")
    assert_operator document_width, :<=, viewport_width
  end
end
