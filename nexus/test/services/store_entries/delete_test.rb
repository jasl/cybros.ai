require "test_helper"

class StoreEntries::DeleteTest < ActiveSupport::TestCase
  include AgentMembershipTestHelper

  setup do
    @entry = workspaces(:shared).store_entries.create!(
      namespace: "notes", key: "pinned", value: { "v" => 1 }
    )
  end

  test "delete is real" do
    result = StoreEntries::Delete.call(
      entry: @entry, by: users(:member), lock_version: @entry.lock_version
    )

    assert_equal :deleted, result.outcome
    assert_nil StoreEntry.find_by(id: @entry.id)
  end

  test "a stale delete loses without removing the row" do
    assert @entry.update(value: { "v" => 2 })

    result = StoreEntries::Delete.call(
      entry: @entry, by: users(:member), lock_version: 0
    )

    assert_equal :stale_object, result.outcome
    assert StoreEntry.exists?(@entry.id)
  end

  test "authority composes access, liveness, and the fence" do
    hidden = StoreEntries::Delete.call(
      entry: workspaces(:personal).store_entries.create!(namespace: "n", key: "k"),
      by: users(:member), lock_version: 0
    )
    assert_equal :not_found, hidden.outcome

    workspaces(:shared).update_columns(state: "archiving", archived_at: Time.current)
    archived = StoreEntries::Delete.call(
      entry: @entry, by: users(:member), lock_version: @entry.lock_version
    )
    assert_equal :workspace_not_active, archived.outcome

    dedicated_entry = workspaces(:dedicated).store_entries.create!(namespace: "n", key: "k")
    mismatched = create_agent_member(steward: users(:owner), agent_identifier: "w5-del-other")
    fenced = StoreEntries::Delete.call(
      entry: dedicated_entry, by: mismatched,
      lock_version: dedicated_entry.lock_version
    )
    assert_equal :workspace_agent_identifier_mismatch, fenced.outcome
    assert StoreEntry.exists?(dedicated_entry.id)

    # The shared workspace was archived above; the conversation host's own
    # refusal needs a live workspace, and a Human owner is never fenced.
    conversation = Conversation.create!(workspace: workspaces(:dedicated), creating_user: users(:owner))
    conversation_entry = conversation.store_entries.create!(namespace: "n", key: "k")
    conversation.update_columns(archived_at: Time.current)
    archived_conversation = StoreEntries::Delete.call(
      entry: conversation_entry, by: users(:owner), lock_version: conversation_entry.lock_version
    )
    assert_equal :conversation_archived, archived_conversation.outcome
    assert StoreEntry.exists?(conversation_entry.id)

    own = users(:owner).store_entries.create!(namespace: "n", key: "k")
    foreign = StoreEntries::Delete.call(entry: own, by: users(:member), lock_version: own.lock_version)
    assert_equal :not_found, foreign.outcome
    assert StoreEntry.exists?(own.id)
  end
end
