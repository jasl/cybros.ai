require "test_helper"
require_relative "../test_helpers/row_lock_test_helper"

# Agent membership foundation invariants: steward attribution in the frozen
# kind/role vocabulary and the logical-registration-stable program identifier with
# creation-time immutability and hard Account-wide instance uniqueness.
class UserStewardshipTest < ActiveSupport::TestCase
  include RowLockTestHelper

  uses_transaction :test_source_removal_that_locks_first_blocks_steward_reassignment,
    :test_steward_reassignment_that_locks_first_wins_before_source_removal

  setup do
    @account = accounts(:cybros)
    @agent = users(:agent)
    @owner = users(:owner)
    @member = users(:member)
  end

  def create_model_work(creating_user)
    inference_request = InferenceRequest.create!(
      account: @account, workspace: workspaces(:shared), creating_user: creating_user,
      workload: "text_generation"
    )
    DevModelLane.create_invocation!(inference_request: inference_request)
  end

  test "the agent fixture is valid and carries steward attribution" do
    assert_predicate @agent, :valid?
    assert_equal @owner, @agent.steward
  end

  test "an agent cannot be suspended; its lifecycle is remove and restore" do
    assert_not @agent.update(status: :suspended)
    assert @agent.errors.of_kind?(:status, :invalid)
    assert @agent.reload.active?

    assert_equal :not_applicable, @agent.suspend
    assert @agent.reload.active?

    assert_equal :removed, @agent.remove
    assert_equal :restored, @agent.reload.restore
  end

  test "a non-system agent member requires a steward" do
    @agent.steward = nil
    assert_not @agent.valid?
    assert @agent.errors.of_kind?(:steward, :blank)
  end

  test "humans and the system user never carry a steward" do
    @member.steward = @owner
    assert_not @member.valid?
    assert @member.errors.of_kind?(:steward, :present)

    system = users(:system)
    system.steward = @owner
    assert_not system.valid?
    assert system.errors.of_kind?(:steward, :present)
  end

  test "steward assignment accepts only an active same-account human" do
    @agent.steward = users(:system)
    assert_not @agent.valid?
    assert @agent.errors.of_kind?(:steward, :not_eligible)

    @member.suspend
    @agent.steward = @member.reload
    assert_not @agent.valid?
    assert @agent.errors.of_kind?(:steward, :not_eligible)
  end

  test "steward liveness is checked at assignment, not on unrelated saves" do
    # Hand ownership to the member so the fixture steward (ex-owner) becomes
    # suspendable.
    @member.change_role(to: :admin)
    assert_equal :transferred, @account.transfer_ownership(to: @member.reload, by: @owner)
    assert_equal :suspended, @owner.reload.suspend

    # The agent still stewarded by the now-suspended ex-owner saves fine.
    assert @agent.reload.update(display_name: "Renamed agent")

    # Reassigning to an active human works; reassigning back to the
    # suspended one is rejected at assignment.
    @agent.update!(steward: @member)
    @agent.steward = @owner
    assert_not @agent.valid?
    assert @agent.errors.of_kind?(:steward, :not_eligible)
  end

  test "steward reassignment advances no authority generation" do
    assert_no_changes -> { @agent.reload.authority_generation } do
      assert_equal :changed, @agent.change_steward(to: @member)
    end
    assert_equal @member.managed_resource_shutdown_generation,
      @agent.reload.applied_steward_shutdown_generation
  end

  test "a new Agent freezes its steward's current shutdown generation" do
    assert_equal :removed, @member.remove
    assert_equal :restored, @member.restore

    profile = create_agent_member(
      steward: @member,
      agent_identifier: "post-restore-profile"
    )

    assert_equal @member.managed_resource_shutdown_generation,
      profile.applied_steward_shutdown_generation
    assert profile.steward_live?
  end

  test "steward remove and restore stays fenced until Profile convergence" do
    profile = create_agent_member(
      steward: @member,
      agent_identifier: "profile-shutdown"
    )
    original_authority = profile.authority_generation

    assert_equal :removed, @member.remove
    assert_equal :restored, @member.restore
    assert_not profile.reload.steward_live?

    assert_equal 1, User.converge[:converged]

    profile.reload
    assert_predicate profile, :removed?
    assert_equal original_authority + 1, profile.authority_generation
    assert_equal @member.managed_resource_shutdown_generation,
      profile.applied_steward_shutdown_generation
  end

  test "Agent restore waits for an active steward and an applied shutdown generation" do
    profile = create_agent_member(
      steward: @member,
      agent_identifier: "restore-after-steward-shutdown"
    )
    assert_equal :removed, profile.remove
    assert_equal :removed, @member.remove

    assert_equal :shutdown_pending, profile.reload.restore,
      "the generation mismatch blocks direct restore"
    assert_equal 1, User.converge[:converged]
    assert_equal :shutdown_pending, profile.reload.restore,
      "an acknowledged Profile still cannot outlive a removed steward"

    assert_equal :restored, @member.restore
    assert_equal :restored, profile.reload.restore
    assert profile.execution_principal_eligible?

    assert_equal :removed, @member.remove
    assert_not profile.reload.execution_principal_eligible?,
      "a later Human removal wins immediately after the earlier restore"
  end

  test "steward reassignment waits for both Profile and address shutdown" do
    profile = create_agent_member(
      steward: @member,
      agent_identifier: "transfer-after-shutdown"
    )
    address = profile.task_executors.create!(
      account: @account,
      executor_kind: :agent_application,
      display_name: "Agent app"
    )

    assert_equal :removed, @member.remove
    assert_equal :shutdown_pending, profile.change_steward(to: @owner)

    assert_equal 1, User.converge[:converged]
    assert_equal :shutdown_pending, profile.reload.change_steward(to: @owner),
      "Profile acknowledgement cannot skip the address's graceful shutdown"

    TaskExecutor.converge
    assert_equal :changed, profile.reload.change_steward(to: @owner)
    assert_equal @owner, profile.reload.steward
    assert_equal @owner.managed_resource_shutdown_generation,
      profile.applied_steward_shutdown_generation
    assert_equal @owner.managed_resource_shutdown_generation,
      address.reload.applied_human_shutdown_generation
  end

  test "source removal that locks first blocks steward reassignment" do
    profile = create_agent_member(
      steward: @member,
      agent_identifier: "remove-first-reassignment"
    )
    profile.task_executors.create!(
      account: @account,
      executor_kind: :agent_application,
      display_name: "Agent app"
    )
    invocation = create_model_work(profile)
    held_source = hold_row_lock(
      User,
      @member.id,
      before_commit: ->(locked) {
        raise "source removal failed" unless locked.remove == :removed
      }
    )
    reassignment = start_database_call do
      User.find(profile.id).change_steward(to: User.find(@owner.id))
    end

    wait_until_waiting_on_lock(reassignment.pid)
    release_row_lock(held_source)
    held_source = nil
    result = finish_database_call(reassignment)
    reassignment = nil

    assert_equal :shutdown_pending, result
    assert_equal @member, profile.reload.steward
    assert_equal 1, User.converge[:converged]
    assert_equal "canceled", invocation.reload.status
    assert_equal "steward_removed", invocation.cancellation_reason
    assert_equal @member.reload.managed_resource_shutdown_generation,
      invocation.steward_shutdown_generation
  ensure
    release_row_lock(held_source) if held_source
    stop_database_call(reassignment) if reassignment
    InferenceRequest.where(id: invocation&.inference_request_id).destroy_all
    # This non-transactional test committed DevModelLane's lane enablement;
  end

  test "steward reassignment that locks first wins before source removal" do
    identity = @account.identities.create!(
      email: "steward-transfer-target-#{SecureRandom.hex(8)}@example.com",
      password: "long enough password",
      password_confirmation: "long enough password"
    )
    target = @account.users.create!(
      identity: identity,
      kind: :human,
      role: :member,
      display_name: "Transfer target"
    )
    profile = create_agent_member(
      steward: @member,
      agent_identifier: "transfer-first-reassignment"
    )
    address = profile.task_executors.create!(
      account: @account,
      executor_kind: :agent_application,
      display_name: "Agent app"
    )
    invocation = create_model_work(profile)
    held_target = hold_row_lock(User, target.id)
    reassignment = start_database_call do
      User.find(profile.id).change_steward(to: User.find(target.id))
    end

    wait_until_waiting_on_lock(reassignment.pid)
    removal = start_database_call { User.find(@member.id).remove }
    wait_until_waiting_on_lock(reassignment.pid, removal.pid)

    release_row_lock(held_target)
    held_target = nil
    assert_equal :changed, finish_database_call(reassignment)
    reassignment = nil
    assert_equal :removed, finish_database_call(removal)
    removal = nil

    assert_equal target, profile.reload.steward
    assert profile.steward_live?
    assert_equal target.managed_resource_shutdown_generation,
      profile.applied_steward_shutdown_generation
    assert_equal target.managed_resource_shutdown_generation,
      address.reload.applied_human_shutdown_generation
    assert_equal 0, User.converge[:converged],
      "the old steward has no Profile shutdown candidate after reassignment"
    assert_equal "queued", invocation.reload.status,
      "the old steward's shutdown cannot cross the committed reassignment"
  ensure
    release_row_lock(held_target) if held_target
    stop_database_call(reassignment) if reassignment
    stop_database_call(removal) if removal
    InferenceRequest.where(id: invocation&.inference_request_id).destroy_all
    # This non-transactional test committed DevModelLane's lane enablement;
  end

  test "direct Agent removal does not invent a Human shutdown episode" do
    assert_no_changes -> { @agent.reload.managed_resource_shutdown_generation } do
      assert_equal :removed, @agent.remove
    end

    assert_equal :changed, @agent.reload.change_steward(to: @member)
    assert_equal @member, @agent.reload.steward
  end

  test "agent_identifier is forbidden on humans and the system user" do
    human = @account.users.new(
      kind: :human,
      role: :member,
      identity: @member.identity,
      display_name: "Human",
      agent_identifier: "some-installation"
    )
    assert_not human.valid?
    assert human.errors.of_kind?(:agent_identifier, :present)

    system = @account.users.new(
      kind: :agent,
      role: :system,
      display_name: User::SYSTEM_DISPLAY_NAME,
      agent_identifier: "some-installation"
    )
    assert_not system.valid?
    assert system.errors.of_kind?(:agent_identifier, :present)
  end

  test "agent_identifier enforces printable non-NUL content without surrounding whitespace" do
    ["bad\0identifier", " padded ", "control\tchars", "a" * 129].each do |identifier|
      candidate = @account.users.new(
        kind: :agent,
        role: :member,
        steward: @owner,
        display_name: "Invalid",
        agent_identifier: identifier
      )
      assert_not candidate.valid?
    end

    fresh = @account.users.new(
      kind: :agent, role: :member, steward: @owner,
      display_name: "Fresh", agent_identifier: "a" * 128
    )
    assert_predicate fresh, :valid?
  end

  test "comparison is exact and case-sensitive: same identifier in another case is a different identity" do
    other = @account.users.create!(
      kind: :agent, role: :member, steward: @owner,
      display_name: "Other case", agent_identifier: @agent.agent_identifier.upcase
    )
    assert_predicate other, :persisted?
  end

  test "every ordinary agent starts identified and the identifier is immutable" do
    missing = @account.users.new(
      kind: :agent,
      role: :member,
      steward: @owner,
      display_name: nil
    )
    assert_not missing.valid?
    assert missing.errors.of_kind?(:agent_identifier, :blank)

    assert_includes User.readonly_attributes, "agent_identifier"
    assert_raises(ActiveRecord::ReadonlyAttributeError) do
      @agent.agent_identifier = "different-installation"
    end
  end

  test "identifier uniqueness is Account-wide and holds even while removed" do
    # The Account-global key remains held across removal and steward changes.
    same_steward = @account.users.new(
      kind: :agent, role: :member, steward: @owner,
      display_name: "Duplicate", agent_identifier: @agent.agent_identifier
    )
    assert_not same_steward.valid?
    assert same_steward.errors.of_kind?(:agent_identifier, :taken)

    @agent.remove
    assert_not same_steward.valid?, "a removed profile still holds its instance identifier"
    assert same_steward.errors.of_kind?(:agent_identifier, :taken)

    # Another Human cannot claim the same instance identifier.
    other_steward = @account.users.new(
      kind: :agent, role: :member, steward: @member,
      display_name: "Another human's copy", agent_identifier: @agent.agent_identifier
    )
    assert_not other_steward.valid?
    assert other_steward.errors.of_kind?(:agent_identifier, :taken)
  end

  test "the database rejects a duplicate profile key even when validations are skipped" do
    duplicate = @account.users.new(
      kind: :agent, role: :member, steward: @owner,
      display_name: "Duplicate", handle: "duplicate",
      agent_identifier: @agent.agent_identifier
    )

    assert_raises ActiveRecord::RecordNotUnique do
      duplicate.save!(validate: false)
    end
  end

  test "the global instance key survives steward reassignment" do
    identifier = @agent.agent_identifier
    assert_equal :changed, @agent.change_steward(to: @member)
    assert_equal identifier, @agent.reload.agent_identifier
    duplicate = @account.users.new(
      kind: :agent, role: :member, steward: @owner,
      display_name: "Duplicate", handle: "duplicate", agent_identifier: identifier
    )
    assert_not duplicate.valid?
    assert duplicate.errors.of_kind?(:agent_identifier, :taken)
    assert_raises ActiveRecord::RecordNotUnique do
      duplicate.save!(validate: false)
    end
  end

  test "founding still succeeds: the system user takes no steward" do
    Account.destroy_all

    account = Account.create_with_owner(
      account: { name: "Fresh" },
      owner: { email: "founder@example.com", display_name: "Founder",
               password: "a strong password", password_confirmation: "a strong password" }
    )

    assert_predicate account, :persisted?
    system = account.users.find_by!(role: :system)
    assert_nil system.steward_id
    assert_nil system.agent_identifier
  end
end
