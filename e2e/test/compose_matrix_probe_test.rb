$LOAD_PATH.unshift File.expand_path("..", __dir__)

require "json"
require "mini_racer"
require "minitest/autorun"
require "support/bench_client"
require "support/bench_records"
require "support/compose_bench"

# A screen's job is watched per draw: its progress reaches the log as each draw finishes.
$stdout.sync = true

# CAN A WEAK MODEL WRITE THE SHAPE IT WAS ASKED FOR? The text rows — the shipped `compose` bytes and
# any re-cut beside them (`Rows`) — under each STYLE of `task`/`ask` spelling beside compose
# (`Styles`: the baseline alone by default) — on the two weak models the product runs, on objectives
# whose prompts state a task and never the script, three samples each, one repair per refused
# sample. Two scorers on every sample: VALID-FIRST (the shipped evaluator accepted the script and
# every tool it names is declared) and CORRECT-SHAPE (the written-order lowering of what it wrote
# equals the objective's hand-written picture: the edge set and every model step's reads, exactly).
# Failures are grouped by error string first.
#
# It is a MEASUREMENT: every assertion is about the harness collecting
# data. The gate (>= 2/3 on both scorers per gate objective on each weak
# model, the control at 0) is written into the readout, where a human
# reads it — a red build says nothing about the code when the finding is
# "this model cannot write JavaScript".
#
# LEG (2026-09-13; B49's cross-model regression leg, run ONCE as the exit of the `task` text's one
# benched re-cut — the runner names out of the kernel bytes, the step/conversation line, the
# first-message worked example on `task`/`spawn`): the shipped R-WO row unchanged, the re-cut `task`
# entry beside it through `Styles::PLAIN`, on the tier set z-ai/glm-5.3 + moonshotai/kimi-k3 at the
# 16,384 cap against a SAME-DAY baseline of the committed bytes (a detached-HEAD worktree, no
# world); the floors re-measured into the fixtures (read-only in judgment; the deepseek-v4-flash
# checkpoint changed 09-10, so its old cells were history). The writer (W) ran nexus / claude /
# nexus+claude, the verifier (V) nexus / codex plus the contested kimi O4 cells; n=3 a draw, pooled
# where two draws exist. valid-first / correct-shape, baseline → re-cut; O5 is the control (compose
# 0 in every cell, both ways).
#
# glm-5.3 nexus O1 3/3 → 3/3 (W) 3/3 (V) · O2 3/3 → 3/3 (W) 3/2 (V) · O4 3/0 → 3/1 (W) 3/2 (V)
# glm-5.3 claude (W) O1 3/3 → 3/3 · O2 3/2 → 3/3 · O4 2/1 → 3/1 glm-5.3 nexus+claude (W) O1 3/3 →
# 3/3 · O2 3/1 → 3/3 · O4 3/2 → 2/2 (the miss = `finish length` at the cap) glm-5.3 codex (V) O1 3/3
# → 3/3 · O2 3/1 → 3/3 · O4 3/2 → 3/2 kimi-k3 nexus O1 3/3 → 3/3 (W, V) · O2 3/3 → 3/3 (W, V) · O4
# shape 6/9 → 7/12 (baseline W 4/6 + V 2/3; re-cut W 2/6 + V 5/6) kimi-k3 claude (W) O1 3/3 → 3/3 ·
# O2 3/3 → 3/3 · O4 shape 5/6 → 5/6 kimi-k3 nexus+claude O1 3/3 → 3/3 · O2 3/3 → 3/3 · O4 shape 6/6
# (W) → 6/9 (W 4/6 + V 2/3) kimi-k3 codex (V) O1 3/3 → 3/3 · O2 3/3 → 3/3 · O4 3/3 → 3/2 T5 (not a
# gate objective): glm 2/0 → 0/0 nexus (`finish length` at the cap ×3), 1/0 → 1/0 claude; kimi 3/2 →
# 3/2 nexus, 3/1 → 3/1 claude.
#
# The reading. valid-first holds at 3/3 on every gate objective of every strong-tier cell, both
# ways; no alias inside any script on a claude cell (zero refusals); the codex cell (plain `task`,
# no ask) is flat or up. Correct-shape moved by ≤1 per n=3 cell everywhere, with both signs: glm O4
# rose (0/3 → 3/6 pooled), kimi O4 read 4/6 → 2/6 in the writer's draw and 2/3 → 5/6 in the
# verifier's (6/9 → 7/12 pooled — noise, not a text effect); the one consistent-sign cell is kimi
# nexus+claude O4 (3/3, 3/3 → 2/3, 2/3, 2/3; buckets `extra_steps` / `over_sync` / `over_read`), and
# the writer's isolation cell (the re-cut minus the two worked examples, n=6) read the baseline's
# numbers there — a ≤1 swing the verdict rule cannot read, recorded in the ledger as the example's
# one possible cost. Floors on the fixtures: deepseek-v4-flash nexus O2 valid-first 0/3
# (`handle_throw` ×3 — the new checkpoint's own; claude/codex 3/3), glm-5.3-flash gate objectives
# 3/3 valid-first under all three styles, O4 shape 2/3, 3/3, 2/3 — recorded, never tuned for.
#
# E2E_LIVE=1 RAILS_ENV=development rake live_compose_matrix E2E_BENCH_ROWS=R-LADDER
# E2E_BENCH_MODELS=deepseek/deepseek-flash E2E_BENCH_OBJECTIVES=O1,O5 … # a subset; models are
# catalog refs, each on the lane its provider segment names (the evals' floor when none is named)
# E2E_BENCH_STYLES=nexus,claude,codex,nexus+claude # the style axis; `nexus` is the same-day
# baseline E2E_BENCH_CANDIDATES=<row>/<id> # a lead_hints candidate #
# per row (e2e/evals/candidates/), its line after SYSTEM on the # models its row covers; the
# readout keys the cell by `candidate` E2E_BENCH_DIR=/path/to/bench # the readout's home
# E2E_BENCH_MAX_OUTPUT_TOKENS=16384 # one cap for the run E2E_BENCH_CAPTURES_DIR=/path/to/captures #
# the captures' home: the nexus fixtures unless named — a stronger # tier's run points it at its
# bench dir so its cells never land
#
# AS A SCREEN'S JOB (`bin/screen`, `E2E::Screen::Job#env`): E2E_BENCH_SAMPLE_FIRST numbers this
# job's draws from its first sample (a cell split by sample halves); every draw is appended to the
# record stream the moment it is scored (`E2E::BenchRecords`); E2E_BENCH_BLIND=1 prints only which
# draw finished and leaves the report to the launch's last act, so nothing a watcher reads mid-run
# carries an outcome; E2E_BENCH_CLIENT=fake draws through the fake transport, unpaid.
#
# Paid, local, opt-in.
class ComposeMatrixProbeTest < Minitest::Test
  ROWS = ENV.fetch("E2E_BENCH_ROWS", E2E::ComposeBench::Rows.ids.join(",")).split(",")
    .map { |id| E2E::ComposeBench::Rows.find(id) }.freeze
  OBJECTIVES = ENV.fetch("E2E_BENCH_OBJECTIVES", E2E::ComposeBench::Objectives.ids.join(",")).split(",")
    .map { |id| E2E::ComposeBench::Objectives.find(id) }.freeze
  # Each model ref on the lane it names, resolved before anything is paid: a ref the catalog does
  # not name is refused here, and the gate checks every key the run will read.
  ROUTES = E2E::ComposeBench::WEAK_MODELS.to_h { |ref| [ref, E2E::BenchClient.route(ref)] }.freeze
  STYLES = E2E::ComposeBench::STYLES
  SAMPLES = E2E::ComposeBench::SAMPLES
  FIRST = Integer(ENV.fetch("E2E_BENCH_SAMPLE_FIRST", "1"))
  BLIND = ENV["E2E_BENCH_BLIND"] == "1"
  # Per model: its candidate cells, else the one baseline cell (nil).
  CELLS = E2E::ComposeBench::CELLS

  def test_the_matrix
    E2E::BenchClient.gate(ENV, key_names: ROUTES.values.map { |route| route.lane.key_name }.uniq)
    samples = ROWS.flat_map do |row|
      ROUTES.flat_map do |model, route|
        client = E2E::BenchClient.for(route)
        CELLS.fetch(model).flat_map do |candidate|
          STYLES.flat_map do |style|
            probe = E2E::ComposeBench::Probe.new(client: client, route: route, row: row, style: style, candidate: candidate)
            OBJECTIVES.flat_map do |objective|
              (FIRST...(FIRST + SAMPLES)).map do |index|
                E2E::BenchRecords.append(ENV["E2E_BENCH_DIR"], probe.sample(objective, index)).tap { |sample| puts progress(sample) }
              end
            end
          end
        end
      end
    end
    unless BLIND
      E2E::ComposeBench::Report.write_all(samples)
      puts "\nreadout: #{E2E::ComposeBench::Report.bench_dir}"
    end

    # THE ONLY GATE IS THE HARNESS: every cell scored, none lost.
    assert_equal ROWS.length * CELLS.values.sum(&:length) * STYLES.length * OBJECTIVES.length * SAMPLES, samples.length
    assert samples.all? { |sample| sample.key?("reached") || sample.key?("compose_zero") }, "a sample was not scored"
    assert_empty E2E::BenchRecords.faults(samples), "the harness itself failed on a sample (a first or a repair call)"
  end

  private

    def progress(sample)
      return E2E::BenchRecords.progress_line(sample) if BLIND

      verdict = if sample["compose_zero"] then "compose 0"
      elsif !sample["reached"] then "no compose (#{sample["error"] || sample["called"].inspect})"
      elsif sample["first_time_right"] then "exact"
      elsif sample["valid_first"] then "valid, #{Array(sample["silent"]).join(",")}"
      else "refused #{sample["loud"]}#{sample["repaired"] ? " → #{sample["repaired"]}" : ""}"
      end
      format("%-7s %-30s %-12s %-6s #%d  %s%s", sample["row"], sample["model"], sample["style"], sample["objective"],
        sample["sample"], verdict, sample["candidate"] ? "  [#{sample["candidate"]}]" : "")
    end
end
