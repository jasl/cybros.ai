require "test_helper"
require "minitest/autorun"
require "tmpdir"

class CheckpointHooksIntegrationTest < Minitest::Test
  Runner = Rho::Runner
  Host = Data.define(:checkpoints, :processes)

  def setup
    @tmp = Dir.mktmpdir("checkpoint-hooks")
    @root = File.join(@tmp, "root")
    FileUtils.mkdir_p(@root)
    @store = Runner::Checkpoints::Store.open(dir: File.join(@tmp, "stores"), root: @root)
    @env = Runner::ToolEnv.new(root: @root, artifacts_dir: File.join(@tmp, "artifacts"), checkpoints: @store)
    loaded = Runner::Extensions::Loader.call(builtin: [Runner::Extensions::Coding, Runner::Extensions::Checkpoints],
      api_options: { host: Host.new(checkpoints: @store, processes: nil) })
    assert_predicate loaded, :ok?, loaded.failures.inspect
    @registry = loaded.registry
  end

  def teardown
    FileUtils.rm_rf(@tmp)
  end

  def test_real_hooks_capture_once_and_real_restore_tool_publishes_a_reusable_undo
    File.binwrite(File.join(@root, "file.txt"), "before")
    first = call("one", "write", "path" => "file.txt", "content" => "after")
    key = first.metadata.fetch("checkpoint")
    assert_equal @store.id, key.fetch("store")
    second = call("one", "write", "path" => "file.txt", "content" => "later")
    assert_nil second.metadata
    assert_equal 1, @store.records.length
    restored = call("restore", "checkpoint_restore", "checkpoint" => key.fetch("hash"))
    refute restored.is_error
    assert_equal "before", File.binread(File.join(@root, "file.txt"))
    undo = restored.structured_content.fetch("undo")
    assert_equal undo, restored.metadata.dig("checkpoint", "hash")
    assert_equal [undo], @store.records(run_public_id: "restore").map(&:hash)
    refute call("undo", "checkpoint_restore", "checkpoint" => undo).is_error
    assert_equal "later", File.binread(File.join(@root, "file.txt"))
    refute call("read", "read", "path" => "file.txt").is_error
    assert_empty @store.records(run_public_id: "read")
  end

  def test_ignored_mark_covers_future_paths_and_preserves_already_tracked_paths
    File.binwrite(File.join(@root, "tracked.log"), "before")
    @store.capture(run_public_id: "seed")
    File.binwrite(File.join(@root, ".gitignore"), "*.log\n")
    assert_equal ["new.log"], @store.ignored(%w[tracked.log new.log])
    result = call("ignored", "write", "path" => "new.log", "content" => "outside snapshot")
    assert_equal ["new.log"], result.metadata.dig("checkpoint", "ignored")
    record = @store.records(run_public_id: "ignored").first
    db = SQLite3::Database.new(File.join(@store.path, Runner::Checkpoints::Store::DATABASE_FILE), readonly: true)
    begin
      manifest = db.get_first_value("SELECT manifest FROM trees WHERE hash = ?", [record.hash])
      refute_includes JSON.parse(manifest).keys, "new.log"
    ensure
      db.close
    end
    assert_equal "outside snapshot", File.binread(File.join(@root, "new.log"))
  end

  def test_real_hook_marks_ignore_rules_inside_a_hidden_directory
    FileUtils.mkdir_p(File.join(@root, ".hidden"))
    File.binwrite(File.join(@root, ".hidden", ".gitignore"), "*.log\n")
    result = call("hidden", "write", "path" => ".hidden/new.log", "content" => "ignored")
    assert_equal [".hidden/new.log"], result.metadata.dig("checkpoint", "ignored")
    assert_equal "ignored", File.binread(File.join(@root, ".hidden/new.log"))
  end

  private

    def call(run, name, arguments)
      tool = @registry.toolset(env: @env).fetch(name)
      context = Runner::ExecutionContext.new(run_public_id: run, task_key: "call_tool", tool_env: @env)
      Runner::ExecutionContext.with(context) do
        input = @registry.hooks.before_call(name, arguments, tool)
        result = tool.handler.call(input, context)
        @registry.hooks.after_result(name, result, tool)
      end
    end
end
