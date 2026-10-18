# rho on Terminal-Bench 2.0 — the re-scoring of 2026-09-18

Four cells on the amd64 box after the ACP round's fixes: the three models through the ACP door (harbor 0.23.0
driving `rho-acp`) and the floor through our own plain driver as the harness's re-baseline. 21 tasks × k=3 per cell.

This is a historical result on a selected 21-task subset, not a full Terminal-Bench score or qualification of the
current source tree. The archive check on 2026-09-19 parsed the 252 retained records and reproduced their scorecards
without running a model. The original run notes identify source snapshot `d38a3adf`; the compact records contain
the bench digest, not a source revision, and the remote traces were not rechecked during this archive review.

The plain cell records six deadline stops and five `needs_person` stops; five of these stopped trials still passed
verification. The ACP records omitted Harbor's termination reason until 2026-09-22, when the importer
was taught to keep Harbor's `result.json` exception: the 16 trials that carried no stop reason (floor 5, glm 6,
kimi 5; every one 919–1 024 s against a 900 s agent budget) are Harbor's `AgentTimeoutError`, and the records and
scorecards here were re-imported from the job directories to say so — a budget cut now reads as `deadline` with
the exception beside it. Thirteen of those trials failed verification and three passed (floor 2, kimi 1).
The pass counts are unchanged by that re-import; termination and verification are now recorded separately.

## The headline

| cell | form | model | task pass | previous | misses by kind |
|---|---|---|---|---|---|
| `2026-09-18-acp-floor` | harbor → `rho-acp` | deepseek/deepseek-flash (direct) | **56/63 (89 %)** | 53/63 (2026-09-19 ACP), 57/63 (2026-09-17 plain) | 7 failed rewards, 3 of them Harbor timeouts; 2 other timed-out trials verified |
| `2026-09-18-acp-kimi` | harbor → `rho-acp` | openrouter/moonshotai/kimi-k3 | **54/63 (86 %)** | 53/63 (2026-09-17 plain) | 9 failed rewards, 4 of them Harbor timeouts; 1 other timed-out trial verified |
| `2026-09-18-acp-glm` | harbor → `rho-acp` | openrouter/z-ai/glm-5.3 | **43/63 (68 %)** | 51/63 (2026-09-17 plain) | 20 failed rewards, 6 of them Harbor timeouts |
| `2026-09-18-score-floor` | plain driver (`rho do`) | deepseek/deepseek-flash (direct) | **54/63 (86 %)** | 57/63 (2026-09-17 plain) | 3 verification failed, 4 deadline, 2 asked a person |

Earlier run notes reported Harbor's terminus-2 agent with kimi-k3 at 45/63 on the same 21 tasks and k.
The retained records in these four directories do not independently substantiate that calibration result.
Run-directory dates are labels:
the earlier `2026-09-19-harbor-acp-floor` records actually start on 2026-09-18 at 05:17 UTC, before the new ACP floor
cell at 12:42 UTC. The labels are preserved. That earlier cell was re-imported through the fixed importer on
2026-09-23, after an open-queue census found it had been left behind when the three cells above were re-read: its
53/63 stands, and five of its ten reds now carry `deadline (failed) — AgentTimeoutError` where the committed
scorecard had said `verification failed`.

## What changed since the last scoring

