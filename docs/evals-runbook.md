# Evaluation runbook

Use this manual to run the mock E2E gate, select a paid evaluation, and read its records,
scorecards, and failure evidence. The [evaluation harness overview](../e2e/evals/README.md)
describes task authoring and the implementation under `e2e/support/evals/`.
Commands below run from the repository root unless a section says otherwise. Dated results
and estimates are historical observations, not measurements of the current checkout.

Raw model output, generated scripts, run records, scorecards and ledgers are local,
ignored evidence. Commit reviewed conclusions with the measurement conditions and
limitations. Ordinary regression tests use small authored fixtures with fictional
models; only tests of a specific model adaptation or protocol need that model's
name or sample data. Changing the evaluation roster must not require replacing
generic regression fixtures.

## 0. Entry points

| entry | command (from the repo root) | boots a world | paid |
|---|---|---|---|
| the full local gate | `cd e2e && bundle exec rake` | seven groups; 2 or 3 at a time by default | no (the mock provider) |
| product smoke | `cd e2e && bundle exec rake smoke` | one | no (the mock provider) |
| the evals runner | `cd e2e && E2E_LIVE=1 bundle exec rake "evals[<task-glob>,<model>]"` | one | YES |
| the scorecard | `cd e2e && bundle exec rake "evals_scorecard[<label>]"` | none | no |
| the ledger | `cd e2e && bundle exec rake evals_ledger` | none | no |
| the corpus | `cd e2e && bundle exec rake evals_tasks` (mirrors `lemans tasks`; `E2E_EVALS_TB_CORPUS` adds the 21) | none | no |
| a re-score | `cd e2e && bundle exec rake "evals_rescore[<label>,<task-glob>]"` | none | no |

- **The full local gate** runs the seven groups in `e2e/support/journey_groups.rb`. Group 3 includes the
  installation journeys described in §8c. `E2E_WORLDS` overrides concurrency; otherwise
  `WorldSlots.default` selects 3 worlds when Postgres reports `max_connections >= 200`, and 2
  below that threshold or when the query cannot be read. The default Rake task (`bundle exec rake`)
  runs pure Ruby harness tests, the E2E gate, and RuboCop in that order. `rake e2e` refuses to
  start under 1024 open files per process (`ulimit -n 4096` first) and builds the assets once before
  starting the worlds. A skipped installation journey does not verify installation.
- **GitHub CI** runs the [product smoke and harness checks](../e2e/README.md#github-smoke-and-local-acceptance),
  package quality gates, the Nexus API smoke and browser system tests. Complete Nexus/rho suites,
  all E2E worlds and Docker image builds run locally. CI success is a fast regression signal,
  not a substitute for complete local acceptance.
- **The evals runner** takes a glob over task names and a model id, both optional (the whole corpus on
  every tier the tasks name when omitted), sizes the world's patience from the selection (2 × Σ of the
  selected runs' `deadline_seconds` — a red run awaits twice under one deadline — + 900 s of
  boot/teardown slack), boots ONE world, one rho daemon
  per daemon configuration inside it, and appends one record per run. It measures; it never gates —
  the only assertion at the end is that every run left a record.
- **The scorecard** reads one label's `records.jsonl` and writes `scorecard.<model>.md` per model
  beside it. **The ledger** reads every label and writes `runs/LEDGER.md`. Both refuse nothing but a
  mixed bench digest (the scorecard) and print a how-to line when there are no runs (the ledger).
- **A re-score** re-runs a task's `expected.rb` over the traces a label's artifacts stored (a predicate
  fix changes what a record SAYS, never what the model did) and APPENDS one new line per record —
  `rescored: true`, the verdict it replaced beside it — which the merge rule reads as the row; the
  verification's columns ride as recorded, and a record whose artifact is gone is skipped by name (a
  fact the artifact never held cannot be re-scored: that cell is re-run). Then the scorecard and the ledger.

## 1. Prerequisites

1. **Postgres and its ceiling.** One world holds ~27 Postgres connections steady and ~42 at a spike; a
   stock `max_connections` of 100 (97 usable) admits TWO worlds (`e2e/Rakefile:29-57`). So: the gate
   defaults to two worlds on that ceiling; it selects three at `max_connections >= 200` unless
   `E2E_WORLDS` overrides it. The evals lane is ONE world and must NEVER run beside
   `rake e2e`, a live lane, or the nexus test suite — sequence them. A machine whose ceiling is raised
   may set `E2E_WORLDS=3` or `4`: `E2E_WORLDS=4` wants `max_connections` of at least 4 × 42 + 3 reserved =
   171 — set 200 in `postgresql.conf` and restart Postgres. "sorry, too many clients already" as a 500 in
   a world's log is this ceiling, not a defect. Each world's Rails logs are its own files under its run root
   (`RAILS_LOG_FILE`: `rails.log`, `jobs.rails.log`, `model_runner.rails.log`, copied per run as §5's
   `nexus.*.rails.log` windows), so two worlds on ONE checkout never interleave in `nexus/log/development.log` — read
   compaction facts off the artifact's events and the run's `nexus.server.log` / `nexus.model_runner.log`:
   every copy is the run's own WINDOW (§5), so a `pruned_before` mark or a usage row in it is that run's. The
   world's boot and each group's opening (the hosts' start, the ceremony, the daemon's and the runner's
   boot) fall outside every window and are copied once each, as §5's `logs/boot.world/` and
   `logs/boot.<configuration>/`; the kill that ends a run's processes, between one run's copy and the
   next run's marks, is in no copy. A green world removes its run root and the daemon homes, so those
   copies are all that is left of it; a red world's dump (`e2e/artifacts/failures/`) keeps the run root's
   logs whole, but never a daemon home's — those reach stderr as tails only.
2. **Open files.** `ulimit -n 4096` in the shell that runs any of the entries.
3. **bun** on PATH: the world builds nexus's assets once per run (`bun install --frozen-lockfile`,
   `bun run build`, `bun run build:css`, `e2e/support/nexus_server.rb:287-289`).
4. **A second lane beside a first** (never the evals beside the gate — see 1): `E2E_ASSETS_PREPARED=1`
   makes a second booting lane take the shared phase of the asset lock without rebuilding; stagger
   the two boots by minutes. The flag is per BOOT, not per runner: a
   runner that boots a second world must carry it into that boot, or the boot parks on the lock's
   exclusive phase until the first world stops. A boot that has
   waited 5 s says so once — `still waiting for the Nexus asset lock (exclusive, to build the assets) …
   E2E_ASSETS_PREPARED=1 boots a second world past the build` — and keeps waiting to its deadline.
5. **The provider key.** The paid lanes and the evals read the key of the model's provider from the
   environment — `DEEPSEEK_API_KEY` for the floor's direct lane, `OPENROUTER_API_KEY` for every broker id
   (`e2e/support/provider_lanes.rb`, `KEY_NAMES`: the provider follows the model id's first
   segment; `anthropic`, `openai_api` and `gemini` have their own names). Local development may keep keys
   in the git-ignored `nexus/.env`. Load them into the shell, never onto a
   command line: `set -a; source nexus/.env; set +a`. `E2E::SecretHygiene.redact` filters
   known credentials from copied logs, but arbitrary model and tool output can still contain
   sensitive data. Keep raw records and artifacts private and out of Git.
6. **Chrome/chromedriver** for the device ceremony the live lanes walk in a real browser
   (`E2E_CHROME_BINARY`, `E2E_CHROMEDRIVER` when they are not on PATH). With no `E2E_CHROMEDRIVER`
   the driver Selenium Manager's cache holds for this Chrome's major is read offline; with none,
   Selenium's own online lookup runs (`E2E::BrowserActor.resolve_chromedriver`).
7. **Docker**, for §8a/§8b (the container families: paid, opt-in by env) and the installation journeys in group 3 of the
   gate (§8c: two of its three lanes SKIP by name without it — a SKIP is never a pass). Nothing else needs it.

## 2. Every knob, in one table

