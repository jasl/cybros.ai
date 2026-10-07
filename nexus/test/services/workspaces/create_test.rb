require "test_helper"
require_relative "../../test_helpers/row_lock_test_helper"

class Workspaces::CreateTest < ActiveSupport::TestCase
  include AgentMembershipTestHelper
  include RowLockTestHelper

  uses_transaction :test_human_creation_and_removal_preserve_final_ownership_integrity,
    :test_agent_creation_and_steward_removal_preserve_final_ownership_integrity

  test "a Human creates an account-wide or private Workspace they own" do
    result = Workspaces::Create.call(
      creator: users(:member), name: "Research", access_mode: :account_wide
    )

    assert_equal :created, result.outcome
    workspace = result.workspace
    assert_equal users(:member), workspace.creator
    assert_equal users(:member), workspace.owner
    assert workspace.account_wide?
    assert workspace.active?
    assert_nil workspace.agent_identifier

    private_result = Workspaces::Create.call(creator: users(:member), name: "Notes")
    assert_equal :created, private_result.outcome
    assert private_result.workspace.private?
  end

  test "the service exposes no caller-supplied agent identifier" do
    assert_raises(ArgumentError) do
      Workspaces::Create.call(
        creator: users(:member), name: "Tagged", agent_identifier: "some-agent"
      )
    end
  end

  test "an Agent is dedicated automatically and its current steward owns" do
    omitted = Workspaces::Create.call(creator: users(:agent), name: "Agent Scratch")
    explicit = Workspaces::Create.call(
      creator: users(:agent), name: "Agent Private", access_mode: :private
    )

    assert_equal :created, omitted.outcome
    assert_equal :created, explicit.outcome
    [omitted.workspace, explicit.workspace].each do |workspace|
      assert_equal users(:agent), workspace.creator
      assert_equal users(:owner), workspace.owner
      assert workspace.private?
      assert_equal users(:agent).agent_identifier, workspace.agent_identifier
    end
  end

  test "an Agent rejects every unsupported access mode without creating" do
    results = nil
    assert_no_difference -> { Workspace.count } do
      results = %i[account_wide public nonsense].map do |access_mode|
        Workspaces::Create.call(
          creator: users(:agent), name: "Unsupported", access_mode: access_mode
        )
      end
    end

    assert_equal %i[invalid_access_mode invalid_access_mode invalid_access_mode],
      results.map(&:outcome)
  end

  test "an identifier dedicates multiple Workspaces before and after steward reassignment" do
    identifier = users(:agent).agent_identifier
    results = []

    assert_difference -> { Workspace.where(agent_identifier: identifier).count }, 2 do
      results << Workspaces::Create.call(creator: users(:agent), name: "Another Home")
      assert_equal :changed, users(:agent).change_steward(to: users(:member))
      results << Workspaces::Create.call(creator: users(:agent), name: "Other Steward Home")
    end

    assert_equal %i[created created], results.map(&:outcome)
    assert_equal [users(:owner), users(:member)], results.map { |result| result.workspace.owner }
  end

  test "false metadata is invalid rather than defaulted" do
    result = nil
    assert_no_difference -> { Workspace.count } do
      result = Workspaces::Create.call(
        creator: users(:member), name: "False Metadata", metadata: false
      )
    end

    assert_equal :invalid, result.outcome
    assert result.errors.of_kind?(:metadata, :invalid)
  end

  test "exponent-form metadata is rejected before persistence" do
    result = nil
    assert_no_difference -> { Workspace.count } do
      result = Workspaces::Create.call(
        creator: users(:member), name: "Exponent Metadata",
        metadata: { "value" => 1e308 }
      )
    end

    assert_equal :invalid, result.outcome
    assert result.errors.of_kind?(:metadata, :unsupported_number)
  end

  test "an inactive creator or non-live steward is rejected" do
    agent = create_agent_member(steward: users(:member), agent_identifier: "w3-create-fence")
    assert_equal :suspended, users(:member).suspend

    suspended_creator = Workspaces::Create.call(creator: users(:member).reload, name: "After")
    assert_equal :not_workspace_owner, suspended_creator.outcome

    dead_steward = Workspaces::Create.call(creator: agent.reload, name: "Orphan")
    assert_equal :not_workspace_owner, dead_steward.outcome
  end

  test "the system user cannot create a Workspace" do
    result = Workspaces::Create.call(creator: users(:system), name: "Kernel")

    assert_equal :not_workspace_owner, result.outcome
  end

  test "model validation failures surface as invalid with errors" do
    result = Workspaces::Create.call(creator: users(:member), name: "")

    assert_equal :invalid, result.outcome
    assert result.errors[:name].any?
  end

  test "steward removal first makes a late Agent create lose its recheck" do
    agent = create_agent_member(steward: users(:member), agent_identifier: "w3-create-race")

    assert_equal :removed, users(:member).remove
    removal_first = Workspaces::Create.call(creator: agent.reload, name: "Late")
    assert_equal :not_workspace_owner, removal_first.outcome
  end

  test "create first makes the owner's later removal wait for transfer" do
    result = Workspaces::Create.call(creator: users(:member), name: "Held")
    assert_equal :created, result.outcome

    # The new Workspace is non-tombstoned ownership until transferred.
    assert_equal :workspace_ownership_transfer_required, users(:member).remove
  end

  test "human creation and removal preserve final ownership integrity" do
    creator = accounts(:cybros).create_direct_member(
      display_name: "Creation race Human",
      email: "creation-race-#{SecureRandom.hex(8)}@example.com",
      role: :member,
      password: "correct horse battery",
      password_confirmation: "correct horse battery"
    ).member
    creator_id = creator.id
    identity_id = creator.identity_id
    workspace_name = "Human creation removal race"
    held_creator = hold_row_lock(User, creator_id)
    removal = start_database_call { User.find(creator_id).remove }

    wait_until_waiting_on_lock(removal.pid)
    creation = start_database_call do
      Workspaces::Create.call(
        creator: User.find(creator_id), name: workspace_name
      )
    end
    wait_until_waiting_on_lock(removal.pid, creation.pid)

    release_row_lock(held_creator)
    held_creator = nil
    removal_result = finish_database_call(removal)
    removal = nil
    creation_result = finish_database_call(creation)
    creation = nil

    assert_includes(
      [
        [:created, :workspace_ownership_transfer_required],
        [:not_workspace_owner, :removed],
      ],
      [creation_result.outcome, removal_result]
    )

    ApplicationRecord.uncached do
      creator = User.find(creator_id)
      workspace = Workspace.find_by(creator_id: creator_id, name: workspace_name)
      assert_equal creation_result.outcome == :created, workspace.present?
      assert_not(
        creator.removed? && Workspace.non_tombstoned.where(owner: creator).exists?
      )
      if workspace
        assert creator.active?
        assert_equal creator, workspace.owner
      else
        assert creator.removed?
      end
    end
  ensure
    begin
      release_row_lock(held_creator) if held_creator
    ensure
      stop_database_call(removal) if removal
      stop_database_call(creation) if creation
      delete_race_workspaces_for(creator_id)
      User.where(id: creator_id).delete_all if creator_id
      Identity.where(id: identity_id).delete_all if identity_id
    end
  end

  test "agent creation and steward removal preserve final ownership integrity" do
    steward = accounts(:cybros).create_direct_member(
      display_name: "Creation race Steward",
      email: "steward-race-#{SecureRandom.hex(8)}@example.com",
      role: :member,
      password: "correct horse battery",
      password_confirmation: "correct horse battery"
    ).member
    steward_id = steward.id
    steward_identity_id = steward.identity_id
    agent = create_agent_member(
      steward: steward,
      agent_identifier: "w3-concurrent-steward-#{SecureRandom.hex(4)}"
    )
    agent_id = agent.id
    workspace_name = "Agent creation steward race"
    held_steward = hold_row_lock(User, steward_id)
    creation = start_database_call do
      Workspaces::Create.call(
        creator: User.find(agent_id), name: workspace_name
      )
    end

    wait_until_waiting_on_lock(creation.pid)
    removal = start_database_call { User.find(steward_id).remove }
    wait_until_waiting_on_lock(creation.pid, removal.pid)

    release_row_lock(held_steward)
    held_steward = nil
    creation_result = finish_database_call(creation)
    creation = nil
    removal_result = finish_database_call(removal)
    removal = nil

    assert_includes(
      [
        [:created, :workspace_ownership_transfer_required],
        [:not_workspace_owner, :removed],
      ],
      [creation_result.outcome, removal_result]
    )

    ApplicationRecord.uncached do
      steward = User.find(steward_id)
      workspace = Workspace.find_by(creator_id: agent_id, name: workspace_name)
      assert_equal creation_result.outcome == :created, workspace.present?
      assert_not(
        steward.removed? && Workspace.non_tombstoned.where(owner: steward).exists?
      )
      if workspace
        assert steward.active?
        assert_equal steward, workspace.owner
      else
        assert steward.removed?
      end
    end
  ensure
    begin
      release_row_lock(held_steward) if held_steward
    ensure
      stop_database_call(creation) if creation
      stop_database_call(removal) if removal
      delete_race_workspaces_for(agent_id, steward_id)
      User.where(id: agent_id).delete_all if agent_id
      User.where(id: steward_id).delete_all if steward_id
      Identity.where(id: steward_identity_id).delete_all if steward_identity_id
    end
  end

  private

    def delete_race_workspaces_for(*user_ids)
      user_ids.compact!
      return if user_ids.empty?

      workspace_ids = Workspace
        .where(creator_id: user_ids)
        .or(Workspace.where(owner_id: user_ids))
        .pluck(:id)
      StoreEntry.where(workspace_id: workspace_ids).delete_all
      Workspace.where(id: workspace_ids).delete_all
    end
end
