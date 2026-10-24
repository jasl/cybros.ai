require_relative "fixtures"

class CheckpointEnumerationTest < Minitest::Test
  include CheckpointFixtures

  def test_ignored_descendants_are_not_statted_but_previously_tracked_files_remain_captured
    write("a", "visible")
    write("cache/tracked", "tracked")
    store = open_store
    store.capture(run_public_id: "first")
    write(".gitignore", "cache/\n")
    100.times { |i| write("cache/ignored-#{i}", "ignored") }
    inspected = []
    lstat = File.method(:lstat)
    File.define_singleton_method(:lstat) do |path|
      inspected << path if path.include?("/cache/ignored-")
      lstat.call(path)
    end
    begin
      captured = store.capture(run_public_id: "second")
      assert_equal 3, captured.files
      assert_equal ["cache/new"], store.ignored(["cache/new", "cache/tracked"])
      assert_empty inspected, "ignored subtrees are pruned before Ruby stats or reads their contents"
    ensure
      File.define_singleton_method(:lstat, lstat)
    end
    File.unlink(File.join(@root, ".gitignore"))
    assert_equal 102, store.capture(run_public_id: "unignored").files
  end

  def test_nested_ignore_files_added_and_changed_after_open_are_applied
    write("a", "visible")
    store = open_store
    store.capture(run_public_id: "first")
    write("sub/.gitignore", "*.log\n!keep.log\n")
    write("sub/keep.log", "keep")
    write("sub/ignored.log", "ignore")

    assert_equal 3, store.capture(run_public_id: "nested-rules").files
    assert_equal ["sub/ignored.log"], store.ignored(["sub/ignored.log", "sub/keep.log", "elsewhere.log"])
    write("sub/.gitignore", "")
    assert_equal 4, store.capture(run_public_id: "changed-rules").files
  end

  def test_excluded_directory_names_are_literal_in_git_enumeration
    write(".gitignore", "")
    write("private[1]/a", "excluded")
    write("private1/a", "visible")
    store = open_store(excluded: [File.join(@root, "private[1]")])
    first = store.capture(run_public_id: "first")
    assert_equal 2, first.files
    write("private[1]/a", "excluded current")
    write("private1/a", "visible changed")

    store.restore(first.hash, undo_loop: "restore")
    assert_equal "visible", File.read(File.join(@root, "private1/a"))
    assert_equal "excluded current", File.read(File.join(@root, "private[1]/a"))
  end

  def test_a_tracked_directory_that_becomes_an_ignored_checkout_stays_a_restore_boundary
    write("nested/a", "before")
    store = open_store
    first = store.capture(run_public_id: "first")
    checkout(File.join(@root, "nested"))
    write("nested/a", "after")
    write(".gitignore", "nested/\n")

    captured = store.capture(run_public_id: "second")
    assert_equal ["nested"], captured.nested
    assert_equal 1, captured.files
    restored = store.restore(first.hash, undo_loop: "restore")
    assert_equal ["nested"], restored.nested
    assert_equal "after", File.read(File.join(@root, "nested/a"))
  end

  def test_an_ignored_file_or_symlink_replacing_a_tracked_ancestor_refuses_restore_without_overwriting_it
    store = open_store
    outside = File.join(@tmp, "outside")
    File.write(outside, "outside current")
    %w[file symlink].each do |kind|
      FileUtils.rm_rf(File.join(@root, "area"))
      FileUtils.rm_f(File.join(@root, ".gitignore"))
      write("area/a", "before")
      first = store.capture(run_public_id: "first-#{kind}")
      FileUtils.rm_rf(File.join(@root, "area"))
      if kind == "symlink"
        File.symlink(outside, File.join(@root, "area"))
      else
        write("area", "ignored current")
      end
      write(".gitignore", "area\n")

      refused = store.restore(first.hash, undo_loop: "restore-#{kind}")
      assert_equal "restore_refused", refused.code
      assert_includes refused.detail, "uncaptured_path: area"
      assert_equal 1, refused.record.files, "only .gitignore is in the undo; the ignored ancestor remains uncaptured"
      assert_equal refused.record, store.records(run_public_id: "restore-#{kind}").fetch(0)
      assert store.tree?(refused.undo)
      if kind == "symlink"
        assert_equal outside, File.readlink(File.join(@root, "area"))
      else
        assert_equal "ignored current", File.read(File.join(@root, "area"))
      end
      assert_equal "outside current", File.read(outside)
    end
  end

  def test_a_tracked_directory_replaced_by_a_symlink_never_reads_or_restores_its_old_descendants
    write("area/a", "before")
    store = open_store
    first = store.capture(run_public_id: "first")
    outside = File.join(@tmp, "outside")
    FileUtils.mv(File.join(@root, "area"), outside)
    File.write(File.join(outside, "a"), "outside current")
    File.symlink(outside, File.join(@root, "area"))

    captured = store.capture(run_public_id: "second")
    assert_equal 1, captured.files, "only the symlink is captured"
    restored = store.restore(first.hash, undo_loop: "restore")
    assert_equal "before", File.read(File.join(@root, "area/a"))
    assert_equal "outside current", File.read(File.join(outside, "a"))
    store.restore(restored.undo, undo_loop: "undo")
    assert_equal outside, File.readlink(File.join(@root, "area"))
    assert_equal "outside current", File.read(File.join(outside, "a"))
  end
end