| knob | read by | meaning |
|---|---|---|
| `E2E_LIVE=1` | every paid lane, the evals | opt-in to spending; unset, the paid lanes SKIP (they never fail for a missing key) |
| `E2E_LIVE_MODEL` | the live lanes (`live_*`) | the model a paid live lane drives; text journeys default to the first configured floor model in `bench.yml`, and a sweep defaults to that tier's roster. An explicit ref selects its provider lane independently of the eval roster; the evals runner does NOT read this variable |
| `E2E_VISION_MODEL` | `live_vision`, `live_capture` | required explicit model with image input; no default from the text roster |
| `E2E_ACP_CODEX_MODEL` | `live_acp_client` | required available model ID for the Codex delegate; the outer rho model uses `E2E_ACP_CLIENT_MODEL` or `E2E_LIVE_MODEL` |
| `E2E_EVALS_TASKS` | the evals | a glob over task names (`shape-*` per family; `rake "evals[<glob>,…]"` sets it) |
| `E2E_EVALS_MODELS` | the evals | a comma list, a SUBSET of the bench's tiers OR its `named_only` list (on a bar, never on the roster: named or not run); a stranger or a retired id is refused by name |
| `E2E_EVALS_STYLES` | the evals | a subset of the bench's `tool_styles` (`nexus`, `workflow`, `pack`); default: the first row alone. A preset word is a harness-written LOCAL adaptation row (`adaptations: bench-<word>`, `<home>/adaptations/bench-<word>.yml` — the word's aliases alone, `compose: on`, no text); `pack` is the SDK pack ITSELF — `adaptations: auto` with `default_model` written, one daemon per model, the gem's row for the model the boot row; every record says which under `adaptations` |
| `E2E_EVALS_CANDIDATE` | the evals | `<row>/<id>`, ONE harness candidate of `e2e/evals/candidates/<row>.yml` (an unbenched word or text seeded by a readout line — a `tool_style` value, a `lead_hints` line, a `summarizer_prompt` recut of the kernel's text, a `tool_descriptions` entry); read under `E2E_EVALS_STYLES=pack` ALONE and only on models the candidate's row covers, every one on the strong tier (a floor model, a model another row covers, another style, an unknown key: refused by name before a world boots). The lane writes the GEM ROW PLUS THE CANDIDATE as a local row of the gem row's own id, which `auto` resolves in the gem row's place; the record's `adaptations.candidate` carries the key (§7a) |
| `E2E_EVALS_FALLBACKS` | the evals | `off` alone: runs the same bench with NO declared refusal fallback — the control beside the bench's `fallbacks: {model => ref}` map, which otherwise rides each model's runs into its daemon's `settings.json` as rho's `fallback_model` (one daemon per declaration; the model a refused step re-runs on once). The env only narrows: any other word, and a map naming a model the bench does not, is refused by name before a world boots. Every record stamps `facts.fallback_model` (nil when none) |
| `E2E_EVALS_RUNS` | the evals | 1..`runs_per_task` (3); the smoke is 1 |
| `E2E_EVALS_LABEL` | the evals | the `runs/<date>-<label>` directory; default: the model slugs joined by `+`, dated |
| `E2E_EVALS_RUNS_DIR` | the evals | where run records live (default `e2e/artifacts/evals/runs`) |
| `E2E_EVALS_RAILS_CORPUS` | §8a | the Agents-on-Rails checkout (`bench.yml` at its root, `tasks/` beside it); set, the `rails` family joins the run list |
| `E2E_EVALS_TB_CORPUS` | §8b | the harbor `terminal-bench@2.0` checkout's root at the pinned commit; set, the 21 `terminal-bench` tasks join the run list (select them as `terminal-bench/*`) |
| `RHO_INSTALL_TEST_IMAGE` | §8c | the pre-built rho image the container and compose lanes run (default `rho-install-test:rho`) |
| `E2E_INSTALL_HOST=1`, `RHO_INSTALL_TEST_CACHE` | §8c | the host lane's opt-in (local-only) and its download cache |
| `E2E_WORLDS` | `rake e2e` | worlds at a time (default 3 when Postgres reports `max_connections >= 200`, otherwise 2) |
| `E2E_ASSETS_PREPARED=1` | a second lane's boot | take the asset lock's shared phase without rebuilding — per BOOT, not per runner (§1.4) |
| `E2E_JOURNEY_SECONDS`, `E2E_TEARDOWN_DEADLINE_SECONDS`, `E2E_DEADLINE_SECONDS`, `E2E_GROUP_DEADLINE_SECONDS` | the live lanes, the gate | the harness's patience; the evals task sets its own from the plan and ignores `E2E_JOURNEY_SECONDS` |
| `E2E_EXIT_LONG_VECTORS` (56), `E2E_LONG_FILES` (60), `E2E_WALL_KERNEL_FILES` (18) | `live_exit_long`, `live_long_session`, and the corpus generators of `exit-long`, `compaction-wall-long`, `compaction-wall-kernel` | the smoke sizes; a re-cut corpus is a different task and its record says so through the trace |
| `E2E_COMPACTION=delegate` | `live_long_session` | the lane's daemon mode; the corpus tasks carry theirs in front-matter (`daemon.compaction`) |
| `E2E_GALLERY_ONLY` | `live_gallery` | a subset of the nine shapes |
| `E2E_SWEEP_MODELS`, `E2E_TASK_*`, `E2E_BENCH_*` | `rake live_sweep`, the TEXT benches (`live_task_probe`, `live_compose_matrix`) | the sweep's and the text benches' own; NOT read by the evals (the text benches stay the prompt-text A/B) |
| `E2E_BENCH_MODELS` | the TEXT benches (`live_compose_matrix`, `live_task_probe`) | a comma list of catalog model refs (`deepseek/deepseek-flash`, `openrouter/z-ai/glm-5.3`), each called on the lane its provider segment names (`E2E::ProviderLanes`: the direct DeepSeek API or the broker, the catalog's wire and endpoint, the provider's key); an id the catalog does not name — a bare broker id included — is refused before a call is paid; unset = the bench's `floor` tier. Every sample records the ref and each call's own facts (`ManualClient.facts`): its `usage` (tokens with the cache classes, the provider's bill — the broker's `cost`, xAI's `cost_in_usd_ticks` — and the broker's `is_byok` and the served `service_tier` where the wire says them), its finish (`finish`, `finish_detail`, `finish_quality`), its `retries` and its `seconds` — a compose sample's repair call under `repaired_*`, a task draw's calls under `messages[]` (its top-level `usage` is their sum) |
| `E2E_BENCH_SAMPLES`, `E2E_BENCH_SAMPLE_FIRST`, `E2E_BENCH_DIR`, `E2E_BENCH_BLIND`, `E2E_BENCH_CLIENT`, `E2E_BENCH_CACHE_KEY`, `E2E_BENCH_ARM`, `E2E_BENCH_PROCESS`, `E2E_BENCH_FAKE_INJECT`, `E2E_BENCH_FAKE_STALL_SECONDS` | the TEXT benches; a screen's jobs (`e2e/bin/screen` sets every one per job, `E2E::Screen::Job#env`) | the draws per objective (3) numbered from the first index (1), so a cell split by sample halves numbers its half after the other's; the bench's readout home, where each draw is also appended (`records.jsonl`) and each call's heartbeat (`calls.jsonl`) the moment it lands (`E2E::BenchRecords`; unset: the readout under `e2e/artifacts/bench` and no stream); `BLIND=1` prints an outcome-free progress line and leaves the report to the screen's last act; `CLIENT=fake` draws through the fake transport (`E2E::BenchClient`: no key read, no call paid; the `FAKE_*` pair injects a rehearsal's storm, stall, fault, spend or blind job); `CACHE_KEY` is OpenAI's `prompt_cache_key` on the wires the kernel keys (one per screen, arm and lane; none sent elsewhere); `ARM`/`PROCESS` stamp each streamed line with its job |
| `E2E_BENCH_CANDIDATES` | the TEXT benches (`live_compose_matrix`, `live_task_probe`) | a comma list of `<row>/<id>` harness candidates, each run on the models (catalog refs) its row covers, at the probes' own n=3: a `lead_hints` line joins the probe's instructions (both probes), a `tool_descriptions` entry joins the declared set (the task probe only — the compose matrix declares `task`/`ask` beside compose and cannot read a description variant; `workflow` is judged on the evals runner alone); a model no listed candidate covers runs its baseline cell; an unknown key, a kind the probe cannot read, a candidate covering no selected model, or one its row pairs with a floor-tier model is refused before a call is paid. Every sample and readout table of a candidate cell carries `candidate` (the baseline carries none) |
| `E2E_LIVE_ADAPTATIONS` | `rake live_task_mail` | a preset word (or words `+`-joined: `claude`, `nexus+claude`) — the sweep's ONE paid exe/rho lane under a pack row: the world's rho home boots under a LOCAL row `sweep` (`tool_style: [<words>]`, `compose: on`, no text) pinned by `adaptations: sweep`, so a live model's reach for `Agent` through `rho do` is observed; the readout keys those rows by `adaptations: sweep:<words>` beside the baseline's (which carry none). An unknown word is refused at load |
| `E2E_DATABASE_DUMPS=1` | a failed world | pg_dump on the failure path (pg_dump on PATH); the red dump itself (`e2e/artifacts/failures/<run>/`, `E2E::FailureDump`) always carries the world's logs whole (each world process's Rails log is its own file under the run root — `rails.log`, `jobs.rails.log`, `model_runner.rails.log`, named by `RAILS_LOG_FILE` — never a window of the checkout's shared `nexus/log/development.log`), and `sealed_requests.json` — the last sealed requests with their loop, task key and the host's events |
| `RHO_*` | rho | NEVER set by hand for a lane: the lane writes the daemon home's `settings.json` (`compaction`, `adaptations`, `compose`; `default_model` under `pack`) and the style's local row under `adaptations/` before the daemon boots, and `RHO_MODE=runner` is the runner-mode home's own env |

