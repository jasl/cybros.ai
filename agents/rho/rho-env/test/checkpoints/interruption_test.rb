require_relative "fixtures"
require "timeout"

class CheckpointsInterruptionTest < Minitest::Test
  include CheckpointFixtures

  def with_interruption(store, stage)
    ready, resume = Queue.new, Queue.new
    hit = false
    store.define_singleton_method(:checkpoint) do |current, deadline|
      if current == stage && !hit
        hit = true
        ready << true
        resume.pop
      end
      super(current, deadline)
    end
    context = Rho::Env::ExecutionContext.new
    worker = Thread.new do
      Rho::Env::ExecutionContext.with(context) { yield }
    rescue Rho::Env::ExecutionContext::Cancelled
      :cancelled
    end
    worker.report_on_exception = false
    Timeout.timeout(5) { ready.pop }
    context.cancel
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    resume << true
    assert worker.join(3), "cancel must release the operation"
    assert_equal :cancelled, worker.value
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 3
  ensure
    resume << true
    worker&.join(3)
    store.singleton_class.remove_method(:checkpoint)
  end

  def test_cancelled_capture_rolls_back_and_later_capture_restore_and_undo_work
    write("a", "before")
    store = open_store
    first = store.capture(run_public_id: "first")
    write("a", "after" * 100_000)
    with_interruption(store, :before_publish) { store.capture(run_public_id: "cancelled") }
    assert_empty store.records(run_public_id: "cancelled")
    db = SQLite3::Database.new(File.join(store.path, Rho::Env::Checkpoints::Store::DATABASE_FILE), readonly: true)
    assert_equal "ok", db.get_first_value("PRAGMA integrity_check")
    db.close
    assert_equal [first.hash], open_store.records.map(&:hash)
    second = store.capture(run_public_id: "next")
    refute_predicate second, :skip?
    restored = store.restore(first.hash, undo_loop: "restore")
    assert_equal "before", File.read(File.join(@root, "a"))
    store.restore(restored.undo, undo_loop: "undo")
    assert_equal "after" * 100_000, File.read(File.join(@root, "a"))
  end

  def test_cancellation_after_undo_publication_preserves_undo_before_files_change
    write("a", "before")
    store = open_store
    first = store.capture(run_public_id: "first")
    write("a", "after")
    with_interruption(store, :before_file_remove) { store.restore(first.hash, undo_loop: "cancelled") }
    assert_equal "after", File.read(File.join(@root, "a"))
    undo = store.records(run_public_id: "cancelled").fetch(0)
    assert store.tree?(undo.hash)
    store.restore(first.hash, undo_loop: "retry")
    store.restore(undo.hash, undo_loop: "undo")
    assert_equal "after", File.read(File.join(@root, "a"))
  end

  def test_cancellation_during_restore_keeps_a_usable_undo
    write("a", "before a")
    write("b", "before b")
    store = open_store
    first = store.capture(run_public_id: "first")
    write("a", "after a")
    write("b", "after b")
    before = disk
    with_interruption(store, :file_written) { store.restore(first.hash, undo_loop: "cancelled") }
    undo = store.records(run_public_id: "cancelled").fetch(0)
    store.restore(undo.hash, undo_loop: "undo")
    assert_equal before, disk
  end

  def test_capture_deadline_rolls_back_and_can_be_retried
    now = 0.0
    write("a", "value")
    store = open_store(clock: -> { now }, capture_timeout_seconds: 1)
    store.define_singleton_method(:checkpoint) do |stage, deadline|
      now = 2 if stage == :blob_written
      super(stage, deadline)
    end
    assert_equal "timeout", store.capture(run_public_id: "timed").reason
    assert_empty store.records
    store.singleton_class.remove_method(:checkpoint)
    refute_predicate store.capture(run_public_id: "next"), :skip?
  end

  def test_cancellation_during_a_file_read_publishes_nothing
    write("large", "x" * (1024 * 1024))
    store = open_store
    with_interruption(store, :file_chunk) { store.capture(run_public_id: "cancelled") }
    assert_empty store.records
    assert_equal 1024 * 1024, File.size(File.join(@root, "large"))
    refute_predicate store.capture(run_public_id: "retry"), :skip?
  end

  def test_restore_deadline_keeps_the_committed_undo
    now = 0.0
    write("a", "before")
    store = open_store(clock: -> { now }, capture_timeout_seconds: 1)
    first = store.capture(run_public_id: "first")
    write("a", "after")
    store.define_singleton_method(:checkpoint) do |stage, deadline|
      now = 2 if stage == :before_file_remove
      super(stage, deadline)
    end
    result = store.restore(first.hash, undo_loop: "timed")
    assert_equal "restore_failed", result.code
    refute_nil result.undo
    assert_equal "after", File.read(File.join(@root, "a"))
    store.singleton_class.remove_method(:checkpoint)
    store.restore(first.hash, undo_loop: "retry")
    store.restore(result.undo, undo_loop: "undo")
    assert_equal "after", File.read(File.join(@root, "a"))
  end

  def test_clean_seeded_gitlink_does_not_spend_the_candidate_budget
    write("nested/a", "nested original")
    checkout(File.join(@root, "nested"))
    checkout(@root)
    store = open_store(max_tree_bytes: 1)
    write("new", "xx")
    result = store.capture(run_public_id: "limited")
    assert_equal "tree_too_large", result.reason
    assert_equal 1, result.files
    assert_equal 2, result.bytes
  end

  def test_plain_roots_never_spawn_git_including_restore_and_undo
    write("a", "before")
    store = open_store(git: File.join(@tmp, "git-must-not-run"))
    first = store.capture(run_public_id: "first")
    write("a", "after")
    result = store.restore(first.hash, undo_loop: "restore")
    store.restore(result.undo, undo_loop: "undo")
    assert_equal "after", File.read(File.join(@root, "a"))
  end

  def test_cancelled_prune_rolls_back_records_content_and_working_cache_together
    write("a", "before")
    store = open_store
    first = store.capture(run_public_id: "first")
    write("a", "after")
    second = store.capture(run_public_id: "second")

    with_interruption(store, :before_prune_publish) { store.prune(retention_days: 0, now: Time.now + 10) }

    assert_equal [first, second], store.records
    store.restore(first.hash, undo_loop: "restore")
    assert_equal "before", File.binread(File.join(@root, "a"))
    store.restore(second.hash, undo_loop: "undo")
    assert_equal "after", File.binread(File.join(@root, "a"))
  end

  def test_a_database_statement_deadline_rolls_back_a_capture_and_leaves_the_store_usable
    write("a", "before")
    store = open_store
    first = store.capture(run_public_id: "first")
    write("a", "after")
    queried = false
    store.define_singleton_method(:checkpoint) do |stage, deadline|
      if stage == :before_publish
        queried = true
        @db.statement_timeout = 5
        @db.execute("WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x + 1 FROM n WHERE x < 100000000) SELECT sum(x) FROM n")
      end
      super(stage, deadline)
    end
    assert_equal "timeout", store.capture(run_public_id: "timed").reason
    assert queried
    assert_equal [first], store.records
    store.singleton_class.remove_method(:checkpoint)
    restored = store.restore(first.hash, undo_loop: "restore")
    assert_equal "before", File.binread(File.join(@root, "a"))
    store.restore(restored.undo, undo_loop: "undo")
    assert_equal "after", File.binread(File.join(@root, "a"))
  end

  def test_a_failed_restore_keeps_its_committed_undo_on_the_refusal
    write("a", "before")
    store = open_store
    first = store.capture(run_public_id: "first")
    write("a", "after")
    store.define_singleton_method(:checkpoint) do |stage, deadline|
      raise Errno::EIO, "fixture write failed" if stage == :before_file_write

      super(stage, deadline)
    end
    refused = store.restore(first.hash, undo_loop: "failed")
    assert_equal "restore_failed", refused.code
    assert_equal refused.undo, store.records(run_public_id: "failed").first.hash
    assert_includes refused.message, refused.undo
    store.singleton_class.remove_method(:checkpoint)
    store.restore(refused.undo, undo_loop: "undo")
    assert_equal "after", File.binread(File.join(@root, "a"))
  end
end
