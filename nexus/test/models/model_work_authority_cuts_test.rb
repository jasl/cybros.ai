require "test_helper"

# The five frozen authority cuts, each proven through its real command. The property under test is
# "first stop": the acceptance transaction that wins the authority also owns the cancellation, so no
# window exists where authority is gone but work is still admissible.
class ModelWorkAuthorityCutsTest < ActiveSupport::TestCase
  include AgentMembershipTestHelper

  setup do
    @account = accounts(:cybros)
    @owner = users(:owner)
    @member = users(:member)
  end

  def create_aggregate(workspace:, creating_user:)
    one_shot = OneShot.create!(
      account: @account, workspace: workspace, creating_user: creating_user,
      workload: "text_generation"
    )
    invocation = DevModelLane.create_invocation!(one_shot: one_shot)
    invocation
  end

  def owned_workspace(access_mode: :private, owner: @owner)
    @account.workspaces.create!(
      creator: owner, owner: owner, name: "Cut #{SecureRandom.hex(3)}",
      access_mode: access_mode
    )
  end

  def assert_stopped(invocation, reason)
    invocation.reload
    assert_equal "canceled", invocation.status
    assert_equal reason, invocation.cancellation_reason
  end

  def assert_survives(invocation)
    invocation.reload
    assert_equal "queued", invocation.status
    assert_nil invocation.cancellation_reason
  end

  def assert_no_model_work_update(label)
    statements = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      sql = payload[:sql].to_s
      if sql.start_with?('UPDATE "model_invocations"')
        statements << sql
      end
    end

    result = yield
    assert_empty statements, "#{label} ends no access and must not update live model work"
    result
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) unless subscriber.nil?
  end

  test "archiving a Workspace stops its work in the acceptance transaction" do
    workspace = owned_workspace
    stopped = create_aggregate(workspace: workspace, creating_user: @owner)
    elsewhere = create_aggregate(workspace: owned_workspace, creating_user: @owner)

    result = Workspaces::Archive.call(
      workspace: workspace, by: @owner, lock_version: workspace.lock_version
    )

    assert_equal :accepted, result.outcome
    assert_stopped(stopped, "workspace_archived")
    assert_survives(elsewhere)
  end

  test "deleting a Workspace stops its work under its own reason" do
    workspace = owned_workspace
    stopped = create_aggregate(workspace: workspace, creating_user: @owner)

    Workspaces::Delete.call(
      workspace: workspace, by: @owner, lock_version: workspace.lock_version
    )

    assert_stopped(stopped, "workspace_deleted")
  end

  # Restore reopens access for NEW work; it never resurrects an accepted
  # cancellation. That asymmetry is the whole point of write-once evidence.
  test "restoring never revives work an archive already stopped" do
    workspace = owned_workspace
    stopped = create_aggregate(workspace: workspace, creating_user: @owner)
    Workspaces::Archive.call(
      workspace: workspace, by: @owner, lock_version: workspace.lock_version
    )
    Workspaces::CompleteTransition.call(workspace: workspace.reload)

    Workspaces::Restore.call(
      workspace: workspace.reload, by: @owner, lock_version: workspace.lock_version
    )

    assert_stopped(stopped, "workspace_archived")
  end

  # Narrowing cuts only principals absent under the NEW relation. The owner
  # keeps access to their own private Workspace, so their work survives while
  # the other member's does not.
  # The suspended member is this test's exclusion-arm tripwire: since the
  # commands that end nobody's access no longer reach the difference SQL at
  # all, the narrowing commands are the only remaining drivers of
  # `principals.status = 'active'` — a rewrite of the difference into
  # "absent now" would sweep the suspended member here, stealing the reason
  # the suspension owner keeps.
  test "narrowing to private stops the members who lost access and spares the owner" do
    workspace = owned_workspace(access_mode: :account_wide)
    survivor = create_aggregate(workspace: workspace, creating_user: @owner)
    stopped = create_aggregate(workspace: workspace, creating_user: @member)
    absent = users(:curator)
    absent_work = create_aggregate(workspace: workspace, creating_user: absent)
    absent.reload.suspend

    result = Workspaces::UpdateAccessMode.call(
      workspace: workspace, by: @owner, to: "private", lock_version: workspace.lock_version
    )

    assert_equal :updated, result.outcome
    assert_stopped(stopped, "workspace_access_revoked")
    assert_survives(survivor)
    assert_survives(absent_work)
    assert_nil absent_work.reload.cancellation_reason,
      "a suspended member was already outside the relation; this cut ended nothing of theirs"
  end

  # The pending-shutdown Agent is the generation-arm tripwire (the same role
  # the suspended member plays above): its steward's advanced
  # `managed_resource_shutdown_generation` has not been acknowledged, so the
  # Profile is already outside the relation and its reason belongs to the
  # convergence owner as `steward_removed` — a cut that asked only "who is
  # absent now" would steal it as `workspace_access_revoked`.
  test "narrowing follows each active Agent through its current live steward" do
    workspace = owned_workspace(access_mode: :account_wide)
    owners_agent = create_agent_member(
      steward: @owner, agent_identifier: "owner-access-survives"
    )
    members_agent = create_agent_member(
      steward: @member, agent_identifier: "member-access-ends"
    )
    pending_agent = create_agent_member(
      steward: users(:curator), agent_identifier: "curator-pending-shutdown"
    )
    survivor = create_aggregate(workspace: workspace, creating_user: owners_agent)
    stopped = create_aggregate(workspace: workspace, creating_user: members_agent)
    pending_work = create_aggregate(workspace: workspace, creating_user: pending_agent)
    # The durable state an unconverged steward removal leaves behind, without
    # the removal ceremony's unrelated side effects.
    users(:curator).update_columns(
      managed_resource_shutdown_generation:
        users(:curator).managed_resource_shutdown_generation + 1
    )

    Workspaces::UpdateAccessMode.call(
      workspace: workspace, by: @owner, to: "private", lock_version: workspace.lock_version
    )

    assert_survives(survivor)
    assert_stopped(stopped, "workspace_access_revoked")
    assert_survives(pending_work)
    assert_nil pending_work.reload.cancellation_reason,
      "the shutdown episode's owner keeps steward_removed and its generation evidence"
  end

  test "the access difference is one lazy correlated database relation" do
    workspace = owned_workspace(access_mode: :account_wide)
    agent = create_agent_member(steward: @member, agent_identifier: "set-access-query")
    invocation = create_aggregate(workspace: workspace, creating_user: agent)
    previously = workspace.dup
    workspace.access_mode = "private"

    selects = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      sql = payload[:sql].to_s
      if payload[:name] != "SCHEMA" && !payload[:cached] && sql.start_with?("SELECT")
        selects << sql
      end
    end
    begin
      relation = workspace.model_work_losing_access(previously: previously)
      assert_empty selects, "building a relation must not materialize principals"
      assert_equal [invocation.id], relation.ids
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    assert_equal 1, selects.length, "the invocation query owns the correlated access predicate"
    assert_match(/EXISTS \( SELECT 1 FROM users AS principals/, selects.first)
    assert_match(/LEFT JOIN users AS stewards/, selects.first)
  end

  test "widening authorizes new work and cancels nothing" do
    workspace = owned_workspace
    survivor = create_aggregate(workspace: workspace, creating_user: @owner)

    assert_no_model_work_update("widening") do
      Workspaces::UpdateAccessMode.call(
        workspace: workspace, by: @owner, to: "account_wide", lock_version: workspace.lock_version
      )
    end

    assert_survives(survivor)
  end

  # The cut is the difference between two relations, not a test of the new
  # one. `data_accessible_by?` also demands an active User and a live steward,
  # and neither suspension nor a steward shutdown awaiting convergence is one
  # of the five frozen reasons — so a principal can hold live work while
  # already outside the relation. These commands now end nobody's access BY
  # CONSTRUCTION and never reach the difference SQL, which is exactly what
  # the already-absent principal in the room pins: the gate, not the cast.
  # The cast's own exclusion arms stay driven by the narrowing tests above,
  # whose suspended member and pending-shutdown Agent walk the ungated path.
  test "a command that ends nobody's access spares a principal who was already absent" do
    [
      ["account-wide transfer", ->(workspace) {
        Workspaces::TransferOwnership.call(
          workspace: workspace.reload, by: @owner, to: users(:curator),
          lock_version: workspace.reload.lock_version
        )
      }],
      ["same-mode update", ->(workspace) {
        Workspaces::UpdateAccessMode.call(
          workspace: workspace.reload, by: @owner, to: "account_wide",
          lock_version: workspace.reload.lock_version
        )
      }],
    ].each do |label, command|
      workspace = owned_workspace(access_mode: :account_wide)
      work = create_aggregate(workspace: workspace, creating_user: @member)
      @member.reload.suspend

      assert_no_model_work_update(label) { command.call(workspace) }

      assert_survives(work)
      assert_nil work.reload.cancellation_reason, "#{label} ended nobody's access"
      @member.reload.reactivate
    end
  end

  # The sharpest consequence: an unrelated command must not win the reason
  # that P8 reserves for the Profile-shutdown owner. Before the fix, an
  # account-wide transfer during the convergence window stamped
  # `workspace_access_revoked` with no shutdown generation, and convergence
  # then acknowledged the Profile with nothing of its own ever written.
  test "an unrelated command does not steal a pending Profile shutdown's reason" do
    agent = create_agent_member(steward: @member, agent_identifier: "reason-owner")
    workspace = owned_workspace(access_mode: :account_wide)
    work = create_aggregate(workspace: workspace, creating_user: agent)
    assert_equal :removed, @member.remove

    Workspaces::TransferOwnership.call(
      workspace: workspace.reload, by: @owner, to: users(:curator),
      lock_version: workspace.reload.lock_version
    )
    assert_nil work.reload.cancellation_reason,
      "the transfer ended nobody's access; the shutdown owner has not run yet"

    assert_equal 1, User.converge[:converged]

    assert_stopped(work, "steward_removed")
    assert_equal @member.reload.managed_resource_shutdown_generation,
      work.reload.steward_shutdown_generation
  end

  test "transferring a private Workspace stops the departing owner's work" do
    workspace = owned_workspace
    stopped = create_aggregate(workspace: workspace, creating_user: @owner)

    result = Workspaces::TransferOwnership.call(
      workspace: workspace, by: @owner, to: @member, lock_version: workspace.lock_version
    )

    assert_equal :transferred, result.outcome
    assert_stopped(stopped, "workspace_access_revoked")
  end

  # An account-wide Workspace keeps every member's access, so the same
  # command is not a cut at all.
  test "transferring an account-wide Workspace cancels nothing" do
    workspace = owned_workspace(access_mode: :account_wide)
    survivor = create_aggregate(workspace: workspace, creating_user: @owner)

    Workspaces::TransferOwnership.call(
      workspace: workspace, by: @owner, to: @member, lock_version: workspace.lock_version
    )

    assert_survives(survivor)
  end

  test "removing a User stops that principal's work with the accepted generation" do
    workspace = owned_workspace(access_mode: :account_wide)
    stopped = create_aggregate(workspace: workspace, creating_user: @member)
    survivor = create_aggregate(workspace: workspace, creating_user: @owner)

    assert_equal :removed, @member.remove

    assert_stopped(stopped, "user_removed")
    assert_equal @member.reload.authority_generation,
      stopped.reload.source_user_authority_generation
    assert_survives(survivor)
  end

  test "direct Agent removal owns user_removed under the Agent generation" do
    agent = create_agent_member(steward: @owner, agent_identifier: "direct-agent-removal")
    workspace = owned_workspace(access_mode: :account_wide)
    stopped = create_aggregate(workspace: workspace, creating_user: agent)

    assert_equal :removed, agent.remove

    assert_stopped(stopped, "user_removed")
    assert_equal agent.reload.authority_generation,
      stopped.reload.source_user_authority_generation
    assert_nil stopped.steward_shutdown_generation
  end

  # A steward's removal reaches its Profiles through convergence, never
  # through ordinary User removal — which would win the wrong reason.
  test "steward shutdown stops its Profile's work as steward_removed" do
    agent = create_agent_member(steward: @member, agent_identifier: "cut-target")
    # An account-wide Workspace owned by someone else: the Agent reaches it
    # through its steward, and removing that steward owns no Workspace of its
    # own, so the removal itself is not blocked.
    workspace = owned_workspace(access_mode: :account_wide)
    stopped = create_aggregate(workspace: workspace, creating_user: agent)

    assert_equal :removed, @member.remove
    # The Human's own removal must not have claimed the Profile's work: that
    # would win `user_removed` where the contract says `steward_removed`.
    assert_nil stopped.reload.cancellation_reason,
      "a steward's removal is not the Profile's cancellation owner"

    assert_equal 1, User.converge[:converged]

    assert_stopped(stopped, "steward_removed")
    assert_equal @member.reload.managed_resource_shutdown_generation,
      stopped.reload.steward_shutdown_generation
    assert_equal "removed", agent.reload.status
  end

  test "steward shutdown cuts all current child work before it acknowledges" do
    agent = create_agent_member(steward: @member, agent_identifier: "profile-shutdown")
    workspace = owned_workspace(access_mode: :account_wide)
    invocations = 3.times.map do
      create_aggregate(workspace: workspace, creating_user: agent)
    end
    applied = agent.applied_steward_shutdown_generation

    assert_equal :removed, @member.remove
    generation = @member.reload.managed_resource_shutdown_generation

    result = agent.converge_steward_shutdown(
      expected_steward_id: @member.id,
      expected_generation: generation,
      expected_applied_generation: applied
    )

    assert_equal :converged, result
    assert invocations.all? { _1.reload.canceled? }
    assert_predicate agent.reload, :removed?
    assert_equal generation, agent.applied_steward_shutdown_generation
  end
end