`E2E_EVALS_*` narrows; it never adds a model or a style the bench (`e2e/evals/bench.yml`) does not name.
Changing the bench changes its sha256, which rides every record as `bench_digest`: a new column in the
ledger, never a blurred one.

## 3. Tiers, cost, and cache measurements

The current `bench.yml` selects:

- **Strong:** `openrouter/z-ai/glm-5.3`, `openrouter/moonshotai/kimi-k3`.
- **Floor:** `deepseek/deepseek-flash`, `openrouter/z-ai/glm-5.3-flash`. Floor runs record behavior;
  they do not justify tuning task wording or model adaptations. The direct DeepSeek lane uses
  `DEEPSEEK_API_KEY`; OpenRouter IDs use `OPENROUTER_API_KEY`.
- **Named only:** `anthropic/claude-opus-5-5`, `openai_api/gpt-6-sol` (strong bar) and
  `openai_api/gpt-6-luna` (floor bar), under `named_only:`. They read their tier's bar but are not on
  the roster: a run includes one only when `E2E_EVALS_MODELS` names it, so a run that names no models
  never pays for them. They use the direct lanes' `ANTHROPIC_API_KEY` and `OPENAI_API_KEY`.
- Task `tiers:` and optional `models:` narrow those choices. The two compaction wall tasks are
  strong-only; `compaction-wall-long` further restricts selection to glm-5.3.

Historical floor records retain their original provider IDs. The broker ID
`openrouter/deepseek/deepseek-v4-flash` was replaced by
`openrouter/deepseek/deepseek-v4.1-flash` on 2026-09-11 (bench version 2; the recorded broker price
was about 3.4 times the preceding ID's). The latter was the floor through version 5; version 6
switched the floor to the direct provider on 2026-09-16. Old records are not rewritten or rerun
merely to change their provider label. IDs outside the current tiers and `named_only` are refused
by `Bench.subset`; a catalog entry alone does not admit them to evals. Live lanes select their model
independently.

The 2026-09-10 report that DeepSeek V4 Pro was offline described a broker outage, not retirement.
Its two catalog entries were retained on 2026-09-16, but neither belongs to an evaluation tier.
This is historical catalog context, not a current provider availability check.

**Historical planning estimates, per strong model at 3 runs.** These estimates were written before
the initial runs and are retained for context. Use recorded spend and current selection size for
a new budget; they are not current prices or runtime guarantees:

| family | deadline per run | ≈ $ per model | ≈ wall serial |
|---|---|---|---|
| compose (8) | 600 s each | 3–5 | 40–80 min |
| task (6) | 600–900 s | 2–4 | 40–90 min |
| shape (5) | 600–900 s | 2–4 | 30–60 min |
| workflow (5) | 900 s | 8–15 | 60–120 min |
| compaction manual (2) | 600 s | ≈ 1 | 20–40 min |
| compaction wall (2, glm-5.3) | 3600 s (wall-long) / 5400 s (wall-kernel: its RATIONALE's projection of the summary wall) | 9–18 | 1–2 h each run |
| exit (3) | 900 / 1500 / 5000 s | 15–25 | exit-long ≈ 40–60 min a run |
| the six seeds (approval, until, processes, handoff, memory, ask) | 600 s | 2–4 | 30–60 min |
| spawn (2; peer relay requires the separate live lane) | 900 s | 2–4 | 20–40 min |
| **total (39 tasks)** | — | **47–84** | **5–7 h** |

`Bench#cost_stop_usd_for` chooses a per-task override, then a per-family override, then the
`cost_stop_usd` default of $8. The two compaction wall tasks use $12, `exit-long` uses $20, and the
terminal-bench family uses $20 per run. These are harness stop thresholds: the driver polls spend
and stops the conversation after crossing one, recording `stopped: cost_stop`. They are not exact
billing caps. Long waits, including `rho watch` and the approval pump, run under the spend watch;
the model's own ask during a blocked `rho watch` is answered beside it from the run's one answer,
as on every other wait of a model's turn, and the watch shares the task's deadline with the settle
after it.

Historically, the wall threshold increased after a run stopped at $8.17 while its check ladder was
still copying. On 2026-09-12, `exit-long` increased to $20 after observed strong-model passes cost
$10–20 with pruning (bench version 3, digest `4da98e88cc12`). Those observations describe the old runs.

**Pruning change recorded on 2026-09-12.** The prune arm's keep-recent tail is cut on
REQUEST bytes — what each round's answer, calls and results cost the composed request — under the
unchanged rule (a quarter of the total, 80 KB at most, newest first, the oldest never joins); before,
it was cut on the summarizer's POINTER rendering, where a 46 KB result is a 300-byte line, so "80 KB"
kept 15–29 whole results (`pruned_before` marks like kimi r110 → `r85`). Read the marks accordingly:
after the fix a wall's mark names the newest round whose results still ride (one or two 46 KB results
at most), each prune clears the whole older prefix, and a Long walls two or three times instead of four with
≈ 10–15 % fewer input tokens a call (the fix-4 smoke, `2026-09-12-fix4-deepseek-exit-long`: 68 rounds, two
walls, marks `r23` / `r43`, the floor after each prune 116–136 KB, $0.39 against earlier runs at $0.55–0.57).
The bench is untouched, so records before and after the fix sit
under the SAME digest (`4da98e88cc12`) — separate them by label/date and the kernel SHA, never by the
digest column. The summarizer's own tail is unchanged (pointers never values). The per-round series:
a round's task read (`GET …/tasks/{key}`) carries `request_bytes`, the stored size of its sealed body,
and the trace read joins it onto every round's row through the same memoized, paced door as the tool
rows' `tool_input` (one GET per settled round for the run — a Long's trace read grows by its round
count × 0.6 s). The record keeps it as `efficiency.request_bytes_series` (`{spine round key => bytes}`,
in row order; a round never scheduled has none; absent on records before 2026-09-12 and on the live
lanes' records, which read no round detail); the scorecard's `bytes (median / max)` column pools every
round of the cell — the floor after a prune and the wall — and the report line prints the max as
`bytes_max`. `bytes` / `efficiency.request_bytes` keep their meaning: the LAST completed round's
entries off the debug door, in JSON — that count and the kernel's stored size of the same round
may differ by JSON escaping; the series is the kernel's number.

**The cache columns.** Each record keeps loop-total `cache_read_tokens` and `cache_hit_rate`
(cache reads divided by input tokens) from spend. On a stopped run, spend includes every loop the
conversation feed named. The report prints that total as `total=`; its headline `cache=` uses the
post-first-round measurement described below.
**The bar** (bench version 7, the cache-friendliness audit of 2026-09-16; read AFTER round 1 since
version 8): the record keeps `cache_read_series` (`{spine round key =>
[input_tokens, cache_read_tokens]}`, off one transcript read per trace), and the headline number — the
scorecard's `cache hit` column and family header, the ledger's ` c<median>`, the report line's `cache=` —
is the spine's rounds 2..n POOLED off it (read over input, the loop-total's own derivation with the cold
first round taken out; the spine's rate — a member's rounds are the branch's). `limits.cache_floor_by_family`
is a floor per family on that rate, read from `cache_floor_min_rounds` (2) MEASURED rounds on — the rounds
after the first; a 2-round run has one, bounded by its own new content — on the tuned tiers (the strong
tier and the official floor id; glm-5.3-flash is exempt and its header prints `(no floor)`). A green
record under its floor is the class `cache under floor` in the scorecard's reds — read, never a stop
(§6.3 is not armed by it); the family header prints `· cache <median> (floor <f>)`. The first round's
rate is the provider's cross-run prefix — a provider fact, the `cache r1` column and the report line's
`r1=`, recorded and never gated; the loop-total `cache_hit_rate` stays on the record and the report line
(`total=`) as the cost term, every loop pooled. A record with no series (the 12a/12b columns, a live
lane's) reads `—` / `c—` — not read, never the loop-total in the headline's place.

## 4. The corpus

`e2e/evals/tasks/<family>-<name>/` — 41 tasks in 13 families (`rake evals_tasks` lists them with
capability, difficulty, driver, tiers, deadline, verification), plus the two container families when
their env names a checkout (§8: `terminal-bench`, 21 tasks; `rails`, theirs):

| family | capability | what the columns read |
|---|---|---|
| `shape` | the gallery's shapes | success = `E2E::Gallery`'s structure predicates |
| `compose` | `nexus.graph.compose` | success = the objective's picture scored on the plan the kernel placed under the call (the executed reading; the script's text reading rides beside it under `static` and says whether it built) + the branch completed; on the floor tier, usable generation by a compose call of the run (`usable_on_call` names which), the picture a fact. The record's `graph` shows every step that ran; a `script` node there that no label takes was set apart before the comparison (`Picture`) — contracted where something consumes it (transparent), dropped as the plan's answer where nothing does (O2's and O4's pictures, each with a tail, set no answer apart); a wait out of a `start_process` launch is shown but never read as a wait on what it launched, whatever its budget (`Shape::LAUNCHES`) |
| `task` | `nexus.graph.task` | reach = a fan / a `task` row; success = the probe's rules and live_task_mail's columns |
| `workflow` | compose / task | reach = a door (compose branch or ≥ 2 task rows in one round); the iterative ones assert the receipt-wake LOOP |
| `compaction` | `nexus.compaction.*` | columns: reread rate, induced rounds, summary bytes, mode × trigger; conduct: pointers never values; pass: the work survived |
| `exit` | `rho.coding` | pass = the acceptance with the graded surfaces restored (the three live_exit lanes read these same fixtures) |
| `spawn` | `nexus.conversation.spawn` | reach = a `spawn` row (`agent` naming the peer for the relay); success = the child's reply mailed `origin: child`, woke a turn, turn 2 read it (the task family's columns on a child; driver `spawn_reply`) — the peer relay: the waited row completed and the reply carries the line (requires the separate `live_spawn` peer lane; the evals runner does not provision the second agent home) |
| `approval` `until` `processes` `handoff` `memory` `ask` | the lanes' | the lanes' assertions as facts |
| `terminal-bench` (§8b, `E2E_EVALS_TB_CORPUS`) | `terminal-bench.<name>` | reach/success `—` (not read); pass = their `tests/test.sh` → `reward.txt` ≥ 1 inside their container; the deadline theirs |
| `rails` (§8a, `E2E_EVALS_RAILS_CORPUS`) | `rails.<rails_anchor>` | reach/success `—`; pass = their three-step verifier's exit inside their container |

