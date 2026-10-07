require "test_helper"

class AccountDirectMemberTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
  end

  test "direct creation builds the identity with the forced-change flag" do
    creation = @account.create_direct_member(
      display_name: "Newcomer",
      email: "newcomer@example.com",
      role: "member",
      password: "temporary password",
      password_confirmation: "temporary password"
    )

    assert_equal :created, creation.outcome
    member = creation.member
    assert member.persisted?
    assert member.human?
    assert member.identity.password_change_required?
  end

  test "direct creation hashes the new credential before opening its transaction" do
    connection = ActiveRecord::Base.lease_connection
    baseline_transactions = connection.open_transactions
    hashing_transactions = []
    bcrypt_create = BCrypt::Password.method(:create)

    BCrypt::Password.stub(:create, ->(*args, **kwargs) {
      hashing_transactions << connection.open_transactions
      bcrypt_create.call(*args, **kwargs)
    }) do
      creation = @account.create_direct_member(
        display_name: "Newcomer",
        email: "newcomer@example.com",
        role: "member",
        password: "temporary password",
        password_confirmation: "temporary password"
      )

      assert_equal :created, creation.outcome
    end

    # Fixture isolation already owns the baseline transaction. Direct member
    # creation must not add another one until after BCrypt has finished.
    assert_equal [baseline_transactions], hashing_transactions
  end

  test "a registered email is rejected with validation errors and creates nothing" do
    creation = nil
    assert_no_difference [-> { Identity.count }, -> { User.count }] do
      creation = @account.create_direct_member(
        display_name: "Duplicate",
        email: identities(:member).email,
        role: "member",
        password: "temporary password",
        password_confirmation: "temporary password"
      )
    end

    assert_equal :invalid, creation.outcome
    assert creation.errors[:email].any?
  end

  test "a null-byte password is rejected without creating a member" do
    creation = nil

    assert_no_difference [-> { Identity.count }, -> { User.count }] do
      creation = @account.create_direct_member(
        display_name: "Newcomer",
        email: "newcomer@example.com",
        role: "member",
        password: "temporary\0password",
        password_confirmation: "temporary\0password"
      )
    end

    assert_equal :invalid, creation.outcome
    assert creation.errors.of_kind?(:password, :invalid)
  end

  test "changing the password clears the forced-change flag" do
    creation = @account.create_direct_member(
      display_name: "Newcomer",
      email: "newcomer@example.com",
      role: "member",
      password: "temporary password",
      password_confirmation: "temporary password"
    )
    identity = creation.member.identity
    session = create_browser_session(identity)

    replacement = identity.change_password(
      current_password: "temporary password",
      password: "their own password",
      password_confirmation: "their own password",
      presented_session: session
    )

    assert replacement
    assert_not identity.reload.password_change_required?
  end
end