The run notes identify `df87d78c` for the 2026-09-17 scoring and `d38a3adf` for this one. Between those revisions the ACP round landed and, on its way,
fixed what its own lanes exposed: the conversation lead was sent once instead of every turn
since 2026-09-08 (every model's context changed with that fix), the `developer` role was refused on the direct
Anthropic/Gemini wires, a reply turn's prompt text was unreadable, an abandon raced the turn converger, and — found
by this re-scoring's first cell — a root set on a runner elsewhere was refused by the daemon's host. The harness
gained per-world Rails logs, and the ACP cell's sidecar stopped racing the pairing page.

## The ACP door, cell by cell

- **The floor through ACP is close to the plain driver in this sample.** 56/63 against the plain driver's 54/63
  today and 57/63 on 2026-09-17. Median trial 125 s, longest 967 s (gcode-to-text #1). The seven failed rewards are
  gcode-to-text ×3, polyglot-c-py ×3 and extract-elf ×1; five trials (gcode-to-text ×3, largest-eigenval ×2) hit
  Harbor's 900 s agent budget, and two of those five still passed their verifier. The records establish that work
  can pass verification at the budget cut; they do not isolate how much boot-and-pairing overhead or model behavior
  caused the difference from the earlier cell.
- **kimi-k3 through ACP: one more pass than the prior plain cell.** 54/63 against 53/63 plain. Misses:
  polyglot-c-py ×3, chess-best-move ×2, gcode-to-text ×2, dna-insert ×1, largest-eigenval ×1. Median 150 s,
  longest 1 380 s (chess-best-move #3).
- **glm-5.3 through ACP: eight fewer than plain.** 43/63 against 51/63. Where it lost: chess-best-move 3→1,
  code-from-image 3→1, log-summary-date-ranges 3→1, polyglot-c-py 2→0, build-cython-ext 3→2, vulnerable-secret
  3→2, extract-elf 2→1; where it gained: sanitize-git-repo 1→3, multi-source-data-merger 2→3. Each miss has a failed
  verifier reward; six were cut by Harbor's agent deadline, as the re-imported exception records establish.
  The two forms differ in what the model is given: the
  plain cell runs under the bench's own adaptations row (`bench-nexus`: the `nexus` tool style; compose on, as
  every evals group's daemon home is written) and our lead; the ACP session runs under rho's default row with
  harbor's task text as the one prompt. Which of those
  the eight trials turn on is not read off these records — it is the next question for the trace reader, and the
  comparison that a later targeted investigation could address. No paid rerun was made for this archive check.

## The plain floor, against itself

54/63 today against 57/63 on 2026-09-17, on the same model name at a different source revision and with the lead
now rendered every turn. The records do not identify a provider-side model checkpoint change between these runs:

| task | 2026-09-17 | 2026-09-18 | what moved |
|---|---|---|---|
| extract-elf | 1/3 | 3/3 | two deadlines became passes |
| multi-source-data-merger | 3/3 | 1/3 | two runs ASKED a person (37 s, 70 s) — the harness's `needs_person` stop; a plain driver scripts no answer |
| polyglot-c-py | 2/3 | 1/3 | one more verification failure |
| dna-insert | 3/3 | 2/3 | one verification failure |
| gcode-to-text | 0/3 | 0/3 | three deadlines in 2026-09-18 (1 000–1 052 s of a 900 s task); in 2026-09-17 two (995 s, 996 s) and one trial that settled at the wire and failed verification |
| largest-eigenval | 3/3 | 2/3 | three deadlines both times; two verified at the cut, one not |
| sanitize-git-repo | 3/3 | 3/3 | three ASKS this time (204–500 s), each verified — the work was done before the question |

The five asks are a new recorded termination shape. Verified at the ask, that is a pass; both
multi-source-data-merger trials that asked failed verification (37 s and 70 s). The plain driver does not script
an answer and records `needs_person`; these records alone do not establish how the equivalent interaction ended
on the ACP door.

## Per task, every cell

Pass counts out of 3. `plain` = our driver, `acp` = harbor → rho-acp.

| task | floor plain 09-17 | floor plain 09-18 | floor acp 09-19 | floor acp 09-18 | glm plain 09-17 | glm acp 09-18 | kimi plain 09-17 | kimi acp 09-18 |
|---|---|---|---|---|---|---|---|---|
| build-cython-ext | 3 | 3 | 3 | 3 | 3 | 2 | 3 | 3 |
| chess-best-move | 3 | 3 | 2 | 3 | 3 | 1 | 1 | 1 |
| code-from-image | 3 | 3 | 3 | 3 | 3 | 1 | 3 | 3 |
| constraints-scheduling | 3 | 3 | 3 | 3 | 3 | 3 | 3 | 3 |
| db-wal-recovery | 3 | 3 | 3 | 3 | 3 | 3 | 3 | 3 |
| dna-insert | 3 | 2 | 3 | 3 | 1 | 1 | 1 | 2 |
| extract-elf | 1 | 3 | 3 | 2 | 2 | 1 | 3 | 3 |
| gcode-to-text | 0 | 0 | 0 | 0 | 0 | 0 | 1 | 1 |
| git-leak-recovery | 3 | 3 | 3 | 3 | 3 | 3 | 3 | 3 |
| kv-store-grpc | 3 | 3 | 3 | 3 | 3 | 3 | 3 | 3 |
| largest-eigenval | 3 | 2 | 1 | 3 | 2 | 2 | 3 | 2 |
| log-summary-date-ranges | 3 | 3 | 3 | 3 | 3 | 1 | 3 | 3 |
| merge-diff-arc-agi-task | 3 | 3 | 3 | 3 | 2 | 2 | 3 | 3 |
| modernize-scientific-stack | 3 | 3 | 3 | 3 | 3 | 3 | 3 | 3 |
| multi-source-data-merger | 3 | 1 | 3 | 3 | 2 | 3 | 3 | 3 |
| openssl-selfsigned-cert | 3 | 3 | 3 | 3 | 3 | 3 | 3 | 3 |
| polyglot-c-py | 2 | 1 | 0 | 0 | 2 | 0 | 0 | 0 |
| regex-log | 3 | 3 | 3 | 3 | 3 | 3 | 3 | 3 |
| sanitize-git-repo | 3 | 3 | 2 | 3 | 1 | 3 | 2 | 3 |
| sqlite-db-truncate | 3 | 3 | 3 | 3 | 3 | 3 | 3 | 3 |
| vulnerable-secret | 3 | 3 | 3 | 3 | 3 | 2 | 3 | 3 |
| **total** | **57** | **54** | **53** | **56** | **51** | **43** | **53** | **54** |

Eight tasks are 3/3 across all eight displayed cells: constraints-scheduling, db-wal-recovery, git-leak-recovery,
kv-store-grpc, modernize-scientific-stack, openssl-selfsigned-cert, regex-log and sqlite-db-truncate.
gcode-to-text and polyglot-c-py remain weak spots, but are not universally unsolved: kimi passes gcode-to-text once
in each form; the floor passes polyglot-c-py once in the new plain cell and twice in the prior one, and the prior
glm plain cell passes it twice.

## Time and money

| cell | trials | recorded trial span | median / longest trial | spend |
|---|---|---|---|---|
| acp-floor | 63 | 1 h 14 m 11 s | 125 s / 967 s | ≈ ¥17.8, reported balance change |
| acp-glm | 63 | 1 h 25 m 36 s | 200 s / 991 s | $17.64, reported OpenRouter spend |
| acp-kimi | 63 | 1 h 28 m 22 s | 150 s / 1 380 s | $17.95, reported OpenRouter spend |
| score-floor (plain) | 63 | 5 h 50 m 47 s | 202 s / 1 052 s | $3.962608422 from records; ≈ ¥6.8 reported balance change |

The trial span is the earliest `started_at` through the latest `started_at + seconds`, not the whole job's wall
time. Original run notes reported job times of 85, 88 and 90 minutes for the ACP cells and 5 h 54 min for the plain
cell. The reported balance changes also included probes. Those operator observations and ACP costs are not independently derivable from the compact records;
ACP records have empty efficiency fields. The notes describe four concurrent Harbor trials and one sequential
plain world running beside them.

## How it was run

- Corpus named by the run notes: terminal-bench 2.0 at `69671fba`, the 21 tasks the bench names
  ([bench.yml](../../e2e/evals/bench.yml)), each with its own
  `[agent].timeout_sec` as the budget (900 s for 17, 1 200 s for two, 1 800 s dna-insert, 600 s vulnerable-secret).
- The ACP door: `rake "evals_harbor_acp[run]"` boots a Nexus world on the box (bound on the LAN), writes an overlay
  corpus whose every task is `FROM` the plain driver's derived image with `tini` alone as the entrypoint, hands
  harbor the registry entry (`agents/rho/rho-acp/registry/rho/agent.json` with the launcher as its `local`
  distribution), and runs `uvx --from harbor harbor run -a acp -m <model> -k 3` while a sidecar pairs every container's
  daemon through the steward's device page; harbor's own runner drives `rho-acp` with the task as one prompt and
  scores by the task's tests. Harbor's agent budget also pays for the in-container boot and pairing; the exact
  effective limits and timeout outcomes require the remote job configuration and results, not these compact records.
- The plain driver: `rake "evals[terminal-bench/*,<model>]"` — one world, one daemon home per group under the
  bench's `bench-nexus` adaptations row, `rho do --dir /app --runner <container>` per trial, the trace read off the
  member plane, the task's tests run by `docker exec`; a deadline stops the loop, an unanswered model question stops
  it as `needs_person`.
- The floor row is text-only (`deepseek-flash` declares no image input). The run notes attribute its code-from-image
  passes to OCR tools in the container; the compact records retain the passes, not that tool trace.
- Locally retained records and scorecards: ACP floor (`2026-09-18-acp-floor`),
  ACP glm (`2026-09-18-acp-glm`), ACP kimi (`2026-09-18-acp-kimi`) and
  plain floor (`2026-09-18-score-floor`), with the generated trend table
  (`LEDGER.md`). These records are not included in the public checkout. Each
  scorecard contains 63 unique `(task, model, style, run)` rows covering
  the same 21 tasks and runs 1–3. All use bench digest `e90719a7c42711c8bbc1362b8a0b920b1ddca95ec756debf09fe0995fbb294e7`.
  The archive check reproduced the four scorecards byte-for-byte from those records with the offline renderer
  used for that check; this document update did not run a new measurement.
- The three ACP record sets now point to local copies under `e2e/artifacts/evals/harbor-jobs/2026-09-18-acp-*`.
  All 189 trial results and ACP event logs were available for the 2026-09-22 re-import; these local artifacts are
  not tracked in Git. The plain records retain absolute artifact paths on the original benchmark host;
  they are not portable links in a fresh checkout. The original box and its other artifacts were not rechecked. The reviewed results and event tallies
  support pass counts and termination reasons; they do not establish why model outcomes differed or prove that
  the remote image exactly matched the named source snapshot.
- Tree reported by the run notes: `d38a3adf`; the two blockers the first launch hit — the root on a runner elsewhere
  (`b4d2737b`) and the pairing-page race (`d38a3adf`) — are in it.

## What to do with these numbers

1. Use these numbers as historical results for the named subset and configurations. They do not qualify the
   current implementation or establish a full-corpus pass rate.
2. Inspect glm's changed task outcomes in the available traces, recovering any missing artifacts from the original
   box, before assigning causes to model behavior, adaptations or the prompt form. The eight-pass difference is
   a net count across separate cells, not eight matched failed trials.
3. Keep any future scripted-answer experiment separate: answering a plain driver's `needs_person` changes its
   interaction policy and would produce another cell, not a correction to these results.
   A later harness change on 2026-09-23 answers
   the first ask of an unattended run with one fixed sentence from `bench.yml` and stops at the second, and the
   bench version moved 9 → 10 so those cells carry a different `bench_digest` and land in their own ledger column.
   The numbers in this report are version 9 and are unaffected.
4. The ACP scores can be reported with their model, 21-task selection, k=3 and source limitations. The calibration
   comparison is descriptive; it does not establish general superiority or equivalent prompts and runtime budgets.
