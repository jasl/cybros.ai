require "test_helper"

# THE STORE, and above all the property the whole design turns on: a fork
# ISOLATES. Read-through the ancestry closure was the first proposal and
# was refuted on exactly this — the closure works for turns because an
# inherited turn cannot change, and a memory document is mutable in place.
class MemoryDocuments::StoreTest < ActiveSupport::TestCase
  setup do
    @human = users(:member)
    @workspace = workspaces(:shared)
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human)
  end

  def anchor(path, conversation: @conversation)
    Scopes::Anchor.call(
      path: path, workspace: @workspace, conversation: conversation
    )
  end

  # The doors' shape: the anchor row is held by the caller, first.
  def write!(path, content, conversation: @conversation)
    resolved = anchor(path, conversation:)
    MemoryDocument.transaction do
      resolved.lockable.lock!
      MemoryDocuments::Write.call(anchor: resolved, expected: memory_expectation_at(resolved), content: content)
    end
  end

  def read(path, conversation: @conversation)
    anchor(path, conversation:).documents.find_by(name: anchor(path, conversation:).name)
  end

  test "a path names its own scope, and a bare name names none" do
    assert_equal "workspace", anchor("workspace/notes.md").scope
    assert_equal "notes.md", anchor("workspace/notes.md").name
    assert_equal "conversation", anchor("conversation/plan.md").scope
    # A default here would decide where a model's notes live by accident,
    # and the two scopes differ in who can read them.
    assert_equal :memory_path_invalid, anchor("notes.md").refusal
    assert_equal :memory_path_invalid, anchor("elsewhere/notes.md").refusal
  end

  # A loop has no conversation — every tool column is on agent_run_tasks
  # — so this refusal is DATA the model reads and retries against, never a
  # node failure.
  test "conversation scope is unavailable where there is no conversation" do
    refused = Scopes::Anchor.call(
      path: "conversation/plan.md", workspace: @workspace, conversation: nil
    )
    assert_equal :memory_scope_unavailable, refused.refusal

    resolved = Scopes::Anchor.call(
      path: "workspace/notes.md", workspace: @workspace, conversation: nil
    )
    assert_predicate resolved, :resolved?
  end

  test "a write is a whole-document replace, and the old version is reclaimed" do
    first = write!("workspace/notes.md", "one")
    assert_predicate first, :written?
    old_version = first.document.memory_document_version_id

    second = write!("workspace/notes.md", "two")
    assert_equal first.document.id, second.document.id, "one document, repointed"
    assert_equal "two", second.document.reload.content
    assert_nil MemoryDocumentVersion.find_by(id: old_version),
      "nothing references the superseded version, so it goes"
  end

  # THE PROPERTY THE DESIGN EXISTS FOR. Read-through would have handed the
  # child whatever the parent says NOW.
  test "a fork copies pointers, and the two are isolated from that instant" do
    write!("conversation/plan.md", "the original plan")
    versions_before = MemoryDocumentVersion.count

    child = fork!
    assert_equal "the original plan", read("conversation/plan.md", conversation: child).content
    assert_equal versions_before, MemoryDocumentVersion.count,
      "a fork copies POINTERS — zero content bytes"

    write!("conversation/plan.md", "the parent changed its mind")
    assert_equal "the original plan",
      read("conversation/plan.md", conversation: child).content,
      "a parent's later edit must never reach a child"

    MemoryDocuments::Delete.call(anchor: anchor("conversation/plan.md"), expected: memory_expectation_at(anchor("conversation/plan.md")))
    assert_not_nil read("conversation/plan.md", conversation: child),
      "nor must a parent's delete take the child's copy"
  end

  test "a delete is a delete — there is no tombstone in either scope" do
    write!("workspace/notes.md", "here")
    version_id = read("workspace/notes.md").memory_document_version_id
    observed = memory_expectation(read("workspace/notes.md"))

    assert_predicate MemoryDocuments::Delete.call(anchor: anchor("workspace/notes.md"), expected: observed),
      :deleted?
    assert_nil read("workspace/notes.md")
    assert_nil MemoryDocumentVersion.find_by(id: version_id)

    assert_equal :stale_object,
      MemoryDocuments::Delete.call(anchor: anchor("workspace/notes.md"), expected: observed).outcome
  end

  # A version shared with a fork survives its author's delete: RESTRICT is
  # the arbiter, and the reclaim losing that race is the correct outcome.
  test "a shared version outlives the delete of one pointer to it" do
    write!("conversation/plan.md", "shared")
    child = fork!
    version_id = read("conversation/plan.md", conversation: child).memory_document_version_id

    MemoryDocuments::Delete.call(anchor: anchor("conversation/plan.md"), expected: memory_expectation_at(anchor("conversation/plan.md")))

    assert_not_nil MemoryDocumentVersion.find_by(id: version_id)
    assert_equal "shared", read("conversation/plan.md", conversation: child).content
  end

  test "the cap is per anchor, and a replace never spends a slot" do
    MemoryDocument::MAX_DOCUMENTS_PER_ANCHOR.times do |n|
      assert_predicate write!("workspace/n#{n}.md", "x"), :written?
    end
    assert_equal :memory_full, write!("workspace/one-too-many.md", "x").outcome
    assert_predicate write!("workspace/n0.md", "replaced"), :written?,
      "an existing document is repointed, not admitted"
  end

  test "an oversized document refuses with a code a caller can act on" do
    bound = Nexus::SizeBounds::BOUNDS.fetch(:memory_document_bound).fetch(:value)
    assert_equal :memory_document_too_large,
      write!("workspace/big.md", "x" * (bound + 1)).outcome
    assert_predicate write!("workspace/big.md", "x" * bound), :written?
  end

  test "the listing reports the CONTENT's age, not the pointer's" do
    write!("conversation/plan.md", "written before the fork")
    authored = read("conversation/plan.md").memory_document_version.created_at
    travel 1.hour
    child = fork!

    entry = MemoryDocuments::Listing.call(
      documents: MemoryDocument.for_conversation(child.id)
    ).sole
    assert_equal "conversation/plan.md", entry.path
    assert_in_delta authored, entry.written_at, 1.second,
      "a fork must not tell a model every inherited note was written just now"
  end

  test "grep is unranked, ordered, bounded, and refuses a pattern it cannot afford" do
    write!("workspace/a.md", "alpha\nbeta\ngamma")
    write!("workspace/b.md", "beta again")

    found = MemoryDocuments::Search.call(
      documents: MemoryDocument.for_workspace(@workspace.id), pattern: "beta"
    )
    assert_predicate found, :found?
    assert_equal [["workspace/a.md", 2], ["workspace/b.md", 1]],
      found.matches.map { |m| [m.path, m.line_number] },
      "path then line — the only order an unranked store can honestly promise"

    assert_equal :memory_pattern_invalid,
      MemoryDocuments::Search.call(
        documents: MemoryDocument.for_workspace(@workspace.id), pattern: "["
      ).refusal
  end

  test "the reclaim sweep collects what a cascade left standing" do
    write!("conversation/plan.md", "orphan me")
    version_id = read("conversation/plan.md").memory_document_version_id
    # The cascade a conversation teardown performs: pointers go, versions
    # stay, and no writer runs to reclaim them.
    MemoryDocument.where(conversation_id: @conversation.id).delete_all

    assert_not_nil MemoryDocumentVersion.find_by(id: version_id)
    result = MemoryDocuments::ReclaimVersions.call
    assert_operator result[:reclaimed], :>=, 1
    assert_nil MemoryDocumentVersion.find_by(id: version_id)
  end

  test "forked pointers get new public identities and reject their parent's condition" do
    parent = write!("conversation/plan.md", "shared body").document
    child = fork!
    inherited = read("conversation/plan.md", conversation: child)
    assert_not_equal parent.public_id, inherited.public_id
    assert_equal parent.memory_document_version_id, inherited.memory_document_version_id
    assert_equal 0, inherited.lock_version
    assert_raises(ActiveRecord::ReadonlyAttributeError) { parent.public_id = SecureRandom.uuid_v7 }

    resolved = anchor("conversation/plan.md", conversation: child)
    assert_no_changes -> { [MemoryDocumentVersion.count, child.reload.context_revision] } do
      child.with_lock do
        result = MemoryDocuments::Write.call(anchor: resolved, content: "wrong row",
          expected: memory_expectation(parent), revises: child)
        assert_equal :stale_object, result.outcome
        result = MemoryDocuments::Delete.call(anchor: resolved,
          expected: memory_expectation(parent), revises: child)
        assert_equal :stale_object, result.outcome
      end
    end
    assert_equal "shared body", inherited.reload.content
    assert_equal "shared body", parent.reload.content
  end

  private

    def fork!
      result = Conversations::Fork.call(Conversations::Fork::Command.new(
        conversation: @conversation, turn_public_id: seed_turn.public_id,
        variant_public_id: nil, acting_user: @human, title: nil
      ))
      assert_predicate result, :accepted?
      result.value
    end

    # A fork needs a completed turn to branch at.
    def seed_turn
      @seed_turn ||= begin
        turn = ConversationTurn.create!(
          account: @workspace.account, conversation: @conversation, position: 0,
          kind: "message", role: "user", status: "completed",
          speaker: Speakers::Resolve.member(account: @workspace.account, user: @human),
          control_owner_user: @human, visibility: "visible"
        )
        variant = ConversationTurnVariant.create!(
          account: @workspace.account, conversation_turn: turn, position: 0,
          status: "completed", source: "manual"
        )
        turn.update!(active_variant: variant)
        @conversation.update!(timeline_position_head: 1)
        turn
      end
    end
end
