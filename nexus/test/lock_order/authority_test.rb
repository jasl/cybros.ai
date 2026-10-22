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

  test "application authorization and Human rotation keep the credential lock order" do
    grant = DeviceAuthorizations::Issue.call(
      account: accounts(:cybros), client_id: OAuth::APPLICATION_CLIENT_ID,
      agent_identifier: "application-lock-order", agent_display_name: "Application",
      requested_executor_display_name: "Application executor"
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
    executor = member.executors.create!(
      account: member.account, executor_kind: :agent, display_name: "Guard app"
    )
    initial = mint_family(member: member, executor: executor)

    sequences = assert_ladder_order("rotation") do
      RefreshTokens::Rotate.call(presented: RefreshToken.find(initial.token.id))
    end

    assert_includes sequences.flatten.uniq, "users"
  end

  test "steward reassignment locks the profile and humans before the address" do
    member = create_agent_member(steward: users(:owner), agent_identifier: "install-guard-steward")
    member.executors.create!(
      account: member.account, executor_kind: :agent, display_name: "Guard app"
    )

    sequences = assert_ladder_order("change_steward") do
      assert_equal :changed, member.change_steward(to: users(:member))
    end

    seen = sequences.flatten.uniq
    assert_includes seen, "users"
    assert_includes seen, "executors"
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
    assert_includes seen, "executors"
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
      .executor_access_token.executor
    assert_predicate runner.announce(services: { runner.executor_kind => { "tools" => TEST_SERVED_TOOLS } }), :accepted?
    created = create_loop(tool("probe"), default_runner_executor_public_id: runner.public_id, workspace: workspaces(:shared), creating_user: manager)
    assert_predicate created, :created?
    run = created.run
    Runs::Start.call(Runs::Start::Command.new(run: run, acting_user: manager))
    Runs::ScheduleReady.call(run_id: run.id)
    assert_equal runner.id, run.tasks.sole.reload.addressed_executor_id
    assert_equal :removed, manager.remove

    sequences = assert_ladder_order("removal passes") do
      assert_equal 1, Runs::Parks::TimeoutSweep.call[:revoked]
      assert_equal 1, Executor.converge[:converged]
    end

    # FailNode writes under the loop's aggregate lock, as Stop's cancel
    # does — no node row lock — then narrates under the cursor.
    cancel = sequences.find { |sequence| sequence.include?("runs") }
    assert_not_nil cancel, "pass (i) canceled the addressed row under the loop lock"
    assert_operator cancel.index("runs"), :<, cancel.index("event_cursors")
    assert_not_includes cancel, "executors", "no executor lock is held across loops"
    acknowledgement = sequences.find { |sequence| sequence.include?("executors") }
    assert_not_nil acknowledgement, "pass (ii) acknowledged under the executor row"
    assert_not_includes acknowledgement, "runs"
    assert_equal "failed", run.tasks.sole.reload.status
  end

  test "Agent removal locks its Profile and address without synchronously locking work" do
    account = accounts(:cybros)
    DevModelLane.ensure_enabled!(account)
    agent = users(:agent)
    announce_tools!(agent, %w[agent_only])
    created = create_loop(tool("probe", "agent_only"), workspace: workspaces(:shared), creating_user: agent)
    assert_predicate created, :created?
    run = created.run
    Runs::Start.call(Runs::Start::Command.new(run: run, acting_user: agent))
    Runs::ScheduleReady.call(run_id: run.id)
    assert_equal "dispatched", run.tasks.sole.reload.status

    sequences = assert_ladder_order("agent removal") do
      assert_equal :removed, agent.remove
    end

    seen = sequences.flatten
    assert_operator seen.index("users"), :<, seen.index("executors")
    assert_not_includes seen, "runs"
    assert_not_includes seen, "event_cursors"
    assert_equal "dispatched", run.tasks.sole.reload.status
  end

  test "human removal holds only the user row while its ownership guard reads" do
    sequences = assert_ladder_order("guarded removal") do
      assert_equal :workspace_ownership_transfer_required, users(:curator).remove
    end

    assert_includes sequences.flatten.uniq, "users"
  end
end