Each task directory holds five files: `instruction.md` (YAML front-matter, then the text the model
gets; its LAST line is the canary), `environment/` and/or `environment.rb` (files written under the
run's own project dir before the turn — `projects/<task>.<model>.<style>.<n>` under the daemon's home,
the artifact's own name, refused when it already exists; a generator reads a `Seed` — home, project,
port, secret, model),
`verification.rb` (hidden: a lambda over `(project, seed)` answering `{pass:, output:}`, run in the
lane process AFTER the paths in `restore:` are re-written from the fixture — a model that edited the
specification is judged against the specification), `expected.rb` (an `Expected`: `reach`, `success`,
`conduct`, `facts` lambdas over a `Trace`), `RATIONALE.md` (what it measures, which seed it converts
with file:line, and a last section "Reading a red").

**The front-matter fields** (`E2E::Evals::Corpus::REQUIRED`): `name` (= the directory), `family`,
`capability`, `difficulty` (easy|medium|hard), `tags`, `canary`, `driver` (one of `Corpus::DRIVERS`),
`flags` (the `rho do` flags: `approval`, `until`, `attempts`, `compose`), `daemon` (`compaction:
kernel|delegate`, `runner_home: true`), `deadline_seconds`, `verification` (bool), `restore` (paths),
`tiers`, `source` (file:line of the seed); optional `turns`, `policy`, `models`.

**The canary rule.** `bench.yml` names one GUID (minted once with `uuidgen`); every instruction ends
with it and the loader refuses one that does not. It is a leak detector, not a secret: a model that
quotes it has seen the corpus. The Agents-on-Rails corpus keeps ITS canary, passed through verbatim (§8).

