require "test_helper"
require_relative "../../test_helpers/row_lock_test_helper"

# The admission half of the create command. Preparation happens outside the lock, so everything it
# decided is stale by the time the rows are held — which is the whole point of rechecking under the
# lock. What these tests pin is that create-first is visible to a later authority cut and that a cut
# landing first leaves no receipt and no work behind.
class InferenceRequests::CreateAdmissionTest < ActiveSupport::TestCase
  include RowLockTestHelper
  include AgentMembershipTestHelper

  uses_transaction :"test_a_create_that_loses_the_key_race_settles_on_the_winner"
  uses_transaction :test_create_first_is_visible_to_a_later_workspace_archive
  uses_transaction :test_workspace_delete_first_refuses_a_waiting_create
  uses_transaction :test_create_first_is_visible_to_later_access_narrowing
  uses_transaction :test_private_transfer_first_admits_only_the_new_owner
  uses_transaction :test_create_first_is_stopped_by_a_later_direct_user_removal
  uses_transaction :test_remove_and_fast_restore_first_still_refuses_the_stale_create
  uses_transaction :test_agent_create_first_is_stopped_before_steward_shutdown_ack
  uses_transaction :test_steward_shutdown_first_refuses_a_waiting_agent_create

  setup do
    @account = accounts(:cybros)
    @workspace = workspaces(:shared)
    @creator = users(:member)
    DevModelLane.ensure_enabled!(@account)
    @port = DevModelLane.port
  end

  def command(**overrides)
    InferenceRequests::Create::Command.new(
      **{
        workspace: @workspace, creating_user: @creator, workload: "text_generation",
        submitted: DevModelLane.submission_for("text_generation"),
        configuration: {}, input: "hello", upload_public_ids: [],
        billing_subject: nil, idempotency_key: SecureRandom.uuid,
      }.merge(overrides)
    )
  end

  def create(**overrides)
    InferenceRequests::Create.call(command: command(**overrides), port: @port)
  end

  def assert_refused_without_a_trace(result)
    assert_equal :refused, result.outcome
    assert_equal InferenceRequests::Create::NOT_AUTHORIZED, result.refusal
    assert_equal 0, InferenceRequest.count
    assert_equal 0, InferenceRequestCreateReceipt.count
  end

  test "an archived Workspace admits no new work" do
    @workspace.update!(state: :archiving)

    assert_refused_without_a_trace(create)
  end

  test "a Workspace the caller cannot reach admits nothing from them" do
    @workspace.update!(access_mode: :private, owner: users(:owner))

    assert_refused_without_a_trace(create)
  end

  test "a suspended creator admits nothing" do
    @creator.update!(status: :suspended)

    assert_refused_without_a_trace(create)
  end

  # The generation captured at request start is the caller's admission ticket.
  # If anything reissued it while this command was preparing, the create is
  # stale and must not slip in under the old one.
  test "a create that raced an authority change is refused as stale" do
    stale = User.find(@creator.id)
    User.where(id: @creator.id).update_all(authority_generation: stale.authority_generation + 1)

    assert_refused_without_a_trace(create(creating_user: stale))
  end

  test "a dedicated Workspace refuses another Agent's create" do
    dedicated = create_agent_workspace(agent_identifier: "owns-this")
    stranger = create_agent_member(steward: users(:owner), agent_identifier: "not-this-one")

    assert_refused_without_a_trace(
      create(workspace: dedicated, creating_user: stranger)
    )
  end

  test "an Agent whose steward is gone admits nothing" do
    dedicated = create_agent_workspace(agent_identifier: "orphaned")
    agent = User.find_by!(agent_identifier: "orphaned")
    agent.steward.update!(status: :removed)

    assert_refused_without_a_trace(create(workspace: dedicated, creating_user: agent))
  end

  test "an Agent on its own dedicated Workspace is admitted" do
    dedicated = create_agent_workspace(agent_identifier: "owns-this")
    agent = User.find_by!(agent_identifier: "owns-this")

    assert_predicate create(workspace: dedicated, creating_user: agent), :created?
  end

  # Both attempts miss the first lookup, remain admissible, and reach receipt
  # identity. This direct unique-index loser rolls back and settles on the
  # winner; a request that refuses before this boundary has no such guarantee.
  test "a create that loses the key race settles on the winner" do
    key = SecureRandom.uuid
    held = hold_row_lock(Workspace, @workspace.id)

    first = start_database_call { InferenceRequests::Create.call(command: command(idempotency_key: key), port: @port) }
    second = start_database_call { InferenceRequests::Create.call(command: command(idempotency_key: key), port: @port) }
    wait_until_waiting_on_lock(first.pid, second.pid)
    release_row_lock(held)
    held = nil

    results = [first, second].map { |call| finish_database_call(call) }
    first = second = nil

    assert_equal [:created, :replayed], results.map(&:outcome).sort_by(&:to_s)
    assert_equal 1, results.map(&:accepted).uniq.length,
      "both callers must be told the same accepted value"
    assert_equal 1, InferenceRequest.count
    assert_equal 1, InferenceRequestCreateReceipt.count
  ensure
    begin
      release_row_lock(held) if held
    ensure
      stop_database_call(first) if first
      stop_database_call(second) if second
      cleanup_created_rows
    end
  end

  # An existing fragment is the natural post-authority-recheck barrier: Create
  # already owns Workspace and creator, while the body writer waits below
  # them. Archive therefore has to serialize after a durable create and must
  # stop that exact invocation before its own acceptance commits.
  def test_create_first_is_visible_to_a_later_workspace_archive
    workspace_before = mutable_workspace_snapshot(@workspace)
    held = hold_matching_fragment
    creating = start_database_call { create }
    wait_until_waiting_on_lock(creating.pid)
    archiving = start_database_call do
      workspace = Workspace.find(@workspace.id)
      Workspaces::Archive.call(
        workspace: workspace, by: User.find(users(:owner).id),
        lock_version: workspace.lock_version
      )
    end
    wait_until_transitively_blocked_by(held.pid, creating.pid, archiving.pid)

    release_row_lock(held)
    held = nil
    created = finish_database_call(creating)
    creating = nil
    archived = finish_database_call(archiving)
    archiving = nil

    assert_predicate created, :created?
    assert_equal :accepted, archived.outcome
    invocation = ModelInvocation.find_by!(workspace_id: @workspace.id)
    assert_equal "canceled", invocation.status
    assert_equal "workspace_archived", invocation.cancellation_reason
  ensure
    release_row_lock(held) if held
    stop_database_call(creating) if creating
    stop_database_call(archiving) if archiving
    cleanup_created_rows
    restore_workspace(@workspace, workspace_before)
  end

  # The lifecycle command runs in the lock holder's real transaction. Create
  # captured the old authority generation and started before the cut, but its
  # locked recheck occurs after `deleting` commits and must leave no receipt.
  def test_workspace_delete_first_refuses_a_waiting_create
    workspace_before = mutable_workspace_snapshot(@workspace)
    deletion = Queue.new
    held = hold_row_lock(
      Workspace, @workspace.id,
      before_commit: ->(locked) {
        deletion << Workspaces::Delete.call(
          workspace: locked, by: User.find(users(:owner).id),
          lock_version: locked.lock_version
        )
      }
    )
    creating = start_database_call { create }
    wait_until_transitively_blocked_by(held.pid, creating.pid)

    release_row_lock(held)
    held = nil
    result = finish_database_call(creating)
    creating = nil

    assert_equal :accepted, Timeout.timeout(RowLockTestHelper::ROW_LOCK_WAIT_TIMEOUT) { deletion.pop }.outcome
    assert_refused_without_a_trace(result)
  ensure
    release_row_lock(held) if held
    stop_database_call(creating) if creating
    cleanup_created_rows
    restore_workspace(@workspace, workspace_before)
  end

  def test_create_first_is_visible_to_later_access_narrowing
    workspace_before = mutable_workspace_snapshot(@workspace)
    held = hold_matching_fragment
    creating = start_database_call { create }
    wait_until_waiting_on_lock(creating.pid)
    narrowing = start_database_call do
      workspace = Workspace.find(@workspace.id)
      Workspaces::UpdateAccessMode.call(
        workspace: workspace, by: User.find(users(:owner).id), to: "private",
        lock_version: workspace.lock_version
      )
    end
    wait_until_transitively_blocked_by(held.pid, creating.pid, narrowing.pid)

    release_row_lock(held)
    held = nil
    created = finish_database_call(creating)
    creating = nil
    narrowed = finish_database_call(narrowing)
    narrowing = nil

    assert_predicate created, :created?
    assert_equal :updated, narrowed.outcome
    invocation = ModelInvocation.find_by!(workspace_id: @workspace.id)
    assert_equal "workspace_access_revoked", invocation.reload.cancellation_reason
  ensure
    release_row_lock(held) if held
    stop_database_call(creating) if creating
    stop_database_call(narrowing) if narrowing
    cleanup_created_rows
    restore_workspace(@workspace, workspace_before)
  end

  def test_private_transfer_first_admits_only_the_new_owner
    workspace = Workspace.create!(
      account: @account, creator: users(:owner), owner: users(:owner),
      name: "Transfer barrier", access_mode: :private
    )
    @disposable_workspace_ids = [workspace.id]
    transfer = Queue.new
    held = hold_row_lock(
      Workspace, workspace.id,
      before_commit: ->(locked) {
        transfer << Workspaces::TransferOwnership.call(
          workspace: locked, by: User.find(users(:owner).id),
          to: User.find(@creator.id), lock_version: locked.lock_version
        )
      }
    )
    old_owner_create = start_database_call do
      create(workspace: Workspace.find(workspace.id), creating_user: User.find(users(:owner).id))
    end
    new_owner_create = start_database_call do
      create(workspace: Workspace.find(workspace.id), creating_user: User.find(@creator.id))
    end
    wait_until_transitively_blocked_by(held.pid, old_owner_create.pid, new_owner_create.pid)

    release_row_lock(held)
    held = nil
    old_result = finish_database_call(old_owner_create)
    old_owner_create = nil
    new_result = finish_database_call(new_owner_create)
    new_owner_create = nil

    assert_equal :transferred,
      Timeout.timeout(RowLockTestHelper::ROW_LOCK_WAIT_TIMEOUT) { transfer.pop }.outcome
    assert_equal :refused, old_result.outcome
    assert_predicate new_result, :created?
    assert_equal [@creator.id], InferenceRequest.where(workspace_id: workspace.id).pluck(:creating_user_id)
  ensure
    release_row_lock(held) if held
    stop_database_call(old_owner_create) if old_owner_create
    stop_database_call(new_owner_create) if new_owner_create
    cleanup_created_rows
    Workspace.where(id: Array(@disposable_workspace_ids)).destroy_all
  end

  def test_create_first_is_stopped_by_a_later_direct_user_removal
    creator_before = mutable_user_snapshot(@creator)
    held = hold_matching_fragment
    creating = start_database_call { create }
    wait_until_waiting_on_lock(creating.pid)
    removing = start_database_call { User.find(@creator.id).remove }
    wait_until_transitively_blocked_by(held.pid, creating.pid, removing.pid)

    release_row_lock(held)
    held = nil
    created = finish_database_call(creating)
    creating = nil
    assert_equal :removed, finish_database_call(removing)
    removing = nil

    assert_predicate created, :created?
    invocation = ModelInvocation.find_by!(workspace_id: @workspace.id)
    assert_equal "user_removed", invocation.cancellation_reason
    assert_equal @creator.reload.authority_generation,
      invocation.source_user_authority_generation
    assert_equal :restored, @creator.restore
    assert_equal "canceled", invocation.reload.status,
      "restore never resurrects accepted work"
  ensure
    release_row_lock(held) if held
    stop_database_call(creating) if creating
    stop_database_call(removing) if removing
    cleanup_created_rows
    restore_user(@creator, creator_before)
  end

  def test_remove_and_fast_restore_first_still_refuses_the_stale_create
    creator_before = mutable_user_snapshot(@creator)
    held = hold_row_lock(Workspace, @workspace.id)
    creating = start_database_call { create }
    wait_until_transitively_blocked_by(held.pid, creating.pid)

    assert_equal :removed, @creator.reload.remove
    assert_equal :restored, @creator.reload.restore
    release_row_lock(held)
    held = nil
    result = finish_database_call(creating)
    creating = nil

    assert_refused_without_a_trace(result)
  ensure
    release_row_lock(held) if held
    stop_database_call(creating) if creating
    cleanup_created_rows
    restore_user(@creator, creator_before)
  end

  def test_agent_create_first_is_stopped_before_steward_shutdown_ack
    steward = @creator
    steward_before = mutable_user_snapshot(steward)
    agent = create_agent_member(
      steward: steward, agent_identifier: "create-first-steward-shutdown"
    )
    @disposable_user_ids = [agent.id]
    held = hold_matching_fragment
    creating = start_database_call do
      create(creating_user: User.find(agent.id))
    end
    wait_until_waiting_on_lock(creating.pid)
    removing = start_database_call { User.find(steward.id).remove }
    wait_until_transitively_blocked_by(held.pid, creating.pid, removing.pid)

    release_row_lock(held)
    held = nil
    created = finish_database_call(creating)
    creating = nil
    assert_equal :removed, finish_database_call(removing)
    removing = nil

    assert_predicate created, :created?
    assert_equal 1, User.converge[:converged]
    invocation = ModelInvocation.find_by!(creating_user_id: agent.id)
    assert_equal "steward_removed", invocation.cancellation_reason
    assert_equal steward.reload.managed_resource_shutdown_generation,
      invocation.steward_shutdown_generation
    assert_predicate agent.reload, :removed?
  ensure
    release_row_lock(held) if held
    stop_database_call(creating) if creating
    stop_database_call(removing) if removing
    cleanup_created_rows
    User.where(id: Array(@disposable_user_ids)).destroy_all
    restore_user(steward, steward_before)
  end

  def test_steward_shutdown_first_refuses_a_waiting_agent_create
    steward = @creator
    steward_before = mutable_user_snapshot(steward)
    agent = create_agent_member(
      steward: steward, agent_identifier: "shutdown-first-agent-create"
    )
    @disposable_user_ids = [agent.id]
    held = hold_row_lock(Workspace, @workspace.id)
    creating = start_database_call do
      create(creating_user: User.find(agent.id))
    end
    wait_until_transitively_blocked_by(held.pid, creating.pid)

    assert_equal :removed, steward.reload.remove
    assert_equal :restored, steward.reload.restore
    release_row_lock(held)
    held = nil
    result = finish_database_call(creating)
    creating = nil

    assert_refused_without_a_trace(result)
  ensure
    release_row_lock(held) if held
    stop_database_call(creating) if creating
    cleanup_created_rows
    User.where(id: Array(@disposable_user_ids)).destroy_all
    restore_user(steward, steward_before)
  end

  private

    def hold_matching_fragment
      fragment = create_fragment({ "text" => "hello" })
      hold_row_lock(ContentFragment, fragment.id)
    end

    def mutable_workspace_snapshot(workspace)
      workspace.reload.attributes.slice(
        "state", "access_mode", "owner_id", "archived_at", "deleted_at",
        "lock_version", "updated_at"
      )
    end

    def restore_workspace(workspace, snapshot)
      Workspace.where(id: workspace&.id).update_all(snapshot) if snapshot
    end

    def mutable_user_snapshot(user)
      user.reload.attributes.slice(
        "status", "authority_generation", "managed_resource_shutdown_generation", "updated_at"
      )
    end

    def restore_user(user, snapshot)
      User.where(id: user&.id).update_all(snapshot) if snapshot
    end

    def create_agent_workspace(agent_identifier:)
      agent = create_agent_member(steward: users(:owner), agent_identifier: agent_identifier)
      Workspaces::Create.call(creator: agent, name: "Agent space").workspace
    end

    def create_fragment(payload)
      address = Nexus::ContentAddress.for(account_id: @account.id, payload: payload)
      @account.content_fragments.create!(
        payload: payload, digest: address.digest
      )
    end

    # These three tests commit for real, so they own their cleanup: a leaked row
    # here would fail some other file in a later run and cost an hour to find.
    def cleanup_created_rows
      InferenceRequestCreateReceipt.delete_all
      InferenceRequest.destroy_all
      ContentFragment.delete_all
      ContentUpload.destroy_all
    end
end
