require "test_helper"

class StoreEntries::UpdateTest < ActiveSupport::TestCase
  include AgentMembershipTestHelper

  setup do
    @entry = workspaces(:shared).store_entries.create!(
      namespace: "notes", key: "pinned", value: { "v" => 1 }
    )
  end

  test "replaces the current value optimistically" do
    result = StoreEntries::Update.call(
      entry: @entry, by: users(:member), lock_version: @entry.lock_version,
      value: { "v" => 2 }
    )

    assert_equal :updated, result.outcome
    assert_equal({ "v" => 2 }, @entry.reload.value)
  end

  test "a stale writer loses without replacing the value" do
    assert @entry.update(value: { "v" => 2 })

    result = StoreEntries::Update.call(
      entry: @entry, by: users(:member), lock_version: 0, value: { "v" => 3 }
    )

    assert_equal :stale_object, result.outcome
    assert_equal({ "v" => 2 }, @entry.reload.value)
  end

  test "authority composes access, liveness, and the fence" do
    no_access = StoreEntries::Update.call(
      entry: workspaces(:personal).store_entries.create!(namespace: "n", key: "k"),
      by: users(:member), lock_version: 0, value: 1
    )
    assert_equal :not_found, no_access.outcome

    workspaces(:shared).update_columns(state: "archived", archived_at: Time.current)
    archived = StoreEntries::Update.call(
      entry: @entry, by: users(:member), lock_version: @entry.lock_version, value: 1
    )
    assert_equal :workspace_not_active, archived.outcome

    dedicated_entry = workspaces(:dedicated).store_entries.create!(namespace: "n", key: "k")
    mismatched = create_agent_member(steward: users(:owner), agent_identifier: "w5-upd-other")
    fenced = StoreEntries::Update.call(
      entry: dedicated_entry, by: mismatched,
      lock_version: dedicated_entry.lock_version, value: 1
    )
    assert_equal :workspace_agent_identifier_mismatch, fenced.outcome

    # The shared workspace was archived above; the conversation host's own
    # refusal needs a live workspace, and a Human owner is never fenced.
    conversation = Conversation.create!(workspace: workspaces(:dedicated), creating_user: users(:owner))
    conversation_entry = conversation.store_entries.create!(namespace: "n", key: "k")
    conversation.update_columns(archived_at: Time.current)
    archived_conversation = StoreEntries::Update.call(
      entry: conversation_entry, by: users(:owner),
      lock_version: conversation_entry.lock_version, value: 1
    )
    assert_equal :conversation_archived, archived_conversation.outcome

    own = users(:owner).store_entries.create!(namespace: "n", key: "k", value: 0)
    foreign = StoreEntries::Update.call(
      entry: own, by: users(:member), lock_version: own.lock_version, value: 1
    )
    assert_equal :not_found, foreign.outcome
    assert_equal 0, own.reload.value
  end

  test "an oversize replacement is rejected with the typed bound" do
    result = StoreEntries::Update.call(
      entry: @entry, by: users(:member), lock_version: @entry.lock_version,
      value: { "k" => "a" * Nexus::SizeBounds.fetch(:snapshot_bound) }
    )

    assert_equal :invalid, result.outcome
    assert result.errors.of_kind?(:value, :content_too_large)
    assert_equal({ "v" => 1 }, @entry.reload.value)
  end
end
