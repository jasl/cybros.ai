require "test_helper"
require_relative "../../test_helpers/row_lock_test_helper"

class StoreEntries::CreateTest < ActiveSupport::TestCase
  include AgentMembershipTestHelper
  include RowLockTestHelper

  uses_transaction :test_archive_acceptance_and_entry_creation_preserve_final_integrity,
    :test_concurrent_writes_at_63_entries_admit_exactly_one_final_slot

  test "any principal with effective data access writes into a live workspace" do
    result = StoreEntries::Create.call(
      host: workspaces(:shared), by: users(:member),
      namespace: "notes", key: "pinned", value: { "ids" => [1] }
    )

    assert_equal :created, result.outcome
    entry = result.entry
    assert_equal({ "ids" => [1] }, entry.value)
    assert_equal accounts(:cybros), entry.account

    agent_result = StoreEntries::Create.call(
      host: workspaces(:dedicated), by: users(:agent),
      namespace: "memory", key: "scratch", value: nil
    )
    assert_equal :created, agent_result.outcome
  end

  test "no effective access conceals the workspace entirely" do
    result = StoreEntries::Create.call(
      host: workspaces(:personal), by: users(:member),
      namespace: "notes", key: "pinned", value: 1
    )

    assert_equal :not_found, result.outcome
  end

  test "a mismatched Agent write is fenced with the typed outcome" do
    mismatched = create_agent_member(steward: users(:owner), agent_identifier: "w5-other")

    result = StoreEntries::Create.call(
      host: workspaces(:dedicated), by: mismatched,
      namespace: "notes", key: "pinned", value: 1
    )

    assert_equal :workspace_agent_identifier_mismatch, result.outcome
  end

  test "create rechecks a stale Human writer after suspension" do
    stale_writer = User.find(users(:member).id)
    assert_equal :suspended, users(:member).reload.suspend

    assert_no_difference -> { StoreEntry.count } do
      result = StoreEntries::Create.call(
        host: workspaces(:shared), by: stale_writer,
        namespace: "notes", key: "after-suspension", value: 1
      )

      assert_equal :not_found, result.outcome
    end
  end

  test "create rechecks an Agent's stale steward after suspension" do
    steward = users(:member)
    agent = create_agent_member(
      steward: steward, agent_identifier: "w5-stale-steward"
    )
    assert agent.steward_live?
    assert_equal :suspended, User.find(steward.id).suspend

    assert_no_difference -> { StoreEntry.count } do
      result = StoreEntries::Create.call(
        host: workspaces(:shared), by: agent,
        namespace: "notes", key: "after-steward-suspension", value: 1
      )

      assert_equal :not_found, result.outcome
    end
  end

  test "writes require a live workspace" do
    workspaces(:shared).update_columns(state: "archiving", archived_at: Time.current)

    result = StoreEntries::Create.call(
      host: workspaces(:shared), by: users(:member),
      namespace: "notes", key: "pinned", value: 1
    )
    assert_equal :workspace_not_active, result.outcome

    workspaces(:shared).update_columns(state: "deleting", deleted_at: Time.current)
    tombstoned = StoreEntries::Create.call(
      host: workspaces(:shared), by: users(:member),
      namespace: "notes", key: "pinned", value: 1
    )
    assert_equal :not_found, tombstoned.outcome
  end

  test "archive acceptance and entry creation preserve final integrity" do
    workspace = Workspaces::Create.call(
      creator: users(:owner), name: "Archive and entry race",
      access_mode: :account_wide
    ).workspace
    workspace_id = workspace.id
    owner_id = users(:owner).id
    writer_id = users(:member).id
    lock_version = workspace.lock_version
    held_workspace = hold_row_lock(Workspace, workspace_id)
    entry_creation = start_database_call do
      StoreEntries::Create.call(
        host: Workspace.find(workspace_id), by: User.find(writer_id),
        namespace: "race", key: "archive", value: 1
      )
    end

    wait_until_waiting_on_lock(entry_creation.pid)
    archive = start_database_call do
      Workspaces::Archive.call(
        workspace: Workspace.find(workspace_id), by: User.find(owner_id),
        lock_version: lock_version
      )
    end
    wait_until_waiting_on_lock(entry_creation.pid, archive.pid)

    release_row_lock(held_workspace)
    held_workspace = nil
    entry_result = finish_database_call(entry_creation)
    entry_creation = nil
    archive_result = finish_database_call(archive)
    archive = nil

    assert_equal :accepted, archive_result.outcome
    assert_includes %i[created not_operable], entry_result.outcome

    ApplicationRecord.uncached do
      workspace = Workspace.find(workspace_id)
      entry = workspace.store_entries.find_by(namespace: "race", key: "archive")
      assert workspace.archiving?
      assert_equal entry_result.outcome == :created, entry.present?
    end
  ensure
    begin
      release_row_lock(held_workspace) if held_workspace
    ensure
      stop_database_call(entry_creation) if entry_creation
      stop_database_call(archive) if archive
      if workspace_id
        StoreEntry.where(workspace_id: workspace_id).delete_all
        Workspace.where(id: workspace_id).delete_all
      end
    end
  end

  test "a duplicate key loses with the typed outcome" do
    first = StoreEntries::Create.call(
      host: workspaces(:shared), by: users(:member),
      namespace: "notes", key: "pinned", value: 1
    )
    assert_equal :created, first.outcome

    duplicate = StoreEntries::Create.call(
      host: workspaces(:shared), by: users(:member),
      namespace: "notes", key: "pinned", value: 2
    )
    assert_equal :key_taken, duplicate.outcome
    # The loser neither upserts nor duplicates: one row, first value intact.
    entries = workspaces(:shared).store_entries.where(namespace: "notes", key: "pinned")
    assert_equal 1, entries.count
    assert_equal 1, entries.sole.value
  end

  test "the 64-entry cap admits the 64th write and refuses the 65th" do
    workspace = workspaces(:shared)
    63.times do |n|
      workspace.store_entries.create!(namespace: "bulk", key: "k#{n}")
    end

    at_cap = StoreEntries::Create.call(
      host: workspace, by: users(:member), namespace: "bulk", key: "k63", value: nil
    )
    assert_equal :created, at_cap.outcome
    assert_equal StoreEntry::MAX_ENTRIES_PER_HOST, workspace.store_entries.count

    over_cap = StoreEntries::Create.call(
      host: workspace, by: users(:member), namespace: "bulk", key: "k64", value: nil
    )
    assert_equal :entry_limit_reached, over_cap.outcome
    assert_equal StoreEntry::MAX_ENTRIES_PER_HOST, workspace.store_entries.count
  end

  test "concurrent writes at 63 entries admit exactly one final slot" do
    workspace = Workspaces::Create.call(
      creator: users(:owner), name: "Store entry cap race",
      access_mode: :account_wide
    ).workspace
    63.times do |n|
      workspace.store_entries.create!(namespace: "concurrent", key: "k#{n}")
    end

    workspace_id = workspace.id
    writer_id = users(:member).id
    held_workspace = hold_row_lock(Workspace, workspace_id)
    first = start_database_call do
      StoreEntries::Create.call(
        host: Workspace.find(workspace_id), by: User.find(writer_id),
        namespace: "concurrent", key: "k63", value: nil
      )
    end
    second = start_database_call do
      StoreEntries::Create.call(
        host: Workspace.find(workspace_id), by: User.find(writer_id),
        namespace: "concurrent", key: "k64", value: nil
      )
    end

    wait_until_waiting_on_lock(first.pid, second.pid)
    release_row_lock(held_workspace)
    held_workspace = nil
    results = [finish_database_call(first), finish_database_call(second)]
    first = second = nil

    assert_equal(
      { created: 1, entry_limit_reached: 1 },
      results.map(&:outcome).tally
    )
    ApplicationRecord.uncached do
      entries = Workspace.find(workspace_id).store_entries
      assert_equal StoreEntry::MAX_ENTRIES_PER_HOST, entries.count
      assert_equal 1, entries.where(namespace: "concurrent", key: %w[k63 k64]).count
    end
  ensure
    begin
      release_row_lock(held_workspace) if held_workspace
    ensure
      stop_database_call(first) if first
      stop_database_call(second) if second
      if workspace_id
        StoreEntry.where(workspace_id: workspace_id).delete_all
        Workspace.where(id: workspace_id).delete_all
      end
    end
  end

  test "validation failures surface as invalid" do
    result = StoreEntries::Create.call(
      host: workspaces(:shared), by: users(:member),
      namespace: "UPPER", key: "pinned", value: 1
    )

    assert_equal :invalid, result.outcome
    assert result.errors[:namespace].any?
  end

  test "exponent-form values are rejected before persistence" do
    result = nil
    assert_no_difference -> { StoreEntry.count } do
      result = StoreEntries::Create.call(
        host: workspaces(:shared), by: users(:member),
        namespace: "notes", key: "exponent", value: { "value" => 1e308 }
      )
    end

    assert_equal :invalid, result.outcome
    assert result.errors.of_kind?(:value, :unsupported_number)
  end

  # ── The conversation host ────────────────────────────────────

  test "a writable caller creates on a conversation host and the row is the conversation's alone" do
    conversation = Conversation.create!(workspace: workspaces(:shared), creating_user: users(:member))

    result = StoreEntries::Create.call(
      host: conversation, by: users(:member),
      namespace: "notes", key: "pinned", value: { "ids" => [1] }
    )

    assert_equal :created, result.outcome
    assert_equal conversation, result.entry.host
    assert_equal accounts(:cybros), result.entry.account
    assert_nil result.entry.workspace_id
    assert_equal 0, workspaces(:shared).store_entries.count
  end

  test "the conversation host reaches the dedication fence, the archived bin and the tombstone" do
    dedicated = Conversation.create!(workspace: workspaces(:dedicated), creating_user: users(:agent))
    mismatched = create_agent_member(steward: users(:owner), agent_identifier: "w5-conv-other")
    fenced = StoreEntries::Create.call(
      host: dedicated, by: mismatched, namespace: "notes", key: "pinned", value: 1
    )
    assert_equal :workspace_agent_identifier_mismatch, fenced.outcome

    conversation = Conversation.create!(workspace: workspaces(:shared), creating_user: users(:member))
    conversation.update_columns(archived_at: Time.current)
    archived = StoreEntries::Create.call(
      host: conversation, by: users(:member), namespace: "notes", key: "pinned", value: 1
    )
    assert_equal :conversation_archived, archived.outcome

    conversation.update_columns(archived_at: nil, tombstoned_at: Time.current)
    tombstoned = StoreEntries::Create.call(
      host: conversation, by: users(:member), namespace: "notes", key: "pinned", value: 1
    )
    assert_equal :not_found, tombstoned.outcome

    hidden = Conversation.create!(workspace: workspaces(:personal), creating_user: users(:curator))
    concealed = StoreEntries::Create.call(
      host: hidden, by: users(:member), namespace: "notes", key: "pinned", value: 1
    )
    assert_equal :not_found, concealed.outcome
  end

  test "the cap is per host: a conversation at cap does not cap its workspace" do
    conversation = Conversation.create!(workspace: workspaces(:shared), creating_user: users(:member))
    StoreEntry::MAX_ENTRIES_PER_HOST.times do |n|
      conversation.store_entries.create!(namespace: "bulk", key: "k#{n}")
    end

    over_cap = StoreEntries::Create.call(
      host: conversation, by: users(:member), namespace: "bulk", key: "k64", value: nil
    )
    assert_equal :entry_limit_reached, over_cap.outcome

    on_workspace = StoreEntries::Create.call(
      host: workspaces(:shared), by: users(:member), namespace: "bulk", key: "k64", value: nil
    )
    assert_equal :created, on_workspace.outcome
  end

  # ── The user host: the ACTING principal's own row ─────────

  test "an agent's create lands under the agent, not its steward" do
    result = StoreEntries::Create.call(
      host: users(:agent), by: users(:agent), namespace: "notes", key: "own", value: 1
    )

    assert_equal :created, result.outcome
    assert_equal 1, StoreEntry.for_user(users(:agent).id).count
    assert_equal 0, StoreEntry.for_user(users(:owner).id).count

    stewards_own = StoreEntries::Create.call(
      host: users(:owner), by: users(:owner), namespace: "notes", key: "own", value: 2
    )
    assert_equal :created, stewards_own.outcome
    assert_equal 1, StoreEntry.for_user(users(:owner).id).count
    assert_equal 2, StoreEntry.for_user(users(:owner).id).sole.value
  end

  test "a repeated pair on the same user is key_taken — no receipt, no replay" do
    first = StoreEntries::Create.call(
      host: users(:member), by: users(:member), namespace: "notes", key: "pinned", value: 1
    )
    assert_equal :created, first.outcome

    repeat = StoreEntries::Create.call(
      host: users(:member), by: users(:member), namespace: "notes", key: "pinned", value: 2
    )
    assert_equal :key_taken, repeat.outcome
    assert_equal 1, StoreEntry.for_user(users(:member).id).sole.value
  end

  test "another principal's profile store is absence, and a suspended Human's is not operable" do
    foreign = StoreEntries::Create.call(
      host: users(:owner), by: users(:member), namespace: "notes", key: "pinned", value: 1
    )
    assert_equal :not_found, foreign.outcome

    assert_equal :suspended, users(:member).suspend
    suspended = StoreEntries::Create.call(
      host: users(:member), by: users(:member), namespace: "notes", key: "pinned", value: 1
    )
    assert_equal :workspace_not_active, suspended.outcome
    assert_equal 0, StoreEntry.for_user(users(:member).id).count
  end
end