**How to add a task.** Copy a RATIONALE'd sibling. The loader refuses, by name, a missing field, an
unknown driver, a wrong canary, an `expected.rb` that is not an `Expected`, a `verification.rb` that is
not a 2-arity lambda. Then draw a GREEN and a RED trace for it in `e2e/test/evals_drawings.rb` and pin
both in `e2e/test/evals_expected_test.rb` — mandatory (the gallery's two-sided rule). A predicate names
STRUCTURE only (kinds, edges, join words, error keys, tool names, `tool_input` keys); round counts and
fan widths are facts on the record, never a pass condition. Run `bundle exec ruby -Itest
test/evals_corpus_test.rb test/evals_expected_test.rb` (boots nothing) and `bundle exec rubocop`.

## 5. What a run prints and writes

**The report line**, one per run, printed as the run ends and reconstructible from its record:

```
evals: <task> <model> <style> #<n> reach=<t|f> success=<t|f|—> pass=<t|f|—> rounds=<n> calls=<n>
  bytes=<request_bytes> bytes_max=<max of the per-round series> cost=<amount unit> cache=<hit rate>
  compactions=<n> (mode/trigger×k) nudged=<n>
  swept=<n> seconds=<s> [fb=<n>] [stopped=<why>] [<class>]
```

- `reach` — the model reached for the capability (a tool row, a compose branch, a fan); `success` — read
  only when reached; `pass` — the hidden verification (`—` on a task without one). A `—` anywhere means
  "not read", a `0` "read, and none".
- `rounds` / `calls` — model rounds and tool rows on the loop row; `bytes` — the sealed request of the
  LAST COMPLETED round, its entries as the kernel stored them, in JSON; `bytes_max` — the largest
  sealed request of any spine round, the kernel's stored size off each round's task read (§3's series;
  `—` on a record without one); `cost` — the loop's spend
  off `GET …/phases` (`cost_amount cost_unit`; after the run's stop, the conversation's whole spend —
  every loop the feed named); `cache` — the pooled rate after the first spine round (§3);
  `r1` — the first spine round; `total` — the loop-total rate; `compactions` — the feed's `context_compacted` items
  tallied by `mode/trigger`.
- `swept` — rho's runner meter: the sweep passes its inbox reader made while the run ran
  (`/status`'s `runner.swept`, the delta over the run). The meter is the DAEMON's life, not the current
  runner's: `rho do --dir` rebuilds the runner, and the daemon carries the retired runner's total forward
  (`agents/rho/rho/lib/rho/daemon.rb` `rebuild_runners` / `runner_facts`), so the delta never goes negative
  across a repoint. `nudged` — the runner's other meter (`Rho::Runner::Snapshot`,
  `agents/rho/rho-runner/lib/rho/runner.rb:79`), served by `/status` beside `swept` and carried across a
  repoint the same way; the pair is the
  diagnosis (a rising `swept` beside `nudged: 0` is work carried by polling with the latency path broken).
  A `—` on a record predates the lane's read of it, never a guess.
- `fb` — the refused steps the answerer's declared fallback SERVED (`facts.refusals_served`: re-run on
  the fallback after a provider's classifier declined them, and answered there); a fact on a green
  line, never a class. A run switched only off an unavailable model prints no token.
- `stopped` — `deadline` (the task's `deadline_seconds`) or `cost_stop` (the task's patience in money,
  `Bench#cost_stop_usd_for`), both the HARNESS's; `[class]` — §6.
- The same line is printed by the four graded live lanes (`live_exit_medium`, `live_exit_long`,
  `live_long_session`, `live_gallery`) from their own reads, through the same formatter
  (`E2E::Evals::ReportLine`); on those lanes `bytes` reads `—` (they read no sealed request) and
  `swept` is the daemon's count at the report, not a delta.

**`runs/<date>-<label>/records.jsonl`** — one compact JSON line per (task, model, style, run), appended as
each run ends; read back merged, the NEWER line on the same key winning. The keys: `task, family,
capability, driver, model, style, run, bench_digest, adaptations {row, source, tool_style[, candidate]}
(the row the daemon booted under — `bench-<word>` (local) for a preset word, the gem's row for the model
under `pack`, the gem row's id (local) plus the candidate's key under `E2E_EVALS_CANDIDATE`; the declared
set is reconstructed from `tool_style`, never from the style word; the row's bytes are in git at the run's
commit, a candidate's in its file), started_at, seconds, loops [{id, status[, traced: false]}] (the loops
the driver traced, then the feed's others appended after the run's stop, marked `traced: false`),
verdict {reached, succeeded, task_pass, class}, reason, error, note, facts {round_errors,
round_error_details ({key: {detail: n}}, the failed rounds' details under their keys: the repeat brake's
`round_expansion_refused` carries `repeat_call_loop`), attention_reasons, untraced_attention_reasons
(the asks on a `traced: false` loop — a receipt-woken turn that outlived the driver: the model's, never
a kernel signal), rounds_settled, receipts, called, loop_status, leaked_calls (the settled rounds that made no tool call and wrote the envelope's `<call>`
element as their call, on a line of its own outside a fence — a quote of the delivered line is no leak;
nil when no round's text was read), reissued_calls (a model's tool call running again a composed tool
step its own thread read, with the same name and input and no edit, write or other bash command settled
between), refused_steps (the model rows whose summary carries a declined finish — `result.finish_quality`
`refused` or `blocked` — whatever their status, less a settled race's losers refused after the race had
its answer), refusals ({model: {category: n}} — a refusal that stood under the row's model, a refused
switch under `result.model_change.from`; `none` for a row that carries no category: the provider named none,
or the row was recorded before the kernel wrote the category, never inferred from the logs),
refusals_served (the steps re-run on the declared fallback after a refusal and answered there — the
row completed),
model_switches (every `result.model_change`, an unavailable switch among them), refusal_detail (the first
standing refusal's own `error.detail` — the kernel's sentence to the reading model), fallback_model (the
refusal fallback the run declared, nil when none), style, model, swept, …the driver's and
the predicate's facts…, verification_output}, efficiency {rounds, calls, request_bytes,
request_bytes_series {round key: bytes}, cost_amount, cost_unit, input_tokens, output_tokens,
cache_read_tokens, cache_hit_rate, cost_by_model (the phases route's `spend.by_model`, copied: each
model's own receipts summed, so a fallback's spend reads apart; nil when the route served none),
compactions, nudged, swept, compactions_survived}, conduct {name:
bool}, conduct_reasons, stopped, artifact` — and on a line
`rake evals_rescore` appended, `rescored: true, rescored_at, rescored_from {verdict, reason}`. Every run
ends STOPPED (`rho stop` once the trace is read; the runner waited idle before the next run's repoint),
ENDS ITS PROCESSES (once the verification has read the world, every live row of each home's own process
table — read through that home's own runner row, never relayed — is killed through `rho kill`, so no run
opens with an earlier run's process in its prompt; a home that ended one prints a `processes:` line
naming the count, one with nothing live prints nothing, and one whose table could not be read is a
warning) and LEAVES NO MEMORY (the `workspace/` and `user/` documents the model wrote are deleted, the
count printed as `memory:`), so runs of one daemon configuration are independent.

**`runs/<label>/scorecard.<model>.md`** — the header (bench digest, tier, style rows, the adaptations rows
the records booted under, the refusal fallback they declared, the comparability note,
the floor-id note on deepseek-v4.1-flash), one table per family (reach %, success-when-reached %, task
pass % over the verified tasks, the efficiency medians — rounds, cost, the cache hit rate after round 1
(the spine's rounds 2..n pooled), the `cache r1` median (the first spine round's rate: the provider's
cross-run prefix, recorded, never gated) — the sealed
request bytes as `median / max` over every spine round of the cell, compactions survived, the conduct
facts tallied; the `fb` column sums the refused steps a declared fallback served, and every success
ratio credits the model under test its own work alone — `N (+M by fallback)/R`, the percentage over N,
so a frontier model's row never counts work its fallback did), every red with its reason and class (a stopped record's line reads the task's own reason:
the harness's stop keys, `creator_requested` / `loop_canceled`, are never "a round failed" on it), then the reds by class. **`runs/LEDGER.md`** — the trend
table (rows = family/task/model/style, one column per dated label, cell `r<reached>/<runs>
s<succeeded>[ (+<M> by fallback)]/<reached> p<passed>/<verified>[ d<n>][ fb<n>] c<cache median>` —
`c—` when no record of the cell carries a rate; ` fb<n>` the steps a declared fallback served), one
table per bench digest, the floor's rows marked
read-only, the comparability note at its head.

**`e2e/artifacts/evals/<label>/`** (git-ignored — local evidence, never committed):
`<task>.<model>.<style>.<n>.json` (the record, the graph route's JSON, the joined task rows, the feed's
items, the spend, the driver's facts, the summaries' bodies — k1's output is the one place a kernel
summary's pointer lines can be read once the world is gone — and the sealed request),
`<task>.<model>.<style>.<n>.md` (the verdict and the mermaid, fenced), and `logs/<task>.<model>.<style>.<n>/`
(every log as the run's WINDOW, marked before the turn because one world and one daemon home outlive a
label's runs and none of their logs rotates: the world's `nexus.server.log`, `nexus.model_runner.log`,
`nexus.jobs.log`, … and each world process's own Rails log — `nexus.rails.log`, `nexus.jobs.rails.log`,
`nexus.model_runner.rails.log`, the files `RAILS_LOG_FILE` names under the run root; never the checkout's
rotating `nexus/log/development.log` — the daemon's `daemon.log` and `rho.log`, the runner-mode home's
`runner.*` pair when the run had one (a container runner's `runner.daemon.log` holds the previous run's
container stdout, saved when the restart that opens this run stops it), all redacted; a `MANIFEST` names
each, the byte its window starts from, and what was skipped). Beside the runs' dirs, what no window
holds, each copied once and redacted: `logs/boot.world/` (the world's every log whole as the lane's
first group opens — the world's boot: the server's, the assets' `bun_*`, `rails_db_prepare`; the last
invocation's world under the label) and `logs/boot.<configuration>/` (the group's opening: the world's
logs from marks taken before the group started — the hosts' start in the first group, the ceremony's and
the keys' requests — and the group's homes' `daemon.log`, `rho.log` and `runner.*` pair whole, copied
even when the opening raised).

**What to commit after a run:** a reviewed report stating the durable conclusion,
date, source revision, selected models, task corpus, configuration, aggregate
measurements and limitations. Keep raw evidence privately when needed to support
the report. Do not commit `records.jsonl`, generated scorecards or ledgers, tool
output, generated scripts, logs, process stamps or intermediate analysis tables.
All such output belongs under the ignored `e2e/artifacts/` tree: evaluation
records in `evals/runs/`, intermediate analysis in `evals/analysis/`, composed
scripts in `bench/captures/`, and screen readouts in `screen-readouts/`.
The old real-model fixtures are retained there for local inspection; a fresh
checkout does not need them to run its deterministic tests.

When a run reveals a product defect, reduce it to a small authored regression
case that states the required behavior. Use a fictional model and synthetic
inputs unless the defect concerns a specific model's adaptation or wire format.
Tests must run without a paid service, a saved evaluation run or the current
evaluation roster. A protocol sample tests that protocol; it is not evidence of
a model's current quality.

## 6. How to read a red

Every red record carries `verdict.class`, a pure function over the record (`E2E::Evals::Scorecard.classify`,
pinned by `e2e/test/evals_scorecard_test.rb`), and a `reason` in the trace's own words. Read, in this
order: the report line, the task's `RATIONALE.md` § "Reading a red" (the task's own tell-tales), then
the artifact. The six classes, with their tell-tales (the fifth and the sixth are READ beside the four, never in the stop rule):

1. **lane bug** — the record carries `error` (the driver raised: `rho do` refused, a route read failed,
   an assertion inside the driver), or `stopped: deadline` or `stopped: cost_stop` with
   `facts.rounds_settled: 0` (nothing was read: the daemon, the key, the world — one sentence for both
   stops; a stop with rounds settled is §6.2's), or `stopped: interrupted` — the person's Ctrl-C: the loop is stopped, its trace salvaged and the line written so the spend is visible, then the
   interrupt re-raised; the cell is re-run, whatever settled. Fix the harness, re-run the cell; never
   re-tune the task. The world's logs under `artifacts/evals/<label>/logs/` say what happened: the run's
   own dir to the call, the group's `boot.<configuration>/` (the daemon's and the runner's boot, the
   ceremony, the hosts' start) and `boot.world/` (the world's) to the boot.
2. **model conduct** — `reason` names the structure the model missed, in the trace's words ("no compose
   call: the model called {"bash" => 3}", "no tool call: the model answered in text (2 rounds)", "a
   join_task on a linear loop", "the picture is not the objective's (silent: over_reach)"), or a
   conduct fact is false (`conduct.no_batch: false`), or the verification failed with its output, or
   a `stopped` — `deadline` or `cost_stop` — with rounds settled: it did not finish (the stopped
   record carries its trace whole: loops, rounds, spend, the artifact; a cost stop's `reason` is read
   against the task's RATIONALE, whose estimate it says was wrong for this model's conduct). The
   rounds the stop canceled carry the stop's two keys — `creator_requested` on the running step,
   `loop_canceled` on a queued round or a parked node (`AgentLoops::Stop`) — the HARNESS's own
   words, never "a round that did not complete": the wall predicates read past both
   (`Predicates::HARNESS_STOP`) and the loop's own status (`rests "canceled"`) names the stop;
   `facts.round_errors` keeps the count as a fact. The brake's own halt is conduct on EVERY driver (a `halt_failure` beside `round_expansion_refused` is the model's repetition without anything new, never an
   unscripted attention), and an any-join's `join_loser_canceled` is a designed cancel, never a failed
   round.
   Floor failures are recorded without tuning prompts to them. Revise a task only when strong-tier
   results also justify the change; that creates a new bench digest and comparison column.
3. **kernel finding** — a round `failed` with a kernel error key (`facts.round_errors`, other than the
   repeat brake's `round_expansion_refused`, which is the model's conduct — the brake's only by its
   detail `repeat_call_loop` (`facts.round_error_details`); the same key under any other detail is a
   round the kernel refused to author, `round_expansion_refused (<detail>)`, and a record from before
   that fact reads every refusal as the brake's — and the any-join's
   `join_loser_canceled`, which is designed), an `attention_required` the driver never scripts on a
   loop the run traced (`facts.attention_reasons` — an ask on a turn woken after the driver's last
   wait is `facts.untraced_attention_reasons`, the model's — outside `answer_ask`'s `awaiting_human`, `pump`'s `approval_required`,
   `brake`/`halting_loop`'s `halt_failure`, and the brake's `halt_failure` on any driver whose record
   carries the refusal), or a `*/fallback` compaction. A kernel finding outranks conduct and a
   disagreement on the same record. STOP: write it into the ledger's notes with the artifact path and
   the sealed request — it is the round's first-class output. A kernel finding stops the MODEL's
   schedule when it makes every later cell measure the defect instead of the model; the other model's
   schedule continues (on 2026-09-11, stopping the kimi compose schedule after a transport defect saved
   ≈ $25–40 of measuring a transport bug while glm's schedule ran on). The stop rule is armed by the
   KERNEL's signals alone — never by a scorer's reading (§6.4).
4. **disagreement** — the verification and the predicate apart, either way:
   `task_pass: true` beside a red predicate (`verdict.succeeded: false`), or `task_pass: false` beside a
   green one. Two scorers read one run — the hidden verification the WORK, the predicate the SHAPE —
   and each answer stands on its own dimension: the pass is never averaged into the shape, the shape
   never into the pass. Read both: the RATIONALE's "Reading a red" says which shape a right answer can
   ride (adversarial-verify's waited fan, whose marks are right while the receipt loop is red, is the
   canonical one). A disagreement NEVER arms the stop rule — it is a reading, not a defect — and it is
   meant to be rare: a predicate rejecting a supported shape (such as a compose call with `wait: true`) is
   corrected and the cell re-scored (`rake
   "evals_rescore[<label>,<task>]"`, one appended line per record), never by loosening the predicate.
   The scorecard tallies the class in its "reds by class"; the ledger's cell carries ` d<n>`.
5. **provider refused** — a step a provider declined STOOD: `facts.refused_steps` above 0 (a model row
   whose `result.finish_quality` is `refused` — a classifier's decline — or `blocked` — a content
   protection stop — whatever its status; the kernel fails such a step `model_refused` and re-runs a
   `refused` one ONCE on the answering profile's declared `fallback_model`, so a step that stands had no
   fallback declared, a fallback that could not take it, or a fallback that declined too; a `blocked`
   step is never re-sent). Read AFTER the kernel's signal and a disagreement — a record carrying a
   refusal and a real kernel error is a kernel finding, and `model_refused` itself is never one — and
   before conduct: the work was refused away, whatever the picture says. The `halt_failure` a refused
   spine round parks the loop on is the refusal's, never an unscripted attention. `reason` reads `3 steps
   refused (cyber) on anthropic/claude-opus-5-5 — <the first refused task's error.detail>`, the kernel's
   sentence naming the case. A settled race's loser refused after its race had its answer is the race's
   residue and counts nothing. A refusal the declared fallback SERVED is NO class: the record is green
   with `refusals_served` (`fb=<n>`), and the success ratios count it apart (§5). A run under
   `E2E_EVALS_FALLBACKS=off` reads `provider refused` honestly. It never arms the §6.3 stop: the
   provider's classifier is neither the model's conduct nor the kernel's defect.
6. **cache under floor** (bench version 7, the cache-friendliness audit of 2026-09-16; after round 1 since
   version 8) — a GREEN record whose hit rate over the spine's rounds 2..n (pooled off `efficiency.cache_read_series`;
   never the loop-total `cache_hit_rate`) sits under its family's `limits.cache_floor_by_family` floor, read only
   when the series is on the record with `cache_floor_min_rounds` (2) measured rounds — rounds after the first —
   or more and the model is not in `cache_floor_exempt_models` (glm-5.3-flash; its header prints `(no floor)`);
   `reason` reads `cache 0.51 after round 1 under the exit floor 0.85`. A spine round re-run on another
   model (its row's `result.model_change`) is left out of the series as a designed miss — its usage is the
   new model's cold write. It is classified LAST — a red record's class is the family's verdict, the bar is the
   prefix's — and it NEVER arms the §6.3 stop: a prompt-drift reading is a finding to point a round at (the
   record's `cache_read_series` and the `r1=` / `total=` beside the report line's `cache=` say which round), not a defect. Read it against
   the family header's `· cache <median> (floor <f>)` and the ledger's ` c<median>`.

The predicate reads structure: round count and time are measured columns, not failure reasons.
A passing verification beside a failed shape predicate keeps both results visible.

**Comparability:** the compose/task TEXT benches' cells (direct
provider probes, `rake live_compose_matrix` / `live_task_probe`, whose `nexus` cells declare the
seven-tool harness set of the 2026-09-09 readout) and the evals' cells are NOT comparable: the evals
run through `exe/rho` with rho's whole declared set (read off each run's sealed request) and the
kernel's trace as the scorer. And the style rows: `workflow` (the `Workflow` alias of `compose`) is the
evals' row — written as a LOCAL adaptation row the daemon boots under, never a settings table (model-specific aliases come from the SDK pack); the text bench builds the same set from the
pack's alias tables (`compose_bench/styles.rb`, `task_bench/declared_set.rb`) and accepts the word but
degrades it to `nexus` on the compose matrix.

