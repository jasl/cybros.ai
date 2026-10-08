require "test_helper"

class InvitationMailerTest < ActionMailer::TestCase
  test "acceptance renders the signed link into both parts" do
    invitation = accounts(:cybros).invitations.create!(
      inviter: users(:owner), email: "invited@example.com"
    )

    email = InvitationMailer.acceptance(invitation.public_id)

    assert_emails 1 do
      email.deliver_now
    end

    assert_equal ["invited@example.com"], email.to
    assert_equal I18n.t("invitation_mailer.acceptance.subject", brand: I18n.t("brand.name")), email.subject
    assert_match "http://example.com/join?token=", email.text_part.body.to_s
    assert_match CGI.escapeHTML("http://example.com/join?token="), email.html_part.body.to_s

    token = email.text_part.body.to_s[/join\?token=([^\s"&]+)/, 1]
    assert_equal invitation, Invitation.find_by_acceptance_token(CGI.unescape(token))
  end

  test "a job whose invitation is gone sends nothing" do
    assert_emails 0 do
      InvitationMailer.acceptance(SecureRandom.uuid_v7).deliver_now
    end
  end

  test "a job whose invitation has expired sends nothing" do
    invitation = accounts(:cybros).invitations.create!(
      inviter: users(:owner), email: "expired@example.com"
    )
    invitation.update!(expires_at: 1.second.ago)

    assert_emails 0 do
      InvitationMailer.acceptance(invitation.public_id).deliver_now
    end
  end

  test "a job running at the invitation expiry sends nothing" do
    freeze_time
    invitation = accounts(:cybros).invitations.create!(
      inviter: users(:owner), email: "expired@example.com"
    )
    travel_to invitation.expires_at

    assert_emails 0 do
      InvitationMailer.acceptance(invitation.public_id).deliver_now
    end
  end
end
