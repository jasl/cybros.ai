require "test_helper"
require "rho/host_policy"
require_relative "support/environment_fixtures"

class HostPolicyTest < Minitest::Test
  def setup
    @store = RhoTest::EnvironmentFixtures::FakeStore.new
  end

  def test_modes_preserve_false_and_omission
    assert_equal false, policy.establish(code_mode: false, subagent: false).code_mode
    assert_equal false, policy.change(model: "new/model").code_mode
    assert_equal false, policy.read.subagent
    assert_equal true, policy.change(subagent: true).subagent
    assert_equal true, policy.change(code_mode: true).code_mode
  end

  def test_missing_policy_is_read_only_and_returns_nil
    assert_nil policy.read
    assert_empty @store.rows
  end

  def test_first_title_opportunity_is_consumed_once_and_survives_reopen_or_other_policy_changes
    assert policy.establish(title_pending: true).title_pending
    assert policy.consume_title("input-1")
    refute policy.change(model: "dev/later").title_pending
    refute policy.establish(model: "dev/replay", title_pending: true).title_pending
    refute policy.read.title_pending
    assert_equal "input-1", policy.read.title_input_public_id
  end

  def test_title_consumers_cannot_borrow_another_inputs_successful_commit
    first = policy
    first.establish(title_pending: true)
    stale = policy
    assert stale.read.title_pending
    assert first.consume_title("input-1")
    assert_raises(CybrosAgent::Api::Conflict) { stale.consume_title("input-2") }
    refute first.consume_title("input-3"), "the same handle also consumes only once"
    assert_equal "input-1", policy.read.title_input_public_id
    assert_equal 3, writes.length, "the losing input never retries its write"
  end

  def test_fork_and_historical_policy_do_not_start_a_new_title_attempt
    policy.establish(title_pending: true)
    child = policy(host_public_id: "child")
    refute child.read.title_pending
    refute child.change(model: "dev/child").title_pending

    row = @store.rows.first
    @store.rows[0] = row.with(value: row.value.except("title_pending"))
    refute child.read.title_pending
    refute @store.rows.first.value.key?("title_pending"), "the read does not rewrite an older policy"
  end

  def test_historical_unset_choices_read_as_fixed_initial_values_without_rewriting_the_record
    policy.establish(code_mode: false, subagent: false)
    stored = @store.rows.first
    @store.rows[0] = stored.with(value: stored.value.except("subagent").merge("code_mode" => nil))
    assert_equal true, policy.read.code_mode
    assert_equal true, policy.read.subagent
    assert_nil @store.rows.first.value.fetch("code_mode")
    refute @store.rows.first.value.key?("subagent")
  end

  def test_actual_model_changes_preserve_the_original_explicit_selection
    intent = { "source" => "explicit", "model" => "provider/chosen", "constraint" => "model", "alternatives" => ["other/chosen"] }
    policy.establish(model: "provider/chosen", model_selection: intent)
    policy.change(model: "other/chosen")
    saved = policy.read
    assert_equal "other/chosen", saved.model
    assert_equal intent, saved.model_selection
    assert_nil policy.change(model_selection: nil).model_selection
  end

  def test_committed_policy_survives_a_new_handle_and_is_not_changed_through_a_read
    notes = { "rho.until" => { "goal" => "finish", "checks" => ["tests"] } }
    written = policy.establish(model: "provider/model", notes: notes)
    reread = policy.read
    assert_equal written, reread
    assert_equal "owner-a", reread.owner_public_id
    assert_equal "host-a", reread.host_public_id

    reread.notes.fetch("rho.until")["goal"] = "changed outside a commit"
    assert_equal "finish", policy.read.notes.fetch("rho.until").fetch("goal")
  end

  def test_change_and_establish_preserve_the_original_owner
    notes = { "rho.side" => { "parent" => "parent", "tools" => "write" } }
    policy.establish(model: "provider/model", notes: notes)
    other = policy(owner_public_id: "owner-b")
    changed = other.change(model: "provider/changed")
    assert_equal "owner-a", changed.owner_public_id
    assert_equal "provider/changed", changed.model
    assert_equal notes, changed.notes

    cleared = other.change(model: nil, notes: {})
    assert_equal "owner-a", cleared.owner_public_id
    assert_nil cleared.model
    assert_empty cleared.notes

    replaced = other.establish(model: "another/model")
    assert_equal "owner-a", replaced.owner_public_id
    assert_equal cleared, replaced
    assert_equal replaced, policy.read
  end

  def test_first_change_uses_current_owner_and_host
    snapshot = policy.change(notes: { "rho.until" => { "goal" => "finish" } })
    assert_equal "owner-a", snapshot.owner_public_id
    assert_equal "host-a", snapshot.host_public_id
    assert_nil snapshot.model
    assert_equal snapshot, policy.read
  end

  def test_establish_leaves_the_complete_same_host_document_and_version_unchanged
    policy.establish(model: "original/model", title_pending: true)
    policy.consume_title("input-1")
    policy.change(notes: { "rho.until" => { "attempts" => 2, "run_public_id" => "run-1" }, "other" => [1] })
    before = @store.rows.first
    established = policy(owner_public_id: "owner-b").establish(model: "replayed/model",
      notes: { "rho.until" => { "attempts" => 20, "run_public_id" => nil } }, title_pending: true)
    assert_equal before, @store.rows.first
    assert_equal before.value, established.to_h
    assert_equal 3, writes.length
  end

  def test_establish_replaces_a_copied_parent_policy_once_with_the_childs_own_policy
    policy.establish(model: "parent/model", notes: { "rho.until" => { "attempts" => 2 } })
    child = policy(owner_public_id: "owner-b", host_public_id: "child")
    established = child.establish(model: "child/model", notes: { "rho.side" => { "parent" => "host-a" } })
    assert_equal ["owner-b", "child", "child/model"], established.to_h.values_at("owner_public_id", "host_public_id", "model")
    refute established.notes.key?("rho.until")
    before = @store.rows.first
    assert_equal established, child.establish(model: "replay/model")
    assert_equal before, @store.rows.first
  end

  def test_fork_copy_inherits_preferences_without_reviving_parent_notes
    notes = { "rho.until" => { "goal" => "parent work" }, "rho.side" => { "parent" => "grandparent" } }
    parent = policy.establish(model: "provider/model", notes: notes, code_mode: false)
    child_store = RhoTest::EnvironmentFixtures::FakeStore.new(@store.rows.map { |row| row.with(value: row.value.dup) })
    child = policy(store: child_store, owner_public_id: "owner-b", host_public_id: "host-b")
    inherited = child.read
    assert_equal "provider/model", inherited.model
    assert_equal false, inherited.code_mode
    assert_empty inherited.notes
    assert_equal "owner-b", inherited.owner_public_id
    assert_equal "host-b", inherited.host_public_id
    assert_equal parent.to_h, child_store.rows.first.value, "reading does not rewrite the copied policy"

    changed = child.change(model: "child/model")
    assert_equal "owner-b", changed.owner_public_id
    assert_equal "host-b", changed.host_public_id
    assert_empty changed.notes
    assert_equal changed, policy(store: child_store, owner_public_id: "owner-b", host_public_id: "host-b").read
    assert_equal parent, policy.read
  end

  def test_failed_write_never_exposes_proposed_model_or_notes
    handle = policy
    before = handle.establish(model: "old/model", notes: { "rho.until" => { "goal" => "old" } })
    failed = ->(*, **) { raise CybrosAgent::TransportError, "before commit" }
    @store.define_singleton_method(:update, failed)
    assert_raises(CybrosAgent::TransportError) { handle.change(model: "new/model", notes: {}) }
    assert_equal before, handle.read
    assert_equal before, policy.read
  end

  def test_stale_change_surfaces_conflict_and_keeps_the_winning_policy_owner_and_notes
    first = policy
    first.establish(model: "old/model")
    stale = policy(owner_public_id: "owner-b")
    stale.read
    winner = first.change(notes: { "rho.until" => { "goal" => "new" } })
    error = assert_raises(CybrosAgent::Api::Conflict) { stale.change(model: "stale/model") }
    assert_equal "stale_object", error.code
    assert_equal winner, stale.read
    assert_equal 3, writes.length, "the rejected write is not replayed"
  end

  def test_unknown_commit_is_confirmed_through_store_document_without_replaying_the_change
    handle = policy
    handle.establish(model: "old/model")
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

  def test_unavailable_store_never_becomes_an_empty_policy
    @store.fail_reads(CybrosAgent::TransportError.new("offline"))
    handle = policy
    assert_raises(CybrosAgent::TransportError) { handle.read }
    assert_empty @store.rows
  end

  def test_malformed_notes_are_refused_instead_of_silently_clearing_policy
    policy.establish(model: "provider/model")
    row = @store.rows.first
    @store.rows.replace([row.with(value: row.value.merge("notes" => nil))])
    assert_raises(Rho::StateError) { policy.read }
  end

  private

    def policy(store: @store, owner_public_id: "owner-a", host_public_id: "host-a")
      Rho::HostPolicy.new(store: -> { store }, owner_public_id: owner_public_id, host_public_id: host_public_id)
    end

    def writes = @store.calls.select { |call| %i[create update].include?(call.first) }
end