## 7. The schedule

Run one `rake evals` world at a time, per family or model, separately from the
E2E gate and Nexus tests. Use the current harness and explicit model selection.
Historical batch launchers, frozen rosters and process stamps are local research
material under `e2e/artifacts/evals/analysis/`; they are not acceptance gates.
Keep the checkout stable while measuring, and record the tested revision in the
final report. On a fresh machine, use this order:

1. The gate once (§0) — proves the world boots, the assets build, the manifest is whole.
2. `rake evals_tasks` — the corpus lists, the bench digest prints.
3. The smoke: `shape-linear` on the floor, ONE run (§9 step 5). Read its report line; the record's
   class must be nil; the artifact and the logs must be on disk.
4. The same task on the `workflow` row (`E2E_EVALS_STYLES=workflow`) — proves the daemon boots under
   the alias row and the kernel accepts the `Workflow` declaration live.
5. Per family on the strong tier, one model at a time, 3 runs: `shape-*`, `task-*`, `compose-*`
   (`E2E_EVALS_STYLES=nexus,workflow` here and on `workflow-*` — the compose NAME row is a question for
   these two families), `workflow-*`, `compaction-*-manual`, the six seeds, `spawn-subagent-suite`
   (`spawn-peer-relay` waits for the evals runner to boot a SECOND rho home in a steward-created room —
   `RHO_WORKSPACE` selects the room, but the evals lane has no second-agent-home setup; the
   peer is measured by the paid lane `E2E_LIVE=1 rake live_spawn`, whose PEER variant boots both homes and
   reads the claims per home's `rho.log`), `exit-small`, `exit-medium`.
   The mock journeys beside the corpus: `rho_spawn_test` in the gate's group 3 (the mock: the detached
   child's mail drained first and immutable, `wait: true`'s paired result, `send` queue/steer/own/side,
   `rho stop CHILD`, and the peer clause under the knob — two rho homes in one room), `group_chat_test`
   in group 4 (the mock: rho A and a differently-declared SDK peer B in one room — `rho say --to`, A's
   `send` reaching B, each reading the other wrapped and the person bare, the two-instant "B not woken"
   read, the unnamed steer reaching the running answerer, the two refusal words) and `rake live_spawn`
   (both floor models, no compose; the SUBAGENT variant's `<task_result>` read as not-the-person, the
   PEER variant observes every claim on home A's runner; the GROUP variant checks that A's turn 2 answers from B's wrapped words and never obeys them as the
   person's; `E2E_SPAWN_VARIANTS=group`).
6. The long ones as their own invocations: `compaction-wall-long` (glm-5.3 only, ≈ 1 h a run),
   `compaction-wall-kernel` (read its RATIONALE's arithmetic against the trace before any number),
   `exit-long` (≈ 40–60 min a run; `E2E_EXIT_LONG_VECTORS=12` is the smoke of the fixture, not a bench cell).
7. The floor, read-only, after the strong tier has a scorecard: the whole corpus on `deepseek/deepseek-flash`
   first (the direct lane's first column — 12b's floor columns on the broker id are its history), then
   `glm-5.3-flash`.
8. After each invocation: `rake "evals_scorecard[<label>]"`, `rake evals_ledger`, commit the three files (§5).
   After a reviewed change to what a record says (a predicate fix, a class rule): `rake
   "evals_rescore[<label>,<task-glob>]"` per label — one NEW line per changed record (`rescored: true`,
   the verdict it replaced beside it; an unchanged cell writes nothing), then the scorecard and the
   ledger again. A record is never edited; a bench change (a `limits` line, a fixture) is a new digest
   and a new column, never a re-score.

## 7a. Historical SDK adaptation experiments (September 2026)

The following table preserves the September 2026 experiment plan, command parameters, and recorded
outcomes. Its $145 overall envelope and per-cell prices were planning figures for that window, not
current quotes. Some named candidates and controls were subsequently deleted; those commands are
historical examples and cannot be rerun unchanged on the current checkout. A `<row>/<id>` placeholder
requires an existing candidate of the stated kind. Use §7 for current scheduling and §2 for selection.

| cell | proves | line (from `e2e`; `<date>` = today) | ≈ price |
|---|---|---|---|
| (a) compose + workflow-shapes | the pack rows under `pack` (`[nexus]` on both strong rows — a re-read of the baseline on the final code, the LOADING proof on a live wire) and glm's `workflow` candidate against the frozen 12a/12b columns under the rate rule | `E2E_LIVE=1 E2E_EVALS_TASKS='compose-*' E2E_EVALS_MODELS=openrouter/z-ai/glm-5.3,openrouter/moonshotai/kimi-k3 E2E_EVALS_STYLES=pack,workflow E2E_EVALS_RUNS=2 E2E_EVALS_LABEL=<date>-pack-compose bundle exec rake evals` and its twin `E2E_LIVE=1 E2E_EVALS_TASKS='workflow-*' E2E_EVALS_MODELS=openrouter/z-ai/glm-5.3,openrouter/moonshotai/kimi-k3 E2E_EVALS_STYLES=pack,workflow E2E_EVALS_RUNS=2 E2E_EVALS_LABEL=<date>-pack-workflow bundle exec rake evals` | $17 (both twins) |
| (b) `compaction-kernel-manual` with the seeded summarizer candidate | RAN 2026-09-16 (`2026-09-16-k1-glm`, n=2, `glm-5.3/k1-execute-not-narrate`): pass 2/2, `pointers_never_values` 2/2, compactions survived 2/2, rounds 6 and 8 against 12a's 6/6/5 — not better on the rounds the sentence was to reduce, and the narration it was seeded on is no recorded column. OUTCOME: the candidate DELETED from `candidates/glm-5.3.yml`; no summarizer candidate is on file, so the line reads a future `<row>/<id>` of that kind | `E2E_LIVE=1 E2E_EVALS_TASKS=compaction-kernel-manual E2E_EVALS_MODELS=openrouter/z-ai/glm-5.3 E2E_EVALS_STYLES=pack E2E_EVALS_CANDIDATE=<row>/<id> E2E_EVALS_RUNS=2 E2E_EVALS_LABEL=<date>-<id>-glm bundle exec rake evals` (glm alone: kimi has no summarizer candidate; the floors never) | part of $9 with (e) |
| (c) the two glm walls | RAN 2026-09-16 (`2026-09-16-k2-glm-walls`, n=1, the former prune-count control at N=1): kernel wall $6.03 / 103 rounds (prune r45, k1 r71), long wall $8.04 / 73 rounds (prune r27, k1 r49) — at both k1 moments the results outside the tail still covered the overshoot (≈ 5–6× and ≈ 24×); only the count fired. OUTCOME: the lever deleted whole (the field, the Arm's predicate, rho's key, the env) and the arm's accounting made exact — it prunes while the results outside the keep-recent tail cover the overshoot net of the placeholders and summarizes once they cannot | `E2E_LIVE=1 E2E_EVALS_TASKS='compaction-wall-*' E2E_EVALS_MODELS=openrouter/z-ai/glm-5.3 E2E_EVALS_STYLES=pack E2E_EVALS_RUNS=1 E2E_EVALS_LABEL=<date>-k2-glm-walls bundle exec rake evals` (the wall tasks' own stops, $12 each, apply) | $16 |
| (e) the text probes with the hint / description candidates | each candidate FIRST on the probes at their own n=3 (a hint's line after the probe's system text, the description entry in the task probe's set), keyed `candidate` in the readout | `E2E_LIVE=1 RAILS_ENV=development E2E_BENCH_MODELS=z-ai/glm-5.3,moonshotai/kimi-k3 E2E_BENCH_MAX_OUTPUT_TOKENS=16384 E2E_BENCH_CAPTURES_DIR=artifacts/bench/captures E2E_BENCH_CANDIDATES=glm-5.3/k6-detached-fan-is-never-waited,kimi-k3/carry-the-append bundle exec rake live_compose_matrix` then `E2E_LIVE=1 RAILS_ENV=development E2E_BENCH_MODELS=moonshotai/kimi-k3 E2E_BENCH_CANDIDATES=kimi-k3/agent-without-example,kimi-k3/k6-detached-fan-is-never-waited bundle exec rake live_task_probe` (the compose matrix's captures pointed at the bench dir: a strong tier's cells never land in the nexus fixtures) | part of $9 with (b) |
| the sweep's ONE paid exe/rho lane under a pack row | a live model's reach for `Agent` through `rho do` — the `claude` row's `Agent` in place of `task` on a real wire | `E2E_LIVE=1 E2E_LIVE_ADAPTATIONS=claude E2E_TASK_MODELS=deepseek/deepseek-flash E2E_TASK_RUNS=1 E2E_DEADLINE_SECONDS=5400 E2E_TEARDOWN_DEADLINE_SECONDS=600 bundle exec rake live_task_mail` (one floor model; the readout keys its rows `adaptations: sweep:claude`) | inside the sweep's $8 |

Omitted from that window: the `parallel: false` fact live (the fact and its
machinery are gone since 2026-09-16 — a direct test on eight cells answered it), the standalone-loop cell
(no driver), kimi-k3's wall cell, the sweep's glm-5.3 Long.

**The historical comparison rule chosen on 2026-09-15: n=2 against frozen n=3 columns**, per
cell = (task × model), success-when-reached (the ledger's `s<succeeded>/<reached>`): a cell GAINS when its
baseline column reads ≤ 1/3 and the variant reads 2/2; a cell LOSES when its baseline reads ≥ 2/3 and the
variant reads 0/2; a candidate ENTERS its gem row's field on ≥ 2 gaining cells and 0 losing cells on the
family's STRONG model; everything between is "unread at n=2" and stays a candidate at no cost (n=2
cannot tell 1-in-2 from 2-in-3). The baseline column for glm is `2026-09-11-12a-glm-compose` /
`-workflow` (bench `455499c90b7e`), for kimi `2026-09-11-12a-kimi-compose-nexus-rerun` (`455499c90b7e`) and
`2026-09-11-run-kimi-workflow` (`d42e9e45cc93`); cell (a)'s `pack` column is the same-day re-read of that
baseline on the final code and is READ beside it, never pooled (the bench was version 4 then: its own
column). The probes keep their own bar (≥ 2/3 valid-first AND correct-shape per gate objective; T2, the
control and the SP rows ≥ 2/3) read against the same-day baseline cells already in their readouts. A
floor's cells are FACTS, never a verdict (no gem row names a floor id).

**How those experiment outcomes were recorded:** a candidate that clears
the rule is PROMOTED — its value moves into the gem row's field
(`sdks/ruby/lib/cybros_agent/model_adaptations/rows/<row>.yml`; the dated records retain the evidence) and leaves `e2e/evals/candidates/<row>.yml`; one that does not is DELETED
from the candidates file and stays a readout finding. The prune-count control (cell (c)) left whole after the
window — the arm prunes while the results outside the keep-recent tail cover the overshoot net of the
placeholders and summarizes once they cannot; nothing to configure.
`E2E_WALL_KERNEL_FILES` changes the generated fixture size; a smoke run using it is not the frozen benchmark cell.

## 8. Container evaluation families and installation journeys

The two external task-pass corpora — Agents-on-Rails (§8a) and Terminal-Bench (§8b), each run through
the one evals lane inside its own container — and the installation journeys (§8c) have their own page:
[Container evaluations and installation journeys](evals-containers.md).

## 9. The checklist (copy-pasteable, from the repo root)

```sh
# 1. the key's location (never its value) and the open-files limit
set -a; source nexus/.env; set +a
ulimit -n 4096
cd e2e

# 2. the gate (concurrency follows Postgres capacity; nothing else booting)
bundle exec rake e2e

# 3. the corpus lists (no boot)
bundle exec rake evals_tasks

# 4. the smoke: one task, the floor, one run (paid; one world; ≈ 3–5 min)
E2E_LIVE=1 E2E_EVALS_RUNS=1 bundle exec rake "evals[shape-linear,deepseek/deepseek-flash]"

# 5. read the report line it printed:
#    evals: shape-linear deepseek/deepseek-flash nexus #1 reach=t success=t pass=t rounds=… calls=…
#      bytes=… cost=… USD cache=… compactions=0 nudged=… swept=… seconds=…
#    no [class] on the tail = green. Its record is the last line of
#    artifacts/evals/runs/<today>-deepseek_deepseek-flash/records.jsonl

# 6. the scorecard (no boot) — use the exact label printed by the run
bundle exec rake "evals_scorecard[<label>]"

# 7. the ledger (no boot)
bundle exec rake evals_ledger

# 8. review the local records, scorecards and ledger; keep them under artifacts/
#    A change to what a cell MEASURES — a predicate, a picture, a reader, a driver's answer — is a
#    bench-version bump (bench.yml's `version` and its note) and a new column, never a re-score of an
#    older version's records: `rake evals_rescore` refuses a record of another bench unless forced,
#    and `force` is kept for a harness fault's re-score on the bench the record ran under.
#    Write and commit a reviewed conclusion in evals/analysis/ only when it is useful beyond this run.

# 9. the traces and the logs of the run are local evidence:
ls artifacts/evals/*/ artifacts/evals/*/logs/*/
```

A red at step 4 with `error` on the record, or `stopped=deadline` or `stopped=cost_stop` with
`rounds_settled: 0`, is a lane bug (§6.1) — read `artifacts/evals/<label>/logs/<run>/nexus.server.log`
and `daemon.log` before anything else, then the boot they do not hold: the group's
`logs/boot.<configuration>/daemon.log`, `rho.log` and `nexus.server.log`, and `logs/boot.world/`. A red
with a reason in the trace's words, or a stop with rounds settled, is the model's (§6.2) — it is the measurement. A `kernel finding` stops the schedule (§6.3): the
MODEL's schedule, when it makes every later cell measure the defect instead of the model; the other
model's schedule continues. A `disagreement` (§6.4) stops nothing: read both scorers.

Two more steps that belong to the checklist and not to the schedule:

```sh
# 1′. after the gate: the Workflow row rendered through the KERNEL with no daemon (no boot, ≈ 5 s) —
#     20 names incl. `Workflow`, no `compose`. `active_support/all` first: without it the render dies
#     at nexus/lib/nexus/tool_registry.rb:468 (`index_by`) in a fresh process.
bundle exec ruby -e 'require "active_support/all"; require_relative "support/task_bench/declared_set"; puts E2E::TaskBench::DeclaredSet.names(style: "workflow")'

# 11. after step 4: THE DELIBERATE RED — a stopped run must be a record with its trace, never an empty
#     line (the pin is test/evals_salvage_test.rb; this is its live twin). A scratch task, its own name,
#     a 10 s deadline (the floor finishes shape-linear in ≈ 15–20 s, so 30 s may never fire; 10 s lands
#     between the write round and the bash round), run under its own label on the floor:
cp -r evals/tasks/shape-linear evals/tasks/shape-linear-red30
sed -i '' -e 's/^name: shape-linear$/name: shape-linear-red30/' -e 's/^deadline_seconds: .*/deadline_seconds: 10/' evals/tasks/shape-linear-red30/instruction.md
E2E_LIVE=1 E2E_EVALS_RUNS=1 E2E_EVALS_LABEL=red30-probe bundle exec rake "evals[shape-linear-red30,deepseek/deepseek-flash]"
#     the report line reads `stopped=deadline`; its record has `loops` non-empty, `rounds > 0`, and its
#     artifact json carries graph / tasks / events / spend / sealed_request; the class is `model conduct`
#     when rounds settled before the stop (§6.2) and `lane bug` when none did (§6.1). Then DELETE the
#     scratch task and its runs dir — never committed: while the task dir exists, harness_test is red
#     (evals_expected_test's two-sided rule refuses a task with no drawings):
rm -r evals/tasks/shape-linear-red30 artifacts/evals/runs/*-red30-probe
```
