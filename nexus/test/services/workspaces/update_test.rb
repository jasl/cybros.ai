require "test_helper"

class Workspaces::UpdateTest < ActiveSupport::TestCase
  setup do
    @workspace = workspaces(:personal)
  end

  test "the active Human owner renames and edits metadata optimistically" do
    result = Workspaces::Update.call(
      workspace: @workspace, by: users(:curator), lock_version: @workspace.lock_version,
      name: "Renamed", metadata: { "labels" => %w[a] }
    )

    assert_equal :updated, result.outcome
    @workspace.reload
    assert_equal "Renamed", @workspace.name
    assert_equal({ "labels" => %w[a] }, @workspace.metadata)
  end

  test "an omitted field stays unchanged while an explicit nil is judged" do
    omitted = Workspaces::Update.call(
      workspace: @workspace, by: users(:curator), lock_version: @workspace.lock_version,
      metadata: { "kept" => true }
    )
    assert_equal :updated, omitted.outcome
    assert_equal "Curator Private", @workspace.reload.name

    explicit_nil = Workspaces::Update.call(
      workspace: @workspace, by: users(:curator), lock_version: @workspace.lock_version,
      name: nil
    )
    assert_equal :invalid, explicit_nil.outcome
    assert explicit_nil.errors[:name].any?
    assert_equal "Curator Private", @workspace.reload.name
  end

  test "only the owner manages, without any admin bypass" do
    result = Workspaces::Update.call(
      workspace: @workspace, by: users(:owner), lock_version: @workspace.lock_version,
      name: "Taken Over"
    )

    assert_equal :not_workspace_owner, result.outcome
    assert_equal "Curator Private", @workspace.reload.name
  end

  test "an Agent never manages, even when its steward owns the Workspace" do
    dedicated = workspaces(:dedicated)

    result = Workspaces::Update.call(
      workspace: dedicated, by: users(:agent), lock_version: dedicated.lock_version,
      name: "Self Managed"
    )

    assert_equal :not_workspace_owner, result.outcome
  end

  test "management requires the active state" do
    %w[archiving archived restoring].each do |state|
      @workspace.update_columns(state: state)

      result = Workspaces::Update.call(
        workspace: @workspace, by: users(:curator), lock_version: @workspace.reload.lock_version,
        name: "While #{state}"
      )

      assert_equal :workspace_not_active, result.outcome, state
    end
  end

  test "a stale lock version loses without writing" do
    assert @workspace.update(name: "Current")

    result = Workspaces::Update.call(
      workspace: @workspace, by: users(:curator), lock_version: 0, name: "Stale"
    )

    assert_equal :stale_object, result.outcome
    assert_equal "Current", @workspace.reload.name
  end

  test "validation failures surface as invalid" do
    result = Workspaces::Update.call(
      workspace: @workspace, by: users(:curator), lock_version: @workspace.lock_version,
      name: "a" * (Workspace::NAME_MAX_LENGTH + 1)
    )

    assert_equal :invalid, result.outcome
    assert result.errors[:name].any?
  end

  test "false metadata is invalid rather than omitted" do
    original_metadata = @workspace.metadata

    result = Workspaces::Update.call(
      workspace: @workspace, by: users(:curator), lock_version: @workspace.lock_version,
      metadata: false
    )

    assert_equal :invalid, result.outcome
    assert result.errors.of_kind?(:metadata, :invalid)
    assert_equal original_metadata, @workspace.reload.metadata
  end
end
