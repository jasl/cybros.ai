require "test_helper"

class PasswordsMailerTest < ActionMailer::TestCase
  test "reset renders the identity's current reset token into both parts" do
    identity = identities(:member)
    email = PasswordsMailer.reset(identity)

    assert_emails 1 do
      email.deliver_now
    end

    assert_equal ["member@example.com"], email.to
    assert_equal I18n.t("passwords_mailer.reset.subject"), email.subject

    token = identity.password_reset_token
    # The token derives from the current password state; both parts carry the
    # reset URL with the token in the filtered token query parameter.
    assert_match "http://example.com/passwords/", email.text_part.body.to_s
    assert_match "http://example.com/passwords/", email.html_part.body.to_s
    assert_equal identity, Identity.find_by_password_reset_token(token)

    delivered_token = email.text_part.body.to_s[/passwords\/edit\?token=([^\s"&]+)/, 1]
    assert_equal identity,
      Identity.find_by_password_reset_token(CGI.unescape(delivered_token))
  end
end
