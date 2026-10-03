require "test_helper"

# THE TREE-SYNC WARNING (borrowed from Claude Code's teleport checkout check): a handoff replays nothing and moves no tree, so `rho
# handoff` compares the OLD binding's and the NEW target's announced
# environment — root, branch, worktree — and says, in ONE line, exactly
# which differ. Never a refusal; nothing when they match, and nothing a
# side cannot say (an unknown runner, a field it never announced).
class HandoffTreeSyncTest < Minitest::Test
  TreeSync = Rho::Extensions::Handoff::TreeSync

  # The discovery document as the SDK projects it: `environment` is the
  # announced snapshot, string-keyed, absent fields unannounced.
  def document(public_id, **environment)
    hash = NexusDoubles.remote_runner(public_id, **environment)
    CybrosAgent::Api::DiscoveredExecutor.new(
      public_id: hash.fetch("public_id"), kind: "runner", display_name: hash["display_name"], status: "active",
      presence: hash.fetch("presence"), assignment_scope: "user_private", environment: hash.fetch("environment")
    )
  end

  def warning(old, new) = TreeSync.warning(old: old, new: new)

  def test_matching_environments_warn_nothing
    old = document("0199-a", root: "/srv/tree", branch: "main")
    new = document("0199-b", root: "/srv/tree", branch: "main")

    assert_nil warning(old, new)
    assert_nil warning(old, old), "the same runner twice: an idempotent handoff"
  end

  def test_every_differing_field_is_named_and_nothing_else
    old = document("0199-a", root: "/a", branch: "feature", worktree: true)
    new = document("0199-b", root: "/b", branch: "main", worktree: false)

    assert_equal "old runner 0199-a on branch feature at /a in a linked worktree, " \
                 "new runner 0199-b on branch main at /b in the main worktree — the tree is not synced",
      warning(old, new)

    same_root = document("0199-b", root: "/a", branch: "main", worktree: true)
    assert_equal "old runner 0199-a on branch feature, new runner 0199-b on branch main — the tree is not synced",
      warning(old, same_root), "only the branch differs, so only the branch is said"
  end

  def test_an_unknown_side_or_an_unannounced_field_is_not_compared
    old = document("0199-a", root: "/a", branch: "feature")
    new = document("0199-b", root: "/b")

    assert_nil warning(nil, new), "the old binding discovery cannot show"
    assert_nil warning(old, nil), "no target document"
    assert_equal "old runner 0199-a at /a, new runner 0199-b at /b — the tree is not synced", warning(old, new),
      "the branch one side never announced is unknown, not different"
    assert_nil warning(document("0199-a", root: nil), document("0199-b", root: nil)), "nothing announced on either side"
  end
end
