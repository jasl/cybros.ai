require "test_helper"

# THE STORE'S READ: four shapes, one hidden tool — the truth the
# kernel's cache is a cache of, and the console's diff producer with
# `files_bytes`.
class CheckpointsToolTest < Minitest::Test
  include RunnerTest::Helpers

  Store = Rho::Runner::Checkpoints::Store

  def setup
    @tmp = File.realpath(Dir.mktmpdir("rho-checkpoints-tool"))
    @root = File.join(@tmp, "root")
    FileUtils.mkdir_p(File.join(@root, "lib"))
    File.write(File.join(@root, "lib", "a.rb"), "one")
    File.write(File.join(@root, "README.md"), "readme")
    @store = Store.open(dir: File.join(@tmp, "checkpoints"), root: @root)
  end

  def teardown
    FileUtils.rm_rf(@tmp)
  end

  def tool(store: @store)
    env = Rho::Runner::ToolEnv.new(root: @root, artifacts_dir: File.join(@tmp, "artifacts"), checkpoints: store)
    Rho::Runner::Tools::Checkpoints.new(env: env)
  end

  def test_an_empty_store_lists_no_records_and_a_missing_store_is_disabled
    result = tool.call({})
    refute_predicate result, :is_error
    assert_equal "No checkpoints.", result.content
    assert_equal({ "records" => [] }, result.structured_content)
    assert_equal "checkpoints", result.title

    disabled = tool(store: nil).call({})
    assert_predicate disabled, :is_error
    assert_equal "checkpoints_disabled: no store", disabled.content
  end

  def test_the_list_and_the_loop_filter_answer_the_records_with_present
    first = @store.capture(run_public_id: "al-1")
    File.write(File.join(@root, "lib", "a.rb"), "two")
    second = @store.capture(run_public_id: "al-2")

    all = tool.call({})
    assert_equal [first.to_row, second.to_row], all.structured_content.fetch("records")
    assert all.structured_content.fetch("records").all? { |row| row.fetch("present") }
    assert_equal "al-1  #{first.hash}  #{first.captured_at}  2 files\nal-2  #{second.hash}  #{second.captured_at}  2 files",
      all.content

    one = tool.call("run_public_id" => "al-2")
    assert_equal [second.to_row], one.structured_content.fetch("records")
    assert_equal({ "records" => [] }, tool.call("run_public_id" => "al-9").structured_content)
  end

  def test_one_checkpoint_answers_its_record_and_the_tree_against_now
    first = @store.capture(run_public_id: "al-1")
    File.write(File.join(@root, "lib", "a.rb"), "two")
    File.write(File.join(@root, "lib", "b.rb"), "new")

    result = tool.call("checkpoint" => first.hash)

    refute_predicate result, :is_error
    assert_equal first.to_row, result.structured_content.fetch("record")
    assert_equal [{ "status" => "M", "path" => "lib/a.rb" }, { "status" => "A", "path" => "lib/b.rb" }],
      result.structured_content.fetch("changed")
    assert_equal "al-1  #{first.hash}  #{first.captured_at}  2 files\nM  lib/a.rb\nA  lib/b.rb", result.content
    assert_equal "checkpoint #{first.hash[0, 12]}", result.title

    unknown = tool.call("checkpoint" => "0" * 40)
    assert_predicate unknown, :is_error
    assert_equal "checkpoint_unknown: #{"0" * 40}", unknown.content
  end

  def test_one_checkpoint_under_a_tree_cap_is_skipped_as_data
    first = @store.capture(run_public_id: "al-1")
    File.write(File.join(@root, "huge.bin"), "z" * 8192)
    capped = Store.open(dir: File.join(@tmp, "checkpoints"), root: @root, max_tree_bytes: 1000)

    result = tool(store: capped).call("checkpoint" => first.hash)

    assert_predicate result, :is_error
    assert_equal "checkpoint_skipped: tree_too_large", result.content
  end

  def test_from_and_to_answer_the_per_turn_diff_with_no_work_tree_pass
    h1 = @store.capture(run_public_id: "al-1").hash
    File.write(File.join(@root, "lib", "a.rb"), "two")
    File.write(File.join(@root, "lib", "b.rb"), "new")
    h2 = @store.capture(run_public_id: "al-2").hash
    File.write(File.join(@root, "lib", "a.rb"), "three")

    result = tool.call("from" => h1, "to" => h2)

    refute_predicate result, :is_error
    assert_equal({ "changed" => [{ "status" => "M", "path" => "lib/a.rb" }, { "status" => "A", "path" => "lib/b.rb" }] },
      result.structured_content)
    assert_equal "M  lib/a.rb\nA  lib/b.rb", result.content
    assert_equal "checkpoint diff", result.title
    assert_equal "No changes.", tool.call("from" => h1, "to" => h1).content
    assert_equal "three", File.read(File.join(@root, "lib", "a.rb"))
    unknown = tool.call("from" => h1, "to" => "0" * 40)
    assert_predicate unknown, :is_error
    assert_equal "checkpoint_unknown: #{"0" * 40}", unknown.content
  end

  def test_a_mixed_or_half_shape_is_refused_as_data
    [{ "from" => "a" }, { "run_public_id" => "x", "checkpoint" => "y" }, { "checkpoint" => "y", "to" => "z" }].each do |args|
      result = tool.call(args)
      assert_predicate result, :is_error, args.inspect
      assert_equal "invalid_arguments: checkpoints takes {}, {run_public_id}, {checkpoint} or {from, to}", result.content
    end
    bad = tool.call("run_public_id" => "../x")
    assert_predicate bad, :is_error
    assert_match(/\Ainvalid_arguments: a checkpoint loop name is a public id/, bad.content)
  end

  def test_it_is_registered_undescribed_with_reads_profile_beside_checkpoint_restore_only_when_the_host_has_a_store
    klass = Rho::Runner::Tools::Checkpoints
    assert_nil klass::DESCRIPTION
    assert_equal Rho::Runner::Tools::Read::EFFECT_PROFILE, klass::EFFECT_PROFILE
    assert_equal false, klass::SCHEMA.fetch("additionalProperties")

    with_store = Rho::Runner::Extensions::Loader.call(
      builtin: [Rho::Runner::Extensions::Checkpoints],
      api_options: { host: Struct.new(:checkpoints, :processes).new(@store, nil) }
    )
    assert_predicate with_store, :ok?
    assert_equal %w[checkpoint_restore checkpoints], with_store.registry.names.sort
    assert_equal %w[checkpoint_restore checkpoints], with_store.registry.entries.select(&:undescribed?).map(&:name).sort
    assert_equal ["rho.checkpoints"], with_store.registry.extension_names

    # The two shapes the contract admits: no host at all, and a host
    # whose `checkpoints` member is nil (every host answers the member).
    [nil, Struct.new(:checkpoints, :processes).new(nil, nil)].each do |host|
      without = Rho::Runner::Extensions::Loader.call(builtin: [Rho::Runner::Extensions::Checkpoints], api_options: { host: host })
      assert_predicate without, :ok?
      assert_empty without.registry.names, "no store, nothing registered (host #{host.inspect})"
    end
  end
end
