require "test_helper"
require "sqlite3"

class CheckpointLifecycleTest < Minitest::Test
  Store = Rho::Env::Checkpoints::Store

  def setup
    @tmp = File.realpath(Dir.mktmpdir("rho-checkpoint-lifecycle"))
    @root = File.join(@tmp, "root")
    @dir = File.join(@tmp, "stores")
    Dir.mkdir(@root)
  end

  def teardown
    FileUtils.rm_rf(@tmp)
  end

  def test_plain_roots_capture_restore_diff_and_reopen_without_git
    write("a", "before")
    options = { dir: @dir, root: @root, git: File.join(@tmp, "no-git") }
    store = Store.open(**options)
    first = store.capture(run_public_id: "first")
    write("a", "after")
    assert_equal [{ "status" => "M", "path" => "a" }], store.changed_since(first.hash)
    assert_equal [first], store.records
    reopened = Store.open(**options)
    assert_equal first, reopened.capture(run_public_id: "first")
    restored = reopened.restore(first.hash, undo_loop: "restore")
    assert_equal "before", File.binread(File.join(@root, "a"))
    reopened.restore(restored.undo, undo_loop: "undo")
    assert_equal "after", File.binread(File.join(@root, "a"))
  end

  def test_prune_reclaims_content_and_space_without_losing_shared_bytes_or_a_usable_working_index
    write("shared", "shared bytes")
    write("large", Random.new(42).bytes(2 * 1024 * 1024))
    store = Store.open(dir: @dir, root: @root)
    old = store.capture(run_public_id: "old")
    age(store, "old", 0)
    File.unlink(File.join(@root, "large"))
    write("current", "current bytes")
    fresh = store.capture(run_public_id: "fresh")
    age(store, "fresh", 10)
    before = store.size_bytes

    assert_equal 1, store.prune(retention_days: 0, now: Time.at(5))
    assert_equal [fresh.hash], store.records.map(&:hash)
    refute store.tree?(old.hash)
    assert store.tree?(fresh.hash)
    assert_operator store.size_bytes, :<, before - 1024 * 1024
    write("shared", "changed")
    store.restore(fresh.hash, undo_loop: "restore")
    assert_equal "shared bytes", File.binread(File.join(@root, "shared"))
    assert_equal "current bytes", File.binread(File.join(@root, "current"))

    # The working stat cache must not reuse a blob which retention removed.
    count = store.records.length
    assert_equal count, store.prune(retention_days: 0, now: Time.now + 10)
    assert_empty store.records
    captured = store.capture(run_public_id: "after-prune")
    refute_predicate captured, :skip?
    write("shared", "later")
    store.restore(captured.hash, undo_loop: "after-prune-restore")
    assert_equal "shared bytes", File.binread(File.join(@root, "shared"))
    assert_equal "ok", database(store) { |db| db.get_first_value("PRAGMA integrity_check") }
  end

  def test_diff_updates_tracking_without_publishing_a_checkpoint_and_its_unreferenced_content_is_reclaimed
    write("a", "before")
    store = Store.open(dir: @dir, root: @root)
    first = store.capture(run_public_id: "first")
    write("a", "after")
    write("new", "tracked by diff")
    assert_equal %w[a new], store.changed_since(first.hash).map { |row| row.fetch("path") }
    write(".gitignore", "new\n")
    assert_empty store.ignored(["new"])
    assert_equal [first], store.records

    assert_equal 0, store.prune
    second = store.capture(run_public_id: "second")
    assert_equal 3, second.files
    write("new", "changed")
    store.restore(second.hash, undo_loop: "restore")
    assert_equal "tracked by diff", File.binread(File.join(@root, "new"))
  end

  def test_prune_finishes_a_large_manifest_within_its_statement_budget
    200.times { |index| write("file-#{index}", "checkpoint #{index}\n" * 256) }
    original = File.binread(File.join(@root, "file-0"))
    store = Store.open(dir: @dir, root: @root)
    first = store.capture(run_public_id: "first")
    refute_predicate first, :skip?
    write("file-0", "changed")
    second = store.capture(run_public_id: "second")
    refute_predicate second, :skip?

    assert_equal 0, store.prune
    assert_equal [first, second], store.records
    restored = store.restore(first.hash, undo_loop: "restore")
    assert_equal original, File.binread(File.join(@root, "file-0"))
    store.restore(restored.undo, undo_loop: "undo")
    assert_equal "changed", File.binread(File.join(@root, "file-0"))

    assert_equal 4, store.prune(retention_days: 0, now: Time.now + 10)
    assert_empty store.records
    assert_equal [0, 0], database(store) { |db| %w[trees blobs].map { |table| db.get_first_value("SELECT count(*) FROM #{table}") } }
    refute_predicate store.capture(run_public_id: "after-prune"), :skip?
  end

  def test_discovery_and_doctor_reads_do_not_modify_stores_or_initialize_missing_ones
    write("a", "before")
    store = Store.open(dir: @dir, root: @root)
    first = store.capture(run_public_id: "first")
    store.restore(first.hash, undo_loop: "undo")
    before = disk
    assert_equal [@root], Store.roots(dir: @dir)
    assert_equal [@root], Store.roots(dir: @dir, id: store.id)
    assert_equal 2, Store.record_count(store.path)
    assert_empty Store.roots(dir: @dir, id: "0" * 16)
    assert_equal 0, Store.record_count(File.join(@dir, "0" * 16))
    assert_equal before, disk

    # History can still be counted when the work root is absent.
    FileUtils.rm_rf(@root)
    assert_equal [@root], Store.roots(dir: @dir)
    assert_equal 2, Store.record_count(store.path)
  end

  def test_undo_records_are_numbered_within_the_exact_run_and_listed_in_creation_order
    write("a", "original")
    store = Store.open(dir: @dir, root: @root)
    first = store.capture(run_public_id: "first")
    store.capture(run_public_id: "request-undo-1")
    undos = 12.times.map do |index|
      write("a", "change #{index}")
      store.restore(first.hash, undo_loop: "request").undo
    end
    assert_equal undos, store.records(run_public_id: "request").map(&:hash)
    assert_equal 1, store.records(run_public_id: "request-undo-1").length
  end

  private

    def write(name, bytes)
      File.binwrite(File.join(@root, name), bytes)
    end

    def database(store)
      db = SQLite3::Database.new(File.join(store.path, "checkpoints.sqlite3"))
      yield db
    ensure
      db&.close
    end

    def age(store, run, seconds)
      database(store) do |db|
        db.execute("UPDATE records SET created_at = ? WHERE run = ?", [seconds, run])
      end
    end

    def disk
      Dir.glob("**/*", File::FNM_DOTMATCH, base: @dir).filter_map do |name|
        full = File.join(@dir, name)
        [name, Digest::SHA256.file(full).hexdigest] if File.file?(full)
      end.to_h
    end
end
