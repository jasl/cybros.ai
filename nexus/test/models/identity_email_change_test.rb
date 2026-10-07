require "test_helper"

class IdentityEmailChangeTest < ActiveSupport::TestCase
  test "an email change cannot reuse password proof superseded by an emailed reset" do
    identity = identities(:member)
    original_email = identity.email
    reset_token = identity.password_reset_token
    changing_identity = Identity.find(identity.id)
    authenticate = changing_identity.method(:authenticate)

    # A browser verifies its current password while the account owner submits
    # the reset link sent to the original mailbox. If the email change had won
    # first, that token would be invalid; both changes cannot succeed together.
    verify_then_reset = lambda do |password|
      authenticated = authenticate.call(password)
      assert authenticated
      assert_equal :reset, Identity.find(identity.id).reset_password(
        token: reset_token,
        password: "owner replacement password",
        password_confirmation: "owner replacement password"
      )
      authenticated
    end

    changed = changing_identity.stub(:authenticate, verify_then_reset) do
      changing_identity.change_email("other-mailbox@example.com", current_password: "password")
    end

    assert_not changed
    assert_equal original_email, identity.reload.email
    assert identity.authenticate("owner replacement password")
    assert_nil Identity.find_by_password_reset_token(reset_token)
  end
end
