require "test_helper"
require "support/evals"
require "tmpdir"

# THE RUNS LEDGER'S ROWS, PINNED: one JSON line appended per run; read back merged with the NEWER
# line winning on the same (task, model, style, run) key — `TaskBench::Report.merge_live`'s shape;
# an unparseable line (a lane that died mid-write) is skipped, never a crash; `read_all` lists every
# label with a ledger, oldest first.
class EvalsRecordsTest < Minitest::Test
  D = E2E::Evals::Drawing
  R = E2E::Evals::Records

  def test_append_writes_one_line_per_record_and_read_merges_newer_wins
    Dir.mktmpdir("evals-records") do |root|
      run_dir = File.join(root, "2026-09-10-smoke")
      R.append(run_dir, D.record(run: 1, seconds: 10))
      R.append(run_dir, D.record(run: 2, seconds: 20))
      assert_equal 2, File.readlines(R.path(run_dir)).size
      assert_equal [1, 2], R.read(run_dir).map { |row| row["run"] }

      R.append(run_dir, D.record(run: 1, seconds: 99, succeeded: false))
      assert_equal 3, File.readlines(R.path(run_dir)).size, "append never rewrites"
      merged = R.read(run_dir)
      assert_equal [1, 2], merged.map { |row| row["run"] }
      assert_equal 99, merged.first["seconds"], "the newer record on the same key wins"
      assert_equal false, merged.first.dig("verdict", "succeeded")

      R.write(run_dir, merged)
      assert_equal 2, File.readlines(R.path(run_dir)).size, "a compacted rewrite"
      assert_equal merged, R.read(run_dir)
    end
  end

  # ONE LABEL IS ONE BENCH: a label's rows are read as one column under one digest, so a record run
  # under another bench is refused where it is written (the lane, a harbor import, a re-score) with
  # the scorecard's own sentence, and nothing of it reaches the file.
  def test_append_refuses_a_record_under_another_bench_digest
    Dir.mktmpdir("evals-records") do |root|
      run_dir = File.join(root, "2026-09-10-smoke")
      R.append(run_dir, D.record(run: 1))
      error = assert_raises(ArgumentError) { R.append(run_dir, D.record(run: 2, bench_digest: "e" * 64)) }
      assert_match(/records\.jsonl mixes bench digests \["d{64}", "e{64}"\]: split the label/, error.message)
      assert_equal 1, File.readlines(R.path(run_dir)).size, "the refused record wrote nothing"
      R.append(run_dir, D.record(run: 2))
      assert_equal [1, 2], R.read(run_dir).map { |row| row["run"] }, "the label's own digest still appends"
      R.append(File.join(root, "2026-09-10-other"), D.record(run: 1, bench_digest: "e" * 64))
      assert_equal ["e" * 64], R.read(File.join(root, "2026-09-10-other")).map { |row| row["bench_digest"] }, "a new label takes any digest"
    end
  end

  def test_the_key_is_task_model_style_run_and_merge_keeps_the_last
    older = [D.record(run: 1), D.record(run: 2)]
    newer = [D.record(run: 2, seconds: 5), D.record(style: "workflow", run: 2)]
    merged = R.merge(older, newer)
    assert_equal [["shape-linear", "fixture/strong", "nexus", 1], ["shape-linear", "fixture/strong", "nexus", 2],
                  ["shape-linear", "fixture/strong", "workflow", 2]], merged.map { |row| R.key(row) }
    assert_equal 5, merged[1]["seconds"]
  end

  def test_an_unparseable_line_is_skipped_and_a_missing_file_reads_empty
    Dir.mktmpdir("evals-records") do |root|
      run_dir = File.join(root, "2026-09-10-torn")
      R.append(run_dir, D.record(run: 1))
      File.open(R.path(run_dir), "a") { |file| file.write("{\"task\": \"shape-linear\", \"mod") }
      _out, err = capture_io { assert_equal [1], R.read(run_dir).map { |row| row["run"] } }
      assert_match(/an unparseable line .* was skipped/, err)
      assert_empty R.read(File.join(root, "2026-09-10-absent"))
    end
  end

  def test_read_all_lists_every_label_with_a_ledger_oldest_first
    Dir.mktmpdir("evals-records") do |root|
      R.append(File.join(root, "2026-09-11-b"), D.record(run: 1))
      R.append(File.join(root, "2026-09-10-a"), D.record(run: 1))
      FileUtils.mkdir_p(File.join(root, "2026-09-12-empty"))
      assert_equal %w[2026-09-10-a 2026-09-11-b], R.read_all(root).keys
      assert_equal({}, R.read_all(File.join(root, "absent")))
    end
  end
end
