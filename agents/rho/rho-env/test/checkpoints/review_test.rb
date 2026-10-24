require_relative "fixtures"

class CheckpointReviewTest < Minitest::Test
  include CheckpointFixtures

  def test_review_retains_dirty_baseline_committed_edits_and_independent_later_turns
    write("file.txt", "committed\n")
    checkout(@root)
    write("file.txt", "already dirty\n")
    store = open_store
    store.capture(run_public_id: "first")
    write("file.txt", "first reply\n")
    checkout(@root)

    first = store.review(run_public_id: "first")
    assert_equal ["file.txt"], first.fetch("files").map { |file| file.fetch("path") }
    patch = first.fetch("files").first.fetch("patch")
    assert_includes patch, "-already dirty\n"
    assert_includes patch, "+first reply\n"
    refute_includes patch, "-committed\n"
    assert_equal 1, first.fetch("files").first.fetch("additions")
    assert_equal 1, first.fetch("files").first.fetch("deletions")
    frozen = JSON.generate(first)

    store.capture(run_public_id: "second")
    write("file.txt", "second reply\n")
    second = store.review(run_public_id: "second")
    assert_includes second.fetch("files").first.fetch("patch"), "-first reply\n"
    store.prune(retention_days: 0, now: Time.now + 1)
    assert_equal frozen, JSON.generate(first)
    assert_equal frozen, JSON.generate(JSON.parse(frozen))
  end

  def test_empty_reverted_and_uncaptured_runs
    write("same.txt", "same\n")
    store = open_store
    assert_nil store.review(run_public_id: "read-only")
    store.capture(run_public_id: "one")
    assert_empty store.review(run_public_id: "one").fetch("files")
    write("same.txt", "different\n")
    refute_empty store.review(run_public_id: "one").fetch("files")
    write("same.txt", "same\n")
    assert_empty store.review(run_public_id: "one").fetch("files")
  end

  def test_added_deleted_binary_and_mode_changes
    write("delete.txt", "gone\n")
    write("mode.txt", "same\n")
    store = open_store
    store.capture(run_public_id: "one")
    File.unlink(File.join(@root, "delete.txt"))
    File.chmod(0o755, File.join(@root, "mode.txt"))
    write("added.txt", "<script>literal</script>\n")
    write("binary.dat", "\x00\xFF".b)
    rows = store.review(run_public_id: "one").fetch("files").to_h { |row| [row.fetch("path"), row] }
    assert_equal "D", rows.fetch("delete.txt").fetch("status")
    assert_equal 1, rows.fetch("delete.txt").fetch("deletions")
    assert_equal "A", rows.fetch("added.txt").fetch("status")
    assert_equal 1, rows.fetch("added.txt").fetch("additions")
    assert_equal "binary", rows.fetch("binary.dat").fetch("state")
    assert_includes rows.fetch("mode.txt").fetch("patch"), "new mode 100755"
  end

  def test_large_reports_are_bounded_without_claiming_omitted_patches_are_empty
    store = open_store
    store.capture(run_public_id: "one")
    4.times { |i| write("#{i}.txt", Array.new(1800) { |n| "line #{n}\n" }.join) }
    write("large.txt", "x" * 40_000)
    document = store.review(run_public_id: "one")
    assert_operator JSON.generate(document).bytesize, :<=, 48 * 1024
    assert_equal 5, document.fetch("files").length
    assert document.fetch("files").any? { |file| file.fetch("state") == "too_large" }
    assert document.fetch("files").any? { |file| file.fetch("state") == "omitted" }
    assert document.fetch("files").any? { |file| file.fetch("state") == "text" }
  end
end
