require "test_helper"
require_relative "../../test_helpers/lock_order_test_helper"

class DeviceAuthorizations::AgentPrivateRunnerTest < ActiveSupport::TestCase
  include LockOrderTestHelper

  setup do
    @account = accounts(:cybros)
    @manager = users(:owner)
    @agent = users(:agent)
  end

  test "a runner supplement captures the existing Agent without rotating its lineage" do
    agent_connection = connect_agent_session(steward: @manager, agent_identifier: @agent.agent_identifier)
    address = agent_connection.executor_access_token.task_executor
    epoch = address.credential_epoch
    grant = issue

    assert_predicate grant, :selects_agent_private?
    assert_nil grant.user
    assert_ladder_order("existing Agent runner supplement") do
      assert_equal :connected, connect(grant, account_wide: true).outcome
      assert_equal @agent, grant.reload.user
      assert_equal @agent.authority_generation, grant.user_authority_generation
      assert_no_difference -> { User.count } do
        assert_no_difference -> { @agent.refresh_token_families.count } do
          result = consume(grant)
          assert_equal :minted, result.outcome
          runner = result.executor_access_token.task_executor
          assert_predicate runner, :agent_private?
          assert_equal @agent, runner.assignment_agent
          assert_equal @manager, runner.manager
          assert_nil runner.agent
          assert_nil result.access_token
          assert_nil result.executor_access_token.user
          assert_nil result.refresh_token.refresh_token_family.user
          assert runner.eligible_for?(@agent)
        end
      end
    end
    assert_equal epoch, address.reload.credential_epoch
    assert_equal agent_connection.access_token, AccessToken.authenticate_token(agent_connection.access_secret)
    assert_equal @agent, grant.reload.user
  end

  test "the same application re-pairs its Runner but another application or a standalone request cannot" do
    first = consume_connected
    runner = first.executor_access_token.task_executor
    second = consume_connected
    assert_equal :minted, second.outcome
    assert_equal runner, second.executor_access_token.task_executor
    assert_equal 2, runner.reload.credential_epoch
    assert_equal @agent, runner.assignment_agent

    other = create_agent_member(steward: @manager)
    [other.public_id, nil].each do |target|
      grant = issue(assignment_agent_public_id: target)
      assert_equal :runner_assignment_mismatch, connect(grant).outcome
      assert_predicate grant.reload, :pending?
      assert_equal 2, runner.reload.credential_epoch
    end
  end

  test "a supplement cannot narrow an existing shared registration through re-pair" do
    %i[user_private account_wide].each do |scope|
      identifier = "shared-#{scope}"
      shared = connect_runner(manager: @manager, registration_identifier: identifier, assignment_scope: scope)
        .executor_access_token.task_executor
      grant = issue(identifier: identifier)

      assert_equal :runner_assignment_mismatch, connect(grant).outcome
      assert_predicate grant.reload, :pending?
      assert_equal scope.to_s, shared.reload.assignment_scope
      assert_nil shared.assignment_agent
      assert_equal 1, shared.credential_epoch
    end
  end

  test "a combined request cannot reuse a Runner bound to another application or sharing scope" do
    other = create_agent_member(steward: @manager)
    [nil, other].each_with_index do |target, index|
      identifier = "combined-mismatch-#{index}"
      runner = connect_runner(manager: @manager, registration_identifier: identifier, assignment_agent: target)
        .executor_access_token.task_executor
      grant = DeviceAuthorizations::Issue.call(
        account: @account, agent_identifier: @agent.agent_identifier, agent_display_name: "Application",
        requested_executor_display_name: "Application executor",
        registration_identifier: identifier, runner_display_name: "Runner"
      ).authorization
      assert_equal :connected, DeviceAuthorizations::Connect.call(authorization: grant, connector: @manager).outcome

      assert_no_difference -> { AccessToken.count } do
        assert_equal :access_denied, consume(grant).outcome
      end
      assert_predicate grant.reload, :invalidated?
      assert_equal 1, runner.reload.credential_epoch
    end
  end

  test "a supplement accepts only an active paired Agent of the connecting Human" do
    other_human_agent = create_agent_member(steward: users(:member))
    removed = create_agent_member(steward: @manager)
    removed.remove
    named = @account.users.create!(kind: :agent, role: :member, steward: @manager,
      display_name: "Named Agent", agent_identifier: "#{@agent.agent_identifier}/named",
      derived_from: @agent, definition_scope: :instance, description: "Named worker")
    [other_human_agent, removed, named, @manager, users(:system)].each do |target|
      grant = issue(assignment_agent_public_id: target.public_id)
      assert_equal :assignment_agent_not_eligible, connect(grant).outcome
      assert_predicate grant.reload, :pending?
      assert_nil grant.user
    end
    assert_equal :assignment_agent_not_eligible, connect(issue(assignment_agent_public_id: SecureRandom.uuid_v7)).outcome
  end

  test "steward transfer after approval invalidates the supplement without any credential consequence" do
    grant = issue
    assert_equal :connected, connect(grant).outcome
    assert_equal :changed, @agent.change_steward(to: users(:member))

    assert_no_difference -> { TaskExecutor.count } do
      assert_no_difference -> { AccessToken.count } do
        assert_equal :access_denied, consume(grant).outcome
      end
    end
    assert_predicate grant.reload, :invalidated?
  end

  test "removal and restore after approval cannot reuse the captured Agent generation" do
    grant = issue
    assert_equal :connected, connect(grant).outcome
    @agent.remove
    @agent.restore

    assert_no_difference -> { TaskExecutor.count } do
      assert_equal :access_denied, consume(grant).outcome
    end
    assert_predicate grant.reload, :invalidated?
  end

  test "canceling a supplement retains its fixed assignment request without any live capture" do
    grant = issue
    assert_equal :connected, connect(grant).outcome
    grant.record_cancellation

    assert_predicate grant, :canceled?
    assert_predicate grant, :selects_agent_private?
    assert_equal @agent.public_id, grant.assignment_agent_public_id
    assert_nil grant.user
    assert_nil grant.user_authority_generation
    assert_nil grant.connected_by
  end

  private

    def issue(identifier: "application-runner", assignment_agent_public_id: @agent.public_id)
      DeviceAuthorizations::Issue.call(account: @account,
        registration_identifier: identifier, runner_display_name: "Application runner",
        assignment_agent_public_id: assignment_agent_public_id).authorization
    end

    def connect(grant, account_wide: false)
      runner = TaskExecutor.runner_for(account_id: @account.id, manager_id: @manager.id,
        registration_identifier: grant.registration_identifier)
      DeviceAuthorizations::Connect.call(authorization: grant, connector: @manager,
        account_wide: account_wide,
        expected_live_runner: DeviceAuthorizations::Connect.live_runner_precondition(runner))
    end

    def consume(grant)
      DeviceAuthorizations::Consume.call(authorization: grant)
    end

    def consume_connected
      grant = issue
      assert_equal :connected, connect(grant).outcome
      consume(grant)
    end
end
