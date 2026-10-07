require "test_helper"
require "evals_fixture_bench"
require "support/evals"
require "evals_drawings"
require "tmpdir"

# THE TREND TABLE, PINNED: rows = (family, task, model, style), one column per dated label, the cell
# `r<reached>/<runs> s<succeeded>/<reached> p<passed>/<verified>`; a bench digest change is a new
# table with its own heading — the rule across the table; the flash floor's rows are marked
# read-only; the file is written beside the labels.
class EvalsLedgerTest < Minitest::Test
  include EvalsFixtureBench
  D = E2E::Evals::Drawing
  L = E2E::Evals::Ledger
  BENCH = EvalsFixtureBench.read

  def test_two_labels_become_two_columns_and_the_floor_is_marked_read_only
    Dir.mktmpdir("evals-ledger") do |runs_dir|
      first = File.join(runs_dir, "2026-09-10-smoke")
      second = File.join(runs_dir, "2026-09-11-strong")
      [D.record(run: 1), D.record(run: 2, succeeded: false, task_pass: false),
       D.record(model: "fixture/floor", run: 1, reached: false, succeeded: nil, task_pass: false)]
        .each { |record| E2E::Evals::Records.append(first, record) }
      [D.record(run: 1), D.record(run: 2), D.record(run: 3, task_pass: nil),
       D.record(task: "task-background-suite", family: "task", run: 1, task_pass: nil)]
        .each { |record| E2E::Evals::Records.append(second, record) }

      text = L.write(runs_dir, bench: BENCH)
      assert_equal text, File.read(File.join(runs_dir, "LEDGER.md"), encoding: Encoding::UTF_8)
      assert_includes text, "# evals ledger"
      assert_includes text, "## bench `#{"d" * 12}` — 2026-09-10-smoke, 2026-09-11-strong"
      assert_includes text, "| family | task | model | style | 2026-09-10-smoke | 2026-09-11-strong |"
      assert_includes text, "| shape | shape-linear | fixture/strong | nexus | r2/2 s1/2 p1/2 c— | r3/3 s3/3 p2/2 c— |"
      assert_includes text, "| shape | shape-linear | fixture/floor (floor, read-only) | nexus | r0/1 s0/0 p0/1 c— | · |"
      assert_includes text, "| task | task-background-suite | fixture/strong | nexus | · | r1/1 s1/1 p— c— |"
      assert_includes text, E2E::Evals::Scorecard::BENCH_SCOPE
    end
  end

  def test_a_bench_digest_change_draws_a_rule_across_the_table
    Dir.mktmpdir("evals-ledger") do |runs_dir|
      E2E::Evals::Records.append(File.join(runs_dir, "2026-09-10-a"), D.record(run: 1))
      E2E::Evals::Records.append(File.join(runs_dir, "2026-09-12-b"), D.record(run: 1, bench_digest: "e" * 64))
      E2E::Evals::Records.append(File.join(runs_dir, "2026-09-13-c"), D.record(run: 1, bench_digest: "e" * 64))
      text = L.render(runs_dir, bench: BENCH)
      sections = text.scan(/^## bench `(\w+)` — (.+)$/)
      assert_equal [["d" * 12, "2026-09-10-a"], ["e" * 12, "2026-09-12-b, 2026-09-13-c"]], sections
      assert_equal 2, text.scan(/^\| family \| task \| model \| style \|/).size, "one table per digest"
    end
  end

  def test_an_empty_runs_dir_says_how_to_write_the_first_run
    Dir.mktmpdir("evals-ledger") do |runs_dir|
      text = L.render(runs_dir, bench: BENCH)
      assert_includes text, L::EMPTY
      assert_includes L.render(File.join(runs_dir, "absent"), bench: BENCH), L::EMPTY
    end
  end

  def test_the_cell_reads_reach_success_and_pass_off_the_verdicts
    assert_equal "·", L.cell([])
    assert_equal "r1/2 s1/1 p— c—", L.cell([D.record(task_pass: nil), D.record(reached: false, succeeded: nil, task_pass: nil)])
    # A family with no reach dimension: the two predicate counts read `—`, task pass as it is.
    assert_equal "r— s— p1/2 c—", L.cell([D.record(reached: nil, succeeded: nil, task_pass: true), D.record(reached: nil, succeeded: nil, task_pass: false, run: 2)])
    assert_equal "r2/2 s1/2 p1/2 c—", L.cell([D.record, D.record(succeeded: false, task_pass: false)])
  end

  # THE CACHE TOKEN (read after round 1): the cell's median hit rate over the mainline's rounds 2..n as
  # ` c<median>`, the same number as the scorecard's headline column, over the records that carry
  # the per-round series; `c—` when none — a record carrying the loop-total rate alone (the 12a/12b
  # columns) is not read — so a family's prefix-cache trend reads across labels beside its pass.
  def test_the_cell_carries_the_cache_median_after_round_1_and_the_legend_names_it
    warm = D.record(efficiency: { "rounds" => 6, "cache_hit_rate" => "0.6",
                                  "cache_read_series" => { "r1" => [1000, 0], "r2" => [1000, 900], "r3" => [1000, 900] } })
    cold = D.record(run: 2, efficiency: { "rounds" => 6, "cache_hit_rate" => 0.9,
                                          "cache_read_series" => { "r1" => [1000, 950], "r2" => [1000, 800], "r3" => [1000, 800] } })
    assert_equal "r2/2 s2/2 p2/2 c0.85", L.cell([warm, cold])
    assert_equal "r3/3 s3/3 p3/3 c0.85", L.cell([warm, cold, D.record(run: 3, efficiency: { "rounds" => 6, "cache_hit_rate" => 0.1 })]),
      "a record with no per-round series is left out of the median: its loop-total is the cost term, never this token"
    Dir.mktmpdir("evals-ledger") do |runs_dir|
      E2E::Evals::Records.append(File.join(runs_dir, "2026-09-16-cache"), warm)
      text = L.render(runs_dir, bench: BENCH)
      assert_includes text, "` c<median>` the cell's median cache hit rate AFTER round 1 (the mainline's rounds 2..n pooled; `c—` when no " \
                            "record carries the per-round series; the bar is the scorecard's `cache under floor`, read against " \
                            "`limits.cache_floor_by_family`)"
      assert_includes text, "| shape | shape-linear | fixture/strong | nexus | r1/1 s1/1 p1/1 c0.9 |"
    end
  end


  # THE FALLBACK'S WORK, APART: a record the answerer's declared fallback served counts toward the
  # model under test only in the `+M` term of `s` — `s<N> (+<M> by fallback)/<reached>` — and the cell
  # marks the steps it served, ` fb<n>` (`facts.refusals_served`, summed); a cell nothing was served
  # in is unchanged, and the legend names both.
  def test_the_cell_splits_the_fallbacks_work_and_marks_the_steps_it_served
    served = ->(run, steps) { D.record(run: run, facts: { "round_errors" => {}, "attention_reasons" => {}, "rounds_settled" => 3,
                                                          "refused_steps" => 0, "refusals_served" => steps }) }
    assert_equal "r3/3 s1 (+2 by fallback)/3 p3/3 fb3 c—", L.cell([served.(1, 0), served.(2, 2), served.(3, 1)])
    assert_equal "r1/1 s1/1 p1/1 c—", L.cell([served.(1, 0)]), "read, none served: unchanged"
    Dir.mktmpdir("evals-ledger") do |runs_dir|
      [served.(1, 0), served.(2, 1)].each { |record| E2E::Evals::Records.append(File.join(runs_dir, "2026-09-26-fallback"), record) }
      text = L.render(runs_dir, bench: BENCH)
      assert_includes text, "`s<N> (+<M> by fallback)/<reached>` counts apart the records whose refused steps the answerer's " \
                            "declared fallback served (the model under test is credited N alone), and ` fb<n>` the steps it served"
      assert_includes text, "| shape | shape-linear | fixture/strong | nexus | r2/2 s1 (+1 by fallback)/2 p2/2 fb1 c— |"
    end
  end

  # THE DISAGREEMENT MARK: a cell carrying records classed `disagreement` says so — ` d<n>` — so a
  # pass column read across labels shows where the two scorers were apart; the class is read live
  # off the record (a label scored before the class existed marks its cells too, its stored class
  # being history); a cell with none is unchanged, and the legend names the mark.
  def test_the_cell_marks_its_disagreements_and_the_legend_names_the_mark
    apart = D.record(task_pass: true, succeeded: false, verdict: { "reached" => true, "succeeded" => false, "task_pass" => true, "class" => "kernel finding" })
    assert_equal "r2/2 s1/2 p2/2 d1 c—", L.cell([D.record, apart]), "the stored class is the old reading; the live one marks it"
    assert_equal "r1/1 s1/1 p1/1 c—", L.cell([D.record])
    Dir.mktmpdir("evals-ledger") do |runs_dir|
      E2E::Evals::Records.append(File.join(runs_dir, "2026-09-12-apart"), apart)
      text = L.render(runs_dir, bench: BENCH)
      assert_includes text, "` d<n>` counts the records classed `disagreement` (task pass and the predicate apart: read, never a stop)"
      assert_includes text, "| shape | shape-linear | fixture/strong | nexus | r1/1 s0/1 p1/1 d1 c— |"
    end
  end
end
