require "test_helper"

# A Runner is a machine address, not an Agent Profile's record. Every Runner has one Human manager,
# while its assignment scope is a registration-time ACL over future work. An agent_application
# executor instead belongs to its Agent Profile and has neither fact.
class RunnerOwnershipTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
    @manager = users(:owner)
    @agent = users(:agent)
  end

  test "an agent_application belongs to its Agent Profile and has no Runner management facts" do
    executor = task_executors(:address)

    assert_equal @agent, executor.agent_profile
    assert_nil executor.manager
    assert_nil executor.assignment_scope
  end

  # The provider's shape IS the runner's: a manager, an identifier, a scope; never a Profile.
  test "a tools provider has the runner's ownership shape" do
    provider = @account.task_executors.create!(
      executor_kind: :tools_provider, display_name: "Provider",
      runner_identifier: "provider-install", manager: @manager, assignment_scope: :account_wide
    )

    assert_equal @manager, provider.manager
    assert_equal @manager, provider.controlling_human
    assert_nil provider.agent_profile
    assert_predicate provider, :account_wide?

    profiled = @account.task_executors.new(
      executor_kind: :tools_provider, display_name: "Wrong shape",
      runner_identifier: "x", manager: @manager, assignment_scope: :user_private, agent_profile: @agent
    )
    assert_not profiled.valid?
    assert profiled.errors.of_kind?(:agent_profile, :present)
  end

  test "private and account-wide Runners both belong to a Human manager" do
    private_runner = create_runner(
      identifier: "private-install",
      manager: @manager,
      assignment_scope: :user_private
    )
    wide_runner = create_runner(
      identifier: "wide-install",
      manager: @manager,
      assignment_scope: :account_wide
    )

    assert_equal @manager, private_runner.manager
    assert_equal @manager, wide_runner.manager
    assert_nil private_runner.agent_profile
    assert_nil wide_runner.agent_profile
    assert_predicate private_runner, :user_private?
    assert_predicate wide_runner, :account_wide?
  end

  test "a Runner requires an identifier scope and manager" do
    scopeless = @account.task_executors.build(
      executor_kind: :runner,
      display_name: "R",
      runner_identifier: "r-1",
      manager: @manager
    )
    anonymous = @account.task_executors.build(
      executor_kind: :runner,
      display_name: "R",
      manager: @manager,
      assignment_scope: :user_private
    )

    assert_not scopeless.valid?
    assert scopeless.errors.of_kind?(:assignment_scope, :blank)
    assert_not anonymous.valid?
    assert anonymous.errors.of_kind?(:runner_identifier, :blank)

    %i[user_private account_wide].each do |assignment_scope|
      managerless = @account.task_executors.build(
        executor_kind: :runner,
        display_name: "R",
        runner_identifier: "managerless-#{assignment_scope}",
        assignment_scope: assignment_scope
      )

      assert_not managerless.valid?
      assert managerless.errors.of_kind?(:manager, :blank)
    end
  end

  test "a Runner manager must be an active Human in its Account" do
    agent_managed = @account.task_executors.build(
      executor_kind: :runner,
      display_name: "R",
      runner_identifier: "agent-managed",
      assignment_scope: :user_private,
      manager: @agent
    )

    assert_not agent_managed.valid?
    assert agent_managed.errors.of_kind?(:manager, :not_eligible)

    inactive_manager = users(:member)
    assert_equal :suspended, inactive_manager.suspend
    inactive_managed = @account.task_executors.build(
      executor_kind: :runner,
      display_name: "R",
      runner_identifier: "inactive-managed",
      assignment_scope: :account_wide,
      manager: inactive_manager
    )

    assert_not inactive_managed.valid?
    assert inactive_managed.errors.of_kind?(:manager, :not_eligible)
  end

  test "a manager may hold several Runners and identifiers repeat across managers" do
    first = create_runner(
      identifier: "shared-identifier",
      manager: @manager,
      assignment_scope: :user_private
    )
    second = create_runner(
      identifier: "other-install",
      manager: @manager,
      assignment_scope: :account_wide
    )
    other = create_runner(
      identifier: "shared-identifier",
      manager: users(:member),
      assignment_scope: :user_private
    )

    assert_predicate first, :persisted?
    assert_predicate second, :persisted?
    assert_predicate other, :persisted?
    assert_not_equal first, other
  end

  test "a Runner is never an Agent Profile delivery address" do
    runner = @agent.task_executors.build(
      account: @account,
      executor_kind: :runner,
      display_name: "R",
      runner_identifier: "r-4",
      assignment_scope: :user_private,
      manager: @manager
    )

    assert_not runner.valid?
    assert runner.errors.of_kind?(:agent_profile, :present)
  end

  test "manager and assignment scope are immutable registration facts in v1" do
    runner = create_runner(
      identifier: "fixed-registration",
      manager: @manager,
      assignment_scope: :user_private
    )

    assert_includes TaskExecutor.readonly_attributes, "manager_id"
    assert_includes TaskExecutor.readonly_attributes, "assignment_scope"
    assert_raises ActiveRecord::ReadonlyAttributeError do
      runner.manager = users(:member)
    end
    assert_raises ActiveRecord::ReadonlyAttributeError do
      runner.assignment_scope = :account_wide
    end
  end

  private

    def create_runner(identifier:, manager:, assignment_scope:)
      @account.task_executors.create!(
        executor_kind: :runner,
        display_name: "Runner #{identifier}",
        runner_identifier: identifier,
        manager: manager,
        assignment_scope: assignment_scope
      )
    end
end
