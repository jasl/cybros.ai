require "test_helper"

class Workspaces::LifecycleTest < ActiveSupport::TestCase
  setup do
    @workspace = workspaces(:personal)
    @curator = users(:curator)
  end

  test "archive accepts from active, commits archiving, and stamps the evidence clock" do
    result = Workspaces::Archive.call(
      workspace: @workspace, by: @curator, lock_version: @workspace.lock_version
    )

    assert_equal :accepted, result.outcome
    @workspace.reload
    assert_equal "archiving", @workspace.state
    assert_not_nil @workspace.archived_at
    assert_nil @workspace.deleted_at
  end

  test "restore accepts from archived, returns live access immediately, and clears the archive clock" do
    place_in(@workspace, "archived")

    result = Workspaces::Restore.call(
      workspace: @workspace, by: @curator, lock_version: @workspace.lock_version
    )

    assert_equal :accepted, result.outcome
    @workspace.reload
    assert_equal "restoring", @workspace.state
    assert_nil @workspace.archived_at
    assert @workspace.live?
    assert @workspace.data_writable_by?(@curator)
  end

  test "delete accepts from active and from archived and stamps the retention clock" do
    result = Workspaces::Delete.call(
      workspace: @workspace, by: @curator, lock_version: @workspace.lock_version
    )
    assert_equal :accepted, result.outcome
    assert_equal "deleting", @workspace.reload.state
    assert_not_nil @workspace.deleted_at

    archived = workspaces(:shared)
    place_in(archived, "archived")
    result = Workspaces::Delete.call(
      workspace: archived, by: users(:owner), lock_version: archived.lock_version
    )
    assert_equal :accepted, result.outcome
    assert_equal "deleting", archived.reload.state
    # The archive evidence survives as history; deletion owns the clock now.
    assert_not_nil archived.archived_at
  end

  test "every illegal edge of the strict serial graph is typed" do
    {
      "archiving" => { archive: :transition_in_progress, restore: :transition_in_progress, delete: :transition_in_progress },
      "restoring" => { archive: :transition_in_progress, restore: :transition_in_progress, delete: :transition_in_progress },
      "archived" => { archive: :state_already_current },
      "active" => { restore: :state_already_current },
      "deleting" => { archive: :not_found, restore: :not_found, delete: :not_found },
      "deleted" => { archive: :not_found, restore: :not_found, delete: :not_found },
    }.each do |state, commands|
      commands.each do |command, expected|
        place_in(@workspace, state)

        result = service_for(command).call(
          workspace: @workspace, by: @curator, lock_version: @workspace.reload.lock_version
        )

        assert_equal expected, result.outcome, "#{command} from #{state}"
        assert_equal state, @workspace.reload.state, "#{command} from #{state} must not move"
      end
    end
  end

  test "lifecycle acceptance is owner-only" do
    result = Workspaces::Archive.call(
      workspace: @workspace, by: users(:owner), lock_version: @workspace.lock_version
    )
    assert_equal :not_workspace_owner, result.outcome

    agent_result = Workspaces::Delete.call(
      workspace: workspaces(:dedicated), by: users(:agent),
      lock_version: workspaces(:dedicated).lock_version
    )
    assert_equal :not_workspace_owner, agent_result.outcome
  end

  test "a stale acceptance loses and cannot reverse newer state" do
    assert @workspace.update(name: "Bumped")

    stale = Workspaces::Archive.call(workspace: @workspace, by: @curator, lock_version: 0)
    assert_equal :stale_object, stale.outcome
    assert_equal "active", @workspace.reload.state
  end

  test "archiving blocks writes while staying browsable; deleting hides every surface" do
    Workspaces::Archive.call(
      workspace: @workspace, by: @curator, lock_version: @workspace.lock_version
    )
    @workspace.reload

    assert_not @workspace.data_writable_by?(@curator)
    assert @workspace.data_accessible_by?(@curator)
    assert_includes Workspace.browsable, @workspace
    assert_not_includes Workspace.live, @workspace

    place_in(@workspace, "active")
    Workspaces::Delete.call(
      workspace: @workspace, by: @curator, lock_version: @workspace.reload.lock_version
    )
    @workspace.reload

    assert_not @workspace.data_writable_by?(@curator)
    assert_not_includes Workspace.browsable, @workspace
    update_result = Workspaces::Update.call(
      workspace: @workspace, by: @curator, lock_version: @workspace.lock_version, name: "Ghost"
    )
    assert_equal :not_found, update_result.outcome
  end

  test "bounded completion advances exactly one transition from current state" do
    Workspaces::Archive.call(
      workspace: @workspace, by: @curator, lock_version: @workspace.lock_version
    )

    result = Workspaces::CompleteTransition.call(workspace: @workspace)
    assert_equal :completed, result.outcome
    assert_equal "archived", @workspace.reload.state

    # Level-triggered: a stale second wake rechecks current state and exits.
    again = Workspaces::CompleteTransition.call(workspace: @workspace)
    assert_equal :nothing_to_complete, again.outcome
    assert_equal "archived", @workspace.reload.state
  end

  test "completion closes the full serial cycle and the delete branch" do
    place_in(@workspace, "restoring")
    assert_equal :completed, Workspaces::CompleteTransition.call(workspace: @workspace).outcome
    assert_equal "active", @workspace.reload.state

    place_in(@workspace, "deleting")
    assert_equal :completed, Workspaces::CompleteTransition.call(workspace: @workspace).outcome
    assert_equal "deleted", @workspace.reload.state

    # deleted is terminal: nothing advances and acceptance finds no surface.
    assert_equal :nothing_to_complete, Workspaces::CompleteTransition.call(workspace: @workspace).outcome
  end

  test "acceptance after completion uses the current state, not history" do
    Workspaces::Archive.call(
      workspace: @workspace, by: @curator, lock_version: @workspace.lock_version
    )
    Workspaces::CompleteTransition.call(workspace: @workspace)
    @workspace.reload

    result = Workspaces::Restore.call(
      workspace: @workspace, by: @curator, lock_version: @workspace.lock_version
    )
    assert_equal :accepted, result.outcome
    assert_equal "restoring", @workspace.reload.state
  end

  test "a duplicate identifier never wedges the old tombstone's convergence" do
    dedicated = workspaces(:dedicated)

    accepted = Workspaces::Delete.call(
      workspace: dedicated, by: users(:owner), lock_version: dedicated.lock_version
    )
    assert_equal :accepted, accepted.outcome

    # The tag is non-unique: the Agent creates another dedicated Workspace
    # while the old tombstone drains.
    duplicate = Workspaces::Create.call(
      creator: users(:agent), name: "Another Home"
    )
    assert_equal :created, duplicate.outcome

    # The tombstone still converges independently of the other Workspace.
    result = Workspaces::CompleteTransition.call(workspace: dedicated)
    assert_equal :completed, result.outcome
    assert_equal "deleted", dedicated.reload.state
  end

  test "tombstoned workspaces return not_found from every management service" do
    place_in(@workspace, "deleting")

    [
      Workspaces::Update.call(
        workspace: @workspace, by: @curator, lock_version: @workspace.lock_version, name: "X"
      ),
      Workspaces::UpdateAccessMode.call(
        workspace: @workspace, by: @curator, to: :account_wide, lock_version: @workspace.lock_version
      ),
      Workspaces::TransferOwnership.call(
        workspace: @workspace, by: @curator, to: users(:owner), lock_version: @workspace.lock_version
      ),
    ].each do |result|
      assert_equal :not_found, result.outcome
    end
  end

  private

    def place_in(workspace, state)
      columns = { state: state }
      columns[:archived_at] = Time.current if %w[archiving archived].include?(state)
      columns[:deleted_at] = Time.current if %w[deleting deleted].include?(state)
      workspace.update_columns(columns)
    end

    def service_for(command)
      { archive: Workspaces::Archive, restore: Workspaces::Restore, delete: Workspaces::Delete }
        .fetch(command)
    end
end
