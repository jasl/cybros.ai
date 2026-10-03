require "test_helper"

class CheckpointsInterruptionTest < Minitest::Test
  include RunnerTest::Helpers

  Store = Rho::Runner::Checkpoints::Store
  Context = Rho::Runner::ExecutionContext

  def setup
    @tmp = File.realpath(Dir.mktmpdir("rho-checkpoint-interruption"))
    @root = File.join(@tmp, "root")
    Dir.mkdir(@root)
    @file = File.join(@root, "a.txt")
    File.write(@file, "before")
    @interrupt = File.join(@tmp, "interrupt")
    @ready = File.join(@tmp, "ready")
    @git = File.join(@tmp, "git")
    File.write(@git, <<~RUBY)
      #!#{RbConfig.ruby}
      if File.exist?(#{@interrupt.dump}) && ARGV.first == File.read(#{@interrupt.dump})
        File.delete(#{@interrupt.dump})
        # Git holds this temporary index from acquisition until publish;
        # killing the process leaves it behind, including on cancellation.
        File.open(ENV.fetch("GIT_INDEX_FILE") + ".lock", "w") do
          File.write(#{@ready.dump}, Process.pid.to_s)
          sleep 30
        end
      end
      exec "git", *ARGV
    RUBY
    File.chmod(0o700, @git)
    @store = Store.open(dir: File.join(@tmp, "stores"), root: @root, git: @git)
  end

  def teardown
    @context&.cancel
    @worker&.join(5)
    FileUtils.rm_rf(@tmp)
  end

  def test_cancelling_capture_does_not_disable_later_capture_or_restore
    original = @store.capture(loop: "original")
    File.write(@file, "after")

    assert_cancelled("add") { @store.capture(loop: "cancelled") }

    refute File.exist?(File.join(@store.path, "index.lock"))
    assert_empty @store.records(loop: "cancelled")
    captured = @store.capture(loop: "next")
    refute_predicate captured, :skip?
    assert_equal "after", File.read(@file)
    restored = @store.restore(original.hash, undo_loop: "restore")
    assert_kind_of Rho::Runner::Checkpoints::Restored, restored
    assert_equal "before", File.read(@file)
    @store.restore(restored.undo, undo_loop: "undo")
    assert_equal "after", File.read(@file)
  end

  def test_capture_timeout_releases_the_index_for_the_next_loop
    timed = Store.open(dir: @store.dir, root: @root, git: @git, capture_timeout_seconds: 1)
    File.write(@interrupt, "add")

    skipped = timed.capture(loop: "timeout")

    assert_equal "timeout", skipped.reason
    assert File.exist?(@ready), "the timeout happened while writing the index"
    assert_process_gone(Integer(File.read(@ready)))
    refute File.exist?(File.join(@store.path, "index.lock"))
    assert_empty @store.records(loop: "timeout")
    refute_predicate @store.capture(loop: "next"), :skip?
  end

  def test_cancelling_target_preparation_preserves_the_undo_and_allows_another_restore
    original = @store.capture(loop: "original")
    File.write(@file, "after")

    assert_cancelled("read-tree") { @store.restore(original.hash, undo_loop: "cancelled") }

    refute File.exist?(File.join(@store.path, "index.restore.lock"))
    assert_equal "after", File.read(@file)
    undo = @store.records(loop: "cancelled").fetch(0)
    assert @store.tree?(undo.hash), "the undo remains available after cancellation"
    restored = @store.restore(original.hash, undo_loop: "next")
    assert_kind_of Rho::Runner::Checkpoints::Restored, restored
    assert_equal "before", File.read(@file)
    @store.restore(undo.hash, undo_loop: "undo")
    assert_equal "after", File.read(@file)
  end

  private

  def assert_cancelled(command, &operation)
    File.write(@interrupt, command)
    @context = Context.new
    @worker = Thread.new do
      Context.with(@context, &operation)
    rescue Context::Cancelled
      :cancelled
    end
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    until File.exist?(@ready)
      flunk "git never acquired its index lock" if
        !@worker.alive? || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.01
    end
    @context.cancel
    assert @worker.join(5), "cancellation must release the worker"
    assert_equal :cancelled, @worker.value
    assert_process_gone(Integer(File.read(@ready)))
  end
end
