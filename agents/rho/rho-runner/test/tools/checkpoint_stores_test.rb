require "test_helper"

class CheckpointStoresTest < Minitest::Test
  Store = Rho::Runner::Checkpoints::Store

  def setup
    @tmp = File.realpath(Dir.mktmpdir("rho-checkpoint-stores"))
    @dir = File.join(@tmp, "checkpoints")
    @stores = %w[first second].map do |name|
      root = File.join(@tmp, name)
      FileUtils.mkdir_p(root)
      File.write(File.join(root, "a.rb"), "original")
      Store.open(dir: @dir, root: root)
    end
    @first, @second = @stores
    @before = @stores.map.with_index { |store, index| store.capture(run_public_id: "loop-#{index}") }
    @env = Rho::Runner::ToolEnv.new(root: @first.root, artifacts_dir: File.join(@tmp, "artifacts"),
      checkpoints: @first, checkpoint_resolver: ->(id) { id ? @stores.select { |store| store.id == id } : @stores })
  end

  def teardown
    FileUtils.rm_rf(@tmp)
  end

  def test_an_explicit_store_restores_only_its_root_even_when_the_tree_hash_exists_in_both
    assert_equal @before.first.hash, @before.last.hash
    @stores.each { |store| File.write(File.join(store.root, "a.rb"), store.id) }

    result = Rho::Runner::Tools::CheckpointRestore.new(env: @env).call(
      "checkpoint" => @before.last.hash, "store" => @second.id
    )

    refute_predicate result, :is_error
    assert_equal "original", File.read(File.join(@second.root, "a.rb"))
    assert_equal @first.id, File.read(File.join(@first.root, "a.rb"))
    assert_equal @second.id, result.metadata.dig("checkpoint", "store")
  end

  def test_unknown_explicit_store_never_falls_back_to_the_current_root
    File.write(File.join(@first.root, "a.rb"), "keep")

    [Rho::Runner::Tools::CheckpointRestore, Rho::Runner::Tools::Checkpoints].each do |klass|
      result = klass.new(env: @env).call("checkpoint" => @before.first.hash, "store" => "0" * 16)
      assert_predicate result, :is_error
      assert_equal "checkpoint_store_unknown: #{"0" * 16}", result.content
    end

    assert_equal "keep", File.read(File.join(@first.root, "a.rb"))
  end

  def test_checkpoint_reads_select_the_store_and_loop_lookup_searches_all_roots
    File.write(File.join(@second.root, "a.rb"), "changed")
    after = @second.capture(run_public_id: "loop-after")
    tool = Rho::Runner::Tools::Checkpoints.new(env: @env)

    found = tool.call("run_public_id" => "loop-1")
    assert_equal [@before.last.to_row], found.structured_content.fetch("records")
    assert_equal @stores.map(&:id).sort,
      tool.call({}).structured_content.fetch("records").map { |record| record.fetch("store") }.uniq.sort

    one = tool.call("checkpoint" => @before.last.hash, "store" => @second.id)
    assert_equal @second.id, one.structured_content.fetch("record").fetch("store")
    assert_equal [{ "status" => "M", "path" => "a.rb" }], one.structured_content.fetch("changed")

    diff = tool.call("from" => @before.last.hash, "to" => after.hash, "store" => @second.id)
    assert_equal one.structured_content.fetch("changed"), diff.structured_content.fetch("changed")
  end

  def test_persisted_records_locate_stores_without_opening_or_creating_an_unknown_store
    assert_equal @stores.map(&:root).sort, Store.roots(dir: @dir).sort
    assert_equal [@second.root], Store.roots(dir: @dir, id: @second.id)
    assert_empty Store.roots(dir: @dir, id: "0" * 16)
    refute File.exist?(File.join(@dir, "0" * 16))
    assert_raises(ArgumentError) { Store.roots(dir: @dir, id: "../second") }
  end

  def test_a_placement_without_a_host_resolver_uses_its_own_store
    zero = Rho::Runner::ToolEnv.new(root: @first.root, artifacts_dir: File.join(@tmp, "artifacts"), checkpoints: @first)
    registry = Rho::Runner::Extensions::Loader.call(builtin: [Rho::Runner::Extensions::Coding]).registry
    sets = Rho::Runner::Toolsets.new(registry: registry, zero: zero, work_dir: @tmp,
      resolver: ->(_conversation, _parent) { Rho::Runner::Environment::Binding.new(root: @second.root, directories: [], anchor: "c-1") },
      checkpoints: ->(_root) { @second })
    task = CybrosAgent::Api::InboxTask.new(workspace_public_id: "ws-1", kind: "tool_call", run_public_id: "loop-1", conversation_public_id: "c-1",
      parent_public_id: nil, task_key: "read", tool_name: "read", tool_input: {}, tool_call_id: "call-1",
      started_at: nil, deadline_at: nil, timeout_ms: nil, claimed: false,
      addressed_to: CybrosAgent::Api::AddressedTo.new(role: "runner", executor_public_id: "ex-1"), scope: nil)

    placed = sets.for(task).env

    assert_equal [@second], placed.checkpoint_stores
    assert_equal [@second], placed.checkpoint_stores(@second.id)
    assert_empty placed.checkpoint_stores(@first.id)
    assert_equal [@first], zero.checkpoint_stores
  end
end
