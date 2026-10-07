$LOAD_PATH.unshift File.expand_path("..", __dir__)

require "json"
require "minitest/autorun"
require "support/bench_client"
require "support/bench_records"
require "support/task_bench"

# A launcher reads this process's lines as they are written, never at exit.
$stdout.sync = true

# CAN A WEAK MODEL USE THE FLAT TOOLS? The set a rho turn really declares — the runner's tools, then
# `code`/`task`/`ask` and the memory verbs, under each STYLE of `task`/`ask` spelling (`nexus`,
# `claude`'s `Agent`, `codex`'s `spawn_agent`; the baseline alone by default) — with rho's own
# instructions block, on the two weak models, scoring ONE emitted message by property: gate 0 (two
# calls in one message at all), T2 (the suite as a `task` call without `wait: true` beside a direct
# lint call — the cross-turn half of this objective runs through rho in `live_task_mail`), and the
# full-set over-reach control (three greps: no `task`, two calls in one message), and
# the SP rows (the `spawn`/`send`/`status`/`cancel` texts by property, including `status` beside
# `<task_result status=…>`). Delegation is the mail lane's `fan` objective.
#
# A MEASUREMENT: the assertions are about the harness; the readout
# carries the verdict a human reads.
#
# THE FRAME IS TWO-STEP (`TaskBench::Sample`): a message whose every call is a read is answered
# from the objective's fixture and the next message asked, up to three; the first message that is
# not all reads is the one scored, three read-only messages are a scout, and G0, the control and
# TT3 — whose right answer IS reads — are scored on their first message. The historical results
# below were read on the one-message frame, whose limit "the reading" names.
#
# These cells measure the conversation-tool descriptions independently from the execution journeys.
# Strong-tier samples inform wording choices; floor samples are observations and do not drive
# tuning. Compare only runs with the same prompt bytes, declaration set, frame and sampling count;
# historical draws remain separate recorded evidence.
#
# 09-12 (frozen texts, nexus) | glm-5.3 | kimi-k3 | deepseek-v4-flash | glm-5.3-flash | | SP0
# subagent-no-agent | 0/3 | 0/3 | 0/3 | 0/3 | | SP1 peer-by-handle | 3/3 | 3/3 | 3/3 | 2/3 | | SP2
# steer-going-wrong | 3/3 | 3/3 | 1/3 | 3/3 | | SP3A one-shot-review-is-a-task | 0/3 | 2/3 | 0/3 |
# 0/3 | | SP3B persistent-reviewer-is-a-spawn | 0/3 | 0/3 | 0/3 | 0/3 | | SP4 no-status-polling |
# 3/3 | 3/3 | 2/3 | 0/3 | | SP5 status-beside-task-result | 3/3 | 3/3 | 3/3 | 3/3 |
#
# Historical result, strong tier (W+V pooled, /6) | glm nexus | glm claude | glm codex | kimi nexus
# | kimi claude | kimi codex | | SP0 | 6/6 | 6/6 | 6/6 | 6/6 | 6/6 | 6/6 | | SP1 | 6/6 | 6/6 | 6/6 |
# 6/6 | 6/6 | 6/6 | | SP2 | 6/6 | 5/6 | 6/6 | 6/6 | 6/6 | 6/6 | | SP3A | 6/6 | 6/6 | 6/6 | 6/6 | 6/6
# | 5/6 | | SP3B | 6/6 | 6/6 | 6/6 | 6/6 | 6/6 | 6/6 | | SP4 | 6/6 | 6/6 | 6/6 | 6/6 | 6/6 | 6/6 | |
# SP5 | 6/6 | 6/6 | 6/6 | 6/6 | 6/6 | 6/6 |
#
# Historical result, floors (nexus; W / V) | deepseek-v4-flash | glm-5.3-flash | | SP0 | 3/3 / 0/3 |
# 3/3 / 3/3 | | SP1 | 2/3 / 2/3 | 3/3 / 3/3 | | SP2 | 3/3 / 2/3 | 3/3 / 3/3 | | SP3A | 0/3 / 0/3 |
# 2/3 / 2/3 | | SP3B | 0/3 / 0/3 | 1/3 / 2/3 | | SP4 | 3/3 / 3/3 | 3/3 / 3/3 | | SP5 | 3/3 / 3/3 |
# 3/3 / 3/3 |
#
# G0 / T2 / T5 (nexus), same-day baseline → re-cut (W+V pooled, /6): glm-5.3: 6/6 → 6/6 · 3/6 → 6/6
# · 5/6 → 3/6; kimi-k3: 6/6 → 6/6 · 0/6 → 3/6 · 4/6 → 6/6
#
# The reading. The zeros of 09-12 were ONE shape — the model LOOKS FIRST
# (`bash`/`ls`/`find` over the project) and spawns or delegates in a
# later message the single-message frame never sees — and the worked
# example ("Delegate from what the person told you, in your FIRST
# message … beside your own part") moved that shape: SP0, SP3A and SP3B
# read 0/3 → 6/6 on both strong models under every style, the
# task-vs-spawn line now DRAWN (one review pass → `task`, the hour of
# diffs → `spawn`) where 09-12 left it unmeasured. Nothing that held
# fell: SP1/SP2/SP4/SP5 stay at the ceiling (glm claude SP2 5/6 — one
# `status` read before the `send`; kimi codex SP3A 5/6 — one `finish
# stop`); codex's `target` spelling steers 6/6 on both. T2 rose on both
# (the `start_process` fact now in rho's guideline under rho's own name:
# glm 3/6 → 6/6, kimi 0/6 → 3/6 — kimi still reaches for `start_process`
# in half its draws, a standing reach problem); T5 (the over-reach
# control) is noise with opposite signs (glm 5/6 → 3/6 on single-grep
# messages, kimi 4/6 → 6/6). Floors, read-only: glm-5.3-flash rose on
# SP0 (0 → 3/3 twice) and SP4 (0 → 3/3 twice); deepseek-v4-flash (the
# new checkpoint) looks first on SP0 in one draw of two and on SP3A/SP3B
# in both — the frame's limit stands there, recorded.
#
# E2E_LIVE=1 RAILS_ENV=development rake live_task_probe
# E2E_BENCH_MODELS=deepseek/deepseek-flash E2E_TASK_OBJECTIVES=G0,T2 … # a subset; models are
# catalog refs, each on the lane its provider segment names (the evals' floor when none is named)
# E2E_BENCH_STYLES=nexus,claude,codex # the style axis
# E2E_BENCH_CANDIDATES=<row>/<id> # a lead_hints / tool_descriptions #
# candidate per row (e2e/evals/candidates/): a hint after the # tool lines, an entry in the set,
# on the models its row covers
# E2E_BENCH_SAMPLES=5 E2E_BENCH_SAMPLE_FIRST=6 # the draws per objective (three) and the first
# index (one): a job split by sample halves numbers its half after the other's
# E2E_BENCH_DIR=/path/to/bench # the records' and the readout's home: every draw appended to
# records.jsonl as it lands, every call's heartbeat to calls.jsonl (`E2E::BenchRecords`)
# E2E_BENCH_BLIND=1 # a screen's job: the progress line names no outcome and the readout is
# written from the records after every job is done, not here
# E2E_BENCH_CLIENT=fake # the fake transport (`E2E::BenchClient`): no key is read, no call is paid
#
# Paid, local, opt-in.
class TaskMatrixProbeTest < Minitest::Test
  MODELS = E2E::TaskBench::WEAK_MODELS
  STYLES = E2E::TaskBench::STYLES
  # Per model: its candidate cells, else the one baseline cell (nil).
  CELLS = E2E::TaskBench::CELLS
  OBJECTIVES = ENV.fetch("E2E_TASK_OBJECTIVES", E2E::TaskBench::Objectives.ids.join(",")).split(",")
    .map { |id| E2E::TaskBench::Objectives.find(id) }.freeze

  # Each model ref on the lane it names, resolved before anything is paid.
  ROUTES = MODELS.to_h { |ref| [ref, E2E::BenchClient.route(ref)] }.freeze
  BLIND = ENV["E2E_BENCH_BLIND"] == "1"
  DIR = E2E::TaskBench::Report.bench_dir
  # A screen's job names its stream's directory; a run outside a screen writes none.
  STREAM = ENV["E2E_BENCH_DIR"]

  def test_the_task_matrix
    # The one paid gate; the fake transport pays nothing and reads no key.
    E2E::BenchClient.gate(ENV, key_names: ROUTES.values.map { |route| route.lane.key_name }.uniq)
    sets = STYLES.product(CELLS.values.flatten.uniq).to_h do |style, candidate|
      declared = E2E::TaskBench::DeclaredSet.function_definitions(style: style, candidate: candidate)
      puts "declared (#{style}#{candidate ? ", #{candidate.key}" : ""}): " \
           "#{E2E::TaskBench::DeclaredSet.names(style: style, candidate: candidate).join(" ")} " \
           "(#{JSON.generate(Nexus::ToolDeclarations.wire(declared)).bytesize} bytes on the wire)"
      [[style, candidate], declared]
    end
    heartbeat = ->(facts) { E2E::BenchRecords.heartbeat(STREAM, facts) }
    samples = ROUTES.flat_map do |model, route|
      client = E2E::BenchClient.for(route)
      CELLS.fetch(model).flat_map do |candidate|
        STYLES.flat_map do |style|
          OBJECTIVES.flat_map do |objective|
            objective.indices.map do |index|
              drawn = E2E::TaskBench::Sample.call(client: client, route: route, style: style, candidate: candidate,
                objective: objective, index: index, declared: sets.fetch([style, candidate]), heartbeat: heartbeat)
              E2E::BenchRecords.append(STREAM, drawn).tap { |s| puts progress(s) }
            end
          end
        end
      end
    end
    # A blind job's readout is written from the records once every job is done.
    unless BLIND
      E2E::TaskBench::Report.write_offline(samples, dir: DIR)
      puts "\nreadout: #{DIR}"
    end

    # THE ONLY GATE IS THE HARNESS: every draw scored, none lost to the harness's own fault.
    assert_equal CELLS.values.sum(&:length) * STYLES.length * OBJECTIVES.sum { |objective| objective.indices.size }, samples.length
    assert samples.all? { |s| s.key?("pass") }, "a sample was not scored"
    assert_empty E2E::BenchRecords.faults(samples), "the harness itself failed on a draw (a call, a read answered, a scoring)"
  end

  private

    # BLIND, the line names the draw alone (`BenchRecords.progress_line`, the line the watch counts)
    # — no pass, no call, no message count: a watcher must not read outcomes while the jobs run.
    def progress(sample)
      if BLIND
        E2E::BenchRecords.progress_line(sample)
      else
        format("%-30s %-12s %-4s #%-2d %s  %s%s%s", sample["model"], sample["style"], sample["objective"], sample["sample"],
          sample["pass"] ? "PASS" : "FAIL", (sample["called"] || sample["error"]).inspect,
          sample["finish"] ? " (finish #{sample["finish"]})" : "", sample["candidate"] ? "  [#{sample["candidate"]}]" : "")
      end
    end
end
