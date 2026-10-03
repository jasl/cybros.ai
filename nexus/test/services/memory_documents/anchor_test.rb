require "test_helper"

# ONE ANCHOR FOR THE THREE SCOPES: the path's first segment is the scope, the resolver answers which
# row to lock and which rows to list, and WHOSE User the `user/` rung means is the CALLER's to pass
# — memory passes the controlling Human, the store will pass the acting User. The resolver itself
# reads no principal off a path, because a path names none.
class MemoryDocuments::AnchorTest < ActiveSupport::TestCase
  setup do
    @workspace = workspaces(:shared)
    @human = users(:owner)
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human)
  end

  def anchor(path, workspace: @workspace, conversation: @conversation, user: @human)
    Scopes::Anchor.call(path: path, workspace: workspace, conversation: conversation, user: user)
  end

  test "user/ resolves to the person: the users row is the lockable, for_user the documents" do
    resolved = anchor("user/notes.md")
    assert_predicate resolved, :resolved?
    assert_equal "user", resolved.scope
    assert_equal "notes.md", resolved.name
    assert_equal @human, resolved.lockable
    assert_equal({ user: @human }, resolved.attributes)
    assert_equal MemoryDocument.for_user(@human.id).to_sql, resolved.documents.to_sql
  end

  test "each scope locks its own row, in ladder order the callers honour" do
    assert_equal @conversation, anchor("conversation/plan.md").lockable
    assert_equal @workspace, anchor("workspace/notes.md").lockable
    assert_equal({ conversation: @conversation }, anchor("conversation/plan.md").attributes)
    assert_equal({ workspace: @workspace }, anchor("workspace/notes.md").attributes)
  end

  test "a scope whose row is absent is unavailable, as data the caller reads" do
    assert_equal :memory_scope_unavailable, anchor("conversation/plan.md", conversation: nil).refusal
    assert_equal :memory_scope_unavailable, anchor("workspace/notes.md", workspace: nil).refusal
    assert_equal :memory_scope_unavailable, anchor("user/notes.md", user: nil).refusal
    assert_predicate anchor("user/notes.md", workspace: nil, conversation: nil), :resolved?,
      "the profile door passes a user and nothing else"
  end

  # The system user has no steward (user.rb), so the nil it answers for
  # `controlling_human` is what reaches `user:` — a refusal, never a nil deref.
  test "the system user's controlling Human is nil, and user/ refuses on it" do
    assert_nil users(:system).controlling_human
    assert_equal :memory_scope_unavailable,
      anchor("user/notes.md", user: users(:system).controlling_human).refusal
  end

  # A path names no Human. An agent stewarded by someone else passes ITS
  # steward and resolves ITS steward's scope — the other person's rows are
  # simply not there. Invisibility is a different row set, not a refusal.
  test "another steward's agent resolves its OWN steward's scope" do
    other = users(:member)
    foreign_agent = other.account.users.create!(
      kind: :agent, role: :member, display_name: "Other's Agent",
      steward: other, agent_identifier: "other-agent"
    )
    resolved = anchor("user/notes.md", user: foreign_agent.controlling_human)
    assert_predicate resolved, :resolved?
    assert_equal other, resolved.lockable
    assert_not_equal @human, resolved.lockable
  end

  test "a bare name and an unknown scope are invalid paths" do
    assert_equal :memory_path_invalid, anchor("notes.md").refusal
    assert_equal :memory_path_invalid, anchor("elsewhere/notes.md").refusal
    assert_equal :memory_path_invalid, anchor("user/").refusal
    assert_equal [nil, nil], Scopes::Anchor.split("notes.md")
    assert_equal %w[user notes.md], Scopes::Anchor.split("user/notes.md")
  end
end
