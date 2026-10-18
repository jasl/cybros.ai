require_relative "fixtures"

class CheckpointSnapshotTest < Minitest::Test
  include CheckpointFixtures

  def test_first_capture_is_idempotent_after_reopening
    write("a", "one")
    store = open_store
    first = store.capture(run_public_id: "first", outside: ["/outside"], ignored: [".env"])
    assert_equal ["/outside"], first.outside
    write("a", "two")
    reopened = open_store
    assert_equal first, reopened.capture(run_public_id: "first")
    assert_equal 1, reopened.records.length
    second = reopened.capture(run_public_id: "second")
    refute_equal first.hash, second.hash
    assert_equal second.hash, reopened.capture(run_public_id: "third").hash
  end

  def test_equal_stats_within_one_filesystem_tick_do_not_hide_changed_bytes_or_spend_unchanged_budget
    # A filesystem can report equal size/mtime/ctime after an immediate equal-size
    # write. Keep that observation fixed across capture and restore;
    # a future timestamp also prevents the fixture aging out under a slow CI run.
    stamp = Time.now.to_i + 3600
    build = ->(**options) do
      open_store(**options).tap do |store|
        store.define_singleton_method(:stat_signature) do |stat|
          super(stat).tap { |signature| signature[1, 4] = [stamp, 0, stamp, 0] }
        end
      end
    end
    write("a", "a")
    store = build.call
    first = store.capture(run_public_id: "first")
    limited = build.call(max_tree_bytes: 0)
    refute_predicate limited.capture(run_public_id: "unchanged"), :skip?

    write("a", "b")
    refused = limited.capture(run_public_id: "limited")
    assert_equal "tree_too_large", refused.reason
    assert_equal 1, refused.bytes
    assert_empty limited.records(run_public_id: "limited")
    assert_equal [{ "status" => "M", "path" => "a" }], store.changed_since(first.hash)
    restored = store.restore(first.hash, undo_loop: "restore")
    assert_equal "a", File.binread(File.join(@root, "a"))
    store.restore(restored.undo, undo_loop: "undo")
    assert_equal "b", File.binread(File.join(@root, "a"))

    write("a", "c")
    second = build.call.restore(first.hash, undo_loop: "restore")
    store.restore(second.undo, undo_loop: "undo")
    assert_equal "c", File.binread(File.join(@root, "a"))
  end

  def test_repeated_restore_has_a_fresh_undo_and_round_trips_all_bytes
    write("a", "original\r\n\0".b)
    store = open_store
    first = store.capture(run_public_id: "first")
    write("a", "modified")
    write("new", "added")
    before = disk
    restored = store.restore(first.hash, undo_loop: "restore")
    assert_equal 1, restored.files
    assert_equal 1, restored.removed
    assert_equal "original\r\n\0".b, File.binread(File.join(@root, "a"))
    store.restore(restored.undo, undo_loop: "restore")
    assert_equal before, disk
    write("a", "third")
    other = store.restore(first.hash, undo_loop: "restore")
    refute_equal restored.undo, other.undo
    assert_equal 3, store.records(run_public_id: "restore").length
  end

  def test_gitignore_precedence_parent_rules_and_changes_after_open
    write(".gitignore", "*.log\n!keep.log\nkeep.log\nignored/\n!ignored/keep\nspace\\ name\n")
    write("root.log", "ignored")
    write("keep.log", "ignored again")
    write("space name", "ignored")
    write("ignored/keep", "parent stays ignored")
    write("sub/.gitignore", "!keep.log\n")
    write("sub/keep.log", "tracked")
    write("visible", "tracked")
    store = open_store
    first = store.capture(run_public_id: "first")
    assert_equal 4, first.files
    write(".gitignore", "*.log\nignored/\nspace\\ name\nnew.secret\n")
    write("new.secret", "never captured")
    write("sub/keep.log", "changed")
    write("root.log", "leave current")
    store.restore(first.hash, undo_loop: "restore")
    assert_equal "tracked", File.read(File.join(@root, "sub/keep.log"))
    assert_equal "leave current", File.read(File.join(@root, "root.log"))
    assert_equal "never captured", File.read(File.join(@root, "new.secret"))
  end

  def test_checkout_tracking_overrides_ignore_and_size_caps_without_writing_project_git
    write("tracked.log", "x" * 4096)
    checkout(@root)
    before = disk.select { |name, _| name.start_with?(".git/") }
    write(".gitignore", "*.log\n")
    write("other.log", "ignored")
    write("big", "y" * 4096)
    store = open_store(max_file_bytes: 1024)
    first = store.capture(run_public_id: "first")
    assert_equal ["big"], first.skipped
    assert_equal 2, first.files
    write("tracked.log", "z" * 8192)
    store.restore(first.hash, undo_loop: "restore")
    assert_equal "x" * 4096, File.read(File.join(@root, "tracked.log"))
    assert_equal before, disk.select { |name, _| name.start_with?(".git/") }
  end

  def test_stat_dirty_identical_bytes_still_spend_the_candidate_budget
    write("a", "original")
    store = open_store
    original = store.capture(run_public_id: "original")
    stamp = Time.now + 10
    File.utime(stamp, stamp, File.join(@root, "a"))
    limited = open_store(max_tree_bytes: 0)
    outcome = limited.capture(run_public_id: "limited")
    assert_equal "tree_too_large", outcome.reason
    assert_equal 8, outcome.bytes
    assert_equal 1, outcome.files
    assert_equal [original.hash], store.records.map(&:hash)
  end

  def test_nested_checkout_is_preserved_and_its_dirt_counts_as_one_zero_byte_candidate
    write("nested/a", "nested original")
    checkout(File.join(@root, "nested"))
    store = open_store
    first = store.capture(run_public_id: "first")
    assert_equal ["nested"], first.nested
    write("nested/a", "nested changed")
    write("new", "xx")
    outcome = open_store(max_tree_bytes: 1).capture(run_public_id: "limited")
    assert_equal "tree_too_large", outcome.reason
    assert_equal 2, outcome.files
    assert_equal 2, outcome.bytes
    before = disk.select { |name, _| name.start_with?("nested/") }
    restored = store.restore(first.hash, undo_loop: "restore")
    assert_equal ["nested"], restored.nested
    assert_equal before, disk.select { |name, _| name.start_with?("nested/") }
  end

  def test_symlink_and_executable_mode_round_trip_without_touching_link_target
    File.write(File.join(@tmp, "outside"), "outside")
    File.symlink("../outside", File.join(@root, "link"))
    write("script", "#!/bin/sh\n")
    File.chmod(0o755, File.join(@root, "script"))
    store = open_store
    first = store.capture(run_public_id: "first")
    File.unlink(File.join(@root, "link"))
    write("link", "regular now")
    File.chmod(0o644, File.join(@root, "script"))
    current = disk
    restored = store.restore(first.hash, undo_loop: "restore")
    assert_equal "../outside", File.readlink(File.join(@root, "link"))
    assert File.executable?(File.join(@root, "script"))
    assert_equal "outside", File.read(File.join(@tmp, "outside"))
    store.restore(restored.undo, undo_loop: "undo")
    assert_equal current, disk
  end

  def test_restore_can_replace_an_uncaptured_empty_directory_with_a_file
    write("report", "original")
    store = open_store
    first = store.capture(run_public_id: "first")
    File.unlink(File.join(@root, "report"))
    store.capture(run_public_id: "deleted")
    FileUtils.mkdir_p(File.join(@root, "report", "empty"))
    result = store.restore(first.hash, undo_loop: "restore")
    assert_kind_of Rho::Runner::Checkpoints::Restored, result
    assert_equal "original", File.read(File.join(@root, "report"))
  end

  def test_two_connections_publish_each_runs_first_capture_once
    write("a", "value")
    a, b = open_store, open_store
    threads = [a, b].map { |store| Thread.new { store.capture(run_public_id: "same") } }
    results = threads.map(&:value)
    assert_equal results.first.hash, results.last.hash
    assert_equal 1, a.records.length
    assert_equal 1, b.records.length
  end

  def test_restoring_a_former_directory_or_ancestor_file_never_enters_a_current_nested_checkout
    write("area", "old file")
    store = open_store
    file = store.capture(run_public_id: "file")
    File.unlink(File.join(@root, "area"))
    write("area/nested/a", "old ordinary file")
    directory = store.capture(run_public_id: "directory")
    write("area/nested/a", "current checkout")
    checkout(File.join(@root, "area", "nested"))
    write("area/nested/uncommitted", "keep")
    before = disk

    [file, directory].each do |record|
      restored = store.restore(record.hash, undo_loop: "restore")
      assert_kind_of Rho::Runner::Checkpoints::Restored, restored
      assert_equal ["area/nested"], restored.nested
      assert_equal before, disk
    end
  end

  def test_ignored_unborn_nested_checkout_is_not_read_or_captured
    write(".gitignore", "ignored/\n")
    write("ignored/a", "ignored")
    assert system("git", "init", "-q", File.join(@root, "ignored"))
    captured = open_store.capture(run_public_id: "capture")
    refute_predicate captured, :skip?
    assert_equal 1, captured.files
    assert_empty captured.nested
  end

  def test_file_type_changes_and_executable_changes_keep_their_distinct_diff_statuses
    write("a", "ordinary")
    write("script", "run")
    store = open_store
    first = store.capture(run_public_id: "first")
    File.unlink(File.join(@root, "a"))
    File.symlink("script", File.join(@root, "a"))
    File.chmod(0o755, File.join(@root, "script"))
    expected = [{ "status" => "T", "path" => "a" }]
    expected << { "status" => "M", "path" => "script" }
    assert_equal expected, store.changed_since(first.hash)
    second = store.capture(run_public_id: "second")
    assert_equal expected, store.changed(from: first.hash, to: second.hash)
  end
end
