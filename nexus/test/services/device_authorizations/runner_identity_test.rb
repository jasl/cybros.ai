require "test_helper"

# One live Runner address represents one logical
# (Account, manager, registration_identifier) registration. Assignment scope is an
# ACL over future work, never part of that identity or credential lifecycle.
class DeviceAuthorizations::RunnerIdentityTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
    @manager = users(:owner)
  end

  test "two connected grants for one new private registration have one typed loser" do
    first = runner_grant(identifier: "first-private-race")
    second = runner_grant(identifier: "first-private-race")
    connect(first, manager: @manager)
    connect(second, manager: @manager)

    winner = DeviceAuthorizations::Consume.call(authorization: first.reload)
    loser = DeviceAuthorizations::Consume.call(authorization: second.reload)

    assert_equal :minted, winner.outcome
    assert_equal :access_denied, loser.outcome
    assert_predicate second.reload, :invalidated?
    assert_equal 1,
      @manager.managed_executors.where(registration_identifier: "first-private-race").count
    assert_equal 1, winner.executor_access_token.task_executor.credential_epoch
    assert_equal winner.executor_access_token,
      AccessToken.authenticate_executor_token(winner.executor_access_secret)
  end

  test "the database rejects a duplicate live manager key across assignment scopes and across kinds" do
    @account.task_executors.create!(
      executor_kind: :runner,
      display_name: "Private",
      registration_identifier: "scope-free-identity",
      assignment_scope: :user_private,
      manager: @manager
    )
    %i[runner tool_provider].each do |kind|
      duplicate = @account.task_executors.new(
        executor_kind: kind,
        display_name: "Account-wide",
        registration_identifier: "scope-free-identity",
        assignment_scope: :account_wide,
        manager: @manager
      )

      assert_not duplicate.valid?, kind
      assert duplicate.errors.of_kind?(:registration_identifier, :taken), kind
      assert_raises ActiveRecord::RecordNotUnique, kind.to_s do
        duplicate.save!(validate: false)
      end
    end
  end

  test "the same identifier names a provider under one manager and a runner under another" do
    first = create_runner(identifier: "shared-product-code", manager: @manager, assignment_scope: :account_wide)
    provider = @account.task_executors.create!(
      executor_kind: :tool_provider, display_name: "Provider", registration_identifier: "shared-product-code",
      assignment_scope: :account_wide, manager: users(:member)
    )

    assert_predicate first, :persisted?
    assert_predicate provider, :persisted?
  end

  test "different managers may register the same identifier" do
    first = create_runner(
      identifier: "shared-product-code",
      manager: @manager,
      assignment_scope: :account_wide
    )
    second = create_runner(
      identifier: "shared-product-code",
      manager: users(:member),
      assignment_scope: :account_wide
    )

    assert_predicate first, :persisted?
    assert_predicate second, :persisted?
    assert_not_equal first, second
  end

  test "a revoked Runner does not occupy its manager key" do
    original = create_runner(
      identifier: "reusable-after-revoke",
      manager: @manager,
      assignment_scope: :user_private
    )
    original.revoke

    replacement = create_runner(
      identifier: "reusable-after-revoke",
      manager: @manager,
      assignment_scope: :account_wide
    )

    assert_predicate replacement, :persisted?
    assert_not_equal original, replacement
  end

  private

    def runner_grant(identifier:)
      DeviceAuthorizations::Issue.call(
        account: @account,
        registration_identifier: identifier,
        runner_display_name: "Runner"
      ).authorization
    end

    def connect(grant, manager:)
      existing = TaskExecutor.runner_for(
        account_id: grant.account_id,
        manager_id: manager.id,
        registration_identifier: grant.registration_identifier
      )
      result = DeviceAuthorizations::Connect.call(
        authorization: grant,
        connector: manager,
        expected_live_runner:
          DeviceAuthorizations::Connect.live_runner_precondition(existing)
      )
      assert_equal :connected, result.outcome
    end

    def create_runner(identifier:, manager:, assignment_scope:)
      @account.task_executors.create!(
        executor_kind: :runner,
        display_name: "Runner #{identifier}",
        registration_identifier: identifier,
        assignment_scope: assignment_scope,
        manager: manager
      )
    end
end
