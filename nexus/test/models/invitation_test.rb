require "test_helper"

class InvitationTest < ActiveSupport::TestCase
  include ActionMailer::TestHelper

  setup do
    @account = accounts(:cybros)
  end

  test "creation records the delivery request and derives expiry from it" do
    freeze_time do
      invitation = create_invitation

      assert_equal Time.current, invitation.last_delivery_requested_at
      assert_equal Invitation::VALIDITY_PERIOD.from_now, invitation.expires_at
      assert invitation.member?
      assert_not invitation.expired?
    end
  end

  test "email address is normalized and globally unique" do
    create_invitation
    duplicate = @account.invitations.build(
      inviter: users(:owner), email: " INVITED@example.com "
    )

    assert_not duplicate.valid?
    assert duplicate.errors.of_kind?(:email, :taken)
  end

  test "an email an identity already owns cannot be invited" do
    invitation = @account.invitations.build(
      inviter: users(:owner), email: "member@example.com"
    )

    assert_not invitation.valid?
    assert invitation.errors.of_kind?(:email, :member_already_exists)
  end

  test "a removed member's email stays reserved against invitation and direct-create" do
    users(:member).remove

    invitation = @account.invitations.build(
      inviter: users(:owner), email: "member@example.com"
    )
    assert_not invitation.valid?
    assert invitation.errors.of_kind?(:email, :member_already_exists)

    result = @account.create_direct_member(
      display_name: "Replacement", email: "member@example.com",
      role: "member", password: "a temporary password",
      password_confirmation: "a temporary password"
    )
    assert_equal :invalid, result.outcome
    assert result.errors.of_kind?(:email, :taken)
  end

  test "expiry is a derived predicate" do
    invitation = create_invitation

    travel Invitation::VALIDITY_PERIOD + 1.minute do
      assert invitation.expired?
    end
  end

  test "acceptance visibility expires at the same instant as consumption" do
    freeze_time
    invitation = create_invitation
    token = invitation.acceptance_token

    travel_to invitation.expires_at - 1.second
    assert_not invitation.expired?
    assert Invitation.unexpired.exists?(invitation.id)
    assert_equal invitation, Invitation.find_by_acceptance_token(token)

    travel_to invitation.expires_at
    assert invitation.expired?
    assert_not Invitation.unexpired.exists?(invitation.id)
    assert_nil Invitation.find_by_acceptance_token(token)
  end

  test "acceptance at its exact expiry leaves no partial member" do
    freeze_time
    invitation = create_invitation
    travel_to invitation.expires_at

    assert_no_difference [-> { Identity.count }, -> { User.count }, -> { Invitation.count }] do
      assert_raises ActiveRecord::RecordNotFound do
        invitation.accept(
          display_name: "Invited", password: "long enough password", password_confirmation: "long enough password"
        )
      end
    end
  end

  test "deliver_later schedules the mailer with the public id only" do
    invitation = create_invitation

    assert_enqueued_email_with InvitationMailer, :acceptance, args: [invitation.public_id] do
      invitation.deliver_later
    end
  end

  test "resend after the interval renews the same row and schedules one email" do
    invitation = create_invitation
    originally_requested_at = invitation.last_delivery_requested_at

    travel Invitation::RESEND_INTERVAL + 1.second

    assert_enqueued_email_with InvitationMailer, :acceptance, args: [invitation.public_id] do
      assert_equal :resent, invitation.resend
    end

    invitation.reload
    assert_operator invitation.last_delivery_requested_at, :>, originally_requested_at
    assert_equal invitation.last_delivery_requested_at + Invitation::VALIDITY_PERIOD, invitation.expires_at
  end

  test "resend renews an expired invitation while its address stays unregistered" do
    invitation = create_invitation

    travel Invitation::VALIDITY_PERIOD + 1.day do
      assert invitation.expired?
      assert_equal :resent, invitation.resend
      assert_not invitation.reload.expired?
    end
  end

  test "the guarded resend admits one winner between instances holding stale state" do
    # The winner rule is one guarded UPDATE; the database supplies its
    # atomicity, so two instances loaded before either write prove it
    # deterministically.
    invitation = create_invitation

    travel Invitation::RESEND_INTERVAL + 1.second do
      first, second = 2.times.map { Invitation.find(invitation.id) }

      assert_enqueued_emails 1 do
        assert_equal :resent, first.resend
        assert_equal :resend_too_soon, second.resend
      end
      assert_predicate second.resend_available_in, :positive?
    end
  end

  test "resend inside the interval changes nothing and schedules no email" do
    invitation = create_invitation

    assert_no_enqueued_emails do
      assert_no_changes -> { invitation.reload.expires_at } do
        assert_equal :resend_too_soon, invitation.resend
      end
    end

    assert invitation.resend_available_in.positive?
  end

  test "resend rejects an email that has since become an identity" do
    invitation = create_invitation
    register_identity(invitation.email)

    travel Invitation::RESEND_INTERVAL + 1.second do
      assert_no_enqueued_emails do
        assert_equal :member_already_exists, invitation.resend
      end
    end
  end

  test "old and new acceptance links resolve the same row and share the renewed expiry" do
    invitation = create_invitation
    first_link = invitation.acceptance_token

    travel Invitation::RESEND_INTERVAL + 1.second do
      invitation.resend
    end
    second_link = invitation.reload.acceptance_token

    assert_equal invitation, Invitation.find_by_acceptance_token(first_link)
    assert_equal invitation, Invitation.find_by_acceptance_token(second_link)
  end

  test "a tampered acceptance token resolves nothing" do
    invitation = create_invitation

    assert_nil Invitation.find_by_acceptance_token(invitation.acceptance_token.swapcase)
  end

  test "acceptance creates a member with the invited email and role, then destroys the row" do
    invitation = create_invitation(role: :admin)

    result = nil
    assert_difference [-> { Identity.count }, -> { User.count }], +1 do
      assert_difference -> { Invitation.count }, -1 do
        result = invitation.accept(
          display_name: "Invited", password: "long enough password", password_confirmation: "long enough password"
        )
      end
    end

    assert_equal :accepted, result.outcome
    member = result.member
    assert member.human?
    assert member.admin?
    assert_equal "Invited", member.display_name
    assert_equal "invited@example.com", member.identity.email
    assert member.identity.authenticate("long enough password")
  end

  test "acceptance hashes the new credential before opening its transaction" do
    invitation = create_invitation
    connection = ActiveRecord::Base.lease_connection
    baseline_transactions = connection.open_transactions
    hashing_transactions = []
    bcrypt_create = BCrypt::Password.method(:create)

    BCrypt::Password.stub(:create, ->(*args, **kwargs) {
      hashing_transactions << connection.open_transactions
      bcrypt_create.call(*args, **kwargs)
    }) do
      result = invitation.accept(
        display_name: "Invited", password: "long enough password", password_confirmation: "long enough password"
      )

      assert_equal :accepted, result.outcome
    end

    # Fixture isolation already owns the baseline transaction. Invitation
    # acceptance must not add another one until after BCrypt has finished.
    assert_equal [baseline_transactions], hashing_transactions
  end

  test "acceptance against a registered email returns member_already_exists and keeps the row" do
    invitation = create_invitation
    register_identity(invitation.email)

    result = nil
    assert_no_difference [-> { User.count }, -> { Invitation.count }] do
      result = invitation.accept(
        display_name: "Invited", password: "long enough password", password_confirmation: "long enough password"
      )
    end

    assert_equal :member_already_exists, result.outcome
  end

  test "a mail-less creation is link-only: expiry anchored, no delivery request" do
    invitation = nil
    ApplicationMailer.stub(:delivery_configured?, false) do
      invitation = create_invitation
    end

    assert_nil invitation.last_delivery_requested_at
    assert_in_delta Invitation::VALIDITY_PERIOD.from_now, invitation.expires_at, 5.seconds
    assert_equal 0, invitation.resend_available_in
  end

  test "a never-mailed invitation accepts its first delivery request immediately" do
    invitation = nil
    ApplicationMailer.stub(:delivery_configured?, false) do
      invitation = create_invitation
    end

    assert_enqueued_email_with InvitationMailer, :acceptance, args: [invitation.public_id] do
      assert_equal :resent, invitation.resend
    end
    assert invitation.reload.last_delivery_requested_at.present?
  end

  test "link-only acceptance works without configured email delivery" do
    invitation = nil
    ApplicationMailer.stub(:delivery_configured?, false) do
      invitation = create_invitation
    end

    result = invitation.accept(
      display_name: "Link Joiner", password: "long enough password", password_confirmation: "long enough password"
    )

    assert_equal :accepted, result.outcome
  end

  test "acceptance after revoke fails without creating a member" do
    invitation = create_invitation
    # The revoke commits between the acceptor's page load and its submit.
    Invitation.find(invitation.id).destroy!

    assert_no_difference [-> { Identity.count }, -> { User.count }] do
      assert_raises ActiveRecord::RecordNotFound do
        invitation.accept(
          display_name: "Invited", password: "long enough password", password_confirmation: "long enough password"
        )
      end
    end
  end

  test "acceptance expiring before final consumption leaves no partial member" do
    invitation = create_invitation
    stale_acceptor = Invitation.find(invitation.id)

    # The form was admitted while the in-memory expiry was current, but the
    # database authority is expired by the time the transaction consumes it.
    invitation.update_column(:expires_at, 1.second.ago)
    assert_not stale_acceptor.expired?

    assert_no_difference [-> { Identity.count }, -> { User.count }] do
      assert_raises ActiveRecord::RecordNotFound do
        stale_acceptor.accept(
          display_name: "Invited", password: "long enough password", password_confirmation: "long enough password"
        )
      end
    end
    assert Invitation.exists?(invitation.id)
  end

  test "the unique index decides a concurrent duplicate create" do
    create_invitation
    # validate: false models the racing writer whose uniqueness SELECT missed
    # the winner; explicit timestamps replace the skipped creation defaults.
    duplicate = @account.invitations.build(
      inviter: users(:owner), email: "invited@example.com",
      expires_at: 7.days.from_now, last_delivery_requested_at: Time.current
    )

    assert_raises ActiveRecord::RecordNotUnique do
      duplicate.save!(validate: false)
    end
  end

  test "acceptance with invalid input returns the validation errors and keeps the row" do
    invitation = create_invitation

    result = nil
    assert_no_difference [-> { Identity.count }, -> { User.count }, -> { Invitation.count }] do
      result = invitation.accept(
        display_name: "Invited", password: "long enough password", password_confirmation: "different"
      )
    end

    assert_equal :rejected, result.outcome
    assert result.errors[:password_confirmation].any?
  end

  test "acceptance rejects a null-byte password and keeps the invitation" do
    invitation = create_invitation
    result = nil

    assert_no_difference [-> { Identity.count }, -> { User.count }, -> { Invitation.count }] do
      result = invitation.accept(
        display_name: "Invited",
        password: "long\0enough password",
        password_confirmation: "long\0enough password"
      )
    end

    assert_equal :rejected, result.outcome
    assert result.errors.of_kind?(:password, :invalid)
  end

  private

    def create_invitation(role: :member)
      @account.invitations.create!(
        inviter: users(:owner), email: "invited@example.com", role: role
      )
    end

    def register_identity(email)
      identity = @account.identities.create!(email: email, password: "long enough password", password_confirmation: "long enough password")
      @account.users.create!(kind: :human, role: :member, identity: identity, display_name: "Registered")
    end
end
