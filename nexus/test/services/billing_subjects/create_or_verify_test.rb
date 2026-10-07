require "test_helper"

# Submit-time billing attribution creates or verifies an opaque bounded key in the same Account,
# owned by the acting User. A unique index settles concurrent first creation; a different owner
# receives a stable refusal.
class BillingSubjects::CreateOrVerifyTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
    @owner = users(:owner)
    @member = users(:member)
  end

  test "a first key is created owned by the acting user" do
    result = call(key: "team-alpha")

    assert_predicate result, :verified?
    subject = result.billing_subject
    assert_equal "team-alpha", subject.key
    assert_equal @owner.id, subject.owning_user_id
    assert_equal @account.id, subject.account_id
  end

  test "the same owner reuses the key and a different owner is refused stably" do
    first = call(key: "team-alpha")
    reuse = call(key: "team-alpha")

    assert_predicate reuse, :verified?
    assert_equal first.billing_subject.id, reuse.billing_subject.id
    assert_equal 1, BillingSubject.count

    stranger = call(acting_user: @member, key: "team-alpha")
    assert_predicate stranger, :not_owner?
    # Stable: the refusal is derived from the frozen row, so a retry says the
    # same thing rather than racing into a second answer.
    assert_predicate call(acting_user: @member, key: "team-alpha"), :not_owner?
    assert_equal 1, BillingSubject.count
  end

  test "the key is normalized once and bounded" do
    assert_equal "team-alpha", call(key: "  team-alpha  ").billing_subject.key
    assert_equal 1, BillingSubject.count

    assert_predicate call(key: "   "), :invalid?
    assert_predicate call(key: nil), :invalid?
    assert_predicate call(key: "x" * (BillingSubject::KEY_MAX_LENGTH + 1)), :invalid?
  end

  test "an acting user from another account cannot attribute here" do
    foreign = User.new(account_id: @account.id + 1)

    assert_predicate call(acting_user: foreign, key: "team-alpha"), :invalid?
  end

  # Concurrent first creation converges on the ordinary (account_id, key) unique winner. The race is
  # driven for real — the winner's row is already committed, and the caller's lookup is blinded
  # exactly once so its INSERT hits the live unique index the way a true loser's would.
  test "a lost creation race converges on the winner" do
    winner = BillingSubject.create!(account: @account, owning_user: @owner, key: "team-alpha")
    real = BillingSubject.method(:find_by)
    blinded = true
    stub = lambda do |**args|
      next nil if blinded.tap { blinded = false }

      real.call(**args)
    end

    result = BillingSubject.stub(:find_by, stub) { call(key: "team-alpha") }

    assert_predicate result, :verified?
    assert_equal winner.id, result.billing_subject.id
    assert_equal 1, BillingSubject.count
  end

  private

    def call(acting_user: @owner, key:)
      BillingSubjects::CreateOrVerify.call(
        account: @account, acting_user: acting_user, key: key
      )
    end
end
