require "test_helper"

# THE RESTORE TOOL: undo-first, unconditional, refused whole,
# described to nobody; the undo rides the reserved key.
class CheckpointRestoreTest < Minitest::Test
  include RunnerTest::Helpers

  Store = Rho::Runner::Checkpoints::Store

  def setup
    @tmp = File.realpath(Dir.mktmpdir("rho-world-restore"))
    @root = File.join(@tmp, "root")
    FileUtils.mkdir_p(@root)
    File.write(File.join(@root, "a.rb"), "one")
    @store = Store.open(dir: File.join(@tmp, "checkpoints"), root: @root)
  end

  def teardown
    FileUtils.rm_rf(@tmp)
  end

  def env(store: @store)
    Rho::Runner::ToolEnv.new(root: @root, artifacts_dir: File.join(@tmp, "artifacts"), checkpoints: store)
  end

  def tool(store: @store) = Rho::Runner::Tools::CheckpointRestore.new(env: env(store: store))

  def in_loop(run_public_id, &)
    Rho::Runner::ExecutionContext.with(Rho::Runner::ExecutionContext.new(run_public_id: run_public_id), &)
  end

  def test_it_restores_the_tree_after_capturing_the_undo_under_the_request_loop_and_answers_the_undo_on_the_key
    target = @store.capture(run_public_id: "al-1").hash
    File.write(File.join(@root, "a.rb"), "two")
    File.write(File.join(@root, "b.rb"), "new")

    result = in_loop("req-1") { tool.call("checkpoint" => target) }

    refute_predicate result, :is_error
    undo = @store.records(run_public_id: "req-1").first
    refute_nil undo, "the undo is recorded under the request loop's id"
    assert_equal "Restored 1 files to #{target} (1 removed); undo with #{undo.hash}", result.content
    assert_equal({ "restored" => target, "undo" => undo.hash, "files" => 1, "removed" => 1, "nested" => [] },
      result.structured_content)
    assert_equal "world restored", result.title
    assert_equal({ "checkpoint" => { "hash" => undo.hash, "store" => @store.id } }, result.metadata,
      "the undo IS a checkpoint on the reserved key")
    assert_equal({ "checkpoint" => undo.key }, result.metadata, "spelled by Record#key, the one writer of the shape")
    assert_equal "one", File.read(File.join(@root, "a.rb"))
    refute File.exist?(File.join(@root, "b.rb"))
  end

  def test_an_unknown_checkpoint_is_refused_as_data_with_no_undo
    result = in_loop("req-1") { tool.call("checkpoint" => "0" * 40) }

    assert_predicate result, :is_error
    assert_equal "checkpoint_unknown: #{"0" * 40}", result.content
    assert_nil result.structured_content
    assert_nil result.metadata
    assert_nil @store.records(run_public_id: "req-1").first
  end

  def test_a_runner_with_no_store_answers_checkpoints_disabled
    result = tool(store: nil).call("checkpoint" => "abc")

    assert_predicate result, :is_error
    assert_equal "checkpoints_disabled: no store", result.content
  end

  def test_a_target_with_an_entry_under_a_protected_root_is_refused_whole
    FileUtils.mkdir_p(File.join(@root, "vault"))
    File.write(File.join(@root, "vault", "key"), "k")
    target = @store.capture(run_public_id: "al-1").hash
    File.write(File.join(@root, "a.rb"), "two")
    guarded = Store.open(dir: File.join(@tmp, "checkpoints"), root: @root, protected_roots: [File.join(@root, "vault")])

    result = in_loop("req-1") { tool(store: guarded).call("checkpoint" => target) }

    assert_predicate result, :is_error
    assert_equal "restore_refused: protected_root_inside", result.content
    assert_equal "two", File.read(File.join(@root, "a.rb")), "nothing was restored"
  end

  # A call outside a task (a probe) mints a local undo name rather than
  # failing: the undo still lands.
  def test_outside_a_task_the_undo_is_recorded_under_a_local_name
    target = @store.capture(run_public_id: "al-1").hash
    File.write(File.join(@root, "a.rb"), "two")

    result = Rho::Runner::ExecutionContext.with(Rho::Runner::ExecutionContext.new) { tool.call("checkpoint" => target) }

    refute_predicate result, :is_error
    assert_match(/\Alocal-[0-9a-f]{8}\z/, @store.records.map(&:run_public_id).find { |l| l.start_with?("local-") })
  end

  # DESCRIBED TO NOBODY, write-kind and closed-world, a park of its own:
  # the announcement carries the name and the profile alone.
  def test_it_is_registered_undescribed_with_a_destructive_closed_write_profile_and_its_own_park
    klass = Rho::Runner::Tools::CheckpointRestore
    assert_nil klass::DESCRIPTION
    assert_equal({ "kind" => "write", "destructive" => true, "effect_scope" => "closed",
                   "idempotency" => "none", "reconciliation" => "none" }, klass::EFFECT_PROFILE)
    assert_equal 120_000, klass::TIMEOUT_MS
    assert_equal ["checkpoint"], klass::SCHEMA.fetch("required")
    host = Struct.new(:checkpoints, :processes).new(@store, nil)
    registry = Rho::Runner::Extensions::Loader.call(
      builtin: [Rho::Runner::Extensions::Checkpoints], api_options: { host: host }
    ).registry
    entry = registry.entries.find { |candidate| candidate.name == "checkpoint_restore" }
    assert_predicate entry, :undescribed?
    announced = registry.announcement.find { |e| e.fetch("name") == "checkpoint_restore" }
    assert_equal %w[effect_profile name timeout_ms], announced.keys.sort
  end
end
