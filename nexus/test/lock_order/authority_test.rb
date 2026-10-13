require "test_helper"
require_relative "../test_helpers/lock_order_test_helper"

class AuthorityLockOrderTest < ActiveSupport::TestCase
  include LockOrderTestHelper

  test "the full agent ceremony acquires every lock in ladder order" do
    sequences = assert_ladder_order("issue → connect → consume") do
      connect_agent_session(steward: users(:owner), agent_identifier: "install-guard")
    end

    seen = sequences.flatten.uniq
    assert_includes seen, "device_authorizations"
    assert_includes seen, "users"
  end

  # The combined shape is a superset straight line of the agent ceremony, no
  # new rank: device_authorizations → users → task_executors (the agent
  # address, then the runner row) → the family writes. The within-table pair
  # is pinned by combined_connection_test's race test.
  test "the combined ceremony acquires every lock in ladder order" do
    sequences = assert_ladder_order("issue → connect → consume, combined") do
      result = connect_combined_session(
        steward: users(:owner), agent_identifier: "install-guard-combined"
      )
      assert_equal :minted, result.outcome
      assert_not_nil result.runner
    end

    seen = sequences.flatten.uniq
    assert_includes seen, "device_authorizations"
    assert_includes seen, "users"
    assert_includes seen, "task_executors"
  end

  test "application authorization and Human rotation keep the credential lock order" do
    grant = DeviceAuthorizations::Issue.call(
      account: accounts(:cybros), client_id: OAuth::APPLICATION_CLIENT_ID,
      agent_identifier: "application-lock-order", agent_display_name: "Application",
      requested_executor_display_name: "Application executor",
      registration_identifier: "application-lock-runner", runner_display_name: "Runner"
    ).authorization
    result = nil
    assert_ladder_order("application connect and consume") do
      assert_equal :connected, DeviceAuthorizations::Connect.call(authorization: grant, connector: users(:owner)).outcome
      result = DeviceAuthorizations::Consume.call(authorization: grant)
      assert_equal :minted, result.outcome
    end
    assert_ladder_order("Human application refresh") do
      assert_equal :rotated, RefreshTokens::Rotate.call(presented: result.refresh_token).outcome
    end
  end

  test "credential rotation descends users, executor, family" do
    member = create_agent_member(steward: users(:owner), agent_identifier: "install-guard-rotate")
    executor = member.task_executors.create!(
      account: member.account, executor_kind: :agent_application, display_name: "Guard app"
    )
    initial = mint_family(member: member, executor: executor)

    sequences = assert_ladder_order("rotation") do
      RefreshTokens::Rotate.call(presented: RefreshToken.find(initial.token.id))
    end

    assert_includes sequences.flatten.uniq, "users"
  end

  test "steward reassignment locks the profile and humans before the address" do
    member = create_agent_member(steward: users(:owner), agent_identifier: "install-guard-steward")
    member.task_executors.create!(
      account: member.account, executor_kind: :agent_application, display_name: "Guard app"
    )

    sequences = assert_ladder_order("change_steward") do
      assert_equal :changed, member.change_steward(to: users(:member))
    end

    seen = sequences.flatten.uniq
    assert_includes seen, "users"
    assert_includes seen, "task_executors"
  end

  test "connection revocation descends user then address" do
    connect_agent_session(steward: users(:owner), agent_identifier: "install-guard-revoke")
    member = User.find_by!(agent_identifier: "install-guard-revoke")

    sequences = assert_ladder_order("revoke_connection") do
      assert_equal :revoked, member.revoke_connection
    end

    # The family revocation itself is a guarded single-statement write (rung 2
    # of the locking ladder), so it never appears here — only the explicit
    # user and address locks do.
    seen = sequences.flatten.uniq
    assert_includes seen, "users"
    assert_includes seen, "task_executors"
  end

  test "machine cancel serializes on the request row alone" do
    grant = DeviceAuthorizations::Issue.call(
      account: accounts(:cybros), agent_identifier: "install-guard-cancel",
      agent_display_name: "Guard", requested_executor_display_name: "Guard app"
    ).authorization

    sequences = assert_ladder_order("machine cancel") do
      assert_equal :canceled, DeviceAuthorizations::MachineCancel.call(authorization: grant).outcome
    end

    assert_includes sequences.flatten.uniq, "device_authorizations"
  end

  # The removal passes: pass (i) takes each loop's lock with NO executor lock held — loop, task,
  # cursor — and pass (ii) is the executor row alone; the two never share a transaction.
  test "human removal convergence cancels addressed work loop-first and acknowledges under the executor row alone" do
    account = accounts(:cybros)
    DevModelLane.ensure_enabled!(account)
    manager = users(:member)
    runner = connect_runner(manager: manager, registration_identifier: "revoked-runner", assignment_scope: :user_private)
      .executor_access_token.task_executor
    assert_predicate runner.announce(tools: TEST_SERVED_TOOLS), :accepted?
    created = create_loop(tool("probe"), default_runner_executor_public_id: runner.public_id, workspace: workspaces(:shared), creating_user: manager)
    assert_predicate created, :created?
    agent_run = created.agent_run
    AgentRuns::Start.call(AgentRuns::Start::Command.new(agent_run: agent_run, acting_user: manager))
    AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
    assert_equal runner.id, agent_run.agent_run_tasks.sole.reload.addressed_executor_id
    assert_equal :removed, manager.remove

    sequences = assert_ladder_order("removal passes") do
      assert_equal 1, AgentRuns::Parks::TimeoutSweep.call[:revoked]
      assert_equal 1, TaskExecutor.converge[:converged]
    end

    # FailNode writes under the loop's aggregate lock, as Stop's cancel
    # does — no node row lock — then narrates under the cursor.
    cancel = sequences.find { |sequence| sequence.include?("agent_runs") }
    assert_not_nil cancel, "pass (i) canceled the addressed row under the loop lock"
    assert_operator cancel.index("agent_runs"), :<, cancel.index("conversation_event_cursors")
    assert_not_includes cancel, "task_executors", "no executor lock is held across loops"
    acknowledgement = sequences.find { |sequence| sequence.include?("task_executors") }
    assert_not_nil acknowledgement, "pass (ii) acknowledged under the executor row"
    assert_not_includes acknowledgement, "agent_runs"
    assert_equal "failed", agent_run.agent_run_tasks.sole.reload.status
  end

  test "Agent removal locks its Profile and address without synchronously locking work" do
    account = accounts(:cybros)
    DevModelLane.ensure_enabled!(account)
    agent = users(:agent)
    announce_tools!(agent, %w[agent_only])
    created = create_loop(tool("probe", "agent_only"), workspace: workspaces(:shared), creating_user: agent)
    assert_predicate created, :created?
    agent_run = created.agent_run
    AgentRuns::Start.call(AgentRuns::Start::Command.new(agent_run: agent_run, acting_user: agent))
    AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
    assert_equal "dispatched", agent_run.agent_run_tasks.sole.reload.status

    sequences = assert_ladder_order("agent removal") do
      assert_equal :removed, agent.remove
    end

    seen = sequences.flatten
    assert_operator seen.index("users"), :<, seen.index("task_executors")
    assert_not_includes seen, "agent_runs"
    assert_not_includes seen, "conversation_event_cursors"
    assert_equal "dispatched", agent_run.agent_run_tasks.sole.reload.status
  end

  test "human removal holds only the user row while its ownership guard reads" do
    sequences = assert_ladder_order("guarded removal") do
      assert_equal :workspace_ownership_transfer_required, users(:curator).remove
    end

    assert_includes sequences.flatten.uniq, "users"
  end
end
