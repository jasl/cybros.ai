require "test_helper"

class Workspaces::SweepTransitionsTest < ActiveSupport::TestCase
  test "the transition-state partial index follows the global id cursor" do
    index = Workspace.connection.indexes(:workspaces).find do |candidate|
      candidate.name == "index_workspaces_on_transition_sweep"
    end

    assert index
    assert_equal ["id"], index.columns
    assert index.where
    Workspaces::SweepTransitions::TRANSITION_STATES.each do |state|
      assert_includes index.where, state
    end
  end

  test "the crash gap converges: an acceptance without inline completion is swept" do
    workspace = workspaces(:personal)
    accepted = Workspaces::Archive.call(
      workspace: workspace, by: users(:curator), lock_version: workspace.lock_version
    )
    assert_equal :accepted, accepted.outcome
    assert_equal "archiving", workspace.reload.state

    result = Workspaces::SweepTransitions.call(budget: 10)

    assert_equal 1, result[:processed]
    assert_not result.more?
    assert_equal "archived", workspace.reload.state
  end

  test "the budget bounds a pass and the cursor advances without revisiting" do
    ids = [workspaces(:personal), workspaces(:shared), workspaces(:dedicated)].map do |workspace|
      workspace.update_columns(state: "deleting", deleted_at: Time.current)
      workspace.id
    end.sort

    first = Workspaces::SweepTransitions.call(budget: 2)
    assert_equal 2, first[:processed]
    assert first.more?
    assert_equal ids[1], first.cursor

    second = Workspaces::SweepTransitions.call(budget: 2, after_id: first.cursor)
    assert_equal 1, second[:processed]
    assert_not second.more?
    assert_equal "deleted", Workspace.find(ids.last).state
  end

  test "a quiet sweep processes nothing and reports no more" do
    result = Workspaces::SweepTransitions.call(budget: 10)

    assert_equal 0, result[:processed]
    assert_not result.more?
  end
end
