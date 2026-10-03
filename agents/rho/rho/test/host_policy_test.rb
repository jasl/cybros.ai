require "test_helper"
require "rho/host_policy"
require_relative "support/environment_fixtures"

class HostPolicyTest < Minitest::Test
  def setup
    @store = RhoTest::EnvironmentFixtures::FakeStore.new
  end

  def test_missing_policy_is_read_only_and_returns_nil
    assert_nil policy.read
    assert_empty @store.rows
  end

  def test_committed_policy_survives_a_new_handle_and_is_not_changed_through_a_read
    notes = { "rho.until" => { "goal" => "finish", "checks" => ["tests"] } }
    written = policy.replace(model: "provider/model", compose: false, notes: notes)
    reread = policy.read
    assert_equal written, reread
    assert_equal "owner-a", reread.owner_public_id
    assert_equal "host-a", reread.host_public_id
    assert_equal false, reread.compose

    reread.notes.fetch("rho.until")["goal"] = "changed outside a commit"
    assert_equal "finish", policy.read.notes.fetch("rho.until").fetch("goal")
  end

  def test_legacy_import_only_fills_a_missing_entry_and_records_current_ownership
    initial = -> { { "model" => "legacy/model", "compose" => true, "notes" => { "rho.until" => { "goal" => "finish" } } } }
    imported = policy(initial: initial).read
    assert_equal "legacy/model", imported.model
    assert_equal "owner-a", imported.owner_public_id
    assert_equal "host-a", imported.host_public_id
    assert_equal imported, policy(initial: -> { flunk "Nexus policy must win over legacy" }).read
    assert_equal 1, writes.length
  end

  def test_absent_legacy_value_does_not_create_a_policy
    assert_nil policy(initial: -> { nil }).read
    assert_empty @store.rows
  end

  def test_legacy_preference_without_notes_imports_as_an_empty_notes_policy
    imported = policy(initial: -> { { "model" => "legacy/model", "compose" => false } }).read
    assert_equal "legacy/model", imported.model
    assert_equal false, imported.compose
    assert_empty imported.notes
    assert_equal imported, policy.read
  end

  def test_change_preserves_owner_and_unspecified_fields_while_replace_claims_current_owner
    notes = { "rho.side" => { "parent" => "parent", "tools" => "none" } }
    policy.replace(model: "provider/model", compose: true, notes: notes)
    other = policy(owner_public_id: "owner-b")
    changed = other.change(compose: false)
    assert_equal "owner-a", changed.owner_public_id
    assert_equal "provider/model", changed.model
    assert_equal notes, changed.notes
    assert_equal false, changed.compose

    cleared = other.change(model: nil, compose: nil, notes: {})
    assert_equal "owner-a", cleared.owner_public_id
    assert_nil cleared.model
    assert_nil cleared.compose
    assert_empty cleared.notes

    replaced = other.replace(model: "another/model")
    assert_equal "owner-b", replaced.owner_public_id
    assert_equal replaced, policy.read
  end

  def test_first_change_uses_current_owner_and_host
    snapshot = policy.change(notes: { "rho.until" => { "goal" => "finish" } })
    assert_equal "owner-a", snapshot.owner_public_id
    assert_equal "host-a", snapshot.host_public_id
    assert_nil snapshot.model
    assert_nil snapshot.compose
    assert_equal snapshot, policy.read
  end

  def test_fork_copy_inherits_preferences_without_reviving_parent_notes
    notes = { "rho.until" => { "goal" => "parent work" }, "rho.side" => { "parent" => "grandparent" } }
    parent = policy.replace(model: "provider/model", compose: false, notes: notes)
    child_store = RhoTest::EnvironmentFixtures::FakeStore.new(@store.rows.map { |row| row.with(value: row.value.dup) })
    child = policy(store: child_store, owner_public_id: "owner-b", host_public_id: "host-b")
    inherited = child.read
    assert_equal "provider/model", inherited.model
    assert_equal false, inherited.compose
    assert_empty inherited.notes
    assert_equal "owner-b", inherited.owner_public_id
    assert_equal "host-b", inherited.host_public_id
    assert_equal parent.to_h, child_store.rows.first.value, "reading does not rewrite the copied policy"

    changed = child.change(model: "child/model")
    assert_equal "owner-b", changed.owner_public_id
    assert_equal "host-b", changed.host_public_id
    assert_equal false, changed.compose
    assert_empty changed.notes
    assert_equal changed, policy(store: child_store, owner_public_id: "owner-b", host_public_id: "host-b").read
    assert_equal parent, policy.read
  end

  def test_failed_write_never_exposes_proposed_model_or_notes
    handle = policy
    before = handle.replace(model: "old/model", notes: { "rho.until" => { "goal" => "old" } })
    failed = ->(*, **) { raise CybrosAgent::TransportError, "before commit" }
    @store.define_singleton_method(:update, failed)
    assert_raises(CybrosAgent::TransportError) { handle.replace(model: "new/model", notes: {}) }
    assert_equal before, handle.read
    assert_equal before, policy.read
  end

  def test_stale_change_surfaces_conflict_and_keeps_the_winning_policy_owner_and_notes
    first = policy
    first.replace(model: "old/model")
    stale = policy(owner_public_id: "owner-b")
    stale.read
    winner = first.change(notes: { "rho.until" => { "goal" => "new" } })
    error = assert_raises(CybrosAgent::Api::Conflict) { stale.change(compose: true) }
    assert_equal "stale_object", error.code
    assert_equal winner, stale.read
    assert_equal 3, writes.length, "the rejected write is not replayed"
  end

  def test_unknown_commit_is_confirmed_through_store_document_without_replaying_the_change
    handle = policy
    handle.replace(model: "old/model")
    update = @store.method(:update)
    lost = ->(*args, **options) do
      update.call(*args, **options)
      raise CybrosAgent::TransportError, "response lost"
    end
    @store.define_singleton_method(:update, lost)
    changed = handle.change(notes: { "rho.until" => { "goal" => "new" } })
    assert_equal changed, policy.read
    assert_equal "new", handle.read.notes.fetch("rho.until").fetch("goal")
    assert_equal 2, writes.length
  end

  def test_unavailable_store_never_becomes_an_empty_policy_or_legacy_import
    @store.fail_reads(CybrosAgent::TransportError.new("offline"))
    handle = policy(initial: -> { flunk "read failure must not import legacy" })
    assert_raises(CybrosAgent::TransportError) { handle.read }
    assert_empty @store.rows
  end

  def test_malformed_notes_are_refused_instead_of_silently_clearing_policy
    policy.replace(model: "provider/model")
    row = @store.rows.first
    @store.rows.replace([row.with(value: row.value.merge("notes" => nil))])
    assert_raises(Rho::StateError) { policy.read }
  end

  private

    def policy(store: @store, owner_public_id: "owner-a", host_public_id: "host-a", initial: nil)
      Rho::HostPolicy.new(store: -> { store }, owner_public_id: owner_public_id, host_public_id: host_public_id, initial: initial)
    end

    def writes = @store.calls.select { |call| %i[create update].include?(call.first) }
end
