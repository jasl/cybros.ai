# Evaluation harness

The suite measures how a model uses Nexus through rho: whether it reaches for a capability,
whether that use succeeds, whether the task passes, how much work and money it spends, and whether
it follows the task's instructions. Deterministic predicates read the kernel trace; hidden verifiers
check the work. These are separate dimensions, so a correct result can still expose a missed shape.

The [evaluation runbook](../../docs/evals-runbook.md) covers prerequisites, selection, budgets,
artifacts, failure classification, and historical experiments. Current selection and limits live in
`bench.yml`; a record's `bench_digest` identifies the exact configuration bytes used for that run.

## Layout

```
evals/
  bench.yml                 model tiers, runs per task, tool styles, deadlines and spend thresholds
  candidates/<row>.yml      harness-only model adaptation candidates, never in the SDK (none on file)
  tasks/<family>-<name>/
    instruction.md          YAML front-matter and the model's instruction, ending with the canary
    environment/            initial files (optional)
    environment.rb          generated files from a Seed (optional)
    verification.rb         hidden lambda: (project, seed) -> {pass:, output:}
    expected.rb             reach, success, conduct, and facts over a Trace
    RATIONALE.md            what the task measures and how to interpret failures
  lane_test.rb              paid runner; every selected run must leave a record
  analysis/                 reviewed historical conclusions, not regression inputs
  docker/Dockerfile         task-base image with the same rho installer used on the host
```

Support under `e2e/support/evals/` loads tasks, builds the run plan, drives rho, reads traces, and
writes records and scorecards. `ReportLine` formats the shared one-line result. `SealedRequest`
reads the last completed round's request. `WorldLog` copies and redacts each run's logs. Trace JSON,
sealed requests, Markdown diagrams, and logs are local evidence under `e2e/artifacts/evals/<label>/`.
Run records, generated scorecards and their ledger live under
`e2e/artifacts/evals/runs/`. Temporary analysis, captured fixtures and retired
experiment scripts live under `e2e/artifacts/evals/analysis/`; these artifacts
are ignored by Git and may contain private provider or environment output.
Commit only a reviewed written conclusion or a small authored behavior fixture.
Default regression tests build their own inputs and do not consume paid runs.

External corpora are not vendored. `E2E_EVALS_TB_CORPUS` names a checkout of the pinned
`terminal-bench@2.0` dataset; `E2E_EVALS_RAILS_CORPUS` names an Agents-on-Rails checkout. Sample
fixtures under `support/fixtures/` exercise those loaders without fetching or running the corpora.

## Running and selecting

```sh
cd e2e
bundle exec rake evals_tasks                                    # list tasks; no world boot
E2E_LIVE=1 bundle exec rake "evals[shape-*,deepseek/deepseek-flash]" # paid
bundle exec rake "evals_scorecard[<label>]"                       # no world boot
bundle exec rake "evals_rescore[<label>,<task-glob>]"              # stored traces only
bundle exec rake evals_ledger                                   # no world boot
```

`E2E_EVALS_TASKS` matches a task name or `family/name`; `E2E_EVALS_MODELS`, `E2E_EVALS_STYLES`, and
`E2E_EVALS_RUNS` narrow the configured matrix. They cannot add an unknown model or style.
`E2E_EVALS_LABEL` names the dated output directory; `E2E_EVALS_RUNS_DIR` changes its parent.
The default style is the first configured style. `nexus` and `claude` create local adaptation
rows; `pack` uses the SDK's model-specific row through `adaptations: auto`.

`E2E_EVALS_CANDIDATE=<row>/<id>` selects one existing harness candidate under `pack` alone, on the
candidate's strong-tier models; with no candidate on file every key is refused by name. The lane
combines it with the matching SDK row in a local override; the plan and each record name that
candidate. Candidates do not alter the installed SDK.

One invocation uses one isolated world, with a daemon per configuration. Run evaluations serially,
separate from the mock E2E gate, other live lanes, and Nexus tests, to stay within Postgres capacity.
A paid failure is recorded rather than turned into a final test assertion; the lane asserts that
all selected runs produced records.

## Task families

Use `rake evals_tasks` for the full current inventory and per-task restrictions.

| Family | What is measured | Driver or verification |
|---|---|---|
| `shape` | Linear, fan/join, human question, halt/retry, and repeated-call brake shapes | Graph predicates; scripted human actions where required |
| `task` | Delegation, fan-out, detached receipts, and later-turn use | Tool rows plus recorded receipt and turn facts; `task-fan-five` reads its merge at a quiet conversation (`settle_receipts`) |
| `workflow` | Fan-out, verification, judging, pipelines, and repeated receipt-driven work | `settle_receipts` waits for a quiet conversation |
| `compaction` | Work surviving pruning or summarization; pointer discipline | Manual compaction or generated byte-wall tasks |
| `exit` | Coding task acceptance at three sizes | Hidden verification after restoring graded files |
| `spawn` | Child replies and peer delegation | `spawn_reply`; peer provisioning currently uses the separate `live_spawn` lane |
| `approval`, `until`, `processes`, `handoff`, `memory`, `ask` | The corresponding platform interactions | Scripted human and runner facts |
| `terminal-bench` | External task acceptance, without a capability-reach score | Upstream `tests/test.sh` and `reward.txt >= 1` |
| `rails` | External Rails task acceptance, without a capability-reach score | Restore, Rails tests, then the upstream verification test |

Task-door classification reads the declared tool names from the run's sealed request, so it evaluates
the set the model actually saw. Direct-provider text probes and these end-to-end evaluations have
different prompts, tool sets, and execution paths; do not pool their results.

## Container families

Each task carries its base image into the daemon configuration. The lane derives an image with rho,
pairs a runner home once, and starts a fresh container over that home for each run. The host's rho
drives the turn through `--runner`; file and process tools execute inside the task container.

Terminal-bench loads the 21 pinned task names in `bench.yml`. The configured default cell is
`deepseek/deepseek-flash`, 3 runs per task. Explicitly selected `openrouter/moonshotai/kimi-k3` or
`openrouter/z-ai/glm-5.3` use the optional cell, also 3 runs. A smoke may narrow the count. Each task
keeps its upstream deadline. Hidden tests are copied in after the turn and run as root with network
access; the model's turn does not receive that test mount. Agents-on-Rails retains its own
instruction, canary, deadline, environment patch, and verifier.

The runbook explains image builds, pairing, stop thresholds, and verifier artifacts. A build failure
or stop still produces a record. Neither container family claims comparability with published
scores from another agent, prompt, checkpoint, or pricing setup.

## Adding a task

Start from a sibling's layout and explain the task in `RATIONALE.md`. The loader checks required
front-matter, the driver, the canary, the `Expected` object, and the verifier signature. The verifier
runs after `restore:` files are restored, so editing the acceptance criteria cannot earn a pass.

Add a drawn green trace and a drawn red trace in `test/evals_drawings.rb` and pin both in
`test/evals_expected_test.rb`. Predicates describe structure and observable results: kinds, edges,
join modes, error keys, tool names, and input fields. Round counts and fan widths are measurements,
not substitute pass conditions. Run the relevant pure harness tests and RuboCop; a new paid result
requires an explicit evaluation run and its own records.
