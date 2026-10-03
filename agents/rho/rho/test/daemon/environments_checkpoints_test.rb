require "test_helper"

class EnvironmentsCheckpointsTest < Minitest::Test
  Task = Data.define(:conversation_public_id, :parent_public_id, :agent_loop_public_id)

  def setup
    @tmp = File.realpath(Dir.mktmpdir("rho-environments-checkpoints"))
    @default = File.join(@tmp, "default")
    @other = File.join(@tmp, "other")
    [@default, @other].each do |root|
      FileUtils.mkdir_p(root)
      File.write(File.join(root, "a.rb"), "original")
    end
    @home = Rho::Home.resolve(base_url: "https://nexus.example", root: File.join(@tmp, "home"))
    @home.prepare
    @registry = Rho::Runner::Extensions::Loader.call(builtin: [Rho::Runner::Extensions::Checkpoints],
      api_options: { host: RhoTest.host }).registry
  end

  def teardown
    FileUtils.rm_rf(@tmp)
  end

  def environments
    Rho::Environments.new(home: @home, config: Rho::Config.from_hash({}), registry: @registry,
      log: nil, clock: -> { Time.now }, booted_at: "2026-09-18T00:00:00Z", default_root: -> { @default },
      member_plane: ->(**) { nil }, own_runner: ->(_id) { true }, learn_runner: ->(_doc) { }, spawn: -> { }, checkpoints: true)
  end

  def task(conversation = nil)
    Task.new(conversation_public_id: conversation, parent_public_id: nil, agent_loop_public_id: "restore-loop")
  end

  def test_settings_reopen_stores_with_new_limits_and_preserve_their_records
    table = environments
    before = table.zero.env.checkpoints
    captured = before.capture(loop: "kept-loop")

    table.configure(config: Rho::Config.from_hash("checkpoints" => { "max_file_bytes" => 1024, "retention_days" => 3 }))

    after = table.zero.env.checkpoints
    refute_same before, after
    assert_equal before.id, after.id
    assert_equal 1024, after.max_file_bytes
    assert_equal 3, after.retention_days
    found = table.zero.toolset.fetch("checkpoints").handler.call({ "loop" => "kept-loop" }, nil)
    assert_equal [captured.to_row], found.structured_content.fetch("records")

    table.configure(config: Rho::Config.from_hash("checkpoints" => { "enabled" => false }), checkpoints: false)
    assert_nil table.zero.env.checkpoints
    assert_empty table.checkpoint_stores
    assert File.directory?(before.path), "disabling captures does not delete existing records"
  end

  def test_a_standalone_restore_after_restart_recovers_the_original_root_from_its_store_record
    before = environments
    before.receive("c-1", Rho::Runner::Environment::Binding.new(root: @other, directories: [], anchor: "c-1"))
    target = before.toolsets.for(task("c-1")).env.checkpoints.capture(loop: "original-loop")
    default = before.toolsets.zero.env.checkpoints.capture(loop: "default-loop")
    assert_equal default.hash, target.hash
    File.write(File.join(@default, "a.rb"), "keep default")
    File.write(File.join(@other, "a.rb"), "other changed")

    restarted = environments
    placed = restarted.toolsets.for(task)
    restored = placed.toolset.fetch("world_restore").handler.call({ "checkpoint" => target.hash, "store" => target.store }, nil)

    refute_predicate restored, :is_error
    assert_equal "original", File.read(File.join(@other, "a.rb"))
    assert_equal "keep default", File.read(File.join(@default, "a.rb"))
    assert_equal target.store, restored.metadata.dig("checkpoint", "store")
    assert_same restarted.checkpoint_stores(target.store).first, restarted.checkpoint_stores(target.store).first
  end

  def test_a_standalone_checkpoint_lookup_after_restart_finds_the_conversation_root
    before = environments
    before.receive("c-1", Rho::Runner::Environment::Binding.new(root: @other, directories: [], anchor: "c-1"))
    target = before.toolsets.for(task("c-1")).env.checkpoints.capture(loop: "original-loop")

    placed = environments.toolsets.for(task)
    found = placed.toolset.fetch("checkpoints").handler.call({ "loop" => "original-loop" }, nil)

    refute_predicate found, :is_error
    assert_equal [target.to_row], found.structured_content.fetch("records")
    unknown = placed.toolset.fetch("world_restore").handler.call({ "checkpoint" => target.hash, "store" => "0" * 16 }, nil)
    assert_predicate unknown, :is_error
    assert_equal "checkpoint_store_unknown: #{"0" * 16}", unknown.content
  end

  def test_an_explicit_store_does_not_restore_a_different_root_after_its_recorded_path_becomes_a_symlink
    before = environments
    before.receive("c-1", Rho::Runner::Environment::Binding.new(root: @other, directories: [], anchor: "c-1"))
    target = before.toolsets.for(task("c-1")).env.checkpoints.capture(loop: "original-loop")
    default = before.toolsets.zero.env.checkpoints.capture(loop: "default-loop")
    assert_equal default.hash, target.hash
    File.write(File.join(@default, "a.rb"), "keep default")
    File.write(File.join(@other, "a.rb"), "keep moved")
    moved = File.join(@tmp, "moved")
    File.rename(@other, moved)
    File.symlink(@default, @other)

    placed = environments.toolsets.for(task)
    restored = placed.toolset.fetch("world_restore").handler.call({ "checkpoint" => target.hash, "store" => target.store }, nil)

    assert_predicate restored, :is_error
    assert_equal "checkpoint_store_unknown: #{target.store}", restored.content
    assert_equal "keep default", File.read(File.join(@default, "a.rb"))
    assert_equal "keep moved", File.read(File.join(moved, "a.rb"))
  end
end
