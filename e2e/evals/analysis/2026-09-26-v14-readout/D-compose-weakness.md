# D — Why compose underdelivers, read from the data

Characterization only: no fix is designed here. Every number below is printed by one of the scripts in the appendix
(`d1`…`d7` and `d5_check.sh`, with the shared loaders `d_common.rb` and `d_harness.rb`), each followed by its
verbatim output. Scratch directory: `/private/tmp/claude-501/-Users-jasl-Workspaces-cybros-ai-alt2/fe6d4094-2f85-4b52-abfc-78043a70e275/scratchpad/v14/readout/`.

## D.0 What was read, and how

- **Records.** v14: `e2e/evals/runs/2026-09-26-v14-{compose,workflow,task}/records.jsonl` (108 / 60 / 72 lines, one
  per run, digest `f69dc4cc6ab4`). v13: the same files under `2026-09-25-v13-*`, read through the harness's own
  merge rule (`E2E::Evals::Records.read`: **the last line per (task, model, style, run) wins**), which is how v13's
  in-place rescores under its own digest `ab836ee0d8be` (563a86aa, 5de9f94a) are read. v13 compose is 139 lines
  → 108 records, workflow 77 → 60, task 84 → 72 (D1 inputs). Because those rescores moved buckets (the O4
  launch ruling, the failed-stage reading), **v13 figures here differ from the v13 readout's §3.2**, which predates
  them — e.g. the v13 strong reds read `extra_steps` 3 and `over_sync` 3 here, not 5 and 4, and no
  `suite_waited_on`.
- **Bars.** "picture" = `facts.picture == true` (the strong tier's bar: first call valid, exact edges and reads,
  branch completed; it rides on every tier). "usable" = `facts.usable_on_call` non-nil (the floor's bar: some compose
  call of the run met usable generation; also recorded on every tier). "success" = `verdict.succeeded`, i.e. the
  tier's own bar. compose-rendezvous (T5) is recorded-only (its success is "accepted" / "usable + completed"); it is
  kept in the picture-miss counts and split out where it matters ("gate tasks" = the seven picture tasks without T5).
- **Offline re-reads.** D2, D5 and D6 rebuild each trace as `Rescore.trace_of` does and call the harness's own
  readers (`Predicates.score_compose`, `Executed.plan`/`lower`/`labels`, and `Picture`'s private
  `values`/`held`/`extensions`/`closest`/`weighed_reads`) under the e2e bundle (the evaluator needs mini_racer). The
  harness is the one that scored v14: `git diff 4a8cf2ea HEAD -- e2e/support nexus/lib e2e/evals/tasks
  e2e/evals/bench.yml` is empty. The re-reads reproduce the records: all 49 over_read readings give the recorded
  buckets (D2a `agree` column); the unchanged-plan control in D5 matches 185/186 — the one difference is v13
  grep-then-edit kimi-k3 #2, recorded `wrong_task_read`, which v14's reader names `edit_as_stage` (the refinement
  bench.yml's VERSION 14 note describes; the record was deliberately not rescored, and is not here).
- **Rules kept.** No paid call, no world, no suite; no record touched; no worktree touched. Nothing here uses the Q10
  analysis (`e2e/artifacts/bench/2026-09-26-q10/`), so its after-the-fact launch stamp does not bear on this
  section (it is section B's to disclose).

## D.1 The compose family's reds and picture misses (d1)

Per cell, success on the tier's bar / picture exact, v13 → v14 (n = 3):

| task (succ/pic) | glm-5.3 | kimi-k3 | ds-flash | glm-flash |
|---|---|---|---|---|
| review-angles | 2/2 -> 3/3 | 3/3 -> 3/3 | 3/3 -> 3/3 | 3/2 -> 3/3 |
| grep-then-edit | 2/2 -> 2/2 | 1/1 -> 2/2 | 3/2 -> 3/3 | 2/1 -> 3/1 |
| race | 3/3 -> 3/3 | 3/3 -> 3/3 | 3/2 -> 3/3 | 3/2 -> 3/2 |
| race-anon | 3/3 -> 3/3 | 3/3 -> 3/3 | 3/2 -> 3/3 | 3/3 -> 3/3 |
| background-suite | 1/1 -> 1/1 | 1/1 -> 1/1 | 3/0 -> 3/1 | 3/1 -> 3/1 |
| three-stage-pairing | 2/2 -> 3/3 | 2/2 -> 3/3 | 3/3 -> 3/1 | 2/1 -> 2/1 |
| two-source-fan-in | 0/0 -> 1/1 | 0/0 -> 0/0 | 3/1 -> 3/0 | 3/1 -> 3/2 |
| rendezvous (recorded) | 3/0 -> 3/1 | 3/0 -> 3/0 | 3/0 -> 3/0 | 3/0 -> 3/2 |

compose-single-read (the control) composed nothing on 12/12 in both versions.

**Picture-miss buckets, ranked** (D1b verbatim; one count per record per bucket; a refusal is `refused:<loud
bucket>`; `unusable_plan` is a missed picture that usable generation's words name, with its silent buckets in
parentheses):

**v14:** 35 picture misses of 96 picture-task runs (strong 16, floor 19)
| bucket | all | strong | floor | glm-5.3 | kimi-k3 | ds-flash | glm-flash |
|---|---|---|---|---|---|---|---|
| over_read | 21 | 10 | 11 | 6 | 4 | 8 | 3 |
| extra_steps | 5 | 2 | 3 | 2 | 0 | 1 | 2 |
| blind_model | 3 | 3 | 0 | 0 | 3 | 0 | 0 |
| over_sync | 3 | 2 | 1 | 1 | 1 | 1 | 0 |
| refused:syntax | 3 | 1 | 2 | 0 | 1 | 1 | 1 |
| missing_steps | 2 | 1 | 1 | 0 | 1 | 0 | 1 |
| (missing_join) | 1 | 0 | 1 | 0 | 0 | 0 | 1 |
| (missing_steps) | 1 | 0 | 1 | 0 | 0 | 0 | 1 |
| no_compose_call | 1 | 0 | 1 | 0 | 0 | 0 | 1 |
| refused:member_not_a_step | 1 | 0 | 1 | 0 | 0 | 0 | 1 |
| unusable_plan | 1 | 0 | 1 | 0 | 0 | 0 | 1 |

**v13:** 46 picture misses of 96 picture-task runs (strong 22, floor 24)
| bucket | all | strong | floor | glm-5.3 | kimi-k3 | ds-flash | glm-flash |
|---|---|---|---|---|---|---|---|
| over_read | 28 | 15 | 13 | 7 | 8 | 6 | 7 |
| extra_steps | 7 | 3 | 4 | 1 | 2 | 1 | 3 |
| over_sync | 5 | 3 | 2 | 2 | 1 | 1 | 1 |
| (missing_steps) | 3 | 2 | 1 | 1 | 1 | 0 | 1 |
| no_compose_call | 3 | 1 | 2 | 1 | 0 | 0 | 2 |
| refused:syntax | 3 | 1 | 2 | 1 | 0 | 2 | 0 |
| unusable_plan | 3 | 2 | 1 | 1 | 1 | 0 | 1 |
| (missing_join) | 1 | 0 | 1 | 0 | 0 | 0 | 1 |
| refused:after_in_input | 1 | 0 | 1 | 0 | 0 | 0 | 1 |
| refused:group_reference | 1 | 0 | 1 | 0 | 0 | 0 | 1 |
| refused:member_not_a_step | 1 | 0 | 1 | 0 | 0 | 1 | 0 |
| refused:unknown_option | 1 | 0 | 1 | 0 | 0 | 1 | 0 |
| wrong_task_read | 1 | 1 | 0 | 0 | 1 | 0 | 0 |

- **over_read is the first bucket on both versions and by a wide margin**: 28/46 = 60.9 % of v13's picture misses,
  21/35 = 60.0 % of v14's; on the seven gate tasks alone (T5 set aside) 17/34 = 50.0 % and 14/26 = 53.8 % (D1h).
  It is spread evenly across tiers (v14 strong 10, floor 11) and across models.
- **It lives on four tasks only** (D1c, v13 → v14): rendezvous 11 → 7, two-source-fan-in 8 → 8, background-suite
  7 → 5, three-stage-pairing 2 → 1. None on review-angles, grep-then-edit, race or race-anon.
- The next buckets are much smaller: `extra_steps` 7 → 5 (background-suite 6 → 4 of them, D1c: a closing report
  after the fix), `over_sync` 5 → 3 (grep-then-edit and two-source-fan-in only; D6 shows every one is a written-order
  wait), `blind_model` 0 → 3 (all kimi-k3 on v14: rendezvous #1 and #3, whose reviewers and merge are value stages,
  and background-suite #3), and `refused:syntax` 3 → 3 beside four one-off refusals on v13 and one on v14.
- **The strong tier's reds** (success is the picture there) are 16 → 11, and `over_read` is on 9 → 7 of them (D1f).
  The floor's reds (usable bar) are 2 → 1, each a run that made no compose call.
- **`edit_as_stage`, v14's new O2 bucket, decides nothing on v14**: it is on 0 executed (recorded) readings and on
  6 static readings beside them, all grep-then-edit runs whose executed picture is exact (D1d, D1h). `wrong_task_read`
  is 1 → 0.
- **Barrier-free (O7 in the workflow family)** misses on `edit_as_tool` (a `cat` merge tool) or on no compose call;
  it carries no `over_read` on either version (picture 1/12 → 0/12, D1g).

## D.2 over_read in depth (d2)

Every over_read reading re-derived with the picture's own correspondence (`closest`) and weighed reads. For each
step that read more than its picture label allows, each extra source is classed **implicit** (the kernel's cursor
delivered it — the spine and the material behind the tip, a group's accumulated members — and the script did not
name it) or **explicit** (named in the step's `results:`, directly or through a stage it named). A step a g.script
stage placed is split the same way off the kernel's `result_from` (none of the four such plans holds an inner stage).

**Totals (D2b):**

| | over_read readings | extra reads | implicit | explicit | readings all-implicit | readings with explicit over-naming |
|---|---|---|---|---|---|---|
| v13 | 28 | 97 | 75 (77.3 %) | 22 | 20/28 | 8 |
| v14 | 21 | 66 | **57 (86.4 %)** | 9 | **18/21** | 3 |
| both | 49 | 163 | 132 (81.0 %) | 31 | | |

On v14 every one of the 57 implicit extra reads is a raw **tool output** (D2b source kinds: `tool 57`).

**What the step's author asked for (D2f, per over-reading step):**

| | over-reading steps | named a subset; position added the rest | named nothing (all positional) | over-named (every extra named) | mixed | a value stage named them |
|---|---|---|---|---|---|---|
| v13 | 41 | 27 | 4 | 4 | 4 | 2 |
| v14 | 27 | **20** | 4 | 3 | 0 | 0 |

So the dominant over_read is **not** a model asking for too much. It is a model that wrote `results:` naming exactly
what its picture label reads — the two summaries, the two reviews, its own head and the dump, the three normalisers —
and received, by position, the raw outputs the group before it accumulated. Where each extra came from (D2c, both
versions, reader label / how / source kind / count): two-source-fan-in `report` implicit tool 42, plus 3 in a
stage-placed plan; rendezvous `merge` implicit tool 48, plus 7 stage-placed; its reviewers `rm` and `rs` implicit tool
7 each (the other review's head), plus 1 implicit and 1 named each in the stage-placed v13 glm-5.3-flash #2 plan;
three-stage-pairing `merge` implicit tool 3 (v14 ds-flash #1, `results: [na, nb, nc]`) and 6 named by a value stage
(v13 glm-5.3 #2 and glm-5.3-flash #2).

**The explicit remainder** on v14 is one pattern, 3 readings, all background-suite: a closing report after the fix
that names the `start_process` launch's receipt — glm-5.3 #1 `results: [tests, audit, fixer, verify]`, glm-5.3 #3
`results: [suite, fixer, verify]`, ds-flash #3 `results: [tests, fix]`. Under the owner's 2026-09-25 O4 ruling a step
reading the launch's receipt reads suite output, so `over_read` (and `extra_steps`) stand there by ruling.

**How the models expressed it — their own script lines** (D2e has every reader; the first four are quoted from the
traces named):

- v14 two-source-fan-in kimi-k3 #3, the report after a five-member group:
  `g.parallel([test, lint, typecheck, testSummary, qualitySummary]);` then
  `// Final report joins only the two summaries (it implicitly waits for all of the above).` and
  `results: [testSummary, qualitySummary],` — it read `test`, `lint` and `typecheck` as well.
- v13 rendezvous ds-flash #1: `// 4. merge: placed after the group, so it reads both reviews and nothing else.` —
  the merge (naming nothing) read migrate, seed and dump too.
- v13 rendezvous ds-flash #3: `g.parallel([migrateReview, seedReview]);   // the two reviews run at once, isolated from each other`
  with `results: [migrate, dump]` / `results: [seed, dump]` — each review read the other's head.
- v13 rendezvous glm-5.3-flash #3: `// Stage 4 — merge, written after the reviews group: it reads both reviews' accumulated output.`
- The v14 over-reading reports and merges all carry a `results:` line naming the picture's sources (D2e):
  e.g. glm-5.3 #3, kimi-k3 #2, ds-flash #2/#3, glm-5.3-flash #2 on two-source-fan-in, `results: [testSummary, qualitySummary]`.

**Why the kernel does this** (read from the code, not the data): `Tasks::Compile#place_model` gives a model step
`input_from = [spine, *material]` from the cursor and appends its `results:` to `result_from`
(`nexus/app/services/agent_loops/tasks/compile.rb:298-307`); a group hands the step after it every member's exit and
content (`place_parallel`). The model-facing ORDER paragraph says the same — "A model step reads the output of the
steps before it … After an "all" group it reads the members' accumulated results", and `results:` "adds selected
completed results" (`nexus/lib/nexus/tool_registry/graph.rb:40-50`). `results:` is additive; the models write it as a
filter. The paragraph's own worked example for "producers and readers peers of the SAME group" ends
`g.parallel([a, b, c, d]); … g.model({prompt: "Combine the reviews."});` (graph.rb:80-86) — by the paragraph's rule
that closing step reads `a` and `b` raw, which is exactly the shape O7b's and T5's pictures bucket as `over_read`.

## D.3 The strong-vs-floor inversion, read like for like (d3)

Every record carries both bars, so each tier can be read on the other's (D3a, the seven gate tasks, 42 runs a tier):

| | official success | usable bar | picture bar |
|---|---|---|---|
| v13 strong | 26 | 41 | 26 |
| v13 floor | 40 | 40 | 24 |
| v14 strong | 31 | **42** | **31** |
| v14 floor | 41 | **41** | **27** |

**Like for like there is no aggregate inversion**: on the usable bar the strong tier is 42 against the floor's 41, on
the picture 31 against 27 (v13: 41/40 and 26/24). The headline gap (strong 31 vs floor 41 on v14) is the two bars.

**Where a floor model still beats both strong models on the same bar** (D3b): only on the picture, and only here —
v14 two-source-fan-in (glm-5.3-flash 2 vs glm-5.3 1, kimi-k3 0) and grep-then-edit (ds-flash 3 vs 2 and 2); v13
two-source-fan-in (ds-flash 1, glm-5.3-flash 1 vs 0 and 0) and three-stage-pairing (ds-flash 3 vs 2 and 2). On the
usable bar no floor model beats both strong models on any task.

**Two-source-fan-in: placement, not naming.** The shapes of all 24 first scripts (D3c; T tool, M model, `rN` = N
named results, P[…] a group):

| where the report stands | strong (v13+v14) | floor (v13+v14) | picture exact |
|---|---|---|---|
| inside the one group, a member naming the two summaries — `P[T T T Mr1 Mr2 Mr2]` | 1 | 4 | all exact |
| anywhere else (after the group, in its own group, or the plan inside a stage) | 11 | 8 | none exact |

(D3g.) The picture is exact exactly when nothing stands after the group. Both tiers name the right inputs: 14/15 (strong)
and 17/18 (floor) of v14's two-source model steps carry `results:` (D7). What the strong models do differently is follow
the compose text's own example — peers in one group, then a combining step after it: v14 glm-5.3 #3 and kimi-k3 #2/#3
write `P[T T T Mr1 Mr2] Mr2`, kimi-k3 #1 `P[T T T Mr1 Mr2] M`, glm-5.3 #1 the same inside a g.script stage. The exact
floor runs put the report in the group — glm-5.3-flash v14 #1:
`g.parallel([tests, lint, types, testSummary, qualitySummary, report]);` under the comment
`// All six steps live in one parallel: the three commands race from t=0, each summary starts as soon as its own inputs are done.`
The strong tier's one exact run (v14 glm-5.3 #2) is that shape too. rendezvous reads the same way (D3f): its exact runs
are glm-5.3-flash v14 #1 `P[T T Ta2 (Mr2) (Mr2) Mr2]` and #3 `P[T T Ta2 Mr2 Mr2 Mr2] Sr4` (the merge inside the group),
and glm-5.3 v14 #1, which wraps the whole group in a stage and hands the merge a value stage of the two reviews; every
"merge after the group" run over-reads.

**grep-then-edit (v14)**: the two strong misses are `over_sync` from three greps written one after another with no
`g.parallel` (glm-5.3 #2, kimi-k3 #3; D6: `g1->g2`, `g1->g3`, `g2->g3`, all written order), while ds-flash wrote the
fan. **three-stage-pairing (v13)**: glm-5.3 #2's merge is a value stage whose `results:` names the raw fetches beside
the normalisers (`results: [fetchA, normA, fetchB, normB, fetchC, normC]`).

**The strong tier does not write bigger plans** (D3e): v14 mean first-call node counts are equal or near-equal per task
(e.g. two-source 6.0 vs 6.0, rendezvous 6.2 vs 6.2, background-suite 4.0 vs 4.6, grep-then-edit 5.8 vs 6.2).

## D.4 Compose versus no compose (d4)

Runs with at least one compose call (D4a):

| model | compose family (24 non-control runs) v13 → v14 | workflow: composed v13 → v14 | workflow: `task` delegation v13 → v14 | workflow: neither v13 → v14 | task family: composed v13 → v14 |
|---|---|---|---|---|---|
| glm-5.3 | 23 → 24 | 3 → 4 /15 | 8 → 8 | 4 → 3 | 0 → 0 /18 |
| kimi-k3 | 24 → 24 | 3 → 1 | 6 → 8 | 6 → 6 | 0 → 0 |
| ds-flash | 24 → 24 | 2 → 2 | 8 → 4 | 5 → 9 | 1 → 1 |
| glm-flash | 22 → 23 | 5 → 2 | 6 → 9 | 4 → 4 | 0 → 0 |

- **When the prompt asks, nearly every run composes** (93/96 non-control runs on v13, 95/96 on v14). **When it is a
  choice, compose is the minority door**: 13/60 workflow runs on v13 and 9/60 on v14, against `task` delegation on
  28/60 and 29/60. On v14
  compose appears on two of the five workflow tasks only — barrier-free-pipeline (glm-5.3 3/3, glm-5.3-flash 2/3) and
  judge-panel (glm-5.3 1, kimi-k3 1, ds-flash 2) — and never on adversarial-verify, fan-out-finders or
  loop-until-dry (D4b).
- **Green**: pooled, composed runs are 12/13 (v13) and 6/9 (v14) green against 35/47 and 37/51 (D4c) — confounded by
  task: barrier-free-pipeline cannot pass without composing (its expected.rb refuses the task door), and its composed
  glm-5.3 runs are the v14 composed reds (0/3, `edit_as_tool`). Held within one task × model cell (cells that ran both
  ways), composing never lost green on v14 (barrier-free glm-5.3-flash 2/2 vs 0/1; judge-panel glm-5.3 1/1 vs 2/2,
  kimi-k3 1/1 vs 2/2, ds-flash 2/2 vs 0/1); on v13 every composed run sits in one of 9 mixed cells, and the one
  composed red is barrier-free glm-5.3 (1/2 against 0/1 not composed) (D4c).
- **Seconds and cost**: composed workflow runs take longer at the median — 147 s vs 101 s on v14, 165 s vs 101 s on
  v13 (D4c) — and cost moves with the model mix, not the door (v14 strong: $0.199 composed vs $0.251 not; floor $0.012
  both). Inside the compose family a missed picture costs no more than an exact one once the task is held fixed (D4f;
  e.g. v14 two-source strong $0.154 exact vs $0.153 missed, rendezvous floor $0.028 vs $0.026). The compose family's
  totals are $4.24 → $4.49 (glm-5.3), $4.33 → $4.49 (kimi-k3), $0.46 → $0.38 (ds-flash), $0.42 → $0.43
  (glm-5.3-flash) (D4d).

## D.5 The explicit-data-flow question, counted from the pictures (d5, d6, d7)

Ultracode's workflow scripts pass data explicitly between steps; our compose model steps read preceding material
implicitly by position. D5 asks, on every compose picture reading whose first call built and placed a plan (186:
v13 90, v14 96 — the gate tasks, T5 and barrier-free), what the picture would have been had **a model step read only
what its script names**. The plan the kernel ran is kept whole — every wait, tool and stage — and only each model
step's reads are replaced: **A (strict)** by its `results:` (race-expanded; a named stage stands for what it read);
**B (+history)** by that plus the model round it continues. The picture is re-scored with the harness's own
`Scoring.score_graph`. This re-reads the scripts **as written**: a model that relied on position and named nothing
reads nothing under the rule, and would presumably have written `results:` had the rule been in force — the data
cannot say. Nothing is implemented. The unchanged-plan control reproduces 185/186 recorded verdicts and buckets (the
one difference is the documented `wrong_task_read` → `edit_as_stage` refinement on v13 grep-then-edit kimi-k3 #2).

**The over_read readings under the rule (D5b, A):**

| | over_read readings | over_read gone | picture exact | still over_read | turned blind_model (named nothing) | other |
|---|---|---|---|---|---|---|
| v13 | 28 | 21 | 16 | 7 | 4 | 1 (`over_sync`) |
| v14 | 21 | **18** | **14** | 3 | 4 | 0 |

(The last three columns tally the D5b `left:` lists (d5_check): v14 still over_read = background-suite glm-5.3 #1, #3 and
ds-flash #3 — the three explicit receipt-namers of D.2; v14 blind = background-suite ds-flash #2 and glm-5.3-flash #2,
rendezvous ds-flash #2, two-source-fan-in kimi-k3 #1. v13's two-source glm-5.3 #3 loses over_read and keeps
`over_sync`.) Every miss the rule turns exact was an over_read reading (d5_check: v13 16, v14 14, 0 without
over_read). B gives the same verdict as A on every reading (D5a); on v13 one reading keeps its over_read bucket under B
(two-source glm-5.3 #3, D5b), so the continued round is not what the pictures turn on.

**The reds the rule would have removed** (D5d, compose family, strong tier, where success is the picture): v14 has 10
strong reds with a built plan; the rule makes **4** exact — all four two-source-fan-in (glm-5.3 #1 and #3, kimi-k3 #2
and #3), i.e. 4 of the 7 over_read reds. The other 3 over_read reds are the two receipt-naming background-suite reports
(explicit, so untouched) and kimi-k3 #1 (named nothing). v13: 14 reds with a plan, 4 exact, of 9 over_read reds.

**What the rule would break as written** (D5e): exact pictures that turn to misses because a step named nothing — v14
4 of 61 (background-suite kimi-k3 #2 and three-stage-pairing kimi-k3 #3 `blind_model`; review-angles glm-5.3 #3 and
glm-5.3-flash #2 `reads_mismatch`, the verdict step after the three reviewers naming none of them); v13 9 of 51. How
explicitly the models already write (D7): 118/168 model steps on v14's first built scripts name `results:` (70.2 %;
v13 115/168, 68.5 %), and nearly all of them on the tasks where over_read lives (two-source 14/15 strong, 17/18
floor; rendezvous 10/10, 17/18); review-angles reads 5/24 per tier because its three reviewers rightly read
nothing; its verdict step names the reviewers in 10 of 12 v14 scripts (D5f: 12 → 10 under A), and the 2 that do not are
D5e's breakage.

**Net, per task** (D5f, exact first-call pictures orig → A): v14 two-source-fan-in 3 → 10 (v13 2 → 9), rendezvous
3 → 9 (0 → 8), review-angles 12 → 10 (10 → 6), three-stage-pairing 8 → 8 (8 → 5), background-suite 4 → 3 (3 → 3),
grep-then-edit 8 → 8 (6 → 5), race/race-anon and barrier-free unchanged. On the seven gate tasks per tier (D5g, out of
42): **v14 strong 31 → 32, floor 27 → 30; v13 strong 26 → 25, floor 24 → 24.** As written, the rule roughly moves the
misses from the tasks where models name their inputs and position adds more (two-source, rendezvous) to the ones where
models leave the input to position (review-angles, three-stage-pairing); the gate-task totals barely move, and the
recorded-only T5 gains most.

**What it does not touch.** Waits. Every `over_sync` reading on both versions (v13 5, v14 3) is a wait from written
order that the waiting step did not name (D6): three greps written one after another with no `g.parallel`
(grep-then-edit: v13 2, v14 2), or a nested sequence `(T T Mr2)` that makes the type-check wait on the lint
(two-source-fan-in: v13 3, v14 1; v13 glm-5.3 #3 serializes everything); written order on 8/8. A reads-only rule leaves all 8; they are the
same "implicit by position" habit on the wait side. Nor does it touch refusals, missing compose calls, `extra_steps`, or
barrier-free's `edit_as_tool`.

## D.6 What it says

1. **Compose's picture misses are mostly one defect, and it is the kernel's implicit read, not the models' naming.**
   `over_read` is 60.0 % of v14's picture misses (21/35; 60.9 % on v13) and 7 of the strong tier's 11 reds. 57 of its
   66 extra reads on v14 (86.4 %) were delivered by position, every one a raw tool output; 20 of the 27 over-reading
   steps had named a subset of what they read in `results:` and got the group's raw outputs on top; the 14 readings
   that hold those 20 steps are the 14 the strict rule turns exact (D2e, D5b), so what they named was exactly their
   picture's inputs. The models'
   comments show they believe `results:` filters ("Final report joins only the two summaries", "so it reads both
   reviews and nothing else"); the kernel and its text make `results:` additive.
2. **The compose text teaches the defect.** Its "peers of the SAME group" example ends with a combining model step
   after the group, which by the ORDER paragraph's rule reads the producers raw — the O7b/T5 `over_read` shape. The
   strong models' two-source-fan-in scripts reproduce it; the floor's exact runs put the reader inside the group.
3. **"Why are the weak models better on two-source-fan-in?"** Mostly the bar: the floor is held to usable generation
   (both floor models 3/3 usable on it, on both versions), the strong tier to the picture. Like for like, the strong tier leads in aggregate
   on both bars (v14 usable 42 vs 41, picture 31 vs 27). On two-source-fan-in's picture itself a small real
   inversion remains (v14 glm-5.3-flash 2/3 vs glm-5.3 1/3, kimi-k3 0/3), and it is placement: exact exactly when the
   report is a member of the one group (5 runs, all exact), never when it stands anywhere else (11 strong and 8 floor
   runs, v13+v14); the floor placed it inside 4 times, the strong tier once. Both tiers name the same inputs.
4. **"Compose did not meet expectations?"** When asked, the models compose (95/96 non-control runs on v14) and the floor is usable on
   41/42 gate runs; what misses is dataflow exactness, concentrated on four tasks (rendezvous, two-source-fan-in,
   background-suite, three-stage-pairing) and one mechanism. When compose is a choice (the workflow family), models
   delegate with `task` far more often than they compose (29/60 vs 9/60 on v14), compose only where the
   task shape demands a pipeline or a panel, and composing costs time (median 147 s vs 101 s) without costing green
   within a cell.
5. **Explicit data flow, counted:** a "reads only what it names" rule removes `over_read` from 18 of v14's 21
   readings and makes 14 exact, including 4 of the strong tier's 10 built-plan reds; as written it breaks 4 of 61
   exact pictures where a step named nothing and relied on position, so the gate totals move only 31 → 32 (strong)
   and 27 → 30 (floor). Its analogue on the wait side would be the one to reach the 8 written-order `over_sync`
   readings. None of this is implemented or designed here.

## Appendix — the scripts and their verbatim outputs

Re-run from the scratch directory: the record-only scripts with `ruby <script>` (d1, d3, d4, d7), the trace re-reads under the e2e bundle with `cd /Users/jasl/Workspaces/cybros-ai.alt2/e2e && bundle exec ruby <scratch>/<script>` (d2, d5, d6; d5 takes about four minutes), and `zsh d5_check.sh` after d5. Ruby 4.0.7; every file read passes encoding UTF-8.

### d_common.rb

```ruby
# Shared loaders for section D. Read-only: records via the harness's own merge rule
# (Records.read: the LAST line per (task, model, style, run) wins — how v13's in-place
# rescores 563a86aa and 5de9f94a are read), traces from the artifact JSON.
require "json"
require "set"
ROOT = "/Users/jasl/Workspaces/cybros-ai.alt2".freeze
require File.join(ROOT, "e2e/support/evals/records")

module D
  BENCHES = { "v13" => "2026-09-25-v13", "v14" => "2026-09-26-v14" }.freeze
  MODELS = %w[openrouter/z-ai/glm-5.3 openrouter/moonshotai/kimi-k3 deepseek/deepseek-flash openrouter/z-ai/glm-5.3-flash].freeze
  SHORT = { "openrouter/z-ai/glm-5.3" => "glm-5.3", "openrouter/moonshotai/kimi-k3" => "kimi-k3",
            "deepseek/deepseek-flash" => "ds-flash", "openrouter/z-ai/glm-5.3-flash" => "glm-flash" }.freeze
  TIER = { "glm-5.3" => "strong", "kimi-k3" => "strong", "ds-flash" => "floor", "glm-flash" => "floor" }.freeze
  PICTURE_TASKS = {
    "compose-review-angles" => "O1", "compose-grep-then-edit" => "O2", "compose-race" => "O3", "compose-race-anon" => "O3",
    "compose-background-suite" => "O4", "compose-three-stage-pairing" => "O7", "compose-two-source-fan-in" => "O7b",
    "compose-rendezvous" => "T5", "workflow-barrier-free-pipeline" => "O7"
  }.freeze

  module_function

  def run_dir(bench, family) = File.join(ROOT, "e2e/evals/runs", "#{BENCHES.fetch(bench)}-#{family}")

  def records(bench, family)
    E2E::Evals::Records.read(run_dir(bench, family)).sort_by { |r| [r["task"], MODELS.index(r["model"]) || 9, r["run"]] }
  end

  def raw_lines(bench, family) = File.readlines(File.join(run_dir(bench, family), "records.jsonl"), encoding: "UTF-8").size

  def short(model) = SHORT.fetch(model)

  def trace_path(bench, family, record)
    File.join(ROOT, "e2e/artifacts/evals", "#{BENCHES.fetch(bench)}-#{family}", File.basename(record["artifact"].to_s))
  end

  def trace(bench, family, record) = JSON.parse(File.read(trace_path(bench, family, record), encoding: "UTF-8"))

  # The picture fact: true, or a String naming the miss.
  def picture_ok?(record) = record.dig("facts", "picture") == true

  # What a picture miss is, in one class and a list of buckets.
  def miss_buckets(record)
    score = record.dig("facts", "score")
    pic = record.dig("facts", "picture").to_s
    return ["no_compose_call"] unless score.is_a?(Hash)
    return ["refused:#{score["loud"]}"] unless score["valid_first"]
    silent = Array(score["silent"])
    if pic.start_with?("the picture is not the objective's")
      silent
    else
      # usable generation's words over a missed picture (a stage that failed, nothing placed)
      ["unusable_plan"] + silent.map { |b| "(#{b})" }
    end
  end

  def table(headers, rows)
    out = +"| #{headers.join(" | ")} |\n|#{headers.map { "---" }.join("|")}|\n"
    rows.each { |row| out << "| #{row.join(" | ")} |\n" }
    out
  end
end
```

### d_harness.rb

```ruby
# Loads the harness's own readers (unchanged since 4a8cf2ea: `git diff 4a8cf2ea HEAD -- e2e/support nexus/lib` is
# empty) to re-derive, offline and read-only, the correspondence the picture used on each reading. Run
# under the e2e bundle: `cd e2e && bundle exec ruby <script>` (the evaluator needs mini_racer).
require_relative "d_common"
require File.join(ROOT, "e2e/support/evals/predicates")
require File.join(ROOT, "e2e/support/evals/trace")

module DH
  P = E2E::Evals::Predicates
  CB = E2E::ComposeBench

  module_function

  # The trace the lane scored, rebuilt as `Rescore.trace_of` rebuilds it.
  def trace_of(record, stored)
    E2E::Evals::Trace.new(loops: Array(record["loops"]), graph: Hash(stored["graph"]), tasks: Array(stored["tasks"]),
      events: Array(stored["events"]), spend: stored["spend"], sealed: stored["sealed_request"],
      facts: Hash(stored["facts"]).merge("summaries" => Hash(stored["summaries"])))
  end

  # Walk the evaluator's steps beside its `lines` mirror: { step key => [verb, body, line] }.
  def step_index(steps, lines, out = {})
    Array(steps).zip(Array(lines)).each do |step, line|
      seq = Array.try_convert(step)
      if seq
        step_index(seq, line.is_a?(Array) ? line : Array(line), out)
      elsif step.key?("parallel")
        step_index(step["parallel"], line.is_a?(Hash) ? line["members"] : [], out)
      else
        verb = (step.keys & CB::Shape::STEP_WORDS).first
        body = step[verb]
        out[body["key"]] = [verb, body, line.is_a?(Hash) ? line["line"] : line]
      end
    end
    out
  end

  # The reading the picture made on the executed plan, re-derived with the picture's own private
  # readers: the graph the buckets read, the closest correspondence, and each weighed node's reads.
  def reading(record, stored, objective_id)
    trace = trace_of(record, stored)
    call = P.compose_call(trace)
    score = P.score_compose(trace, objective_id)
    objective = CB::Objectives.find(objective_id)
    picture = objective.picture
    tools = trace.calls.to_h { |row| [row["key"], row["tool_name"]] }
    plan = CB::Executed.plan(trace.graph, call["key"], tools: tools)
    labels = CB::Executed.labels(plan)
    graph = CB::Executed.lower(plan).without_launch_waits
    values = picture.send(:values, graph, [])
    transparent = plan.transparent
    kept = picture.send(:held, graph, values | transparent)
    read = graph.contract(transparent - kept).without(values - kept - transparent)
    past = picture.tail.nil? ? [] : picture.send(:extensions, read)
    read = read.without(past)
    mapping, = picture.send(:closest, read, picture.send(:waits_of, read))
    weighed = picture.send(:weighed_reads, read, mapping, [])
    script = trace.input_of(call)["script"].to_s
    built = Nexus::Compose::Evaluator.call(script: script, params: trace.input_of(call)["params"] || {}, tool_names: P.declared_names(trace))
    index = built.built? ? step_index(built.steps, built.lines) : {}
    { trace: trace, call: call["key"], score: score, picture: picture, plan: plan, labels: labels, read: read,
      mapping: mapping, weighed: weighed, script: script, index: index, past: past, contracted: (transparent - kept),
      dropped: (values - kept - transparent), objective: objective }
  end

  def race_exits(graph) = CB::Executed.send(:race_exits, graph)

  # The sources a plan's model node NAMED (`results:`), race-expanded, in plan keys. A step the call
  # placed: its `results:` off the evaluator's steps. A step a g.script stage placed: the kernel's
  # `result_from` (inside those stages nothing is result-only material, since none of the four
  # stage-placed plans holds an inner stage — printed by d2 as `inner stages`), owner-mapped.
  def named_sources(r, key)
    node = r[:plan].nodes.fetch(key)
    exits = race_exits(r[:trace].graph)
    if node["expansion_parent"] == r[:call]
      entry = r[:index][r[:labels].fetch(key)] or return []
      results = Array(entry[1]["results"]).map { |k| "#{r[:call]}-#{k}" }
      # A named stage that expanded: the kernel's splice points the reader at what it placed.
      spliced = Array(node["result_from"])
      named = results.flat_map do |k|
        if r[:plan].expanded?(k)
          spliced.select { |s| r[:plan].nodes.key?(s) && r[:plan].stages_above(s).include?(k) }
        else
          [k]
        end
      end
      CB::Shape.race_reads(exits, named).select { |k| r[:plan].nodes.key?(k) }
    else
      CB::Shape.race_reads(exits, Array(node["result_from"])).select { |k| r[:plan].nodes.key?(k) }
    end
  end

  def stage_placed?(r, key) = r[:plan].nodes.fetch(key)["expansion_parent"] != r[:call]

  # The continued round: a model's first `input_from` when it is a model of the plan (Compile puts the
  # cursor's spine first).
  def spine_of(r, key)
    first = Array(r[:plan].nodes.fetch(key)["input_from"]).first
    first && r[:plan].nodes.dig(first, "kind") == "model_task" ? first : nil
  end
end
```

### d1_buckets.rb

```ruby
# D(1): the compose family's reds and picture misses, v13 vs v14, per model and per task.
# Run: ruby d1_buckets.rb   (plain ruby; reads records only)
require_relative "d_common"

puts "## D1 inputs"
%w[v13 v14].each do |bench|
  %w[compose workflow].each do |family|
    recs = D.records(bench, family)
    puts "- #{bench} #{family}: #{D.raw_lines(bench, family)} lines on disk, #{recs.size} merged records (last line per key), digests #{recs.map { |r| r["bench_digest"][0, 12] }.uniq.join(",")}"
  end
end
puts

tasks = D::PICTURE_TASKS.keys.select { |t| t.start_with?("compose-") }

puts "## D1a success and picture per cell (success on the tier's bar / picture exact), v13 -> v14"
rows = tasks.map do |task|
  cells = D::MODELS.map do |model|
    %w[v13 v14].map do |bench|
      recs = D.records(bench, "compose").select { |r| r["task"] == task && r["model"] == model }
      "#{recs.count { |r| r.dig("verdict", "succeeded") == true }}/#{recs.count { |r| D.picture_ok?(r) }}"
    end.join(" -> ")
  end
  [task.delete_prefix("compose-"), *cells]
end
puts D.table(["task (succ/pic)", *D::MODELS.map { |m| D.short(m) }], rows)
single = %w[v13 v14].map { |b| D.records(b, "compose").select { |r| r["task"] == "compose-single-read" }.count { |r| r.dig("verdict", "succeeded") } }
puts "\ncompose-single-read (control, composed nothing): v13 #{single[0]}/12, v14 #{single[1]}/12\n\n"

puts "## D1b picture-miss buckets, ranked (one count per record per bucket; picture tasks incl. recorded-only T5)"
%w[v13 v14].each do |bench|
  recs = D.records(bench, "compose").select { |r| tasks.include?(r["task"]) }
  misses = recs.reject { |r| D.picture_ok?(r) }
  tally = Hash.new { |h, k| h[k] = Hash.new(0) }
  misses.each do |r|
    D.miss_buckets(r).each do |b|
      tally[b]["all"] += 1
      tally[b][D::TIER[D.short(r["model"])]] += 1
      tally[b][D.short(r["model"])] += 1
    end
  end
  puts "\n### #{bench}: #{misses.size} picture misses of #{recs.size} picture-task runs (strong #{misses.count { |r| D::TIER[D.short(r["model"])] == "strong" }}, floor #{misses.count { |r| D::TIER[D.short(r["model"])] == "floor" }})"
  ranked = tally.sort_by { |b, h| [-h["all"], b] }
  puts D.table(["bucket", "all", "strong", "floor", *D::MODELS.map { |m| D.short(m) }],
    ranked.map { |b, h| [b, h["all"], h["strong"], h["floor"], *D::MODELS.map { |m| h[D.short(m)] }] })
end

puts "\n## D1c picture-miss buckets per task (v13 -> v14), one count per record per bucket"
all_buckets = %w[v13 v14].flat_map { |b| D.records(b, "compose").select { |r| tasks.include?(r["task"]) }.reject { |r| D.picture_ok?(r) }.flat_map { |r| D.miss_buckets(r) } }.tally.sort_by { |k, v| [-v, k] }.map(&:first)
rows = tasks.map do |task|
  per = %w[v13 v14].map do |bench|
    D.records(bench, "compose").select { |r| r["task"] == task }.reject { |r| D.picture_ok?(r) }.flat_map { |r| D.miss_buckets(r) }.tally
  end
  [task.delete_prefix("compose-"), *all_buckets.map { |b| per[0][b].to_i.zero? && per[1][b].to_i.zero? ? "" : "#{per[0][b].to_i}->#{per[1][b].to_i}" }]
end
puts D.table(["task", *all_buckets], rows)

puts "\n## D1d every v14 picture miss (task, model, run, success, buckets; executed reading, static beside)"
rows = D.records("v14", "compose").select { |r| tasks.include?(r["task"]) }.reject { |r| D.picture_ok?(r) }.map do |r|
  s = r.dig("facts", "score")
  static = s.is_a?(Hash) ? Array(s.dig("static", "silent")).join(",") : ""
  [r["task"].delete_prefix("compose-"), D.short(r["model"]), r["run"], r.dig("verdict", "succeeded").inspect, D.miss_buckets(r).join(","), static]
end
puts D.table(%w[task model run succeeded buckets static_buckets], rows)

puts "\n## D1e every v13 picture miss (last line per key)"
rows = D.records("v13", "compose").select { |r| tasks.include?(r["task"]) }.reject { |r| D.picture_ok?(r) }.map do |r|
  s = r.dig("facts", "score")
  static = s.is_a?(Hash) ? Array(s.dig("static", "silent")).join(",") : ""
  [r["task"].delete_prefix("compose-"), D.short(r["model"]), r["run"], r.dig("verdict", "succeeded").inspect, D.miss_buckets(r).join(","), static, r["rescored"] ? "rescored" : ""]
end
puts D.table(%w[task model run succeeded buckets static_buckets line], rows)

puts "\n## D1f strong-tier reds (success false) — the bar that decides the strong cells"
%w[v13 v14].each do |bench|
  reds = D.records(bench, "compose").select { |r| D::TIER[D.short(r["model"])] == "strong" && r.dig("verdict", "succeeded") != true }
  by = reds.flat_map { |r| D.picture_ok?(r) ? ["picture exact, other: #{r["reason"].to_s[0, 60]}"] : D.miss_buckets(r) }.tally.sort_by { |k, v| [-v, k] }
  puts "- #{bench}: #{reds.size} strong reds; buckets #{by.map { |k, v| "#{k} #{v}" }.join(", ")}"
end
%w[v13 v14].each do |bench|
  reds = D.records(bench, "compose").select { |r| D::TIER[D.short(r["model"])] == "floor" && r.dig("verdict", "succeeded") != true }
  puts "- #{bench}: #{reds.size} floor reds: #{reds.map { |r| "#{r["task"].delete_prefix("compose-")} #{D.short(r["model"])}##{r["run"]} (#{r["reason"].to_s[0, 70]})" }.join("; ")}"
end

puts "\n## D1g workflow-barrier-free-pipeline (O7 picture in the workflow family)"
%w[v13 v14].each do |bench|
  recs = D.records(bench, "workflow").select { |r| r["task"] == "workflow-barrier-free-pipeline" }
  recs.each do |r|
    next if D.picture_ok?(r)
    puts "- #{bench} #{D.short(r["model"])}##{r["run"]} succ=#{r.dig("verdict", "succeeded").inspect} compose=#{r.dig("facts", "called", "compose").inspect} buckets=#{D.miss_buckets(r).join(",")}"
  end
  puts "- #{bench} picture exact: #{recs.count { |r| D.picture_ok?(r) }}/#{recs.size}"
end

puts "\n## D1h shares: picture misses carrying over_read, all picture tasks and the gate tasks alone (T5 is recorded-only)"
%w[v13 v14].each do |bench|
  recs = D.records(bench, "compose").select { |r| tasks.include?(r["task"]) }.reject { |r| D.picture_ok?(r) }
  gate = recs.reject { |r| r["task"] == "compose-rendezvous" }
  share = ->(xs) { "#{xs.count { |r| D.miss_buckets(r).include?("over_read") }}/#{xs.size} = #{(100.0 * xs.count { |r| D.miss_buckets(r).include?("over_read") } / xs.size).round(1)} %" }
  puts "- #{bench}: all picture tasks #{share.(recs)}; gate tasks (no T5) #{share.(gate)}"
  static_only = D.records(bench, "compose").select { |r| tasks.include?(r["task"]) }.count do |r|
    s = r.dig("facts", "score")
    s.is_a?(Hash) && Array(s.dig("static", "silent")).include?("edit_as_stage")
  end
  exec = D.records(bench, "compose").select { |r| tasks.include?(r["task"]) }.count { |r| D.miss_buckets(r).include?("edit_as_stage") }
  puts "- #{bench}: edit_as_stage on the executed (recorded) reading #{exec}; on the static reading beside it #{static_only}"
end
```

Output (`d1_buckets.out`):

```text
## D1 inputs
- v13 compose: 139 lines on disk, 108 merged records (last line per key), digests ab836ee0d8be
- v13 workflow: 77 lines on disk, 60 merged records (last line per key), digests ab836ee0d8be
- v14 compose: 108 lines on disk, 108 merged records (last line per key), digests f69dc4cc6ab4
- v14 workflow: 60 lines on disk, 60 merged records (last line per key), digests f69dc4cc6ab4

## D1a success and picture per cell (success on the tier's bar / picture exact), v13 -> v14
| task (succ/pic) | glm-5.3 | kimi-k3 | ds-flash | glm-flash |
|---|---|---|---|---|
| review-angles | 2/2 -> 3/3 | 3/3 -> 3/3 | 3/3 -> 3/3 | 3/2 -> 3/3 |
| grep-then-edit | 2/2 -> 2/2 | 1/1 -> 2/2 | 3/2 -> 3/3 | 2/1 -> 3/1 |
| race | 3/3 -> 3/3 | 3/3 -> 3/3 | 3/2 -> 3/3 | 3/2 -> 3/2 |
| race-anon | 3/3 -> 3/3 | 3/3 -> 3/3 | 3/2 -> 3/3 | 3/3 -> 3/3 |
| background-suite | 1/1 -> 1/1 | 1/1 -> 1/1 | 3/0 -> 3/1 | 3/1 -> 3/1 |
| three-stage-pairing | 2/2 -> 3/3 | 2/2 -> 3/3 | 3/3 -> 3/1 | 2/1 -> 2/1 |
| two-source-fan-in | 0/0 -> 1/1 | 0/0 -> 0/0 | 3/1 -> 3/0 | 3/1 -> 3/2 |
| rendezvous | 3/0 -> 3/1 | 3/0 -> 3/0 | 3/0 -> 3/0 | 3/0 -> 3/2 |

compose-single-read (control, composed nothing): v13 12/12, v14 12/12

## D1b picture-miss buckets, ranked (one count per record per bucket; picture tasks incl. recorded-only T5)

### v13: 46 picture misses of 96 picture-task runs (strong 22, floor 24)
| bucket | all | strong | floor | glm-5.3 | kimi-k3 | ds-flash | glm-flash |
|---|---|---|---|---|---|---|---|
| over_read | 28 | 15 | 13 | 7 | 8 | 6 | 7 |
| extra_steps | 7 | 3 | 4 | 1 | 2 | 1 | 3 |
| over_sync | 5 | 3 | 2 | 2 | 1 | 1 | 1 |
| (missing_steps) | 3 | 2 | 1 | 1 | 1 | 0 | 1 |
| no_compose_call | 3 | 1 | 2 | 1 | 0 | 0 | 2 |
| refused:syntax | 3 | 1 | 2 | 1 | 0 | 2 | 0 |
| unusable_plan | 3 | 2 | 1 | 1 | 1 | 0 | 1 |
| (missing_join) | 1 | 0 | 1 | 0 | 0 | 0 | 1 |
| refused:after_in_input | 1 | 0 | 1 | 0 | 0 | 0 | 1 |
| refused:group_reference | 1 | 0 | 1 | 0 | 0 | 0 | 1 |
| refused:member_not_a_step | 1 | 0 | 1 | 0 | 0 | 1 | 0 |
| refused:unknown_option | 1 | 0 | 1 | 0 | 0 | 1 | 0 |
| wrong_task_read | 1 | 1 | 0 | 0 | 1 | 0 | 0 |

### v14: 35 picture misses of 96 picture-task runs (strong 16, floor 19)
| bucket | all | strong | floor | glm-5.3 | kimi-k3 | ds-flash | glm-flash |
|---|---|---|---|---|---|---|---|
| over_read | 21 | 10 | 11 | 6 | 4 | 8 | 3 |
| extra_steps | 5 | 2 | 3 | 2 | 0 | 1 | 2 |
| blind_model | 3 | 3 | 0 | 0 | 3 | 0 | 0 |
| over_sync | 3 | 2 | 1 | 1 | 1 | 1 | 0 |
| refused:syntax | 3 | 1 | 2 | 0 | 1 | 1 | 1 |
| missing_steps | 2 | 1 | 1 | 0 | 1 | 0 | 1 |
| (missing_join) | 1 | 0 | 1 | 0 | 0 | 0 | 1 |
| (missing_steps) | 1 | 0 | 1 | 0 | 0 | 0 | 1 |
| no_compose_call | 1 | 0 | 1 | 0 | 0 | 0 | 1 |
| refused:member_not_a_step | 1 | 0 | 1 | 0 | 0 | 0 | 1 |
| unusable_plan | 1 | 0 | 1 | 0 | 0 | 0 | 1 |

## D1c picture-miss buckets per task (v13 -> v14), one count per record per bucket
| task | over_read | extra_steps | over_sync | refused:syntax | (missing_steps) | no_compose_call | unusable_plan | blind_model | (missing_join) | missing_steps | refused:member_not_a_step | refused:after_in_input | refused:group_reference | refused:unknown_option | wrong_task_read |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| review-angles |  |  |  | 1->0 |  |  |  |  |  |  |  |  | 1->0 |  |  |
| grep-then-edit |  | 0->1 | 2->2 | 1->1 | 1->0 | 1->0 | 1->0 |  |  |  |  |  |  |  | 1->0 |
| race |  |  |  | 1->0 | 1->1 |  | 1->1 |  | 1->1 |  |  |  |  |  |  |
| race-anon |  |  |  |  |  |  |  |  |  |  | 1->0 |  |  |  |  |
| background-suite | 7->5 | 6->4 |  | 0->1 |  | 1->0 |  | 0->1 |  | 0->1 | 0->1 |  |  | 1->0 |  |
| three-stage-pairing | 2->1 |  |  | 0->1 | 1->0 | 1->1 | 1->0 |  |  | 0->1 |  |  |  |  |  |
| two-source-fan-in | 8->8 |  | 3->1 |  |  |  |  |  |  |  |  |  |  |  |  |
| rendezvous | 11->7 | 1->0 |  |  |  |  |  | 0->2 |  |  |  | 1->0 |  |  |  |

## D1d every v14 picture miss (task, model, run, success, buckets; executed reading, static beside)
| task | model | run | succeeded | buckets | static_buckets |
|---|---|---|---|---|---|
| background-suite | glm-5.3 | 1 | false | extra_steps,over_read | extra_steps,over_read |
| background-suite | glm-5.3 | 3 | false | extra_steps,over_read | extra_steps,over_read |
| background-suite | kimi-k3 | 1 | false | refused:syntax |  |
| background-suite | kimi-k3 | 3 | false | missing_steps,blind_model | missing_steps,blind_model |
| background-suite | ds-flash | 2 | true | over_read | over_read |
| background-suite | ds-flash | 3 | true | extra_steps,over_read | extra_steps,over_read |
| background-suite | glm-flash | 2 | true | extra_steps,over_read | missing_steps |
| background-suite | glm-flash | 3 | true | refused:member_not_a_step |  |
| grep-then-edit | glm-5.3 | 2 | false | over_sync | over_sync |
| grep-then-edit | kimi-k3 | 3 | false | over_sync | over_sync |
| grep-then-edit | glm-flash | 1 | true | extra_steps | edit_as_tool,extra_steps |
| grep-then-edit | glm-flash | 3 | true | refused:syntax |  |
| race | glm-flash | 3 | true | unusable_plan,(missing_join),(missing_steps) | missing_join,missing_steps |
| rendezvous | glm-5.3 | 2 | true | over_read | over_read |
| rendezvous | glm-5.3 | 3 | true | over_read | over_read |
| rendezvous | kimi-k3 | 1 | true | blind_model | missing_steps |
| rendezvous | kimi-k3 | 2 | true | over_read | over_read |
| rendezvous | kimi-k3 | 3 | true | blind_model | missing_steps |
| rendezvous | ds-flash | 1 | true | over_read | over_read |
| rendezvous | ds-flash | 2 | true | over_read | over_read |
| rendezvous | ds-flash | 3 | true | over_read | over_read |
| rendezvous | glm-flash | 2 | true | over_read | over_read |
| three-stage-pairing | ds-flash | 1 | true | over_read | over_read |
| three-stage-pairing | ds-flash | 3 | true | refused:syntax |  |
| three-stage-pairing | glm-flash | 1 | nil | no_compose_call |  |
| three-stage-pairing | glm-flash | 2 | true | missing_steps |  |
| two-source-fan-in | glm-5.3 | 1 | false | over_read | missing_steps |
| two-source-fan-in | glm-5.3 | 3 | false | over_read | over_read |
| two-source-fan-in | kimi-k3 | 1 | false | over_read | over_read |
| two-source-fan-in | kimi-k3 | 2 | false | over_read | over_read |
| two-source-fan-in | kimi-k3 | 3 | false | over_read | over_read |
| two-source-fan-in | ds-flash | 1 | true | over_sync | over_sync |
| two-source-fan-in | ds-flash | 2 | true | over_read | over_read |
| two-source-fan-in | ds-flash | 3 | true | over_read | over_read |
| two-source-fan-in | glm-flash | 2 | true | over_read | over_read |

## D1e every v13 picture miss (last line per key)
| task | model | run | succeeded | buckets | static_buckets | line |
|---|---|---|---|---|---|---|
| background-suite | glm-5.3 | 2 | false | extra_steps,over_read | extra_steps,over_read | rescored |
| background-suite | glm-5.3 | 3 | nil | no_compose_call |  | rescored |
| background-suite | kimi-k3 | 2 | false | extra_steps,over_read | extra_steps,over_read | rescored |
| background-suite | kimi-k3 | 3 | false | extra_steps,over_read | extra_steps,over_read | rescored |
| background-suite | ds-flash | 1 | true | refused:unknown_option |  |  |
| background-suite | ds-flash | 2 | true | extra_steps,over_read | extra_steps,over_read | rescored |
| background-suite | ds-flash | 3 | true | over_read | over_read | rescored |
| background-suite | glm-flash | 2 | true | extra_steps,over_read | extra_steps,over_read |  |
| background-suite | glm-flash | 3 | true | extra_steps,over_read | extra_steps,over_read | rescored |
| grep-then-edit | glm-5.3 | 1 | false | unusable_plan,(missing_steps) | missing_steps | rescored |
| grep-then-edit | kimi-k3 | 1 | false | over_sync | over_sync | rescored |
| grep-then-edit | kimi-k3 | 2 | false | wrong_task_read | wrong_task_read | rescored |
| grep-then-edit | ds-flash | 2 | true | refused:syntax |  |  |
| grep-then-edit | glm-flash | 1 | nil | no_compose_call |  | rescored |
| grep-then-edit | glm-flash | 3 | true | over_sync | over_sync | rescored |
| race | ds-flash | 1 | true | refused:syntax |  |  |
| race | glm-flash | 1 | true | unusable_plan,(missing_join),(missing_steps) |  | rescored |
| race-anon | ds-flash | 3 | true | refused:member_not_a_step |  |  |
| rendezvous | glm-5.3 | 1 | true | over_read | over_read | rescored |
| rendezvous | glm-5.3 | 2 | true | over_read | over_read | rescored |
| rendezvous | glm-5.3 | 3 | true | over_read | missing_steps | rescored |
| rendezvous | kimi-k3 | 1 | true | over_read | over_read | rescored |
| rendezvous | kimi-k3 | 2 | true | over_read | over_read | rescored |
| rendezvous | kimi-k3 | 3 | true | over_read | over_read | rescored |
| rendezvous | ds-flash | 1 | true | over_read | over_read | rescored |
| rendezvous | ds-flash | 2 | true | over_read | over_read | rescored |
| rendezvous | ds-flash | 3 | true | over_read | over_read | rescored |
| rendezvous | glm-flash | 1 | true | refused:after_in_input |  | rescored |
| rendezvous | glm-flash | 2 | true | extra_steps,over_read | missing_steps | rescored |
| rendezvous | glm-flash | 3 | true | over_read | over_read | rescored |
| review-angles | glm-5.3 | 3 | false | refused:syntax |  |  |
| review-angles | glm-flash | 1 | true | refused:group_reference |  |  |
| three-stage-pairing | glm-5.3 | 2 | false | over_read | over_read |  |
| three-stage-pairing | kimi-k3 | 1 | false | unusable_plan,(missing_steps) | missing_steps | rescored |
| three-stage-pairing | glm-flash | 1 | nil | no_compose_call |  |  |
| three-stage-pairing | glm-flash | 2 | true | over_read | over_read |  |
| two-source-fan-in | glm-5.3 | 1 | false | over_read | over_read |  |
| two-source-fan-in | glm-5.3 | 2 | false | over_sync | over_sync |  |
| two-source-fan-in | glm-5.3 | 3 | false | over_sync,over_read | over_sync,over_read |  |
| two-source-fan-in | kimi-k3 | 1 | false | over_read | over_read |  |
| two-source-fan-in | kimi-k3 | 2 | false | over_read | over_read |  |
| two-source-fan-in | kimi-k3 | 3 | false | over_read | over_read |  |
| two-source-fan-in | ds-flash | 1 | true | over_read | extra_steps,over_read |  |
| two-source-fan-in | ds-flash | 2 | true | over_sync | over_sync |  |
| two-source-fan-in | glm-flash | 2 | true | over_read | over_read |  |
| two-source-fan-in | glm-flash | 3 | true | over_read | over_read |  |

## D1f strong-tier reds (success false) — the bar that decides the strong cells
- v13: 16 strong reds; buckets over_read 9, extra_steps 3, over_sync 3, (missing_steps) 2, unusable_plan 2, no_compose_call 1, refused:syntax 1, wrong_task_read 1
- v14: 11 strong reds; buckets over_read 7, extra_steps 2, over_sync 2, blind_model 1, missing_steps 1, refused:syntax 1
- v13: 2 floor reds: grep-then-edit glm-flash#1 (no compose call: the model called {}); three-stage-pairing glm-flash#1 (no compose call: the model called {"write" => 1, "bash" => 3, "read" =)
- v14: 1 floor reds: three-stage-pairing glm-flash#1 (no compose call: the model called {"write" => 1, "bash" => 3, "edit" =)

## D1g workflow-barrier-free-pipeline (O7 picture in the workflow family)
- v13 glm-5.3#1 succ=nil compose=nil buckets=no_compose_call
- v13 glm-5.3#2 succ=false compose=1 buckets=edit_as_tool
- v13 kimi-k3#1 succ=nil compose=nil buckets=no_compose_call
- v13 kimi-k3#2 succ=nil compose=nil buckets=no_compose_call
- v13 kimi-k3#3 succ=nil compose=nil buckets=no_compose_call
- v13 ds-flash#1 succ=nil compose=nil buckets=no_compose_call
- v13 ds-flash#2 succ=nil compose=nil buckets=no_compose_call
- v13 ds-flash#3 succ=true compose=1 buckets=edit_as_tool
- v13 glm-flash#1 succ=true compose=1 buckets=edit_as_tool
- v13 glm-flash#2 succ=nil compose=nil buckets=no_compose_call
- v13 glm-flash#3 succ=true compose=1 buckets=edit_as_tool
- v13 picture exact: 1/12
- v14 glm-5.3#1 succ=false compose=1 buckets=edit_as_tool
- v14 glm-5.3#2 succ=false compose=1 buckets=edit_as_tool
- v14 glm-5.3#3 succ=false compose=1 buckets=edit_as_tool
- v14 kimi-k3#1 succ=nil compose=nil buckets=no_compose_call
- v14 kimi-k3#2 succ=nil compose=nil buckets=no_compose_call
- v14 kimi-k3#3 succ=nil compose=nil buckets=no_compose_call
- v14 ds-flash#1 succ=nil compose=nil buckets=no_compose_call
- v14 ds-flash#2 succ=nil compose=nil buckets=no_compose_call
- v14 ds-flash#3 succ=nil compose=nil buckets=no_compose_call
- v14 glm-flash#1 succ=nil compose=nil buckets=no_compose_call
- v14 glm-flash#2 succ=true compose=1 buckets=edit_as_tool
- v14 glm-flash#3 succ=true compose=1 buckets=edit_as_tool
- v14 picture exact: 0/12

## D1h shares: picture misses carrying over_read, all picture tasks and the gate tasks alone (T5 is recorded-only)
- v13: all picture tasks 28/46 = 60.9 %; gate tasks (no T5) 17/34 = 50.0 %
- v13: edit_as_stage on the executed (recorded) reading 0; on the static reading beside it 0
- v14: all picture tasks 21/35 = 60.0 %; gate tasks (no T5) 14/26 = 53.8 %
- v14: edit_as_stage on the executed (recorded) reading 0; on the static reading beside it 6
```

### d2_over_read.rb

```ruby
# D(2): every over_read reading on the compose family (v13 last line per key, v14), and the workflow
# family's picture task: which step read which material the picture does not give it, and whether the
# script NAMED it (`results:`) or the step got it implicitly by its written position (the kernel's
# cursor: spine + material behind the tip, a group's members' exits and content).
# Run: cd /Users/jasl/Workspaces/cybros-ai.alt2/e2e && bundle exec ruby <scratch>/d2_over_read.rb
require_relative "d_harness"

# Named sources, followed through every stage the reading contracted (a read of a contracted stage is a
# read of what it read — explicit when the stage was named).
def explicit_closure(r, key)
  named = DH.named_sources(r, key)
  seen = Set.new
  frontier = named.dup
  until frontier.empty?
    k = frontier.shift
    next if seen.include?(k)

    seen << k
    frontier.concat(Array(r[:plan].reads[k])) unless r[:read].keys.include?(k)
  end
  seen
end

def step_lines(r, key)
  entry = r[:index][r[:labels].fetch(key, "")] or return []
  start = entry[2].to_i
  starts = r[:index].values.map { |e| e[2].to_i }.select { |l| l > start }
  stop = [starts.min || (start + 40), start + 40].min
  src = r[:script].lines
  (start..stop - 1).filter_map { |n| [n, src[n - 1].to_s.rstrip] if src[n - 1] }
    .select { |_, text| text.match?(/g\.(model|script|parallel|tool)|results|after|^\s*\}\)/) }
    .map { |n, text| "L#{n}: #{text.strip[0, 150]}" }
end

rows = []
sources = []
detail = []
readers = []
[["v13", "compose"], ["v14", "compose"], ["v13", "workflow"], ["v14", "workflow"]].each do |bench, family|
  D.records(bench, family).each do |record|
    objective = D::PICTURE_TASKS[record["task"]] or next
    score = record.dig("facts", "score")
    next unless score.is_a?(Hash) && Array(score["silent"]).include?("over_read")

    stored = D.trace(bench, family, record)
    r = DH.reading(record, stored, objective)
    agree = r[:score].is_a?(Hash) && Array(r[:score]["silent"]) == Array(score["silent"])
    lab = ->(k) { "#{r[:labels].fetch(k, k)}#{"=#{r[:mapping].key(k)}" if r[:mapping].key(k)}" }
    per_record = { implicit: 0, explicit: 0, wait: 0, stage: 0 }
    inner = r[:plan].nodes.values.count { |n| n["kind"] == "script_task" && n["expansion_parent"] != r[:call] }
    per_record[:stage] = r[:plan].nodes.keys.count { |k| r[:plan].nodes[k]["kind"] == "model_task" && DH.stage_placed?(r, k) }
    lines = []
    r[:weighed].each do |key, actual|
      label = r[:mapping].key(key)
      expected = label && r[:picture].reads[label] ? r[:picture].reads[label].map { |l| r[:mapping][l] } : []
      extras = actual - expected
      next if extras.empty?

      kind = r[:read].node(key).kind
      closure = kind == "model" ? explicit_closure(r, key) : nil
      extras.each do |src|
        how = if kind == "script" then "explicit(stage results:)"
              elsif kind == "tool" then "wait(computing tool)"
              elsif closure.include?(src) then (DH.stage_placed?(r, key) ? "explicit(stage-placed)" : "explicit")
              else (DH.stage_placed?(r, key) ? "implicit(stage-placed)" : "implicit")
              end
        bucket = { "explicit" => :explicit, "explicit(stage results:)" => :explicit, "explicit(stage-placed)" => :explicit,
                   "implicit" => :implicit, "implicit(stage-placed)" => :implicit, "wait(computing tool)" => :wait }.fetch(how)
        per_record[bucket] += 1
        src_kind = r[:read].node(src)&.kind || r[:plan].nodes.dig(src, "kind")
        sources << { bench: bench, task: record["task"], model: D.short(record["model"]), run: record["run"],
                     reader: lab.(key), reader_kind: kind, source: lab.(src), source_kind: src_kind, how: how,
                     reader_label: label || "(extra)", source_label: r[:mapping].key(src) || "(extra)" }
      end
      named = closure ? DH.named_sources(r, key).map { |k| r[:labels].fetch(k, k) } : nil
      if kind == "model"
        named_keys = DH.named_sources(r, key)
        intent = if named_keys.empty? then "named nothing: every read positional"
                 elsif extras.all? { |x| closure.include?(x) } then "over-named: every extra read named"
                 elsif extras.none? { |x| closure.include?(x) } then "named a subset: position added the rest"
                 else "mixed: some extras named, some positional"
                 end
        quote = step_lines(r, key).select { |l| l.include?("results") || l.include?("g.model") }.first(2).map { |l| l.sub(/\AL\d+: /, "")[0, 70] }.join(" / ")
        readers << { bench: bench, task: record["task"].sub(/\A(compose|workflow)-/, ""), model: D.short(record["model"]), run: record["run"],
                     reader: lab.(key), extras: extras.map(&lab).join(" "), named: named.join(" "), intent: intent,
                     stage: DH.stage_placed?(r, key), quote: DH.stage_placed?(r, key) ? "(placed by a g.script stage)" : quote }
      else
        readers << { bench: bench, task: record["task"].sub(/\A(compose|workflow)-/, ""), model: D.short(record["model"]), run: record["run"],
                     reader: lab.(key), extras: extras.map(&lab).join(" "), named: "(stage results)", intent: "a value stage named them", stage: false,
                     quote: step_lines(r, key).select { |l| l.include?("results") }.first(1).map { |l| l.sub(/\AL\d+: /, "")[0, 70] }.join }
      end
      lines << "  reader #{lab.(key)} (#{kind}) reads #{actual.map(&lab).join(", ")}; picture gives #{label ? expected.compact.map(&lab).join(", ") : "(no label: extra step)"}; " \
               "extra #{extras.map(&lab).join(", ")}; named results: #{named.nil? ? "n/a" : named.inspect}"
      step_lines(r, key).each { |l| lines << "      #{l}" }
    end
    rows << [bench, record["task"].sub(/\A(compose|workflow)-/, ""), D.short(record["model"]), record["run"],
             Array(score["silent"]).join(","), agree ? "yes" : "NO", per_record[:implicit], per_record[:explicit], per_record[:wait], per_record[:stage]]
    detail << "#{bench} #{record["task"]} inner stages=#{inner} #{D.short(record["model"])} ##{record["run"]} [#{Array(score["silent"]).join(",")}] graph=#{JSON.generate(score["graph"])[0, 400]}"
    detail.concat(lines)
  end
end

puts "## D2a over_read readings: extra reads by how they reached the reader"
puts "(implicit = the reader's cursor gave it, the script did not name it; explicit = named in results:, or through a named stage;"
puts " wait = a computing tool reads what it waits on; stage-models = models a g.script stage placed in this plan (their reads are split the same way). `agree` = the offline re-read gives the record's buckets)"
puts D.table(%w[bench task model run buckets agree implicit explicit wait stage-models], rows)

puts "\n## D2b totals"
%w[v13 v14].each do |bench|
  s = sources.select { |x| x[:bench] == bench }
  recs = rows.select { |row| row[0] == bench }
  only_implicit = recs.count { |row| row[6].positive? && row[7].zero? && row[8].zero? }
  any_explicit = recs.count { |row| row[7].positive? }
  puts "- #{bench}: #{recs.size} over_read readings, #{s.size} extra reads: #{s.map { |x| x[:how] }.tally.sort_by { |k, v| [-v, k] }.map { |k, v| "#{k} #{v}" }.join(", ")}; " \
       "readings whose every extra read is implicit: #{only_implicit}/#{recs.size}; readings with any explicit over-naming: #{any_explicit}"
end
s = sources
imp = s.count { |x| x[:how].start_with?("implicit") }
puts "- both: #{rows.size} over_read readings, #{s.size} extra reads, implicit #{imp} (#{(100.0 * imp / s.size).round(1)} %), explicit (any kind) #{s.count { |x| x[:how].start_with?("explicit") }}"
%w[v13 v14].each do |bench|
  x = s.select { |y| y[:bench] == bench }
  i = x.count { |y| y[:how].start_with?("implicit") }
  puts "- #{bench}: implicit #{i}/#{x.size} = #{(100.0 * i / x.size).round(1)} % of extra reads; explicit (any kind) #{x.count { |y| y[:how].start_with?("explicit") }}"
end

%w[v13 v14].each do |bench|
  x = s.select { |y| y[:bench] == bench }
  puts "- #{bench}: extra reads by source kind: #{x.map { |y| y[:source_kind] }.tally.map { |k, v| "#{k} #{v}" }.join(", ")}; implicit extra reads by source kind: #{x.select { |y| y[:how].start_with?("implicit") }.map { |y| y[:source_kind] }.tally.map { |k, v| "#{k} #{v}" }.join(", ")}"
end

puts "\n## D2c extra reads by task, reader label and source kind (v13+v14)"
tally = sources.group_by { |x| [x[:task].sub(/\A(compose|workflow)-/, ""), x[:reader_label], x[:how], x[:source_kind]] }.transform_values(&:size)
puts D.table(%w[task reader_label how source_kind count], tally.sort_by { |k, v| [k[0], -v] }.map { |k, v| [*k, v] })

puts "\n## D2e every over-reading step (reader), what it read beyond the picture, what its script named, and the line"
puts D.table(%w[bench task model run reader extra_reads named_results intent script_line],
  readers.map { |x| [x[:bench], x[:task], x[:model], x[:run], x[:reader], x[:extras], x[:named], x[:intent], x[:quote].gsub("|", "\\|")] })
puts "\n## D2f readers by intent"
%w[v13 v14].each do |bench|
  x = readers.select { |y| y[:bench] == bench }
  puts "- #{bench}: #{x.size} over-reading steps: #{x.map { |y| y[:intent] }.tally.sort_by { |k, v| [-v, k] }.map { |k, v| "#{k} #{v}" }.join(", ")}"
end

puts "\n## D2d per reading: the reader, its reads, the picture's, and its script lines"
puts detail
```

Output (`d2_over_read.out`):

```text
## D2a over_read readings: extra reads by how they reached the reader
(implicit = the reader's cursor gave it, the script did not name it; explicit = named in results:, or through a named stage;
 wait = a computing tool reads what it waits on; stage-models = models a g.script stage placed in this plan (their reads are split the same way). `agree` = the offline re-read gives the record's buckets)
| bench | task | model | run | buckets | agree | implicit | explicit | wait | stage-models |
|---|---|---|---|---|---|---|---|---|---|
| v13 | background-suite | glm-5.3 | 2 | extra_steps,over_read | yes | 2 | 1 | 0 | 0 |
| v13 | background-suite | kimi-k3 | 2 | extra_steps,over_read | yes | 0 | 3 | 0 | 0 |
| v13 | background-suite | kimi-k3 | 3 | extra_steps,over_read | yes | 1 | 5 | 0 | 0 |
| v13 | background-suite | ds-flash | 2 | extra_steps,over_read | yes | 3 | 0 | 0 | 0 |
| v13 | background-suite | ds-flash | 3 | over_read | yes | 1 | 0 | 0 | 0 |
| v13 | background-suite | glm-flash | 2 | extra_steps,over_read | yes | 0 | 1 | 0 | 0 |
| v13 | background-suite | glm-flash | 3 | extra_steps,over_read | yes | 0 | 4 | 0 | 0 |
| v13 | rendezvous | glm-5.3 | 1 | over_read | yes | 3 | 0 | 0 | 0 |
| v13 | rendezvous | glm-5.3 | 2 | over_read | yes | 3 | 0 | 0 | 0 |
| v13 | rendezvous | glm-5.3 | 3 | over_read | yes | 3 | 0 | 0 | 3 |
| v13 | rendezvous | kimi-k3 | 1 | over_read | yes | 3 | 0 | 0 | 0 |
| v13 | rendezvous | kimi-k3 | 2 | over_read | yes | 3 | 0 | 0 | 0 |
| v13 | rendezvous | kimi-k3 | 3 | over_read | yes | 3 | 0 | 0 | 0 |
| v13 | rendezvous | ds-flash | 1 | over_read | yes | 5 | 0 | 0 | 0 |
| v13 | rendezvous | ds-flash | 2 | over_read | yes | 5 | 0 | 0 | 0 |
| v13 | rendezvous | ds-flash | 3 | over_read | yes | 5 | 0 | 0 | 0 |
| v13 | rendezvous | glm-flash | 2 | extra_steps,over_read | yes | 6 | 2 | 0 | 3 |
| v13 | rendezvous | glm-flash | 3 | over_read | yes | 5 | 0 | 0 | 0 |
| v13 | three-stage-pairing | glm-5.3 | 2 | over_read | yes | 0 | 3 | 0 | 0 |
| v13 | three-stage-pairing | glm-flash | 2 | over_read | yes | 0 | 3 | 0 | 0 |
| v13 | two-source-fan-in | glm-5.3 | 1 | over_read | yes | 3 | 0 | 0 | 0 |
| v13 | two-source-fan-in | glm-5.3 | 3 | over_sync,over_read | yes | 3 | 0 | 0 | 0 |
| v13 | two-source-fan-in | kimi-k3 | 1 | over_read | yes | 3 | 0 | 0 | 0 |
| v13 | two-source-fan-in | kimi-k3 | 2 | over_read | yes | 3 | 0 | 0 | 0 |
| v13 | two-source-fan-in | kimi-k3 | 3 | over_read | yes | 3 | 0 | 0 | 0 |
| v13 | two-source-fan-in | ds-flash | 1 | over_read | yes | 3 | 0 | 0 | 0 |
| v13 | two-source-fan-in | glm-flash | 2 | over_read | yes | 3 | 0 | 0 | 0 |
| v13 | two-source-fan-in | glm-flash | 3 | over_read | yes | 3 | 0 | 0 | 0 |
| v14 | background-suite | glm-5.3 | 1 | extra_steps,over_read | yes | 0 | 4 | 0 | 0 |
| v14 | background-suite | glm-5.3 | 3 | extra_steps,over_read | yes | 0 | 3 | 0 | 0 |
| v14 | background-suite | ds-flash | 2 | over_read | yes | 1 | 0 | 0 | 0 |
| v14 | background-suite | ds-flash | 3 | extra_steps,over_read | yes | 0 | 2 | 0 | 0 |
| v14 | background-suite | glm-flash | 2 | extra_steps,over_read | yes | 2 | 0 | 0 | 1 |
| v14 | rendezvous | glm-5.3 | 2 | over_read | yes | 5 | 0 | 0 | 0 |
| v14 | rendezvous | glm-5.3 | 3 | over_read | yes | 3 | 0 | 0 | 0 |
| v14 | rendezvous | kimi-k3 | 2 | over_read | yes | 3 | 0 | 0 | 0 |
| v14 | rendezvous | ds-flash | 1 | over_read | yes | 5 | 0 | 0 | 0 |
| v14 | rendezvous | ds-flash | 2 | over_read | yes | 3 | 0 | 0 | 0 |
| v14 | rendezvous | ds-flash | 3 | over_read | yes | 5 | 0 | 0 | 0 |
| v14 | rendezvous | glm-flash | 2 | over_read | yes | 3 | 0 | 0 | 0 |
| v14 | three-stage-pairing | ds-flash | 1 | over_read | yes | 3 | 0 | 0 | 0 |
| v14 | two-source-fan-in | glm-5.3 | 1 | over_read | yes | 3 | 0 | 0 | 3 |
| v14 | two-source-fan-in | glm-5.3 | 3 | over_read | yes | 3 | 0 | 0 | 0 |
| v14 | two-source-fan-in | kimi-k3 | 1 | over_read | yes | 3 | 0 | 0 | 0 |
| v14 | two-source-fan-in | kimi-k3 | 2 | over_read | yes | 3 | 0 | 0 | 0 |
| v14 | two-source-fan-in | kimi-k3 | 3 | over_read | yes | 3 | 0 | 0 | 0 |
| v14 | two-source-fan-in | ds-flash | 2 | over_read | yes | 3 | 0 | 0 | 0 |
| v14 | two-source-fan-in | ds-flash | 3 | over_read | yes | 3 | 0 | 0 | 0 |
| v14 | two-source-fan-in | glm-flash | 2 | over_read | yes | 3 | 0 | 0 | 0 |

## D2b totals
- v13: 28 over_read readings, 97 extra reads: implicit 66, explicit 14, implicit(stage-placed) 9, explicit(stage results:) 6, explicit(stage-placed) 2; readings whose every extra read is implicit: 20/28; readings with any explicit over-naming: 8
- v14: 21 over_read readings, 66 extra reads: implicit 52, explicit 9, implicit(stage-placed) 5; readings whose every extra read is implicit: 18/21; readings with any explicit over-naming: 3
- both: 49 over_read readings, 163 extra reads, implicit 132 (81.0 %), explicit (any kind) 31
- v13: implicit 75/97 = 77.3 % of extra reads; explicit (any kind) 22
- v14: implicit 57/66 = 86.4 % of extra reads; explicit (any kind) 9
- v13: extra reads by source kind: tool 89, model 8; implicit extra reads by source kind: tool 71, model 4
- v14: extra reads by source kind: tool 63, model 3; implicit extra reads by source kind: tool 57

## D2c extra reads by task, reader label and source kind (v13+v14)
| task | reader_label | how | source_kind | count |
|---|---|---|---|---|
| background-suite | (extra) | explicit | tool | 16 |
| background-suite | (extra) | explicit | model | 7 |
| background-suite | fix | implicit | tool | 3 |
| background-suite | (extra) | implicit | model | 3 |
| background-suite | (extra) | implicit | tool | 2 |
| background-suite | fix | implicit(stage-placed) | tool | 2 |
| rendezvous | merge | implicit | tool | 48 |
| rendezvous | merge | implicit(stage-placed) | tool | 7 |
| rendezvous | rm | implicit | tool | 7 |
| rendezvous | rs | implicit | tool | 7 |
| rendezvous | rm | explicit(stage-placed) | tool | 1 |
| rendezvous | rm | implicit(stage-placed) | tool | 1 |
| rendezvous | rs | implicit(stage-placed) | tool | 1 |
| rendezvous | rs | explicit(stage-placed) | tool | 1 |
| three-stage-pairing | merge | explicit(stage results:) | tool | 6 |
| three-stage-pairing | merge | implicit | tool | 3 |
| two-source-fan-in | report | implicit | tool | 42 |
| two-source-fan-in | report | implicit(stage-placed) | tool | 3 |
| two-source-fan-in | ts | implicit | tool | 2 |
| two-source-fan-in | qs | implicit | model | 1 |

## D2e every over-reading step (reader), what it read beyond the picture, what its script named, and the line
| bench | task | model | run | reader | extra_reads | named_results | intent | script_line |
|---|---|---|---|---|---|---|---|---|
| v13 | background-suite | glm-5.3 | 2 | model-1=fix | tool-1=suite | tool-2 | named a subset: position added the rest | const fixer1 = g.model({ / results: [cop1], |
| v13 | background-suite | glm-5.3 | 2 | model-2 | model-1=fix tool-3 | tool-3 | mixed: some extras named, some positional | const fixer2 = g.model({ / results: [cop2], |
| v13 | background-suite | kimi-k3 | 2 | model-2 | tool-1=suite model-1=fix tool-3 | tool-1 model-1 tool-3 | over-named: every extra read named | g.model({ / results: [tests, fixer, verify], |
| v13 | background-suite | kimi-k3 | 3 | model-2 | model-1=fix tool-3 | tool-3 | mixed: some extras named, some positional | const fix2 = g.model({ / results: [rubo2], |
| v13 | background-suite | kimi-k3 | 3 | model-3 | tool-1=suite model-2 tool-4 model-1=fix | tool-1 model-1 model-2 tool-4 | over-named: every extra read named | g.model({ / results: [tests, fix1, fix2, rubo3], |
| v13 | background-suite | ds-flash | 2 | model-2 | tool-1=suite tool-2=lint model-1=fix |  | named nothing: every read positional | g.model({ / `Write the short final report for a two-part background job (results a |
| v13 | background-suite | ds-flash | 3 | model-1=fix | tool-1=suite |  | named nothing: every read positional | g.model({ |
| v13 | background-suite | glm-flash | 2 | model-1 | tool-1=suite | tool-1 | over-named: every extra read named | const suiteSummary = g.model({ / results: [suite] |
| v13 | background-suite | glm-flash | 3 | model-2 | tool-1=suite tool-2=lint model-1=fix tool-3 | tool-1 tool-2 model-1 tool-3 script-1 | over-named: every extra read named | const report = g.model({ / results: [suite, survey, fix, verify, ensure], |
| v13 | rendezvous | glm-5.3 | 1 | model-3=merge | tool-1=mig tool-2=seed tool-3=dump | model-1 model-2 | named a subset: position added the rest | const merge = g.model({ / results: [reviewMigrate, reviewSeed] |
| v13 | rendezvous | glm-5.3 | 2 | model-3=merge | tool-1=mig tool-2=seed tool-3=dump | model-1 model-2 | named a subset: position added the rest | const merge = g.model({ / results: [reviewMigrate, reviewSeed], |
| v13 | rendezvous | glm-5.3 | 3 | script-1/model-3=merge | script-1/tool-1=mig script-1/tool-2=seed script-1/tool-3=dump | script-1/model-1 script-1/model-2 | named a subset: position added the rest | (placed by a g.script stage) |
| v13 | rendezvous | kimi-k3 | 1 | model-3=merge | tool-1=mig tool-2=seed tool-3=dump | model-1 model-2 | named a subset: position added the rest | g.model({ / results: [migrateReview, seedReview] |
| v13 | rendezvous | kimi-k3 | 2 | model-3=merge | tool-1=mig tool-2=seed tool-3=dump | model-1 model-2 | named a subset: position added the rest | g.model({ / results: [migrateReview, seedReview], |
| v13 | rendezvous | kimi-k3 | 3 | model-3=merge | tool-1=mig tool-2=seed tool-3=dump | model-1 model-2 | named a subset: position added the rest | g.model({ / results: [migReview, seedReview], |
| v13 | rendezvous | ds-flash | 1 | model-1=rm | tool-2=seed | tool-1 tool-3 | named a subset: position added the rest | const reviewMigrate = g.model({ / results: [migrate, dump], |
| v13 | rendezvous | ds-flash | 1 | model-2=rs | tool-1=mig | tool-2 tool-3 | named a subset: position added the rest | const reviewSeed = g.model({ / results: [seed, dump], |
| v13 | rendezvous | ds-flash | 1 | model-3=merge | tool-1=mig tool-2=seed tool-3=dump |  | named nothing: every read positional | g.model({ |
| v13 | rendezvous | ds-flash | 2 | model-1=rm | tool-2=seed | tool-1 tool-3 | named a subset: position added the rest | const reviewMigrate = g.model({ / results: [migrate, dump], |
| v13 | rendezvous | ds-flash | 2 | model-2=rs | tool-1=mig | tool-2 tool-3 | named a subset: position added the rest | const reviewSeed = g.model({ / results: [seed, dump], |
| v13 | rendezvous | ds-flash | 2 | model-3=merge | tool-1=mig tool-2=seed tool-3=dump | model-1 model-2 | named a subset: position added the rest | g.model({ / results: [reviewMigrate, reviewSeed], |
| v13 | rendezvous | ds-flash | 3 | model-1=rm | tool-2=seed | tool-1 tool-3 | named a subset: position added the rest | const migrateReview = g.model({ / results: [migrate, dump] |
| v13 | rendezvous | ds-flash | 3 | model-2=rs | tool-1=mig | tool-2 tool-3 | named a subset: position added the rest | const seedReview = g.model({ / results: [seed, dump] |
| v13 | rendezvous | ds-flash | 3 | model-3=merge | tool-1=mig tool-2=seed tool-3=dump | model-1 model-2 | named a subset: position added the rest | g.model({ / results: [migrateReview, seedReview] |
| v13 | rendezvous | glm-flash | 2 | script-1/model-1=rm | script-1/tool-2=seed script-1/tool-4 | script-1/tool-1 script-1/tool-3 script-1/tool-4 | mixed: some extras named, some positional | (placed by a g.script stage) |
| v13 | rendezvous | glm-flash | 2 | script-1/model-2=rs | script-1/tool-1=mig script-1/tool-4 | script-1/tool-2 script-1/tool-3 script-1/tool-4 | mixed: some extras named, some positional | (placed by a g.script stage) |
| v13 | rendezvous | glm-flash | 2 | script-1/model-3=merge | script-1/tool-1=mig script-1/tool-2=seed script-1/tool-3=dump script-1/tool-4 | script-1/model-1 script-1/model-2 | named a subset: position added the rest | (placed by a g.script stage) |
| v13 | rendezvous | glm-flash | 3 | model-1=rm | tool-2=seed | tool-1 tool-3 | named a subset: position added the rest | const reviewMigrate = g.model({ / results: [migrate, dump], |
| v13 | rendezvous | glm-flash | 3 | model-2=rs | tool-1=mig | tool-2 tool-3 | named a subset: position added the rest | const reviewSeed = g.model({ / results: [seed, dump], |
| v13 | rendezvous | glm-flash | 3 | model-3=merge | tool-1=mig tool-2=seed tool-3=dump |  | named nothing: every read positional | g.model({ |
| v13 | three-stage-pairing | glm-5.3 | 2 | script-1=merge | tool-1=a tool-2=b tool-3=c | (stage results) | a value stage named them | results: [fetchA, normA, fetchB, normB, fetchC, normC], |
| v13 | three-stage-pairing | glm-flash | 2 | script-1=merge | tool-1=a tool-2=b tool-3=c | (stage results) | a value stage named them | results: [pairs[0][0], pairs[1][0], pairs[2][0], pairs[0][1], pairs[1] |
| v13 | two-source-fan-in | glm-5.3 | 1 | model-3=report | tool-1=t tool-2=l tool-3=ty | model-1 model-2 | named a subset: position added the rest | const report = g.model({ / results: [testSummary, qualitySummary] |
| v13 | two-source-fan-in | glm-5.3 | 3 | model-1=ts | tool-2=l tool-3=ty | tool-1 | named a subset: position added the rest | const testSummary = g.model({prompt: "Summarise the test failures from |
| v13 | two-source-fan-in | glm-5.3 | 3 | model-2=qs | model-1=ts | tool-2 tool-3 | named a subset: position added the rest | const qualitySummary = g.model({prompt: "Summarise code quality from t |
| v13 | two-source-fan-in | kimi-k3 | 1 | model-3=report | tool-1=t tool-2=l tool-3=ty | model-1 model-2 | named a subset: position added the rest | g.model({ / prompt: "You are given two summaries: one of the test results and one  |
| v13 | two-source-fan-in | kimi-k3 | 2 | model-3=report | tool-1=t tool-2=l tool-3=ty | model-1 model-2 | named a subset: position added the rest | g.model({ / results: [testSummary, qualitySummary], |
| v13 | two-source-fan-in | kimi-k3 | 3 | model-3=report | tool-1=t tool-2=l tool-3=ty | model-1 model-2 | named a subset: position added the rest | g.model({ / results: [testSummary, qualitySummary] |
| v13 | two-source-fan-in | ds-flash | 1 | model-3=report | tool-1=t tool-2=l tool-3=ty | script-1 | named a subset: position added the rest | g.model({ / results: [both], |
| v13 | two-source-fan-in | glm-flash | 2 | model-3=report | tool-1=t tool-2=l tool-3=ty | model-1 model-2 | named a subset: position added the rest | g.model({ / results: [testSummary, qualitySummary], |
| v13 | two-source-fan-in | glm-flash | 3 | model-3=report | tool-1=t tool-2=l tool-3=ty | model-1 model-2 | named a subset: position added the rest | g.model({ / results: [testSummary, qualitySummary] |
| v14 | background-suite | glm-5.3 | 1 | model-2 | tool-1=suite tool-2=lint model-1=fix tool-3 | tool-1 tool-2 model-1 tool-3 | over-named: every extra read named | const report = g.model({ / results: [tests, audit, fixer, verify], |
| v14 | background-suite | glm-5.3 | 3 | model-2 | tool-1=suite model-1=fix tool-3 | tool-1 model-1 tool-3 | over-named: every extra read named | const closer = g.model({ / results: [suite, fixer, verify], |
| v14 | background-suite | ds-flash | 2 | model-1=fix | tool-1=suite |  | named nothing: every read positional | g.model({ |
| v14 | background-suite | ds-flash | 3 | model-2 | tool-1=suite model-1=fix | tool-1 model-1 | over-named: every extra read named | g.model({ / "Combine the results below into one report for the operator.", |
| v14 | background-suite | glm-flash | 2 | script-1/model-1=fix | script-1/tool-2 script-1/tool-3 |  | named nothing: every read positional | (placed by a g.script stage) |
| v14 | rendezvous | glm-5.3 | 2 | model-1=rm | tool-2=seed | tool-1 tool-3 | named a subset: position added the rest | const reviewMigrate = g.model({ / prompt: "You are reviewing a Rails migration run. You are given exactl |
| v14 | rendezvous | glm-5.3 | 2 | model-2=rs | tool-1=mig | tool-2 tool-3 | named a subset: position added the rest | const reviewSeed = g.model({ / prompt: "You are reviewing a Rails seeding run. You are given exactly  |
| v14 | rendezvous | glm-5.3 | 2 | model-3=merge | tool-1=mig tool-2=seed tool-3=dump | model-1 model-2 | named a subset: position added the rest | g.model({ / prompt: "You are given exactly two results, in this order: (1) a revie |
| v14 | rendezvous | glm-5.3 | 3 | model-3=merge | tool-1=mig tool-2=seed tool-3=dump | model-1 model-2 | named a subset: position added the rest | g.model({ / results: [reviewMigrate, reviewSeed] |
| v14 | rendezvous | kimi-k3 | 2 | model-3=merge | tool-1=mig tool-2=seed tool-3=dump | model-1 model-2 | named a subset: position added the rest | g.model({ / results: [migrateReview, seedReview], |
| v14 | rendezvous | ds-flash | 1 | model-1=rm | tool-2=seed | tool-1 tool-3 | named a subset: position added the rest | const migrateReview = g.model({ / results: [migrate, dump], |
| v14 | rendezvous | ds-flash | 1 | model-2=rs | tool-1=mig | tool-2 tool-3 | named a subset: position added the rest | const seedReview = g.model({ / results: [seed, dump], |
| v14 | rendezvous | ds-flash | 1 | model-3=merge | tool-1=mig tool-2=seed tool-3=dump | model-1 model-2 | named a subset: position added the rest | g.model({ / results: [migrateReview, seedReview], |
| v14 | rendezvous | ds-flash | 2 | model-3=merge | tool-1=mig tool-2=seed tool-3=dump |  | named nothing: every read positional | g.model({ |
| v14 | rendezvous | ds-flash | 3 | model-1=rm | tool-2=seed | tool-1 tool-3 | named a subset: position added the rest | const reviewMigrate = g.model({ / "Review the database MIGRATION step only. Your scope is exactly two ba |
| v14 | rendezvous | ds-flash | 3 | model-2=rs | tool-1=mig | tool-2 tool-3 | named a subset: position added the rest | const reviewSeed = g.model({ / "Review the database SEED step only. Your scope is exactly two bash re |
| v14 | rendezvous | ds-flash | 3 | model-3=merge | tool-1=mig tool-2=seed tool-3=dump | model-1 model-2 | named a subset: position added the rest | g.model({ / results: [reviewMigrate, reviewSeed], |
| v14 | rendezvous | glm-flash | 2 | model-3=merge | tool-1=mig tool-2=seed tool-3=dump | model-1 model-2 | named a subset: position added the rest | g.model({ / results: [reviewMigrate, reviewSeed], |
| v14 | three-stage-pairing | ds-flash | 1 | model-4=merge | tool-1=a tool-2=b tool-3=c | model-1 model-2 model-3 | named a subset: position added the rest | g.model({ / results: [na, nb, nc], |
| v14 | two-source-fan-in | glm-5.3 | 1 | script-1/model-3=report | script-1/tool-1=t script-1/tool-2=l script-1/tool-3=ty | script-1/model-1 script-1/model-2 | named a subset: position added the rest | (placed by a g.script stage) |
| v14 | two-source-fan-in | glm-5.3 | 3 | model-3=report | tool-1=t tool-2=l tool-3=ty | model-1 model-2 | named a subset: position added the rest | g.model({ / results: [testSummary, qualitySummary], |
| v14 | two-source-fan-in | kimi-k3 | 1 | model-3=report | tool-1=t tool-2=l tool-3=ty |  | named nothing: every read positional | g.model({ |
| v14 | two-source-fan-in | kimi-k3 | 2 | model-3=report | tool-1=t tool-2=l tool-3=ty | model-1 model-2 | named a subset: position added the rest | g.model({ / results: [testSummary, qualitySummary], |
| v14 | two-source-fan-in | kimi-k3 | 3 | model-3=report | tool-1=t tool-2=l tool-3=ty | model-1 model-2 | named a subset: position added the rest | g.model({ / prompt: "Write the final report from the two summaries below (one of t |
| v14 | two-source-fan-in | ds-flash | 2 | model-3=report | tool-1=t tool-2=l tool-3=ty | model-1 model-2 | named a subset: position added the rest | g.model({ / results: [testSummary, qualitySummary] |
| v14 | two-source-fan-in | ds-flash | 3 | model-3=report | tool-1=t tool-2=l tool-3=ty | model-1 model-2 | named a subset: position added the rest | g.model({ / results: [testsSummary, qualitySummary], |
| v14 | two-source-fan-in | glm-flash | 2 | model-3=report | tool-1=t tool-2=l tool-3=ty | model-1 model-2 | named a subset: position added the rest | g.model({ / results: [testSummary, qualitySummary], |

## D2f readers by intent
- v13: 41 over-reading steps: named a subset: position added the rest 27, mixed: some extras named, some positional 4, named nothing: every read positional 4, over-named: every extra read named 4, a value stage named them 2
- v14: 27 over-reading steps: named a subset: position added the rest 20, named nothing: every read positional 4, over-named: every extra read named 3

## D2d per reading: the reader, its reads, the picture's, and its script lines
v13 compose-background-suite inner stages=0 glm-5.3 #2 [extra_steps,over_read] graph={"nodes":["tool-1:tool","tool-2:tool","model-1:model","tool-3:tool","model-2:model","tool-4:tool","script-1:script"],"edges":["tool-1->tool-2","tool-2->model-1","model-1->tool-3","tool-3->model-2","model-2->tool-4","tool-1->script-1","tool-2->script-1","model-1->script-1","tool-3->script-1","model-2->script-1","tool-4->script-1"],"reads":{"model-1":["tool-1","tool-2"],"model-2":["model-1","tool-3"
  reader model-1=fix (model) reads tool-1=suite, tool-2=lint; picture gives tool-2=lint; extra tool-1=suite; named results: ["tool-2"]
      L19: const fixer1 = g.model({
      L21: results: [cop1],
      L38: });
  reader model-2 (model) reads model-1=fix, tool-3; picture gives (no label: extra step); extra model-1=fix, tool-3; named results: ["tool-3"]
      L46: const fixer2 = g.model({
      L48: results: [cop2],
      L52: "The attached tool result is a fresh run of `bin/rubocop app` made after those fixes.",
      L65: });
v13 compose-background-suite inner stages=0 kimi-k3 #2 [extra_steps,over_read] graph={"nodes":["tool-1:tool","tool-2:tool","model-1:model","tool-3:tool","model-2:model"],"edges":["tool-2->model-1","model-1->tool-3","tool-1->model-2","model-1->model-2","tool-3->model-2"],"reads":{"model-1":["tool-2"],"model-2":["tool-1","model-1","tool-3"]}}
  reader model-2 (model) reads tool-1=suite, model-1=fix, tool-3; picture gives (no label: extra step); extra tool-1=suite, model-1=fix, tool-3; named results: ["tool-1", "model-1", "tool-3"]
      L36: g.model({
      L37: results: [tests, fixer, verify],
      L39: "You are given three step results: (1) the header from starting `bin/rails test` as a background process, (2) a fixer's report of the rubocop offences
      L42: });
v13 compose-background-suite inner stages=0 kimi-k3 #3 [extra_steps,over_read] graph={"nodes":["tool-1:tool","tool-2:tool","model-1:model","tool-3:tool","model-2:model","tool-4:tool","model-3:model"],"edges":["tool-2->model-1","model-1->tool-3","tool-3->model-2","model-2->tool-4","tool-1->model-3","model-1->model-3","model-2->model-3","tool-4->model-3"],"reads":{"model-1":["tool-2"],"model-2":["model-1","tool-3"],"model-3":["tool-1","model-2","tool-4","model-1"]}}
  reader model-2 (model) reads model-1=fix, tool-3; picture gives (no label: extra step); extra model-1=fix, tool-3; named results: ["tool-3"]
      L29: const fix2 = g.model({
      L30: results: [rubo2],
      L31: prompt: `You are working in a Rails project; the current working directory is its root. Attached is the output of a SECOND run of \`bin/rubocop app\`,
      L32: });
  reader model-3 (model) reads tool-1=suite, model-2, tool-4, model-1=fix; picture gives (no label: extra step); extra tool-1=suite, model-2, tool-4, model-1=fix; named results: ["tool-1", "model-1", "model-2", "tool-4"]
      L43: g.model({
      L44: results: [tests, fix1, fix2, rubo3],
      L50: });
v13 compose-background-suite inner stages=0 ds-flash #2 [extra_steps,over_read] graph={"nodes":["tool-1:tool","tool-2:tool","model-1:model","model-2:model"],"edges":["tool-2->model-1","tool-1->model-2","tool-2->model-2","model-1->model-2"],"reads":{"model-1":["tool-2"],"model-2":["tool-1","tool-2","model-1"]}}
  reader model-2 (model) reads tool-1=suite, tool-2=lint, model-1=fix; picture gives (no label: extra step); extra tool-1=suite, tool-2=lint, model-1=fix; named results: []
      L46: g.model({
      L48: `Write the short final report for a two-part background job (results are above).`,
      L50: `Part A — the test suite: report the start_process receipt for \`bin/rails test\`: its process id, status, and log path. It is expected to still be ru
      L57: });
v13 compose-background-suite inner stages=0 ds-flash #3 [over_read] graph={"nodes":["tool-1:tool","tool-2:tool","model-1:model","tool-3:tool","model-2:model"],"edges":["tool-1->model-1","tool-2->model-1","model-1->tool-3","tool-3->model-2"],"reads":{"model-1":["tool-1","tool-2"],"model-2":["model-1","tool-3"]}}
  reader model-1=fix (model) reads tool-1=suite, tool-2=lint; picture gives tool-2=lint; extra tool-1=suite; named results: []
      L22: g.model({
      L29: });
v13 compose-background-suite inner stages=0 glm-flash #2 [extra_steps,over_read] graph={"nodes":["tool-1:tool","model-1:model","tool-2:tool","model-2:model","tool-3:tool","model-3:model"],"edges":["tool-1->model-1","tool-2->model-2","model-2->tool-3","model-2->model-3","tool-3->model-3"],"reads":{"model-1":["tool-1"],"model-2":["tool-2"],"model-3":["model-2","tool-3"]}}
  reader model-1 (model) reads tool-1=suite; picture gives (no label: extra step); extra tool-1=suite; named results: ["tool-1"]
      L6: const suiteSummary = g.model({
      L8: results: [suite]
      L9: });
v13 compose-background-suite inner stages=0 glm-flash #3 [extra_steps,over_read] graph={"nodes":["tool-1:tool","tool-2:tool","model-1:model","tool-3:tool","script-1:script","model-2:model"],"edges":["tool-2->model-1","model-1->tool-3","tool-3->script-1","tool-1->model-2","tool-2->model-2","model-1->model-2","tool-3->model-2","script-1->model-2"],"reads":{"model-1":["tool-2"],"script-1":["tool-3"],"model-2":["tool-1","tool-2","model-1","tool-3","script-1"]}}
  reader model-2 (model) reads tool-1=suite, tool-2=lint, model-1=fix, tool-3; picture gives (no label: extra step); extra tool-1=suite, tool-2=lint, model-1=fix, tool-3; named results: ["tool-1", "tool-2", "model-1", "tool-3", "script-1"]
      L82: const report = g.model({
      L83: results: [suite, survey, fix, verify, ensure],
      L85: prompt: `Write the final answer to the operator. You receive five results:
      L87: results[0] — the start_process receipt for the background command: bin/rails test
      L88: results[1] — the initial bin/rubocop app survey
      L89: results[2] — the first fixer's report
      L90: results[3] — an independent re-run of bin/rubocop app
      L91: results[4] — the follow-up stage: either a "verified clean" marker, or a second fix pass's report and assessment
      L94: 1. From results[0], find the background process id: check structured_content for an id/process_id field, otherwise match a token like p3 in the receip
      L97: Test suite — started in the background as a tracked process (give its id) and what the snapshot shows right now. State plainly that nothing was made t
      L99: Rubocop — the initial offence count and cops involved, every file changed and how (autocorrect vs hand-fix), and the authoritative final state from re
      L102: });
      L104: g.parallel([suite, survey, fix, verify, ensure, report]);
v13 compose-rendezvous inner stages=0 glm-5.3 #1 [over_read] graph={"nodes":["tool-1:tool","tool-2:tool","tool-3:tool","model-1:model","model-2:model","model-3:model"],"edges":["tool-1->tool-3","tool-2->tool-3","tool-1->model-1","tool-3->model-1","tool-2->model-2","tool-3->model-2","tool-1->model-3","tool-2->model-3","tool-3->model-3","model-1->model-3","model-2->model-3"],"reads":{"model-1":["tool-1","tool-3"],"model-2":["tool-2","tool-3"],"model-3":["tool-1","t
  reader model-3=merge (model) reads tool-1=mig, tool-2=seed, tool-3=dump, model-1=rm, model-2=rs; picture gives model-1=rm, model-2=rs; extra tool-1=mig, tool-2=seed, tool-3=dump; named results: ["model-1", "model-2"]
      L29: const merge = g.model({
      L31: results: [reviewMigrate, reviewSeed]
      L32: });
v13 compose-rendezvous inner stages=0 glm-5.3 #2 [over_read] graph={"nodes":["tool-1:tool","tool-2:tool","tool-3:tool","model-1:model","model-2:model","model-3:model"],"edges":["tool-1->tool-3","tool-2->tool-3","tool-1->model-1","tool-3->model-1","tool-2->model-2","tool-3->model-2","tool-1->model-3","tool-2->model-3","tool-3->model-3","model-1->model-3","model-2->model-3"],"reads":{"model-1":["tool-1","tool-3"],"model-2":["tool-2","tool-3"],"model-3":["tool-1","t
  reader model-3=merge (model) reads tool-1=mig, tool-2=seed, tool-3=dump, model-1=rm, model-2=rs; picture gives model-1=rm, model-2=rs; extra tool-1=mig, tool-2=seed, tool-3=dump; named results: ["model-1", "model-2"]
      L22: const merge = g.model({
      L24: results: [reviewMigrate, reviewSeed],
      L25: });
v13 compose-rendezvous inner stages=0 glm-5.3 #3 [over_read] graph={"nodes":["script-1/tool-1:tool","script-1/tool-2:tool","script-1/tool-3:tool","script-1/model-1:model","script-1/model-2:model","script-1/model-3:model"],"edges":["script-1/tool-1->script-1/tool-3","script-1/tool-2->script-1/tool-3","script-1/tool-1->script-1/model-1","script-1/tool-3->script-1/model-1","script-1/tool-2->script-1/model-2","script-1/tool-3->script-1/model-2","script-1/tool-1->scri
  reader script-1/model-3=merge (model) reads script-1/tool-1=mig, script-1/tool-2=seed, script-1/tool-3=dump, script-1/model-1=rm, script-1/model-2=rs; picture gives script-1/model-1=rm, script-1/model-2=rs; extra script-1/tool-1=mig, script-1/tool-2=seed, script-1/tool-3=dump; named results: ["script-1/model-1", "script-1/model-2"]
v13 compose-rendezvous inner stages=0 kimi-k3 #1 [over_read] graph={"nodes":["tool-1:tool","tool-2:tool","tool-3:tool","model-1:model","model-2:model","model-3:model"],"edges":["tool-1->tool-3","tool-2->tool-3","tool-1->model-1","tool-3->model-1","tool-2->model-2","tool-3->model-2","tool-1->model-3","tool-2->model-3","tool-3->model-3","model-1->model-3","model-2->model-3"],"reads":{"model-1":["tool-1","tool-3"],"model-2":["tool-2","tool-3"],"model-3":["tool-1","t
  reader model-3=merge (model) reads tool-1=mig, tool-2=seed, tool-3=dump, model-1=rm, model-2=rs; picture gives model-1=rm, model-2=rs; extra tool-1=mig, tool-2=seed, tool-3=dump; named results: ["model-1", "model-2"]
      L17: g.model({
      L19: results: [migrateReview, seedReview]
      L20: });
v13 compose-rendezvous inner stages=0 kimi-k3 #2 [over_read] graph={"nodes":["tool-1:tool","tool-2:tool","tool-3:tool","model-1:model","model-2:model","model-3:model"],"edges":["tool-1->tool-3","tool-2->tool-3","tool-1->model-1","tool-3->model-1","tool-2->model-2","tool-3->model-2","tool-1->model-3","tool-2->model-3","tool-3->model-3","model-1->model-3","model-2->model-3"],"reads":{"model-1":["tool-1","tool-3"],"model-2":["tool-2","tool-3"],"model-3":["tool-1","t
  reader model-3=merge (model) reads tool-1=mig, tool-2=seed, tool-3=dump, model-1=rm, model-2=rs; picture gives model-1=rm, model-2=rs; extra tool-1=mig, tool-2=seed, tool-3=dump; named results: ["model-1", "model-2"]
      L52: g.model({
      L62: results: [migrateReview, seedReview],
      L63: });
v13 compose-rendezvous inner stages=0 kimi-k3 #3 [over_read] graph={"nodes":["tool-1:tool","tool-2:tool","tool-3:tool","model-1:model","model-2:model","model-3:model"],"edges":["tool-1->tool-3","tool-2->tool-3","tool-1->model-1","tool-3->model-1","tool-2->model-2","tool-3->model-2","tool-1->model-3","tool-2->model-3","tool-3->model-3","model-1->model-3","model-2->model-3"],"reads":{"model-1":["tool-1","tool-3"],"model-2":["tool-2","tool-3"],"model-3":["tool-1","t
  reader model-3=merge (model) reads tool-1=mig, tool-2=seed, tool-3=dump, model-1=rm, model-2=rs; picture gives model-1=rm, model-2=rs; extra tool-1=mig, tool-2=seed, tool-3=dump; named results: ["model-1", "model-2"]
      L21: g.model({
      L22: results: [migReview, seedReview],
      L24: });
v13 compose-rendezvous inner stages=0 ds-flash #1 [over_read] graph={"nodes":["tool-1:tool","tool-2:tool","tool-3:tool","model-1:model","model-2:model","model-3:model"],"edges":["tool-1->tool-3","tool-2->tool-3","tool-1->model-1","tool-3->model-1","tool-2->model-2","tool-3->model-2","model-1->model-3","model-2->model-3"],"reads":{"model-1":["tool-1","tool-2","tool-3"],"model-2":["tool-1","tool-2","tool-3"],"model-3":["tool-1","tool-2","tool-3","model-1","model-2"]
  reader model-1=rm (model) reads tool-1=mig, tool-2=seed, tool-3=dump; picture gives tool-1=mig, tool-3=dump; extra tool-2=seed; named results: ["tool-1", "tool-3"]
      L23: const reviewMigrate = g.model({
      L35: results: [migrate, dump],
      L36: });
  reader model-2=rs (model) reads tool-1=mig, tool-2=seed, tool-3=dump; picture gives tool-2=seed, tool-3=dump; extra tool-1=mig; named results: ["tool-2", "tool-3"]
      L38: const reviewSeed = g.model({
      L51: results: [seed, dump],
      L52: });
      L54: g.parallel([reviewMigrate, reviewSeed]);
      L56: // 4. merge: placed after the group, so it reads both reviews and nothing else.
  reader model-3=merge (model) reads tool-1=mig, tool-2=seed, tool-3=dump, model-1=rm, model-2=rs; picture gives model-1=rm, model-2=rs; extra tool-1=mig, tool-2=seed, tool-3=dump; named results: []
      L57: g.model({
      L71: });
v13 compose-rendezvous inner stages=0 ds-flash #2 [over_read] graph={"nodes":["tool-1:tool","tool-2:tool","tool-3:tool","model-1:model","model-2:model","model-3:model"],"edges":["tool-1->tool-3","tool-2->tool-3","tool-1->model-1","tool-3->model-1","tool-2->model-2","tool-3->model-2","model-1->model-3","model-2->model-3"],"reads":{"model-1":["tool-1","tool-2","tool-3"],"model-2":["tool-1","tool-2","tool-3"],"model-3":["tool-1","tool-2","tool-3","model-1","model-2"]
  reader model-1=rm (model) reads tool-1=mig, tool-2=seed, tool-3=dump; picture gives tool-1=mig, tool-3=dump; extra tool-2=seed; named results: ["tool-1", "tool-3"]
      L15: const reviewMigrate = g.model({
      L18: results: [migrate, dump],
      L19: });
  reader model-2=rs (model) reads tool-1=mig, tool-2=seed, tool-3=dump; picture gives tool-2=seed, tool-3=dump; extra tool-1=mig; named results: ["tool-2", "tool-3"]
      L21: const reviewSeed = g.model({
      L24: results: [seed, dump],
      L25: });
      L27: g.parallel([reviewMigrate, reviewSeed]);
  reader model-3=merge (model) reads tool-1=mig, tool-2=seed, tool-3=dump, model-1=rm, model-2=rs; picture gives model-1=rm, model-2=rs; extra tool-1=mig, tool-2=seed, tool-3=dump; named results: ["model-1", "model-2"]
      L30: g.model({
      L33: results: [reviewMigrate, reviewSeed],
      L34: });
v13 compose-rendezvous inner stages=0 ds-flash #3 [over_read] graph={"nodes":["tool-1:tool","tool-2:tool","tool-3:tool","model-1:model","model-2:model","model-3:model"],"edges":["tool-1->tool-3","tool-2->tool-3","tool-1->model-1","tool-3->model-1","tool-2->model-2","tool-3->model-2","model-1->model-3","model-2->model-3"],"reads":{"model-1":["tool-1","tool-2","tool-3"],"model-2":["tool-1","tool-2","tool-3"],"model-3":["tool-1","tool-2","tool-3","model-1","model-2"]
  reader model-1=rm (model) reads tool-1=mig, tool-2=seed, tool-3=dump; picture gives tool-1=mig, tool-3=dump; extra tool-2=seed; named results: ["tool-1", "tool-3"]
      L10: const migrateReview = g.model({
      L11: prompt: 'You are one of two independent reviewers working in parallel. The other reviewer cannot see your output and you cannot see theirs: use nothin
      L12: results: [migrate, dump]
      L13: });
  reader model-2=rs (model) reads tool-1=mig, tool-2=seed, tool-3=dump; picture gives tool-2=seed, tool-3=dump; extra tool-1=mig; named results: ["tool-2", "tool-3"]
      L14: const seedReview = g.model({
      L15: prompt: 'You are one of two independent reviewers working in parallel. The other reviewer cannot see your output and you cannot see theirs: use nothin
      L16: results: [seed, dump]
      L17: });
      L18: g.parallel([migrateReview, seedReview]);   // the two reviews run at once, isolated from each other
  reader model-3=merge (model) reads tool-1=mig, tool-2=seed, tool-3=dump, model-1=rm, model-2=rs; picture gives model-1=rm, model-2=rs; extra tool-1=mig, tool-2=seed, tool-3=dump; named results: ["model-1", "model-2"]
      L21: g.model({
      L22: prompt: 'Below are two independent reviews of the same Rails task, produced in parallel and unable to see each other. One reviewed the `bin/rails db:m
      L23: results: [migrateReview, seedReview]
      L24: });
v13 compose-rendezvous inner stages=0 glm-flash #2 [extra_steps,over_read] graph={"nodes":["script-1/tool-1:tool","script-1/tool-2:tool","script-1/tool-3:tool","script-1/tool-4:tool","script-1/model-1:model","script-1/model-2:model","script-1/model-3:model"],"edges":["script-1/tool-1->script-1/tool-3","script-1/tool-2->script-1/tool-3","script-1/tool-3->script-1/tool-4","script-1/tool-1->script-1/model-1","script-1/tool-3->script-1/model-1","script-1/tool-4->script-1/model-1",
  reader script-1/model-1=rm (model) reads script-1/tool-1=mig, script-1/tool-2=seed, script-1/tool-3=dump, script-1/tool-4; picture gives script-1/tool-1=mig, script-1/tool-3=dump; extra script-1/tool-2=seed, script-1/tool-4; named results: ["script-1/tool-1", "script-1/tool-3", "script-1/tool-4"]
  reader script-1/model-2=rs (model) reads script-1/tool-1=mig, script-1/tool-2=seed, script-1/tool-3=dump, script-1/tool-4; picture gives script-1/tool-2=seed, script-1/tool-3=dump; extra script-1/tool-1=mig, script-1/tool-4; named results: ["script-1/tool-2", "script-1/tool-3", "script-1/tool-4"]
  reader script-1/model-3=merge (model) reads script-1/tool-1=mig, script-1/tool-2=seed, script-1/tool-3=dump, script-1/tool-4, script-1/model-1=rm, script-1/model-2=rs; picture gives script-1/model-1=rm, script-1/model-2=rs; extra script-1/tool-1=mig, script-1/tool-2=seed, script-1/tool-3=dump, script-1/tool-4; named results: ["script-1/model-1", "script-1/model-2"]
v13 compose-rendezvous inner stages=0 glm-flash #3 [over_read] graph={"nodes":["tool-1:tool","tool-2:tool","tool-3:tool","model-1:model","model-2:model","model-3:model"],"edges":["tool-1->tool-3","tool-2->tool-3","tool-1->model-1","tool-3->model-1","tool-2->model-2","tool-3->model-2","model-1->model-3","model-2->model-3"],"reads":{"model-1":["tool-1","tool-2","tool-3"],"model-2":["tool-1","tool-2","tool-3"],"model-3":["tool-1","tool-2","tool-3","model-1","model-2"]
  reader model-1=rm (model) reads tool-1=mig, tool-2=seed, tool-3=dump; picture gives tool-1=mig, tool-3=dump; extra tool-2=seed; named results: ["tool-1", "tool-3"]
      L19: const reviewMigrate = g.model({
      L20: results: [migrate, dump],
      L22: });
  reader model-2=rs (model) reads tool-1=mig, tool-2=seed, tool-3=dump; picture gives tool-2=seed, tool-3=dump; extra tool-1=mig; named results: ["tool-2", "tool-3"]
      L23: const reviewSeed = g.model({
      L24: results: [seed, dump],
      L26: });
      L27: g.parallel([reviewMigrate, reviewSeed]);
      L29: // Stage 4 — merge, written after the reviews group: it reads both reviews' accumulated output.
  reader model-3=merge (model) reads tool-1=mig, tool-2=seed, tool-3=dump, model-1=rm, model-2=rs; picture gives model-1=rm, model-2=rs; extra tool-1=mig, tool-2=seed, tool-3=dump; named results: []
      L30: g.model({
      L32: });
v13 compose-three-stage-pairing inner stages=0 glm-5.3 #2 [over_read] graph={"nodes":["tool-1:tool","model-1:model","tool-2:tool","model-2:model","tool-3:tool","model-3:model","script-1:script"],"edges":["tool-1->model-1","tool-2->model-2","tool-3->model-3","tool-1->script-1","model-1->script-1","tool-2->script-1","model-2->script-1","tool-3->script-1","model-3->script-1"],"reads":{"model-1":["tool-1"],"model-2":["tool-2"],"model-3":["tool-3"],"script-1":["tool-1","model-
  reader script-1=merge (script) reads tool-1=a, model-1=na, tool-2=b, model-2=nb, tool-3=c, model-3=nc; picture gives model-1=na, model-2=nb, model-3=nc; extra tool-1=a, tool-2=b, tool-3=c; named results: n/a
      L37: g.script({
      L38: results: [fetchA, normA, fetchB, normB, fetchC, normC],
      L46: const fetch = results[2 * i];
      L47: const norm = results[2 * i + 1];
      L65: });
v13 compose-three-stage-pairing inner stages=0 glm-flash #2 [over_read] graph={"nodes":["tool-1:tool","model-1:model","tool-2:tool","model-2:model","tool-3:tool","model-3:model","script-1:script"],"edges":["tool-1->model-1","tool-2->model-2","tool-3->model-3","tool-1->script-1","model-1->script-1","tool-2->script-1","model-2->script-1","tool-3->script-1","model-3->script-1"],"reads":{"model-1":["tool-1"],"model-2":["tool-2"],"model-3":["tool-3"],"script-1":["tool-1","tool-2
  reader script-1=merge (script) reads tool-1=a, tool-2=b, tool-3=c, model-1=na, model-2=nb, model-3=nc; picture gives model-1=na, model-2=nb, model-3=nc; extra tool-1=a, tool-2=b, tool-3=c; named results: n/a
      L46: g.script({
      L47: results: [pairs[0][0], pairs[1][0], pairs[2][0], pairs[0][1], pairs[1][1], pairs[2][1]],
      L50: const fetches = results.slice(0, 3);
      L51: const norms = results.slice(3);
      L60: });
      L76: });
      L81: });
v13 compose-two-source-fan-in inner stages=0 glm-5.3 #1 [over_read] graph={"nodes":["tool-1:tool","tool-2:tool","tool-3:tool","model-1:model","model-2:model","model-3:model"],"edges":["tool-1->model-1","tool-2->model-2","tool-3->model-2","tool-1->model-3","tool-2->model-3","tool-3->model-3","model-1->model-3","model-2->model-3"],"reads":{"model-1":["tool-1"],"model-2":["tool-2","tool-3"],"model-3":["tool-1","tool-2","tool-3","model-1","model-2"]}}
  reader model-3=report (model) reads tool-1=t, tool-2=l, tool-3=ty, model-1=ts, model-2=qs; picture gives model-1=ts, model-2=qs; extra tool-1=t, tool-2=l, tool-3=ty; named results: ["model-1", "model-2"]
      L18: const report = g.model({
      L20: results: [testSummary, qualitySummary]
      L21: });
      L22: g.parallel([report]);
v13 compose-two-source-fan-in inner stages=0 glm-5.3 #3 [over_sync,over_read] graph={"nodes":["tool-1:tool","tool-2:tool","tool-3:tool","model-1:model","model-2:model","model-3:model"],"edges":["tool-1->tool-2","tool-2->tool-3","tool-1->model-1","tool-3->model-1","tool-2->model-2","tool-3->model-2","model-1->model-2","model-1->model-3","model-2->model-3"],"reads":{"model-1":["tool-1","tool-2","tool-3"],"model-2":["model-1","tool-2","tool-3"],"model-3":["model-2","model-1"]}}
  reader model-1=ts (model) reads tool-1=t, tool-2=l, tool-3=ty; picture gives tool-1=t; extra tool-2=l, tool-3=ty; named results: ["tool-1"]
      L5: const testSummary = g.model({prompt: "Summarise the test failures from this test output alone. Name each failing test as file:line with a one-line rea
  reader model-2=qs (model) reads model-1=ts, tool-2=l, tool-3=ty; picture gives tool-2=l, tool-3=ty; extra model-1=ts; named results: ["tool-2", "tool-3"]
      L6: const qualitySummary = g.model({prompt: "Summarise code quality from the lint output and the type-check output together. Name each offence / type erro
      L7: g.parallel([[tests, lint, srb, testSummary, qualitySummary]]);
v13 compose-two-source-fan-in inner stages=0 kimi-k3 #1 [over_read] graph={"nodes":["tool-1:tool","tool-2:tool","tool-3:tool","model-1:model","model-2:model","model-3:model"],"edges":["tool-1->model-1","tool-2->model-2","tool-3->model-2","tool-1->model-3","tool-2->model-3","tool-3->model-3","model-1->model-3","model-2->model-3"],"reads":{"model-1":["tool-1"],"model-2":["tool-2","tool-3"],"model-3":["tool-1","tool-2","tool-3","model-1","model-2"]}}
  reader model-3=report (model) reads tool-1=t, tool-2=l, tool-3=ty, model-1=ts, model-2=qs; picture gives model-1=ts, model-2=qs; extra tool-1=t, tool-2=l, tool-3=ty; named results: ["model-1", "model-2"]
      L17: g.model({
      L18: prompt: "You are given two summaries: one of the test results and one of code quality (lint + type check). Write the final report with a 'Tests' secti
      L19: results: [testSummary, qualitySummary],
      L20: });
v13 compose-two-source-fan-in inner stages=0 kimi-k3 #2 [over_read] graph={"nodes":["tool-1:tool","tool-2:tool","tool-3:tool","model-1:model","model-2:model","model-3:model"],"edges":["tool-1->model-1","tool-2->model-2","tool-3->model-2","tool-1->model-3","tool-2->model-3","tool-3->model-3","model-1->model-3","model-2->model-3"],"reads":{"model-1":["tool-1"],"model-2":["tool-2","tool-3"],"model-3":["tool-1","tool-2","tool-3","model-1","model-2"]}}
  reader model-3=report (model) reads tool-1=t, tool-2=l, tool-3=ty, model-1=ts, model-2=qs; picture gives model-1=ts, model-2=qs; extra tool-1=t, tool-2=l, tool-3=ty; named results: ["model-1", "model-2"]
      L40: g.model({
      L46: results: [testSummary, qualitySummary],
      L47: });
v13 compose-two-source-fan-in inner stages=0 kimi-k3 #3 [over_read] graph={"nodes":["tool-1:tool","tool-2:tool","tool-3:tool","model-1:model","model-2:model","model-3:model"],"edges":["tool-1->model-1","tool-2->model-2","tool-3->model-2","tool-1->model-3","tool-2->model-3","tool-3->model-3","model-1->model-3","model-2->model-3"],"reads":{"model-1":["tool-1"],"model-2":["tool-2","tool-3"],"model-3":["tool-1","tool-2","tool-3","model-1","model-2"]}}
  reader model-3=report (model) reads tool-1=t, tool-2=l, tool-3=ty, model-1=ts, model-2=qs; picture gives model-1=ts, model-2=qs; extra tool-1=t, tool-2=l, tool-3=ty; named results: ["model-1", "model-2"]
      L22: g.model({
      L24: results: [testSummary, qualitySummary]
      L25: });
v13 compose-two-source-fan-in inner stages=0 ds-flash #1 [over_read] graph={"nodes":["tool-1:tool","model-1:model","tool-2:tool","tool-3:tool","model-2:model","script-1:script","model-3:model"],"edges":["tool-1->model-1","tool-2->model-2","tool-3->model-2","tool-1->script-1","model-1->script-1","tool-2->script-1","tool-3->script-1","model-2->script-1","script-1->model-3"],"reads":{"model-1":["tool-1"],"model-2":["tool-2","tool-3"],"script-1":["model-1","model-2"],"model-
  reader model-3=report (model) reads tool-1=t, model-1=ts, tool-2=l, tool-3=ty, model-2=qs; picture gives model-1=ts, model-2=qs; extra tool-1=t, tool-2=l, tool-3=ty; named results: ["script-1"]
      L65: g.model({
      L66: results: [both],
      L80: });
v13 compose-two-source-fan-in inner stages=0 glm-flash #2 [over_read] graph={"nodes":["tool-1:tool","tool-2:tool","tool-3:tool","model-1:model","model-2:model","model-3:model"],"edges":["tool-1->model-1","tool-2->model-2","tool-3->model-2","tool-1->model-3","tool-2->model-3","tool-3->model-3","model-1->model-3","model-2->model-3"],"reads":{"model-1":["tool-1"],"model-2":["tool-2","tool-3"],"model-3":["tool-1","tool-2","tool-3","model-1","model-2"]}}
  reader model-3=report (model) reads tool-1=t, tool-2=l, tool-3=ty, model-1=ts, model-2=qs; picture gives model-1=ts, model-2=qs; extra tool-1=t, tool-2=l, tool-3=ty; named results: ["model-1", "model-2"]
      L57: g.model({
      L78: results: [testSummary, qualitySummary],
      L79: });
v13 compose-two-source-fan-in inner stages=0 glm-flash #3 [over_read] graph={"nodes":["tool-1:tool","tool-2:tool","tool-3:tool","model-1:model","model-2:model","model-3:model"],"edges":["tool-1->model-1","tool-2->model-2","tool-3->model-2","tool-1->model-3","tool-2->model-3","tool-3->model-3","model-1->model-3","model-2->model-3"],"reads":{"model-1":["tool-1"],"model-2":["tool-2","tool-3"],"model-3":["tool-1","tool-2","tool-3","model-1","model-2"]}}
  reader model-3=report (model) reads tool-1=t, tool-2=l, tool-3=ty, model-1=ts, model-2=qs; picture gives model-1=ts, model-2=qs; extra tool-1=t, tool-2=l, tool-3=ty; named results: ["model-1", "model-2"]
      L33: g.model({
      L35: results: [testSummary, qualitySummary]
      L36: });
v14 compose-background-suite inner stages=0 glm-5.3 #1 [extra_steps,over_read] graph={"nodes":["tool-1:tool","tool-2:tool","model-1:model","tool-3:tool","model-2:model"],"edges":["tool-2->model-1","tool-1->tool-3","tool-2->tool-3","model-1->tool-3","tool-1->model-2","tool-2->model-2","model-1->model-2","tool-3->model-2"],"reads":{"model-1":["tool-2"],"model-2":["tool-1","tool-2","model-1","tool-3"]}}
  reader model-2 (model) reads tool-1=suite, tool-2=lint, model-1=fix, tool-3; picture gives (no label: extra step); extra tool-1=suite, tool-2=lint, model-1=fix, tool-3; named results: ["tool-1", "tool-2", "model-1", "tool-3"]
      L56: const report = g.model({
      L58: results: [tests, audit, fixer, verify],
      L64: 4. A fresh 'bin/rubocop app' re-check captured after the fixes.
      L73: });
v14 compose-background-suite inner stages=0 glm-5.3 #3 [extra_steps,over_read] graph={"nodes":["tool-1:tool","tool-2:tool","model-1:model","tool-3:tool","model-2:model"],"edges":["tool-2->model-1","tool-1->tool-3","model-1->tool-3","tool-1->model-2","model-1->model-2","tool-3->model-2"],"reads":{"model-1":["tool-2"],"model-2":["tool-1","model-1","tool-3"]}}
  reader model-2 (model) reads tool-1=suite, model-1=fix, tool-3; picture gives (no label: extra step); extra tool-1=suite, model-1=fix, tool-3; named results: ["tool-1", "model-1", "tool-3"]
      L57: const closer = g.model({
      L58: results: [suite, fixer, verify],
      L60: prompt: `You are closing out a lint-and-fix job on a Rails project whose root is your current working directory. Three results are delivered to you:
      L64: 3. An independent "bin/rubocop app" run that executed after all fixing finished. RuboCop exits 1 when offences exist, so this result may be flagged as
      L73: });
v14 compose-background-suite inner stages=0 ds-flash #2 [over_read] graph={"nodes":["tool-1:tool","tool-2:tool","model-1:model","tool-3:tool","model-2:model"],"edges":["tool-1->tool-2","tool-2->model-1","model-1->tool-3","tool-3->model-2"],"reads":{"model-1":["tool-1","tool-2"],"model-2":["model-1","tool-3"]}}
  reader model-1=fix (model) reads tool-1=suite, tool-2=lint; picture gives tool-2=lint; extra tool-1=suite; named results: []
      L15: g.model({
      L22: "Re-run `bin/rubocop app` yourself after each round of edits and keep going until it is clean.",
      L26: });
v14 compose-background-suite inner stages=0 ds-flash #3 [extra_steps,over_read] graph={"nodes":["tool-1:tool","tool-2:tool","model-1:model","model-2:model"],"edges":["tool-2->model-1","tool-1->model-2","model-1->model-2"],"reads":{"model-1":["tool-2"],"model-2":["tool-1","model-1"]}}
  reader model-2 (model) reads tool-1=suite, model-1=fix; picture gives (no label: extra step); extra tool-1=suite, model-1=fix; named results: ["tool-1", "model-1"]
      L28: g.model({
      L30: "Combine the results below into one report for the operator.",
      L36: results: [tests, fix]
      L37: });
v14 compose-background-suite inner stages=0 glm-flash #2 [extra_steps,over_read] graph={"nodes":["tool-1:tool","script-1/tool-1:tool","script-1/tool-2:tool","script-1/tool-3:tool","script-1/model-1:model"],"edges":["script-1/tool-1->script-1/tool-2","script-1/tool-2->script-1/tool-3","script-1/tool-3->script-1/model-1","tool-1->script-1/tool-1"],"reads":{"script-1/model-1":["script-1/tool-1","script-1/tool-2","script-1/tool-3"]}}
  reader script-1/model-1=fix (model) reads script-1/tool-1=lint, script-1/tool-2, script-1/tool-3; picture gives script-1/tool-1=lint; extra script-1/tool-2, script-1/tool-3; named results: []
v14 compose-rendezvous inner stages=0 glm-5.3 #2 [over_read] graph={"nodes":["tool-1:tool","tool-2:tool","tool-3:tool","model-1:model","model-2:model","model-3:model"],"edges":["tool-1->tool-3","tool-2->tool-3","tool-1->model-1","tool-3->model-1","tool-2->model-2","tool-3->model-2","model-1->model-3","model-2->model-3"],"reads":{"model-1":["tool-1","tool-2","tool-3"],"model-2":["tool-1","tool-2","tool-3"],"model-3":["tool-1","tool-2","tool-3","model-1","model-2"]
  reader model-1=rm (model) reads tool-1=mig, tool-2=seed, tool-3=dump; picture gives tool-1=mig, tool-3=dump; extra tool-2=seed; named results: ["tool-1", "tool-3"]
      L11: const reviewMigrate = g.model({
      L12: prompt: "You are reviewing a Rails migration run. You are given exactly two results, in this order: (1) the full output of the command `bin/rails db:m
      L13: results: [migrate, dump]
      L14: });
  reader model-2=rs (model) reads tool-1=mig, tool-2=seed, tool-3=dump; picture gives tool-2=seed, tool-3=dump; extra tool-1=mig; named results: ["tool-2", "tool-3"]
      L15: const reviewSeed = g.model({
      L16: prompt: "You are reviewing a Rails seeding run. You are given exactly two results, in this order: (1) the full output of the command `bin/rails db:see
      L17: results: [seed, dump]
      L18: });
      L19: g.parallel([reviewMigrate, reviewSeed]);
  reader model-3=merge (model) reads tool-1=mig, tool-2=seed, tool-3=dump, model-1=rm, model-2=rs; picture gives model-1=rm, model-2=rs; extra tool-1=mig, tool-2=seed, tool-3=dump; named results: ["model-1", "model-2"]
      L22: g.model({
      L23: prompt: "You are given exactly two results, in this order: (1) a review of the output of `bin/rails db:migrate` written alongside the schema dump, and
      L24: results: [reviewMigrate, reviewSeed]
      L25: });
v14 compose-rendezvous inner stages=0 glm-5.3 #3 [over_read] graph={"nodes":["tool-1:tool","tool-2:tool","tool-3:tool","model-1:model","model-2:model","model-3:model"],"edges":["tool-1->tool-3","tool-2->tool-3","tool-1->model-1","tool-3->model-1","tool-2->model-2","tool-3->model-2","tool-1->model-3","tool-2->model-3","tool-3->model-3","model-1->model-3","model-2->model-3"],"reads":{"model-1":["tool-1","tool-3"],"model-2":["tool-2","tool-3"],"model-3":["tool-1","t
  reader model-3=merge (model) reads tool-1=mig, tool-2=seed, tool-3=dump, model-1=rm, model-2=rs; picture gives model-1=rm, model-2=rs; extra tool-1=mig, tool-2=seed, tool-3=dump; named results: ["model-1", "model-2"]
      L45: g.model({
      L47: results: [reviewMigrate, reviewSeed]
      L48: });
v14 compose-rendezvous inner stages=0 kimi-k3 #2 [over_read] graph={"nodes":["tool-1:tool","tool-2:tool","tool-3:tool","model-1:model","model-2:model","model-3:model"],"edges":["tool-1->tool-3","tool-2->tool-3","tool-1->model-1","tool-3->model-1","tool-2->model-2","tool-3->model-2","tool-1->model-3","tool-2->model-3","tool-3->model-3","model-1->model-3","model-2->model-3"],"reads":{"model-1":["tool-1","tool-3"],"model-2":["tool-2","tool-3"],"model-3":["tool-1","t
  reader model-3=merge (model) reads tool-1=mig, tool-2=seed, tool-3=dump, model-1=rm, model-2=rs; picture gives model-1=rm, model-2=rs; extra tool-1=mig, tool-2=seed, tool-3=dump; named results: ["model-1", "model-2"]
      L25: g.model({
      L27: results: [migrateReview, seedReview],
      L28: });
v14 compose-rendezvous inner stages=0 ds-flash #1 [over_read] graph={"nodes":["tool-1:tool","tool-2:tool","tool-3:tool","model-1:model","model-2:model","model-3:model"],"edges":["tool-1->tool-3","tool-2->tool-3","tool-1->model-1","tool-3->model-1","tool-2->model-2","tool-3->model-2","model-1->model-3","model-2->model-3"],"reads":{"model-1":["tool-1","tool-2","tool-3"],"model-2":["tool-1","tool-2","tool-3"],"model-3":["tool-1","tool-2","tool-3","model-1","model-2"]
  reader model-1=rm (model) reads tool-1=mig, tool-2=seed, tool-3=dump; picture gives tool-1=mig, tool-3=dump; extra tool-2=seed; named results: ["tool-1", "tool-3"]
      L10: const migrateReview = g.model({
      L13: "You are given exactly two inputs: (a) the stdout/stderr of `bin/rails db:migrate`, and (b) the db/schema.rb produced afterwards by `bin/rails db:sche
      L21: results: [migrate, dump],
      L22: });
  reader model-2=rs (model) reads tool-1=mig, tool-2=seed, tool-3=dump; picture gives tool-2=seed, tool-3=dump; extra tool-1=mig; named results: ["tool-2", "tool-3"]
      L24: const seedReview = g.model({
      L27: "You are given exactly two inputs: (a) the stdout/stderr of `bin/rails db:seed`, and (b) the db/schema.rb produced afterwards by `bin/rails db:schema:
      L35: results: [seed, dump],
      L36: });
      L39: g.parallel([migrateReview, seedReview]);
  reader model-3=merge (model) reads tool-1=mig, tool-2=seed, tool-3=dump, model-1=rm, model-2=rs; picture gives model-1=rm, model-2=rs; extra tool-1=mig, tool-2=seed, tool-3=dump; named results: ["model-1", "model-2"]
      L42: g.model({
      L52: results: [migrateReview, seedReview],
      L53: });
v14 compose-rendezvous inner stages=0 ds-flash #2 [over_read] graph={"nodes":["tool-1:tool","tool-2:tool","tool-3:tool","model-1:model","model-2:model","model-3:model"],"edges":["tool-1->tool-3","tool-2->tool-3","tool-1->model-1","tool-3->model-1","tool-2->model-2","tool-3->model-2","tool-1->model-3","tool-2->model-3","tool-3->model-3","model-1->model-3","model-2->model-3"],"reads":{"model-1":["tool-1","tool-3"],"model-2":["tool-2","tool-3"],"model-3":["tool-1","t
  reader model-3=merge (model) reads tool-1=mig, tool-2=seed, tool-3=dump, model-1=rm, model-2=rs; picture gives model-1=rm, model-2=rs; extra tool-1=mig, tool-2=seed, tool-3=dump; named results: []
      L17: g.model({
      L19: });
v14 compose-rendezvous inner stages=0 ds-flash #3 [over_read] graph={"nodes":["tool-1:tool","tool-2:tool","tool-3:tool","model-1:model","model-2:model","model-3:model"],"edges":["tool-1->tool-3","tool-2->tool-3","tool-1->model-1","tool-3->model-1","tool-2->model-2","tool-3->model-2","model-1->model-3","model-2->model-3"],"reads":{"model-1":["tool-1","tool-2","tool-3"],"model-2":["tool-1","tool-2","tool-3"],"model-3":["tool-1","tool-2","tool-3","model-1","model-2"]
  reader model-1=rm (model) reads tool-1=mig, tool-2=seed, tool-3=dump; picture gives tool-1=mig, tool-3=dump; extra tool-2=seed; named results: ["tool-1", "tool-3"]
      L16: const reviewMigrate = g.model({
      L18: "Review the database MIGRATION step only. Your scope is exactly two bash results: " +
      L28: results: [migrate, dump],
      L29: });
  reader model-2=rs (model) reads tool-1=mig, tool-2=seed, tool-3=dump; picture gives tool-2=seed, tool-3=dump; extra tool-1=mig; named results: ["tool-2", "tool-3"]
      L31: const reviewSeed = g.model({
      L33: "Review the database SEED step only. Your scope is exactly two bash results: " +
      L44: results: [seed, dump],
      L45: });
      L46: g.parallel([reviewMigrate, reviewSeed]);
  reader model-3=merge (model) reads tool-1=mig, tool-2=seed, tool-3=dump, model-1=rm, model-2=rs; picture gives model-1=rm, model-2=rs; extra tool-1=mig, tool-2=seed, tool-3=dump; named results: ["model-1", "model-2"]
      L49: g.model({
      L60: results: [reviewMigrate, reviewSeed],
      L61: });
v14 compose-rendezvous inner stages=0 glm-flash #2 [over_read] graph={"nodes":["tool-1:tool","tool-2:tool","tool-3:tool","model-1:model","model-2:model","model-3:model"],"edges":["tool-1->tool-3","tool-2->tool-3","tool-1->model-1","tool-3->model-1","tool-2->model-2","tool-3->model-2","tool-1->model-3","tool-2->model-3","tool-3->model-3","model-1->model-3","model-2->model-3"],"reads":{"model-1":["tool-1","tool-3"],"model-2":["tool-2","tool-3"],"model-3":["tool-1","t
  reader model-3=merge (model) reads tool-1=mig, tool-2=seed, tool-3=dump, model-1=rm, model-2=rs; picture gives model-1=rm, model-2=rs; extra tool-1=mig, tool-2=seed, tool-3=dump; named results: ["model-1", "model-2"]
      L36: g.model({
      L38: results: [reviewMigrate, reviewSeed],
      L39: });
v14 compose-three-stage-pairing inner stages=0 ds-flash #1 [over_read] graph={"nodes":["tool-1:tool","tool-2:tool","tool-3:tool","model-1:model","model-2:model","model-3:model","model-4:model"],"edges":["tool-1->model-1","tool-2->model-2","tool-3->model-3","tool-1->model-4","tool-2->model-4","tool-3->model-4","model-1->model-4","model-2->model-4","model-3->model-4"],"reads":{"model-1":["tool-1"],"model-2":["tool-2"],"model-3":["tool-3"],"model-4":["tool-1","tool-2","tool-3
  reader model-4=merge (model) reads tool-1=a, tool-2=b, tool-3=c, model-1=na, model-2=nb, model-3=nc; picture gives model-1=na, model-2=nb, model-3=nc; extra tool-1=a, tool-2=b, tool-3=c; named results: ["model-1", "model-2", "model-3"]
      L25: g.model({
      L27: results: [na, nb, nc],
      L28: });
v14 compose-two-source-fan-in inner stages=0 glm-5.3 #1 [over_read] graph={"nodes":["script-1/tool-1:tool","script-1/tool-2:tool","script-1/tool-3:tool","script-1/model-1:model","script-1/model-2:model","script-1/model-3:model"],"edges":["script-1/tool-1->script-1/model-1","script-1/tool-2->script-1/model-2","script-1/tool-3->script-1/model-2","script-1/tool-1->script-1/model-3","script-1/tool-2->script-1/model-3","script-1/tool-3->script-1/model-3","script-1/model-1->s
  reader script-1/model-3=report (model) reads script-1/tool-1=t, script-1/tool-2=l, script-1/tool-3=ty, script-1/model-1=ts, script-1/model-2=qs; picture gives script-1/model-1=ts, script-1/model-2=qs; extra script-1/tool-1=t, script-1/tool-2=l, script-1/tool-3=ty; named results: ["script-1/model-1", "script-1/model-2"]
v14 compose-two-source-fan-in inner stages=0 glm-5.3 #3 [over_read] graph={"nodes":["tool-1:tool","tool-2:tool","tool-3:tool","model-1:model","model-2:model","model-3:model"],"edges":["tool-1->model-1","tool-2->model-2","tool-3->model-2","tool-1->model-3","tool-2->model-3","tool-3->model-3","model-1->model-3","model-2->model-3"],"reads":{"model-1":["tool-1"],"model-2":["tool-2","tool-3"],"model-3":["tool-1","tool-2","tool-3","model-1","model-2"]}}
  reader model-3=report (model) reads tool-1=t, tool-2=l, tool-3=ty, model-1=ts, model-2=qs; picture gives model-1=ts, model-2=qs; extra tool-1=t, tool-2=l, tool-3=ty; named results: ["model-1", "model-2"]
      L23: g.model({
      L24: results: [testSummary, qualitySummary],
      L26: });
v14 compose-two-source-fan-in inner stages=0 kimi-k3 #1 [over_read] graph={"nodes":["tool-1:tool","tool-2:tool","tool-3:tool","model-1:model","model-2:model","model-3:model"],"edges":["tool-1->model-1","tool-2->model-2","tool-3->model-2","tool-1->model-3","tool-2->model-3","tool-3->model-3","model-1->model-3","model-2->model-3"],"reads":{"model-1":["tool-1"],"model-2":["tool-2","tool-3"],"model-3":["tool-1","tool-2","tool-3","model-1","model-2"]}}
  reader model-3=report (model) reads tool-1=t, tool-2=l, tool-3=ty, model-1=ts, model-2=qs; picture gives model-1=ts, model-2=qs; extra tool-1=t, tool-2=l, tool-3=ty; named results: []
      L22: g.model({
      L24: });
v14 compose-two-source-fan-in inner stages=0 kimi-k3 #2 [over_read] graph={"nodes":["tool-1:tool","tool-2:tool","tool-3:tool","model-1:model","model-2:model","model-3:model"],"edges":["tool-1->model-1","tool-2->model-2","tool-3->model-2","tool-1->model-3","tool-2->model-3","tool-3->model-3","model-1->model-3","model-2->model-3"],"reads":{"model-1":["tool-1"],"model-2":["tool-2","tool-3"],"model-3":["tool-1","tool-2","tool-3","model-1","model-2"]}}
  reader model-3=report (model) reads tool-1=t, tool-2=l, tool-3=ty, model-1=ts, model-2=qs; picture gives model-1=ts, model-2=qs; extra tool-1=t, tool-2=l, tool-3=ty; named results: ["model-1", "model-2"]
      L17: g.model({
      L19: results: [testSummary, qualitySummary],
      L20: });
v14 compose-two-source-fan-in inner stages=0 kimi-k3 #3 [over_read] graph={"nodes":["tool-1:tool","tool-2:tool","tool-3:tool","model-1:model","model-2:model","model-3:model"],"edges":["tool-1->model-1","tool-2->model-2","tool-3->model-2","tool-1->model-3","tool-2->model-3","tool-3->model-3","model-1->model-3","model-2->model-3"],"reads":{"model-1":["tool-1"],"model-2":["tool-2","tool-3"],"model-3":["tool-1","tool-2","tool-3","model-1","model-2"]}}
  reader model-3=report (model) reads tool-1=t, tool-2=l, tool-3=ty, model-1=ts, model-2=qs; picture gives model-1=ts, model-2=qs; extra tool-1=t, tool-2=l, tool-3=ty; named results: ["model-1", "model-2"]
      L22: g.model({
      L23: prompt: "Write the final report from the two summaries below (one of test results, one of code quality from rubocop + sorbet). Structure it as: 1) a h
      L24: results: [testSummary, qualitySummary],
      L25: });
v14 compose-two-source-fan-in inner stages=0 ds-flash #2 [over_read] graph={"nodes":["tool-1:tool","tool-2:tool","tool-3:tool","model-1:model","model-2:model","model-3:model"],"edges":["tool-1->model-1","tool-2->model-2","tool-3->model-2","tool-1->model-3","tool-2->model-3","tool-3->model-3","model-1->model-3","model-2->model-3"],"reads":{"model-1":["tool-1"],"model-2":["tool-2","tool-3"],"model-3":["tool-1","tool-2","tool-3","model-1","model-2"]}}
  reader model-3=report (model) reads tool-1=t, tool-2=l, tool-3=ty, model-1=ts, model-2=qs; picture gives model-1=ts, model-2=qs; extra tool-1=t, tool-2=l, tool-3=ty; named results: ["model-1", "model-2"]
      L17: g.model({
      L19: results: [testSummary, qualitySummary]
      L20: });
v14 compose-two-source-fan-in inner stages=0 ds-flash #3 [over_read] graph={"nodes":["tool-1:tool","tool-2:tool","tool-3:tool","model-1:model","model-2:model","model-3:model"],"edges":["tool-1->model-1","tool-2->model-2","tool-3->model-2","tool-1->model-3","tool-2->model-3","tool-3->model-3","model-1->model-3","model-2->model-3"],"reads":{"model-1":["tool-1"],"model-2":["tool-2","tool-3"],"model-3":["tool-1","tool-2","tool-3","model-1","model-2"]}}
  reader model-3=report (model) reads tool-1=t, tool-2=l, tool-3=ty, model-1=ts, model-2=qs; picture gives model-1=ts, model-2=qs; extra tool-1=t, tool-2=l, tool-3=ty; named results: ["model-1", "model-2"]
      L39: g.model({
      L40: results: [testsSummary, qualitySummary],
      L43: "code quality summary). Use only what those summaries say — do not invent results, do not soften " +
      L50: });
v14 compose-two-source-fan-in inner stages=0 glm-flash #2 [over_read] graph={"nodes":["tool-1:tool","tool-2:tool","tool-3:tool","model-1:model","model-2:model","model-3:model"],"edges":["tool-1->model-1","tool-2->model-2","tool-3->model-2","tool-1->model-3","tool-2->model-3","tool-3->model-3","model-1->model-3","model-2->model-3"],"reads":{"model-1":["tool-1"],"model-2":["tool-2","tool-3"],"model-3":["tool-1","tool-2","tool-3","model-1","model-2"]}}
  reader model-3=report (model) reads tool-1=t, tool-2=l, tool-3=ty, model-1=ts, model-2=qs; picture gives model-1=ts, model-2=qs; extra tool-1=t, tool-2=l, tool-3=ty; named results: ["model-1", "model-2"]
      L43: g.model({
      L44: prompt: `You are the report writer. Two earlier agents produced: (1) a test-failure summary and (2) a code-quality summary (rubocop + Sorbet). They ar
      L55: results: [testSummary, qualitySummary],
      L57: });
```

### d3_inversion.rb

```ruby
# D(3): the strong-vs-floor inversion read like for like. Every compose-family record carries BOTH bars:
# `facts.picture` (true = the strong tier's bar: first call valid, exact edges and reads, branch completed)
# and `facts.usable_on_call` (non-nil = the floor's bar met by some call of the run). The recorded-only
# T5 (rendezvous) is shown on the same two readings (its official bars are "accepted"/"usable+completed").
# Run: ruby d3_inversion.rb (records only; plain ruby)
require_relative "d_common"

tasks = D::PICTURE_TASKS.keys.select { |t| t.start_with?("compose-") }

def usable?(r) = !r.dig("facts", "usable_on_call").nil?

%w[v13 v14].each do |bench|
  recs = D.records(bench, "compose")
  puts "## D3a #{bench}: per cell, official success / usable bar / picture bar (n = 3 each)"
  rows = tasks.map do |task|
    [task.delete_prefix("compose-"), *D::MODELS.map do |m|
      x = recs.select { |r| r["task"] == task && r["model"] == m }
      "#{x.count { |r| r.dig("verdict", "succeeded") == true }} / #{x.count { |r| usable?(r) }} / #{x.count { |r| D.picture_ok?(r) }}"
    end]
  end
  puts D.table(["task (succ / usable / picture)", *D::MODELS.map { |m| D.short(m) }], rows)
  gate = tasks - ["compose-rendezvous"]
  %w[strong floor].each do |tier|
    x = recs.select { |r| gate.include?(r["task"]) && D::TIER[D.short(r["model"])] == tier }
    puts "- #{bench} #{tier}, the seven gate/picture tasks (#{x.size} runs): official #{x.count { |r| r.dig("verdict", "succeeded") == true }}, usable #{x.count { |r| usable?(r) }}, picture #{x.count { |r| D.picture_ok?(r) }}"
  end
  puts
  puts "### D3b #{bench}: cells where a floor model beats a strong model on the SAME bar (per task: strong models' best vs floor models')"
  gate.each do |task|
    %w[usable picture].each do |bar|
      count = ->(m) { recs.select { |r| r["task"] == task && r["model"] == m }.count { |r| bar == "usable" ? usable?(r) : D.picture_ok?(r) } }
      strong = D::MODELS.first(2).to_h { |m| [D.short(m), count.(m)] }
      floor = D::MODELS.last(2).to_h { |m| [D.short(m), count.(m)] }
      next unless floor.values.max > strong.values.min

      puts "- #{task.delete_prefix("compose-")} on #{bar}: strong #{strong} floor #{floor}#{floor.values.max > strong.values.max ? "  <-- a floor model beats BOTH strong models" : ""}"
    end
  end
  puts
end

puts "## D3c compose-two-source-fan-in, every run: the shape of the first script, and both bars"
# Shape of the evaluator's steps: T tool, M model (rN = N named results), S stage, P[...] group, (...) nested sequence.
def shape(steps)
  Array(steps).map do |step|
    if step.is_a?(Array) then "(#{shape(step)})"
    elsif step.key?("parallel") then "P#{step["until"] ? "{#{step["until"]}}" : ""}[#{shape(step["parallel"])}]"
    else
      verb = (step.keys & %w[tool model script ask wait]).first
      body = step[verb]
      named = Array(body["results"]).size
      "#{verb[0].upcase}#{named.positive? ? "r#{named}" : ""}#{body["after"] ? "a#{Array(body["after"]).size}" : ""}"
    end
  end.join(" ")
end
%w[v13 v14].each do |bench|
  recs = D.records(bench, "compose").select { |r| r["task"] == "compose-two-source-fan-in" }
  puts D.table(%w[bench model run shape_of_first_script usable picture buckets cost_usd seconds],
    recs.map do |r|
      s = r.dig("facts", "score")
      [bench, D.short(r["model"]), r["run"], s.is_a?(Hash) && s["steps"] ? shape(s["steps"]) : "-", usable?(r), D.picture_ok?(r),
       D.miss_buckets(r).join(",").then { |b| D.picture_ok?(r) ? "" : b }, r.dig("efficiency", "cost_amount").to_f.round(3), r["seconds"]]
    end)
  puts
end

puts "## D3d the shape of the final (report) step on two-source-fan-in, by tier (v13+v14)"
tally = Hash.new { |h, k| h[k] = Hash.new(0) }
%w[v13 v14].each do |bench|
  D.records(bench, "compose").select { |r| r["task"] == "compose-two-source-fan-in" }.each do |r|
    s = r.dig("facts", "score")
    kind = if !s.is_a?(Hash) || !s["steps"] then "no script"
           else
             top = s["steps"]
             last = top.last
             inner = last.is_a?(Hash) && last["script"] ? "stage-wrapped: " : ""
             steps = inner.empty? ? top : nil
             if steps.nil? then "the whole plan inside one g.script stage"
             elsif last.is_a?(Hash) && last.key?("parallel") && Array(last["parallel"]).flatten.any? { |m| m.is_a?(Hash) && m["model"] && Array(m.dig("model", "results")).size == 2 && top.size == 1 }
               "report INSIDE the group (a member naming the two summaries)"
             elsif last.is_a?(Hash) && last["model"] then "report AFTER the group, #{Array(last.dig("model", "results")).empty? ? "naming nothing" : "naming #{Array(last.dig("model", "results")).size}"}"
             else "other: #{shape(top)[0, 60]}"
             end
           end
    tally[kind][D::TIER[D.short(r["model"])]] += 1
    tally[kind]["exact"] += 1 if D.picture_ok?(r)
  end
end
puts D.table(%w[final_step strong floor picture_exact], tally.map { |k, h| [k, h["strong"], h["floor"], h["exact"]] })

puts "\n## D3e how much each tier writes: first-call plan size (nodes on the recorded executed graph) against the picture's, and model steps, per task (v14; built first calls)"
PICTURE_NODES = { "O1" => 4, "O2" => 4, "O3" => 5, "O4" => 3, "O7" => 7, "O7b" => 6, "T5" => 6 }.freeze
rows = tasks.map do |task|
  obj = D::PICTURE_TASKS[task]
  cells = %w[strong floor].map do |tier|
    x = D.records("v14", "compose").select { |r| r["task"] == task && D::TIER[D.short(r["model"])] == tier }
      .map { |r| r.dig("facts", "score") }.select { |s| s.is_a?(Hash) && s["graph"] }
    nodes = x.map { |s| s["graph"]["nodes"].size }
    models = x.map { |s| s["graph"]["nodes"].count { |n| n.split(":")[1] == "model" } }
    over = x.count { |s| s["graph"]["nodes"].size > PICTURE_NODES[obj] }
    "n=#{x.size}: nodes mean #{nodes.empty? ? "-" : (nodes.sum.to_f / nodes.size).round(1)}, models mean #{models.empty? ? "-" : (models.sum.to_f / models.size).round(1)}, above picture #{over}"
  end
  [task.delete_prefix("compose-"), "#{obj} (#{PICTURE_NODES[obj]})", *cells]
end
puts D.table(["task", "objective (picture nodes)", "strong", "floor"], rows)

puts "\n## D3f compose-rendezvous and compose-background-suite, every run: shape of the first script and the picture"
%w[compose-rendezvous compose-background-suite].each do |task|
  rows = %w[v13 v14].flat_map do |bench|
    D.records(bench, "compose").select { |r| r["task"] == task }.map do |r|
      s = r.dig("facts", "score")
      [task.delete_prefix("compose-"), bench, D.short(r["model"]), r["run"], s.is_a?(Hash) && s["steps"] ? shape(s["steps"]) : "-",
       D.picture_ok?(r) ? "exact" : D.miss_buckets(r).join(",")]
    end
  end
  puts D.table(%w[task bench model run shape picture], rows)
end

puts "\n## D3g two-source-fan-in (v13+v14): the report inside the group vs after it, by tier and picture"
counts = Hash.new(0)
%w[v13 v14].each do |bench|
  D.records(bench, "compose").select { |r| r["task"] == "compose-two-source-fan-in" }.each do |r|
    s = r.dig("facts", "score")
    next unless s.is_a?(Hash) && s["steps"]

    inside = s["steps"].size == 1 && s["steps"][0].key?("parallel") &&
      s["steps"][0]["parallel"].count { |m| m.is_a?(Hash) && m["model"] } == 3
    where = inside ? "inside" : "not inside (after the group, own group, or stage-wrapped)"
    counts[[where, D::TIER[D.short(r["model"])], D.picture_ok?(r)]] += 1
  end
end
counts.sort.each { |(where, tier, pic), n| puts "- #{where}, #{tier}, picture #{pic ? "exact" : "miss"}: #{n}" }
```

Output (`d3_inversion.out`):

```text
## D3a v13: per cell, official success / usable bar / picture bar (n = 3 each)
| task (succ / usable / picture) | glm-5.3 | kimi-k3 | ds-flash | glm-flash |
|---|---|---|---|---|
| review-angles | 2 / 3 / 2 | 3 / 3 / 3 | 3 / 3 / 3 | 3 / 3 / 2 |
| grep-then-edit | 2 / 3 / 2 | 1 / 3 / 1 | 3 / 3 / 2 | 2 / 2 / 1 |
| race | 3 / 3 / 3 | 3 / 3 / 3 | 3 / 3 / 2 | 3 / 3 / 2 |
| race-anon | 3 / 3 / 3 | 3 / 3 / 3 | 3 / 3 / 2 | 3 / 3 / 3 |
| background-suite | 1 / 2 / 1 | 1 / 3 / 1 | 3 / 3 / 0 | 3 / 3 / 1 |
| three-stage-pairing | 2 / 3 / 2 | 2 / 3 / 2 | 3 / 3 / 3 | 2 / 2 / 1 |
| two-source-fan-in | 0 / 3 / 0 | 0 / 3 / 0 | 3 / 3 / 1 | 3 / 3 / 1 |
| rendezvous | 3 / 3 / 0 | 3 / 3 / 0 | 3 / 3 / 0 | 3 / 3 / 0 |
- v13 strong, the seven gate/picture tasks (42 runs): official 26, usable 41, picture 26
- v13 floor, the seven gate/picture tasks (42 runs): official 40, usable 40, picture 24

### D3b v13: cells where a floor model beats a strong model on the SAME bar (per task: strong models' best vs floor models')
- review-angles on picture: strong {"glm-5.3" => 2, "kimi-k3" => 3} floor {"ds-flash" => 3, "glm-flash" => 2}
- grep-then-edit on picture: strong {"glm-5.3" => 2, "kimi-k3" => 1} floor {"ds-flash" => 2, "glm-flash" => 1}
- background-suite on usable: strong {"glm-5.3" => 2, "kimi-k3" => 3} floor {"ds-flash" => 3, "glm-flash" => 3}
- three-stage-pairing on picture: strong {"glm-5.3" => 2, "kimi-k3" => 2} floor {"ds-flash" => 3, "glm-flash" => 1}  <-- a floor model beats BOTH strong models
- two-source-fan-in on picture: strong {"glm-5.3" => 0, "kimi-k3" => 0} floor {"ds-flash" => 1, "glm-flash" => 1}  <-- a floor model beats BOTH strong models

## D3a v14: per cell, official success / usable bar / picture bar (n = 3 each)
| task (succ / usable / picture) | glm-5.3 | kimi-k3 | ds-flash | glm-flash |
|---|---|---|---|---|
| review-angles | 3 / 3 / 3 | 3 / 3 / 3 | 3 / 3 / 3 | 3 / 3 / 3 |
| grep-then-edit | 2 / 3 / 2 | 2 / 3 / 2 | 3 / 3 / 3 | 3 / 3 / 1 |
| race | 3 / 3 / 3 | 3 / 3 / 3 | 3 / 3 / 3 | 3 / 3 / 2 |
| race-anon | 3 / 3 / 3 | 3 / 3 / 3 | 3 / 3 / 3 | 3 / 3 / 3 |
| background-suite | 1 / 3 / 1 | 1 / 3 / 1 | 3 / 3 / 1 | 3 / 3 / 1 |
| three-stage-pairing | 3 / 3 / 3 | 3 / 3 / 3 | 3 / 3 / 1 | 2 / 2 / 1 |
| two-source-fan-in | 1 / 3 / 1 | 0 / 3 / 0 | 3 / 3 / 0 | 3 / 3 / 2 |
| rendezvous | 3 / 3 / 1 | 3 / 3 / 0 | 3 / 3 / 0 | 3 / 3 / 2 |
- v14 strong, the seven gate/picture tasks (42 runs): official 31, usable 42, picture 31
- v14 floor, the seven gate/picture tasks (42 runs): official 41, usable 41, picture 27

### D3b v14: cells where a floor model beats a strong model on the SAME bar (per task: strong models' best vs floor models')
- grep-then-edit on picture: strong {"glm-5.3" => 2, "kimi-k3" => 2} floor {"ds-flash" => 3, "glm-flash" => 1}  <-- a floor model beats BOTH strong models
- two-source-fan-in on picture: strong {"glm-5.3" => 1, "kimi-k3" => 0} floor {"ds-flash" => 0, "glm-flash" => 2}  <-- a floor model beats BOTH strong models

## D3c compose-two-source-fan-in, every run: the shape of the first script, and both bars
| bench | model | run | shape_of_first_script | usable | picture | buckets | cost_usd | seconds |
|---|---|---|---|---|---|---|---|---|
| v13 | glm-5.3 | 1 | P[T T T Mr1 Mr2] P[Mr2] | true | false | over_read | 0.055 | 56 |
| v13 | glm-5.3 | 2 | P[(T Mr1) (T T Mr2)] M | true | false | over_sync | 0.038 | 56 |
| v13 | glm-5.3 | 3 | P[(T T T Mr1 Mr2)] Mr2 | true | false | over_sync,over_read | 0.022 | 65 |
| v13 | kimi-k3 | 1 | P[T T T Mr1 Mr2] Mr2 | true | false | over_read | 0.17 | 83 |
| v13 | kimi-k3 | 2 | P[T T T Mr1 Mr2] Mr2 | true | false | over_read | 0.192 | 92 |
| v13 | kimi-k3 | 3 | P[T T T Mr1 Mr2] Mr2 | true | false | over_read | 0.189 | 89 |
| v13 | ds-flash | 1 | P[T Mr1 T T Mr2] Sr2 Mr1 | true | false | over_read | 0.011 | 65 |
| v13 | ds-flash | 2 | P[(T Mr1) (T T Mr2)] M | true | false | over_sync | 0.005 | 56 |
| v13 | ds-flash | 3 | P[T T T Mr1 Mr2 Mr2] | true | true |  | 0.006 | 59 |
| v13 | glm-flash | 1 | P[T T T Mr1 Mr2 Mr2] | true | true |  | 0.013 | 120 |
| v13 | glm-flash | 2 | P[T T T Mr1 Mr2] Mr2 | true | false | over_read | 0.013 | 159 |
| v13 | glm-flash | 3 | P[T T T Mr1 Mr2] Mr2 | true | false | over_read | 0.015 | 242 |

| bench | model | run | shape_of_first_script | usable | picture | buckets | cost_usd | seconds |
|---|---|---|---|---|---|---|---|---|
| v14 | glm-5.3 | 1 | S | true | false | over_read | 0.215 | 236 |
| v14 | glm-5.3 | 2 | P[T T T Mr1 Mr2 Mr2] | true | true |  | 0.154 | 214 |
| v14 | glm-5.3 | 3 | P[T T T Mr1 Mr2] Mr2 | true | false | over_read | 0.078 | 109 |
| v14 | kimi-k3 | 1 | P[T T T Mr1 Mr2] M | true | false | over_read | 0.144 | 93 |
| v14 | kimi-k3 | 2 | P[T T T Mr1 Mr2] Mr2 | true | false | over_read | 0.153 | 120 |
| v14 | kimi-k3 | 3 | P[T T T Mr1 Mr2] Mr2 | true | false | over_read | 0.166 | 123 |
| v14 | ds-flash | 1 | P[(T Mr1) (T T Mr2)] M | true | false | over_sync | 0.009 | 78 |
| v14 | ds-flash | 2 | P[T T T Mr1 Mr2] Mr2 | true | false | over_read | 0.008 | 66 |
| v14 | ds-flash | 3 | P[T T T Mr1 Mr2] Mr2 | true | false | over_read | 0.01 | 63 |
| v14 | glm-flash | 1 | P[T T T Mr1 Mr2 Mr2] | true | true |  | 0.011 | 126 |
| v14 | glm-flash | 2 | P[T T T Mr1 Mr2] Mr2 | true | false | over_read | 0.013 | 221 |
| v14 | glm-flash | 3 | P[T T T Mr1 Mr2 Mr2] | true | true |  | 0.011 | 160 |

## D3d the shape of the final (report) step on two-source-fan-in, by tier (v13+v14)
| final_step | strong | floor | picture_exact |
|---|---|---|---|
| other: P[T T T Mr1 Mr2] P[Mr2] | 1 | 0 | 0 |
| report AFTER the group, naming nothing | 2 | 2 | 0 |
| report AFTER the group, naming 2 | 7 | 5 | 0 |
| report AFTER the group, naming 1 | 0 | 1 | 0 |
| report INSIDE the group (a member naming the two summaries) | 1 | 4 | 5 |
| the whole plan inside one g.script stage | 1 | 0 | 0 |

## D3e how much each tier writes: first-call plan size (nodes on the recorded executed graph) against the picture's, and model steps, per task (v14; built first calls)
| task | objective (picture nodes) | strong | floor |
|---|---|---|---|
| review-angles | O1 (4) | n=6: nodes mean 4.0, models mean 4.0, above picture 0 | n=6: nodes mean 4.0, models mean 4.0, above picture 0 |
| grep-then-edit | O2 (4) | n=6: nodes mean 5.8, models mean 0.2, above picture 5 | n=5: nodes mean 6.2, models mean 0.6, above picture 5 |
| race | O3 (5) | n=6: nodes mean 5.0, models mean 0.8, above picture 0 | n=6: nodes mean 4.2, models mean 0.5, above picture 0 |
| race-anon | O3 (5) | n=6: nodes mean 5.0, models mean 0.8, above picture 0 | n=6: nodes mean 5.0, models mean 0.5, above picture 0 |
| background-suite | O4 (3) | n=5: nodes mean 4.0, models mean 1.4, above picture 3 | n=5: nodes mean 4.6, models mean 1.6, above picture 5 |
| three-stage-pairing | O7 (7) | n=6: nodes mean 7.0, models mean 3.3, above picture 0 | n=4: nodes mean 6.8, models mean 3.5, above picture 0 |
| two-source-fan-in | O7b (6) | n=6: nodes mean 6.0, models mean 3.0, above picture 0 | n=6: nodes mean 6.0, models mean 3.0, above picture 0 |
| rendezvous | T5 (6) | n=6: nodes mean 6.2, models mean 3.0, above picture 1 | n=6: nodes mean 6.2, models mean 3.0, above picture 1 |

## D3f compose-rendezvous and compose-background-suite, every run: shape of the first script and the picture
| task | bench | model | run | shape | picture |
|---|---|---|---|---|---|
| rendezvous | v13 | glm-5.3 | 1 | P[T T Ta2 Mr2 Mr2] Mr2 | over_read |
| rendezvous | v13 | glm-5.3 | 2 | P[T T Ta2 Mr2 Mr2] Mr2 | over_read |
| rendezvous | v13 | glm-5.3 | 3 | S | over_read |
| rendezvous | v13 | kimi-k3 | 1 | P[T T Ta2 Mr2 Mr2] Mr2 | over_read |
| rendezvous | v13 | kimi-k3 | 2 | P[T T Ta2 Mr2 Mr2] Mr2 | over_read |
| rendezvous | v13 | kimi-k3 | 3 | P[T T Ta2 Mr2 Mr2] Mr2 | over_read |
| rendezvous | v13 | ds-flash | 1 | P[T T] Ta2 P[Mr2 Mr2] M | over_read |
| rendezvous | v13 | ds-flash | 2 | P[T T] Ta2 P[Mr2 Mr2] Mr2 | over_read |
| rendezvous | v13 | ds-flash | 3 | P[T T] Ta2 P[Mr2 Mr2] Mr2 | over_read |
| rendezvous | v13 | glm-flash | 1 | - | refused:after_in_input |
| rendezvous | v13 | glm-flash | 2 | S | extra_steps,over_read |
| rendezvous | v13 | glm-flash | 3 | P[T T] Ta2 P[Mr2 Mr2] M | over_read |
| rendezvous | v14 | glm-5.3 | 1 | S Mr1 | exact |
| rendezvous | v14 | glm-5.3 | 2 | P[T T] Ta2 P[Mr2 Mr2] Mr2 | over_read |
| rendezvous | v14 | glm-5.3 | 3 | P{all}[T T Ta2 Mr2 Mr2] Mr2 | over_read |
| rendezvous | v14 | kimi-k3 | 1 | P[T T] Ta2 P[Sr2 Sr2] Sr2 | blind_model |
| rendezvous | v14 | kimi-k3 | 2 | P[T T Ta2 Mr2 Mr2] Mr2 | over_read |
| rendezvous | v14 | kimi-k3 | 3 | P[T T] T P[Sr2 Sr2] Sr2 | blind_model |
| rendezvous | v14 | ds-flash | 1 | P[T T] T P[Mr2 Mr2] Mr2 | over_read |
| rendezvous | v14 | ds-flash | 2 | P[T T Ta2 Mr2 Mr2] M | over_read |
| rendezvous | v14 | ds-flash | 3 | P[T T] Ta2 P[Mr2 Mr2] Mr2 | over_read |
| rendezvous | v14 | glm-flash | 1 | P[T T Ta2 (Mr2) (Mr2) Mr2] | exact |
| rendezvous | v14 | glm-flash | 2 | P[T T Ta2 Mr2 Mr2] Mr2 | over_read |
| rendezvous | v14 | glm-flash | 3 | P[T T Ta2 Mr2 Mr2 Mr2] Sr4 | exact |
| task | bench | model | run | shape | picture |
|---|---|---|---|---|---|
| background-suite | v13 | glm-5.3 | 1 | P[T (T Mr1 Ta1 Mr2)] | exact |
| background-suite | v13 | glm-5.3 | 2 | T T Mr1 Ta1 Mr1 Ta1 Sr6 | extra_steps,over_read |
| background-suite | v13 | glm-5.3 | 3 | - | no_compose_call |
| background-suite | v13 | kimi-k3 | 1 | P[T (T M)] | exact |
| background-suite | v13 | kimi-k3 | 2 | P[T (T Mr1 Ta1)] Mr3 | extra_steps,over_read |
| background-suite | v13 | kimi-k3 | 3 | P[T (T Mr1 Ta1 Mr1 Ta1)] Mr4 | extra_steps,over_read |
| background-suite | v13 | ds-flash | 1 | - | refused:unknown_option |
| background-suite | v13 | ds-flash | 2 | P[T T Mr1] M | extra_steps,over_read |
| background-suite | v13 | ds-flash | 3 | P[T T] M T M | over_read |
| background-suite | v13 | glm-flash | 1 | P[T (T Mr1 Ta1 Mr1 Ta1 Mr1 Ta1 Mr1)] | exact |
| background-suite | v13 | glm-flash | 2 | P[(T Mr1) (T Mr1 Ta1 Mr2)] | extra_steps,over_read |
| background-suite | v13 | glm-flash | 3 | P[T T Mr1 Ta1 Sr1 Mr5] | extra_steps,over_read |
| background-suite | v14 | glm-5.3 | 1 | P[T T Mr1] T Mr4 | extra_steps,over_read |
| background-suite | v14 | glm-5.3 | 2 | P[T T Mr1 Ta1 Sr3] | exact |
| background-suite | v14 | glm-5.3 | 3 | P[T (T Mr1)] Ta1 Mr3 | extra_steps,over_read |
| background-suite | v14 | kimi-k3 | 1 | - | refused:syntax |
| background-suite | v14 | kimi-k3 | 2 | P[T (T M)] | exact |
| background-suite | v14 | kimi-k3 | 3 | P[T M] | missing_steps,blind_model |
| background-suite | v14 | ds-flash | 1 | P[T T Mr1 Ta1 Mr1] | exact |
| background-suite | v14 | ds-flash | 2 | T T M T M | over_read |
| background-suite | v14 | ds-flash | 3 | P[T (T Mr1)] Mr2 | extra_steps,over_read |
| background-suite | v14 | glm-flash | 1 | P[T T Mr1 Ta1] | exact |
| background-suite | v14 | glm-flash | 2 | T S | extra_steps,over_read |
| background-suite | v14 | glm-flash | 3 | - | refused:member_not_a_step |

## D3g two-source-fan-in (v13+v14): the report inside the group vs after it, by tier and picture
- inside, floor, picture exact: 4
- inside, strong, picture exact: 1
- not inside (after the group, own group, or stage-wrapped), floor, picture miss: 8
- not inside (after the group, own group, or stage-wrapped), strong, picture miss: 11
```

### d4_compose_use.rb

```ruby
# D(4): how often each model composes, and whether composing goes with green, cost and seconds —
# the workflow family (compose is the model's choice there) and the compose family (the prompt asks
# for it, except the single-read control). Green = verdict.succeeded == true on the tier's bar.
# Run: ruby d4_compose_use.rb (records only; plain ruby)
require_relative "d_common"

def composed?(r) = r.dig("facts", "called", "compose").to_i.positive?
def delegated?(r) = r.dig("facts", "called", "task").to_i.positive?
def cost(r) = r.dig("efficiency", "cost_amount").to_f
def median(xs)
  return nil if xs.empty?

  s = xs.sort
  n = s.size
  n.odd? ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2.0
end
def green(xs) = "#{xs.count { |r| r.dig("verdict", "succeeded") == true }}/#{xs.size}"
def summary(xs)
  return "-" if xs.empty?

  "#{green(xs)} green, med $#{median(xs.map { |r| cost(r) }).round(3)}, med #{median(xs.map { |r| r["seconds"].to_f }).round}s"
end

%w[v13 v14].each do |bench|
  puts "## D4a #{bench}: runs with >= 1 compose call / runs, per family and model (workflow: also `task` delegations)"
  rows = D::MODELS.map do |m|
    c = D.records(bench, "compose").select { |r| r["model"] == m && r["task"] != "compose-single-read" }
    w = D.records(bench, "workflow").select { |r| r["model"] == m }
    t = D.records(bench, "task").select { |r| r["model"] == m }
    [D.short(m), "#{c.count { |r| composed?(r) }}/#{c.size}", "#{w.count { |r| composed?(r) }}/#{w.size}",
     "#{w.count { |r| delegated?(r) }}/#{w.size}", "#{w.count { |r| !composed?(r) && !delegated?(r) }}/#{w.size}",
     "#{t.count { |r| composed?(r) }}/#{t.size}"]
  end
  cf = D.records(bench, "compose").reject { |r| r["task"] == "compose-single-read" }
  wf = D.records(bench, "workflow")
  puts "- #{bench} totals: compose family #{cf.count { |r| composed?(r) }}/#{cf.size} non-control runs composed; workflow composed #{wf.count { |r| composed?(r) }}/#{wf.size}, delegated #{wf.count { |r| delegated?(r) }}/#{wf.size}"
  puts D.table(["model", "compose family (8 tasks)", "workflow: composed", "workflow: delegated (task)", "workflow: neither", "task family: composed"], rows)
  puts
  puts "### D4b #{bench} workflow family, per task x model: composed runs vs not (green, median cost, median seconds)"
  tasks = D.records(bench, "workflow").map { |r| r["task"] }.uniq.sort
  rows = tasks.flat_map do |task|
    D::MODELS.map do |m|
      x = D.records(bench, "workflow").select { |r| r["task"] == task && r["model"] == m }
      [task.delete_prefix("workflow-"), D.short(m), summary(x.select { |r| composed?(r) }), summary(x.reject { |r| composed?(r) }),
       x.map { |r| composed?(r) ? "C" : (delegated?(r) ? "T" : "-") }.join]
    end
  end
  puts D.table(%w[task model composed not_composed runs(C=compose,T=task,-=neither)], rows)
  puts
  w = D.records(bench, "workflow")
  puts "### D4c #{bench} workflow family pooled"
  puts "- composed: #{summary(w.select { |r| composed?(r) })}; not composed: #{summary(w.reject { |r| composed?(r) })}"
  %w[strong floor].each do |tier|
    x = w.select { |r| D::TIER[D.short(r["model"])] == tier }
    puts "- #{tier}: composed #{summary(x.select { |r| composed?(r) })}; not #{summary(x.reject { |r| composed?(r) })}"
  end
  # Within-cell comparison: only cells that have both composed and non-composed runs.
  mixed = w.group_by { |r| [r["task"], r["model"]] }.select { |_, xs| xs.any? { |r| composed?(r) } && xs.any? { |r| !composed?(r) } }
  puts "- cells with both kinds of run: #{mixed.size}: " + mixed.map { |(task, m), xs| "#{task.delete_prefix("workflow-")} #{D.short(m)} C #{summary(xs.select { |r| composed?(r) })} | not #{summary(xs.reject { |r| composed?(r) })}" }.join("; ")
  puts
end

puts "## D4d compose family: cost and seconds of the composing runs, per model (v13 -> v14), picture tasks + T5"
rows = D::MODELS.map do |m|
  [D.short(m), *%w[v13 v14].map do |bench|
    x = D.records(bench, "compose").select { |r| r["model"] == m && r["task"] != "compose-single-read" }
    "#{summary(x)}; total $#{x.sum { |r| cost(r) }.round(2)}"
  end]
end
puts D.table(%w[model v13 v14], rows)
puts
puts "## D4e compose family, picture-exact vs picture-missed runs (v14, strong and floor), median cost and seconds"
x = D.records("v14", "compose").select { |r| D::PICTURE_TASKS.key?(r["task"]) }
%w[strong floor].each do |tier|
  y = x.select { |r| D::TIER[D.short(r["model"])] == tier }
  e = y.select { |r| D.picture_ok?(r) }
  mi = y.reject { |r| D.picture_ok?(r) }
  puts "- #{tier}: picture exact #{e.size}: med $#{median(e.map { |r| cost(r) }).round(3)}, med #{median(e.map { |r| r["seconds"].to_f }).round}s; " \
       "missed #{mi.size}: med $#{median(mi.map { |r| cost(r) }).round(3)}, med #{median(mi.map { |r| r["seconds"].to_f }).round}s"
end

puts "\n## D4f compose family v14, per task and tier: picture-exact runs vs picture-missed runs (median cost, median seconds) — the task held fixed"
rows = D::PICTURE_TASKS.keys.select { |t| t.start_with?("compose-") }.flat_map do |task|
  %w[strong floor].map do |tier|
    y = D.records("v14", "compose").select { |r| r["task"] == task && D::TIER[D.short(r["model"])] == tier }
    e = y.select { |r| D.picture_ok?(r) }
    mi = y.reject { |r| D.picture_ok?(r) }
    f = ->(xs) { xs.empty? ? "-" : "#{xs.size}: $#{median(xs.map { |r| cost(r) }).round(3)}, #{median(xs.map { |r| r["seconds"].to_f }).round}s" }
    [task.delete_prefix("compose-"), tier, f.(e), f.(mi)]
  end
end
puts D.table(%w[task tier picture_exact picture_missed], rows)
```

Output (`d4_compose_use.out`):

```text
## D4a v13: runs with >= 1 compose call / runs, per family and model (workflow: also `task` delegations)
- v13 totals: compose family 93/96 non-control runs composed; workflow composed 13/60, delegated 28/60
| model | compose family (8 tasks) | workflow: composed | workflow: delegated (task) | workflow: neither | task family: composed |
|---|---|---|---|---|---|
| glm-5.3 | 23/24 | 3/15 | 8/15 | 4/15 | 0/18 |
| kimi-k3 | 24/24 | 3/15 | 6/15 | 6/15 | 0/18 |
| ds-flash | 24/24 | 2/15 | 8/15 | 5/15 | 1/18 |
| glm-flash | 22/24 | 5/15 | 6/15 | 4/15 | 0/18 |

### D4b v13 workflow family, per task x model: composed runs vs not (green, median cost, median seconds)
| task | model | composed | not_composed | runs(C=compose,T=task,-=neither) |
|---|---|---|---|---|
| adversarial-verify | glm-5.3 | - | 1/3 green, med $0.393, med 264s | TTT |
| adversarial-verify | kimi-k3 | - | 1/3 green, med $0.836, med 201s | TTT |
| adversarial-verify | ds-flash | - | 3/3 green, med $0.083, med 283s | TTT |
| adversarial-verify | glm-flash | - | 2/3 green, med $0.074, med 258s | TTT |
| barrier-free-pipeline | glm-5.3 | 1/2 green, med $0.253, med 283s | 0/1 green, med $0.147, med 171s | -CC |
| barrier-free-pipeline | kimi-k3 | - | 0/3 green, med $0.052, med 34s | --- |
| barrier-free-pipeline | ds-flash | 1/1 green, med $0.012, med 73s | 0/2 green, med $0.003, med 35s | --C |
| barrier-free-pipeline | glm-flash | 2/2 green, med $0.009, med 112s | 0/1 green, med $0.004, med 48s | C-C |
| fan-out-finders | glm-5.3 | - | 3/3 green, med $0.04, med 62s | TTT |
| fan-out-finders | kimi-k3 | 1/1 green, med $0.386, med 108s | 2/2 green, med $0.378, med 84s | TTC |
| fan-out-finders | ds-flash | - | 3/3 green, med $0.007, med 56s | TTT |
| fan-out-finders | glm-flash | 1/1 green, med $0.015, med 202s | 2/2 green, med $0.019, med 100s | TTC |
| judge-panel | glm-5.3 | 1/1 green, med $0.637, med 345s | 2/2 green, med $0.296, med 192s | TTC |
| judge-panel | kimi-k3 | 2/2 green, med $0.339, med 158s | 1/1 green, med $0.571, med 187s | CTC |
| judge-panel | ds-flash | 1/1 green, med $0.014, med 57s | 2/2 green, med $0.043, med 122s | CTT |
| judge-panel | glm-flash | 2/2 green, med $0.031, med 268s | 1/1 green, med $0.024, med 206s | TCC |
| loop-until-dry | glm-5.3 | - | 3/3 green, med $0.102, med 101s | --- |
| loop-until-dry | kimi-k3 | - | 3/3 green, med $0.324, med 120s | --- |
| loop-until-dry | ds-flash | - | 3/3 green, med $0.004, med 60s | --- |
| loop-until-dry | glm-flash | - | 3/3 green, med $0.017, med 93s | --- |

### D4c v13 workflow family pooled
- composed: 12/13 green, med $0.036, med 165s; not composed: 35/47 green, med $0.062, med 101s
- strong: composed 5/6 green, med $0.359, med 174s; not 16/24 green, med $0.218, med 112s
- floor: composed 7/7 green, med $0.014, med 137s; not 19/23 green, med $0.018, med 93s
- cells with both kinds of run: 9: barrier-free-pipeline glm-5.3 C 1/2 green, med $0.253, med 283s | not 0/1 green, med $0.147, med 171s; barrier-free-pipeline ds-flash C 1/1 green, med $0.012, med 73s | not 0/2 green, med $0.003, med 35s; barrier-free-pipeline glm-flash C 2/2 green, med $0.009, med 112s | not 0/1 green, med $0.004, med 48s; fan-out-finders kimi-k3 C 1/1 green, med $0.386, med 108s | not 2/2 green, med $0.378, med 84s; fan-out-finders glm-flash C 1/1 green, med $0.015, med 202s | not 2/2 green, med $0.019, med 100s; judge-panel glm-5.3 C 1/1 green, med $0.637, med 345s | not 2/2 green, med $0.296, med 192s; judge-panel kimi-k3 C 2/2 green, med $0.339, med 158s | not 1/1 green, med $0.571, med 187s; judge-panel ds-flash C 1/1 green, med $0.014, med 57s | not 2/2 green, med $0.043, med 122s; judge-panel glm-flash C 2/2 green, med $0.031, med 268s | not 1/1 green, med $0.024, med 206s

## D4a v14: runs with >= 1 compose call / runs, per family and model (workflow: also `task` delegations)
- v14 totals: compose family 95/96 non-control runs composed; workflow composed 9/60, delegated 29/60
| model | compose family (8 tasks) | workflow: composed | workflow: delegated (task) | workflow: neither | task family: composed |
|---|---|---|---|---|---|
| glm-5.3 | 24/24 | 4/15 | 8/15 | 3/15 | 0/18 |
| kimi-k3 | 24/24 | 1/15 | 8/15 | 6/15 | 0/18 |
| ds-flash | 24/24 | 2/15 | 4/15 | 9/15 | 1/18 |
| glm-flash | 23/24 | 2/15 | 9/15 | 4/15 | 0/18 |

### D4b v14 workflow family, per task x model: composed runs vs not (green, median cost, median seconds)
| task | model | composed | not_composed | runs(C=compose,T=task,-=neither) |
|---|---|---|---|---|
| adversarial-verify | glm-5.3 | - | 3/3 green, med $0.677, med 333s | TTT |
| adversarial-verify | kimi-k3 | - | 2/3 green, med $0.656, med 220s | TTT |
| adversarial-verify | ds-flash | - | 0/3 green, med $0.013, med 189s | T-- |
| adversarial-verify | glm-flash | - | 1/3 green, med $0.053, med 205s | TTT |
| barrier-free-pipeline | glm-5.3 | 0/3 green, med $0.15, med 157s | - | CCC |
| barrier-free-pipeline | kimi-k3 | - | 0/3 green, med $0.051, med 44s | --- |
| barrier-free-pipeline | ds-flash | - | 0/3 green, med $0.002, med 34s | --- |
| barrier-free-pipeline | glm-flash | 2/2 green, med $0.01, med 147s | 0/1 green, med $0.004, med 62s | -CC |
| fan-out-finders | glm-5.3 | - | 3/3 green, med $0.04, med 65s | TTT |
| fan-out-finders | kimi-k3 | - | 3/3 green, med $0.263, med 96s | TTT |
| fan-out-finders | ds-flash | - | 3/3 green, med $0.007, med 57s | TTT |
| fan-out-finders | glm-flash | - | 3/3 green, med $0.019, med 82s | TTT |
| judge-panel | glm-5.3 | 1/1 green, med $0.655, med 447s | 2/2 green, med $0.51, med 331s | TCT |
| judge-panel | kimi-k3 | 1/1 green, med $0.244, med 107s | 2/2 green, med $0.26, med 106s | TTC |
| judge-panel | ds-flash | 2/2 green, med $0.02, med 73s | 0/1 green, med $0.004, med 94s | CC- |
| judge-panel | glm-flash | - | 3/3 green, med $0.026, med 165s | TTT |
| loop-until-dry | glm-5.3 | - | 3/3 green, med $0.052, med 123s | --- |
| loop-until-dry | kimi-k3 | - | 3/3 green, med $0.202, med 160s | --- |
| loop-until-dry | ds-flash | - | 3/3 green, med $0.004, med 48s | --- |
| loop-until-dry | glm-flash | - | 3/3 green, med $0.016, med 95s | --- |

### D4c v14 workflow family pooled
- composed: 6/9 green, med $0.135, med 147s; not composed: 37/51 green, med $0.051, med 101s
- strong: composed 2/5 green, med $0.199, med 157s; not 21/25 green, med $0.251, med 123s
- floor: composed 4/4 green, med $0.012, med 97s; not 16/26 green, med $0.012, med 80s
- cells with both kinds of run: 4: barrier-free-pipeline glm-flash C 2/2 green, med $0.01, med 147s | not 0/1 green, med $0.004, med 62s; judge-panel glm-5.3 C 1/1 green, med $0.655, med 447s | not 2/2 green, med $0.51, med 331s; judge-panel kimi-k3 C 1/1 green, med $0.244, med 107s | not 2/2 green, med $0.26, med 106s; judge-panel ds-flash C 2/2 green, med $0.02, med 73s | not 0/1 green, med $0.004, med 94s

## D4d compose family: cost and seconds of the composing runs, per model (v13 -> v14), picture tasks + T5
| model | v13 | v14 |
|---|---|---|
| glm-5.3 | 16/24 green, med $0.198, med 177s; total $4.24 | 19/24 green, med $0.157, med 225s; total $4.49 |
| kimi-k3 | 16/24 green, med $0.191, med 91s; total $4.33 | 18/24 green, med $0.161, med 92s; total $4.49 |
| ds-flash | 24/24 green, med $0.012, med 59s; total $0.46 | 24/24 green, med $0.014, med 68s; total $0.38 |
| glm-flash | 22/24 green, med $0.015, med 263s; total $0.42 | 23/24 green, med $0.017, med 224s; total $0.43 |

## D4e compose family, picture-exact vs picture-missed runs (v14, strong and floor), median cost and seconds
- strong: picture exact 32: med $0.142, med 99s; missed 16: med $0.234, med 206s
- floor: picture exact 29: med $0.014, med 115s; missed 19: med $0.016, med 120s

## D4f compose family v14, per task and tier: picture-exact runs vs picture-missed runs (median cost, median seconds) — the task held fixed
| task | tier | picture_exact | picture_missed |
|---|---|---|---|
| review-angles | strong | 6: $0.205, 142s | - |
| review-angles | floor | 6: $0.02, 171s | - |
| grep-then-edit | strong | 4: $0.291, 195s | 2: $0.229, 235s |
| grep-then-edit | floor | 4: $0.024, 116s | 2: $0.03, 606s |
| race | strong | 6: $0.073, 76s | - |
| race | floor | 5: $0.005, 33s | 1: $0.017, 226s |
| race-anon | strong | 6: $0.077, 53s | - |
| race-anon | floor | 6: $0.007, 69s | - |
| background-suite | strong | 2: $0.2, 177s | 4: $0.253, 194s |
| background-suite | floor | 2: $0.02, 175s | 4: $0.015, 142s |
| three-stage-pairing | strong | 6: $0.151, 135s | - |
| three-stage-pairing | floor | 2: $0.017, 172s | 4: $0.014, 124s |
| two-source-fan-in | strong | 1: $0.154, 214s | 5: $0.153, 120s |
| two-source-fan-in | floor | 2: $0.011, 143s | 4: $0.009, 72s |
| rendezvous | strong | 1: $0.36, 315s | 5: $0.326, 288s |
| rendezvous | floor | 2: $0.028, 404s | 4: $0.026, 98s |
```

### d5_explicit_rule.rb

```ruby
# D(5): the explicit-data-flow counterfactual, counted from the pictures, never implemented. On every
# compose picture reading of v13 (last line per key) and v14 whose first call built and placed a plan,
# the plan the kernel ran is re-read with each MODEL step's reads replaced by what its script named:
#   A (strict)   — a model step reads only its `results:` (race-expanded; a named stage stands for what
#                  it read, as the picture already contracts it);
#   B (+history) — A plus the round it continues (its spine, when that is a model step of the plan).
# Waits, tools and stages are untouched (a stage already reads only what it names). The picture is
# re-scored with the harness's own `Scoring.score_graph`. This changes what the model READ, not what
# it WROTE: a model that relied on position and named nothing reads nothing under A.
# Run: cd /Users/jasl/Workspaces/cybros-ai.alt2/e2e && bundle exec ruby <scratch>/d5_explicit_rule.rb
require_relative "d_harness"

def rescore(r, reads)
  plan = r[:plan].with(reads: reads)
  graph = DH::CB::Executed.lower(plan)
  DH::CB::Scoring.score_graph(r[:objective], graph, labels: DH::CB::Executed.labels(plan), transparent: plan.transparent)
end

rows = []
[["v13", "compose"], ["v14", "compose"], ["v13", "workflow"], ["v14", "workflow"]].each do |bench, family|
  D.records(bench, family).each do |record|
    objective = D::PICTURE_TASKS[record["task"]] or next
    score = record.dig("facts", "score")
    next unless score.is_a?(Hash) && score["valid_first"] && score["reading"] == "executed"

    r = DH.reading(record, D.trace(bench, family, record), objective)
    models = r[:plan].nodes.select { |_, n| n["kind"] == "model_task" }.keys
    strict = r[:plan].reads.merge(models.to_h { |k| [k, DH.named_sources(r, k)] })
    history = r[:plan].reads.merge(models.to_h { |k| [k, (DH.named_sources(r, k) | [DH.spine_of(r, k)].compact)] })
    a = rescore(r, strict)
    b = rescore(r, history)
    same = rescore(r, r[:plan].reads) # control: the unchanged plan must give the record's verdict
    blind = models.count { |k| DH.named_sources(r, k).empty? }
    rows << { family: family, bench: bench, task: record["task"].sub(/\A(compose|workflow)-/, ""), model: D.short(record["model"]),
              tier: D::TIER[D.short(record["model"])], run: record["run"], succeeded: record.dig("verdict", "succeeded"),
              orig: score["first_time_right"], orig_silent: Array(score["silent"]),
              control: same["first_time_right"] == score["first_time_right"] && same["silent"] == Array(score["silent"]),
              a: a["first_time_right"], a_silent: a["silent"], b: b["first_time_right"], b_silent: b["silent"],
              models: models.size, unnamed: blind }
  end
end

puts "## D5 inputs"
puts "- readings re-scored: #{rows.size} (v13 #{rows.count { |x| x[:bench] == "v13" }}, v14 #{rows.count { |x| x[:bench] == "v14" }}); control (unchanged plan reproduces the record's verdict and buckets): #{rows.count { |x| x[:control] }}/#{rows.size}"
rows.reject { |x| x[:control] }.each { |x| puts "  - control differs: #{x[:bench]} #{x[:task]} #{x[:model]} ##{x[:run]}: record #{x[:orig_silent].inspect}" }
puts

def fmt(bool) = bool ? "exact" : "miss"

puts "## D5a transitions per bench and tier (orig -> A strict / B +history)"
%w[v13 v14].each do |bench|
  %w[strong floor].each do |tier|
    x = rows.select { |y| y[:bench] == bench && y[:tier] == tier }
    t = ->(key) { x.map { |y| "#{fmt(y[:orig])}->#{fmt(y[key])}" }.tally.sort.map { |k, v| "#{k} #{v}" }.join(", ") }
    puts "- #{bench} #{tier} (#{x.size}): A: #{t.(:a)} | B: #{t.(:b)}"
  end
end

puts "\n## D5b over_read readings: does the bucket go, and does the picture become exact?"
%w[v13 v14].each do |bench|
  x = rows.select { |y| y[:bench] == bench && y[:orig_silent].include?("over_read") }
  %i[a b].each do |v|
    gone = x.count { |y| !y[:"#{v}_silent"].include?("over_read") }
    exact = x.count { |y| y[v] }
    puts "- #{bench} #{v.upcase}: over_read readings #{x.size}; over_read gone #{gone}; picture exact #{exact}; " \
         "left: #{x.reject { |y| y[v] }.map { |y| "#{y[:task]} #{y[:model]}##{y[:run]} [#{y[:"#{v}_silent"].join(",")}]" }.join("; ")}"
  end
end

puts "\n## D5c every picture miss (orig) and every change, with buckets under A and B"
changed = rows.select { |y| !y[:orig] || !y[:a] || !y[:b] }
puts D.table(%w[bench task model run succ orig_buckets A A_buckets B B_buckets models unnamed_models],
  changed.map { |y| [y[:bench], y[:task], y[:model], y[:run], y[:succeeded].inspect, y[:orig] ? "exact" : y[:orig_silent].join(","),
                     fmt(y[:a]), y[:a_silent].join(","), fmt(y[:b]), y[:b_silent].join(","), y[:models], y[:unnamed]] })

puts "\n## D5d the compose family's strong reds the rule would have removed (strong tier: success is the picture; reds with no built plan are out of reach)"
%w[v13 v14].each do |bench|
  reds = rows.select { |y| y[:bench] == bench && y[:family] == "compose" && y[:tier] == "strong" && y[:succeeded] == false }
  %i[a b].each do |v|
    puts "- #{bench} #{v.upcase}: strong reds with a built plan #{reds.size}; exact under the rule #{reds.count { |y| y[v] }}; " \
         "of the over_read reds #{reds.count { |y| y[:orig_silent].include?("over_read") }}, exact #{reds.count { |y| y[:orig_silent].include?("over_read") && y[v] }}"
  end
end

puts "\n## D5e breakage as written: exact pictures that the strict rule turns into misses (the model named nothing and relied on position)"
%w[v13 v14].each do |bench|
  x = rows.select { |y| y[:bench] == bench && y[:orig] }
  %i[a b].each do |v|
    broke = x.reject { |y| y[v] }
    puts "- #{bench} #{v.upcase}: exact #{x.size}, broken #{broke.size}: #{broke.map { |y| "#{y[:task]} #{y[:model]}##{y[:run]} [#{y[:"#{v}_silent"].join(",")}]" }.join("; ")}"
  end
end

puts "\n## D5f per task: exact pictures orig / A / B (built plans only)"
tasks = rows.map { |y| y[:task] }.uniq
puts D.table(%w[task bench n orig A B], %w[v13 v14].flat_map do |bench|
  tasks.map do |task|
    x = rows.select { |y| y[:bench] == bench && y[:task] == task }
    [task, bench, x.size, x.count { |y| y[:orig] }, x.count { |y| y[:a] }, x.count { |y| y[:b] }]
  end
end)

puts "\n## D5g the compose family's seven gate/picture tasks per tier (42 runs each; a run with no built plan stays a miss): exact first-call scores orig / A / B"
%w[v13 v14].each do |bench|
  %w[strong floor].each do |tier|
    x = rows.select { |y| y[:bench] == bench && y[:family] == "compose" && y[:tier] == tier && y[:task] != "rendezvous" }
    puts "- #{bench} #{tier}: orig #{x.count { |y| y[:orig] }}, A #{x.count { |y| y[:a] }}, B #{x.count { |y| y[:b] }} (built plans #{x.size})"
  end
end
```

Output (`d5_explicit_rule.out`):

```text
## D5 inputs
- readings re-scored: 186 (v13 90, v14 96); control (unchanged plan reproduces the record's verdict and buckets): 185/186
  - control differs: v13 grep-then-edit kimi-k3 #2: record ["wrong_task_read"]

## D5a transitions per bench and tier (orig -> A strict / B +history)
- v13 strong (48): A: exact->exact 22, exact->miss 5, miss->exact 10, miss->miss 11 | B: exact->exact 22, exact->miss 5, miss->exact 10, miss->miss 11
- v13 floor (42): A: exact->exact 20, exact->miss 4, miss->exact 6, miss->miss 12 | B: exact->exact 20, exact->miss 4, miss->exact 6, miss->miss 12
- v14 strong (50): A: exact->exact 29, exact->miss 3, miss->exact 7, miss->miss 11 | B: exact->exact 29, exact->miss 3, miss->exact 7, miss->miss 11
- v14 floor (46): A: exact->exact 28, exact->miss 1, miss->exact 7, miss->miss 10 | B: exact->exact 28, exact->miss 1, miss->exact 7, miss->miss 10

## D5b over_read readings: does the bucket go, and does the picture become exact?
- v13 A: over_read readings 28; over_read gone 21; picture exact 16; left: background-suite glm-5.3#2 [extra_steps,over_read]; background-suite kimi-k3#2 [extra_steps,over_read]; background-suite kimi-k3#3 [extra_steps,over_read]; background-suite ds-flash#3 [blind_model]; background-suite glm-flash#2 [extra_steps,over_read]; background-suite glm-flash#3 [extra_steps,over_read]; rendezvous ds-flash#1 [blind_model]; rendezvous glm-flash#2 [extra_steps,over_read]; rendezvous glm-flash#3 [blind_model]; three-stage-pairing glm-5.3#2 [blind_model]; three-stage-pairing glm-flash#2 [over_read]; two-source-fan-in glm-5.3#3 [over_sync]
- v13 B: over_read readings 28; over_read gone 20; picture exact 16; left: background-suite glm-5.3#2 [extra_steps,over_read]; background-suite kimi-k3#2 [extra_steps,over_read]; background-suite kimi-k3#3 [extra_steps,over_read]; background-suite ds-flash#3 [blind_model]; background-suite glm-flash#2 [extra_steps,over_read]; background-suite glm-flash#3 [extra_steps,over_read]; rendezvous ds-flash#1 [blind_model]; rendezvous glm-flash#2 [extra_steps,over_read]; rendezvous glm-flash#3 [blind_model]; three-stage-pairing glm-5.3#2 [blind_model]; three-stage-pairing glm-flash#2 [over_read]; two-source-fan-in glm-5.3#3 [over_sync,over_read]
- v14 A: over_read readings 21; over_read gone 18; picture exact 14; left: background-suite glm-5.3#1 [extra_steps,over_read]; background-suite glm-5.3#3 [extra_steps,over_read]; background-suite ds-flash#2 [blind_model]; background-suite ds-flash#3 [extra_steps,over_read]; background-suite glm-flash#2 [extra_steps,blind_model]; rendezvous ds-flash#2 [blind_model]; two-source-fan-in kimi-k3#1 [blind_model]
- v14 B: over_read readings 21; over_read gone 18; picture exact 14; left: background-suite glm-5.3#1 [extra_steps,over_read]; background-suite glm-5.3#3 [extra_steps,over_read]; background-suite ds-flash#2 [blind_model]; background-suite ds-flash#3 [extra_steps,over_read]; background-suite glm-flash#2 [extra_steps,blind_model]; rendezvous ds-flash#2 [blind_model]; two-source-fan-in kimi-k3#1 [blind_model]

## D5c every picture miss (orig) and every change, with buckets under A and B
| bench | task | model | run | succ | orig_buckets | A | A_buckets | B | B_buckets | models | unnamed_models |
|---|---|---|---|---|---|---|---|---|---|---|---|
| v13 | background-suite | glm-5.3 | 2 | false | extra_steps,over_read | miss | extra_steps,over_read | miss | extra_steps,over_read | 2 | 0 |
| v13 | background-suite | kimi-k3 | 1 | true | exact | miss | blind_model | miss | blind_model | 1 | 1 |
| v13 | background-suite | kimi-k3 | 2 | false | extra_steps,over_read | miss | extra_steps,over_read | miss | extra_steps,over_read | 2 | 0 |
| v13 | background-suite | kimi-k3 | 3 | false | extra_steps,over_read | miss | extra_steps,over_read | miss | extra_steps,over_read | 3 | 0 |
| v13 | background-suite | ds-flash | 2 | true | extra_steps,over_read | exact |  | exact |  | 2 | 1 |
| v13 | background-suite | ds-flash | 3 | true | over_read | miss | blind_model | miss | blind_model | 2 | 2 |
| v13 | background-suite | glm-flash | 2 | true | extra_steps,over_read | miss | extra_steps,over_read | miss | extra_steps,over_read | 3 | 0 |
| v13 | background-suite | glm-flash | 3 | true | extra_steps,over_read | miss | extra_steps,over_read | miss | extra_steps,over_read | 2 | 0 |
| v13 | grep-then-edit | glm-5.3 | 1 | false | missing_steps | miss | missing_steps | miss | missing_steps | 0 | 0 |
| v13 | grep-then-edit | kimi-k3 | 1 | false | over_sync | miss | over_sync | miss | over_sync | 0 | 0 |
| v13 | grep-then-edit | kimi-k3 | 2 | false | wrong_task_read | miss | edit_as_stage | miss | edit_as_stage | 0 | 0 |
| v13 | grep-then-edit | ds-flash | 1 | true | exact | miss | blind_model | miss | blind_model | 1 | 1 |
| v13 | grep-then-edit | glm-flash | 3 | true | over_sync | miss | over_sync | miss | over_sync | 0 | 0 |
| v13 | rendezvous | glm-5.3 | 1 | true | over_read | exact |  | exact |  | 3 | 0 |
| v13 | rendezvous | glm-5.3 | 2 | true | over_read | exact |  | exact |  | 3 | 0 |
| v13 | rendezvous | glm-5.3 | 3 | true | over_read | exact |  | exact |  | 3 | 0 |
| v13 | rendezvous | kimi-k3 | 1 | true | over_read | exact |  | exact |  | 3 | 0 |
| v13 | rendezvous | kimi-k3 | 2 | true | over_read | exact |  | exact |  | 3 | 0 |
| v13 | rendezvous | kimi-k3 | 3 | true | over_read | exact |  | exact |  | 3 | 0 |
| v13 | rendezvous | ds-flash | 1 | true | over_read | miss | blind_model | miss | blind_model | 3 | 1 |
| v13 | rendezvous | ds-flash | 2 | true | over_read | exact |  | exact |  | 3 | 0 |
| v13 | rendezvous | ds-flash | 3 | true | over_read | exact |  | exact |  | 3 | 0 |
| v13 | rendezvous | glm-flash | 2 | true | extra_steps,over_read | miss | extra_steps,over_read | miss | extra_steps,over_read | 3 | 0 |
| v13 | rendezvous | glm-flash | 3 | true | over_read | miss | blind_model | miss | blind_model | 3 | 1 |
| v13 | review-angles | glm-5.3 | 2 | true | exact | miss | reads_mismatch | miss | reads_mismatch | 4 | 4 |
| v13 | review-angles | kimi-k3 | 2 | true | exact | miss | reads_mismatch | miss | reads_mismatch | 4 | 4 |
| v13 | review-angles | kimi-k3 | 3 | true | exact | miss | reads_mismatch | miss | reads_mismatch | 4 | 4 |
| v13 | review-angles | ds-flash | 2 | true | exact | miss | reads_mismatch | miss | reads_mismatch | 4 | 4 |
| v13 | three-stage-pairing | glm-5.3 | 2 | false | over_read | miss | blind_model | miss | blind_model | 3 | 3 |
| v13 | three-stage-pairing | kimi-k3 | 1 | false | missing_steps | miss | missing_steps | miss | missing_steps | 3 | 0 |
| v13 | three-stage-pairing | kimi-k3 | 2 | true | exact | miss | blind_model | miss | blind_model | 4 | 3 |
| v13 | three-stage-pairing | ds-flash | 2 | true | exact | miss | blind_model | miss | reads_mismatch | 4 | 1 |
| v13 | three-stage-pairing | ds-flash | 3 | true | exact | miss | blind_model | miss | blind_model | 3 | 3 |
| v13 | three-stage-pairing | glm-flash | 2 | true | over_read | miss | over_read | miss | over_read | 3 | 0 |
| v13 | two-source-fan-in | glm-5.3 | 1 | false | over_read | exact |  | exact |  | 3 | 0 |
| v13 | two-source-fan-in | glm-5.3 | 2 | false | over_sync | miss | over_sync,blind_model | miss | over_sync | 3 | 1 |
| v13 | two-source-fan-in | glm-5.3 | 3 | false | over_sync,over_read | miss | over_sync | miss | over_sync,over_read | 3 | 0 |
| v13 | two-source-fan-in | kimi-k3 | 1 | false | over_read | exact |  | exact |  | 3 | 0 |
| v13 | two-source-fan-in | kimi-k3 | 2 | false | over_read | exact |  | exact |  | 3 | 0 |
| v13 | two-source-fan-in | kimi-k3 | 3 | false | over_read | exact |  | exact |  | 3 | 0 |
| v13 | two-source-fan-in | ds-flash | 1 | true | over_read | exact |  | exact |  | 3 | 0 |
| v13 | two-source-fan-in | ds-flash | 2 | true | over_sync | miss | over_sync,blind_model | miss | over_sync | 3 | 1 |
| v13 | two-source-fan-in | glm-flash | 2 | true | over_read | exact |  | exact |  | 3 | 0 |
| v13 | two-source-fan-in | glm-flash | 3 | true | over_read | exact |  | exact |  | 3 | 0 |
| v14 | background-suite | glm-5.3 | 1 | false | extra_steps,over_read | miss | extra_steps,over_read | miss | extra_steps,over_read | 2 | 0 |
| v14 | background-suite | glm-5.3 | 3 | false | extra_steps,over_read | miss | extra_steps,over_read | miss | extra_steps,over_read | 2 | 0 |
| v14 | background-suite | kimi-k3 | 2 | true | exact | miss | blind_model | miss | blind_model | 1 | 1 |
| v14 | background-suite | kimi-k3 | 3 | false | missing_steps,blind_model | miss | missing_steps,blind_model | miss | missing_steps,blind_model | 1 | 1 |
| v14 | background-suite | ds-flash | 2 | true | over_read | miss | blind_model | miss | blind_model | 2 | 2 |
| v14 | background-suite | ds-flash | 3 | true | extra_steps,over_read | miss | extra_steps,over_read | miss | extra_steps,over_read | 2 | 0 |
| v14 | background-suite | glm-flash | 2 | true | extra_steps,over_read | miss | extra_steps,blind_model | miss | extra_steps,blind_model | 1 | 1 |
| v14 | grep-then-edit | glm-5.3 | 2 | false | over_sync | miss | over_sync | miss | over_sync | 1 | 0 |
| v14 | grep-then-edit | kimi-k3 | 3 | false | over_sync | miss | over_sync | miss | over_sync | 0 | 0 |
| v14 | grep-then-edit | glm-flash | 1 | true | extra_steps | miss | extra_steps | miss | extra_steps | 0 | 0 |
| v14 | race | glm-flash | 3 | true | missing_join,missing_steps | miss | missing_join,missing_steps | miss | missing_join,missing_steps | 0 | 0 |
| v14 | rendezvous | glm-5.3 | 2 | true | over_read | exact |  | exact |  | 3 | 0 |
| v14 | rendezvous | glm-5.3 | 3 | true | over_read | exact |  | exact |  | 3 | 0 |
| v14 | rendezvous | kimi-k3 | 1 | true | blind_model | miss | blind_model | miss | blind_model | 3 | 3 |
| v14 | rendezvous | kimi-k3 | 2 | true | over_read | exact |  | exact |  | 3 | 0 |
| v14 | rendezvous | kimi-k3 | 3 | true | blind_model | miss | blind_model | miss | blind_model | 3 | 3 |
| v14 | rendezvous | ds-flash | 1 | true | over_read | exact |  | exact |  | 3 | 0 |
| v14 | rendezvous | ds-flash | 2 | true | over_read | miss | blind_model | miss | blind_model | 3 | 1 |
| v14 | rendezvous | ds-flash | 3 | true | over_read | exact |  | exact |  | 3 | 0 |
| v14 | rendezvous | glm-flash | 2 | true | over_read | exact |  | exact |  | 3 | 0 |
| v14 | review-angles | glm-5.3 | 3 | true | exact | miss | reads_mismatch | miss | reads_mismatch | 4 | 4 |
| v14 | review-angles | glm-flash | 2 | true | exact | miss | reads_mismatch | miss | reads_mismatch | 4 | 4 |
| v14 | three-stage-pairing | kimi-k3 | 3 | true | exact | miss | blind_model | miss | blind_model | 4 | 4 |
| v14 | three-stage-pairing | ds-flash | 1 | true | over_read | exact |  | exact |  | 4 | 0 |
| v14 | three-stage-pairing | glm-flash | 2 | true | missing_steps | miss | missing_steps | miss | missing_steps | 3 | 0 |
| v14 | two-source-fan-in | glm-5.3 | 1 | false | over_read | exact |  | exact |  | 3 | 0 |
| v14 | two-source-fan-in | glm-5.3 | 3 | false | over_read | exact |  | exact |  | 3 | 0 |
| v14 | two-source-fan-in | kimi-k3 | 1 | false | over_read | miss | blind_model | miss | blind_model | 3 | 1 |
| v14 | two-source-fan-in | kimi-k3 | 2 | false | over_read | exact |  | exact |  | 3 | 0 |
| v14 | two-source-fan-in | kimi-k3 | 3 | false | over_read | exact |  | exact |  | 3 | 0 |
| v14 | two-source-fan-in | ds-flash | 1 | true | over_sync | miss | over_sync,blind_model | miss | over_sync | 3 | 1 |
| v14 | two-source-fan-in | ds-flash | 2 | true | over_read | exact |  | exact |  | 3 | 0 |
| v14 | two-source-fan-in | ds-flash | 3 | true | over_read | exact |  | exact |  | 3 | 0 |
| v14 | two-source-fan-in | glm-flash | 2 | true | over_read | exact |  | exact |  | 3 | 0 |
| v13 | barrier-free-pipeline | glm-5.3 | 2 | false | edit_as_tool | miss | edit_as_tool | miss | edit_as_tool | 0 | 0 |
| v13 | barrier-free-pipeline | ds-flash | 3 | true | edit_as_tool | miss | edit_as_tool | miss | edit_as_tool | 0 | 0 |
| v13 | barrier-free-pipeline | glm-flash | 1 | true | edit_as_tool | miss | edit_as_tool | miss | edit_as_tool | 0 | 0 |
| v13 | barrier-free-pipeline | glm-flash | 3 | true | edit_as_tool | miss | edit_as_tool | miss | edit_as_tool | 0 | 0 |
| v14 | barrier-free-pipeline | glm-5.3 | 1 | false | edit_as_tool | miss | edit_as_tool | miss | edit_as_tool | 0 | 0 |
| v14 | barrier-free-pipeline | glm-5.3 | 2 | false | edit_as_tool | miss | edit_as_tool | miss | edit_as_tool | 0 | 0 |
| v14 | barrier-free-pipeline | glm-5.3 | 3 | false | edit_as_tool | miss | edit_as_tool | miss | edit_as_tool | 0 | 0 |
| v14 | barrier-free-pipeline | glm-flash | 2 | true | edit_as_tool | miss | edit_as_tool | miss | edit_as_tool | 0 | 0 |
| v14 | barrier-free-pipeline | glm-flash | 3 | true | edit_as_tool | miss | edit_as_tool | miss | edit_as_tool | 0 | 0 |

## D5d the compose family's strong reds the rule would have removed (strong tier: success is the picture; reds with no built plan are out of reach)
- v13 A: strong reds with a built plan 14; exact under the rule 4; of the over_read reds 9, exact 4
- v13 B: strong reds with a built plan 14; exact under the rule 4; of the over_read reds 9, exact 4
- v14 A: strong reds with a built plan 10; exact under the rule 4; of the over_read reds 7, exact 4
- v14 B: strong reds with a built plan 10; exact under the rule 4; of the over_read reds 7, exact 4

## D5e breakage as written: exact pictures that the strict rule turns into misses (the model named nothing and relied on position)
- v13 A: exact 51, broken 9: background-suite kimi-k3#1 [blind_model]; grep-then-edit ds-flash#1 [blind_model]; review-angles glm-5.3#2 [reads_mismatch]; review-angles kimi-k3#2 [reads_mismatch]; review-angles kimi-k3#3 [reads_mismatch]; review-angles ds-flash#2 [reads_mismatch]; three-stage-pairing kimi-k3#2 [blind_model]; three-stage-pairing ds-flash#2 [blind_model]; three-stage-pairing ds-flash#3 [blind_model]
- v13 B: exact 51, broken 9: background-suite kimi-k3#1 [blind_model]; grep-then-edit ds-flash#1 [blind_model]; review-angles glm-5.3#2 [reads_mismatch]; review-angles kimi-k3#2 [reads_mismatch]; review-angles kimi-k3#3 [reads_mismatch]; review-angles ds-flash#2 [reads_mismatch]; three-stage-pairing kimi-k3#2 [blind_model]; three-stage-pairing ds-flash#2 [reads_mismatch]; three-stage-pairing ds-flash#3 [blind_model]
- v14 A: exact 61, broken 4: background-suite kimi-k3#2 [blind_model]; review-angles glm-5.3#3 [reads_mismatch]; review-angles glm-flash#2 [reads_mismatch]; three-stage-pairing kimi-k3#3 [blind_model]
- v14 B: exact 61, broken 4: background-suite kimi-k3#2 [blind_model]; review-angles glm-5.3#3 [reads_mismatch]; review-angles glm-flash#2 [reads_mismatch]; three-stage-pairing kimi-k3#3 [blind_model]

## D5f per task: exact pictures orig / A / B (built plans only)
| task | bench | n | orig | A | B |
|---|---|---|---|---|---|
| background-suite | v13 | 10 | 3 | 3 | 3 |
| grep-then-edit | v13 | 10 | 6 | 5 | 5 |
| race | v13 | 10 | 10 | 10 | 10 |
| race-anon | v13 | 11 | 11 | 11 | 11 |
| rendezvous | v13 | 11 | 0 | 8 | 8 |
| review-angles | v13 | 10 | 10 | 6 | 6 |
| three-stage-pairing | v13 | 11 | 8 | 5 | 5 |
| two-source-fan-in | v13 | 12 | 2 | 9 | 9 |
| barrier-free-pipeline | v13 | 5 | 1 | 1 | 1 |
| background-suite | v14 | 10 | 4 | 3 | 3 |
| grep-then-edit | v14 | 11 | 8 | 8 | 8 |
| race | v14 | 12 | 11 | 11 | 11 |
| race-anon | v14 | 12 | 12 | 12 | 12 |
| rendezvous | v14 | 12 | 3 | 9 | 9 |
| review-angles | v14 | 12 | 12 | 10 | 10 |
| three-stage-pairing | v14 | 10 | 8 | 8 | 8 |
| two-source-fan-in | v14 | 12 | 3 | 10 | 10 |
| barrier-free-pipeline | v14 | 5 | 0 | 0 | 0 |

## D5g the compose family's seven gate/picture tasks per tier (42 runs each; a run with no built plan stays a miss): exact first-call scores orig / A / B
- v13 strong: orig 26, A 25, B 25 (built plans 40)
- v13 floor: orig 24, A 24, B 24 (built plans 34)
- v14 strong: orig 31, A 32, B 32 (built plans 41)
- v14 floor: orig 27, A 30, B 30 (built plans 38)
```

### d5_check.sh

```zsh
#!/bin/zsh
# D(5) check over d5_explicit_rule.out's D5c table: which misses turn exact under the strict rule (A), and whether
# every one of them was an over_read reading. Run: zsh d5_check.sh
sed -n '/## D5c/,/## D5d/p' d5_explicit_rule.out | awk -F'|' 'NR>3 && $8 ~ /exact/ && $7 !~ /exact/ { n[$2]++; if ($7 !~ /over_read/) bad++ } END { for (b in n) print b, "miss->exact under A:", n[b]; print "of which without over_read:", bad+0 }'
# The D5b `left:` lists under A, tallied by the bucket each reading ends on.
sed -n '/## D5b/,/## D5c/p' d5_explicit_rule.out | grep '^- v1[34] A:' | while IFS= read -r line; do
  bench=${line[3,5]}
  print -r -- "$line" | sed 's/.*left: //' | tr ';' '\n' | sed -E 's/.*\[(.*)\].*/\1/' | awk -v b="$bench" '{ if ($0 ~ /over_read/) o++; else if ($0 ~ /blind_model/) bl++; else other++ } END { print b, "A left: still over_read", o+0, "| blind_model (no over_read)", bl+0, "| other", other+0 }'
done
```

Output (`d5_check.out`):

```text
 v13  miss->exact under A: 16
 v14  miss->exact under A: 14
of which without over_read: 0
v13 A left: still over_read 7 | blind_model (no over_read) 4 | other 1
v14 A left: still over_read 3 | blind_model (no over_read) 4 | other 0
```

### d6_over_sync.rb

```ruby
# D(1/5 side): every over_sync reading (v13 last line per key, v14): the waits the graph makes that the
# picture does not, under the picture's closest correspondence, and whether the SCRIPT NAMED each one
# (`after:`/`results:` on the waiting step) or it came from written order (the tip before the step).
# Run: cd /Users/jasl/Workspaces/cybros-ai.alt2/e2e && bundle exec ruby <scratch>/d6_over_sync.rb
require_relative "d_harness"

def named_waits(r, key)
  node = r[:plan].nodes.fetch(key)
  return nil unless node["expansion_parent"] == r[:call]

  entry = r[:index][r[:labels].fetch(key)] or return []
  (Array(entry[1]["after"]) | Array(entry[1]["results"])).map { |k| "#{r[:call]}-#{k}" }
end

rows = []
[["v13", "compose"], ["v14", "compose"]].each do |bench, family|
  D.records(bench, family).each do |record|
    objective = D::PICTURE_TASKS[record["task"]] or next
    score = record.dig("facts", "score")
    next unless score.is_a?(Hash) && Array(score["silent"]).include?("over_sync")

    r = DH.reading(record, D.trace(bench, family, record), objective)
    pic = r[:picture]
    theirs = pic.send(:waits_of, r[:read])
    mine = pic.instance_variable_get(:@waits)
    over = r[:mapping].to_a.permutation(2).filter_map do |(label, key), (other, other_key)|
      [label, other, key, other_key] if theirs.closure.include?([key, other_key]) && !mine.closure.include?([label, other])
    end
    # The direct edges into each over-waiting step, and whether its script named them.
    reduced = theirs.reduced
    detail = over.map do |label, other, key, other_key|
      direct = reduced.select { |from, to| to == other_key }.map(&:first)
      named = named_waits(r, other_key)
      how = if named.nil? then "stage-placed"
            elsif (direct & named).any? && (direct - named).empty? then "named"
            elsif (direct & named).empty? then "written order"
            else "mixed"
            end
      "#{label}->#{other} (#{how})"
    end
    rows << [bench, record["task"].delete_prefix("compose-"), D.short(record["model"]), record["run"], detail.join("; ")]
  end
end
puts "## D6 over_sync readings: the pictured-free waits the graph makes, and where each came from"
puts D.table(["bench", "task", "model", "run", "over waits (pair: how the waiting step got its direct waits)"], rows)
puts "- readings per bench and task: #{rows.group_by { |r| [r[0], r[1]] }.transform_values(&:size).map { |(b, t), n| "#{b} #{t} #{n}" }.join(", ")}; " \
     "readings whose every over wait is written order: #{rows.count { |r| r[4].scan(/\(([^)]*)\)/).flatten.all? { |h| h == "written order" } }}/#{rows.size}"
```

Output (`d6_over_sync.out`):

```text
## D6 over_sync readings: the pictured-free waits the graph makes, and where each came from
| bench | task | model | run | over waits (pair: how the waiting step got its direct waits) |
|---|---|---|---|---|
| v13 | grep-then-edit | kimi-k3 | 1 | g1->g2 (written order); g1->g3 (written order); g2->g3 (written order) |
| v13 | grep-then-edit | glm-flash | 3 | g1->g2 (written order); g1->g3 (written order); g2->g3 (written order) |
| v13 | two-source-fan-in | glm-5.3 | 2 | l->ty (written order) |
| v13 | two-source-fan-in | glm-5.3 | 3 | t->l (written order); t->ty (written order); t->qs (written order); l->ty (written order); l->ts (written order); ty->ts (written order); ts->qs (written order) |
| v13 | two-source-fan-in | ds-flash | 2 | l->ty (written order) |
| v14 | grep-then-edit | glm-5.3 | 2 | g1->g2 (written order); g1->g3 (written order); g2->g3 (written order) |
| v14 | grep-then-edit | kimi-k3 | 3 | g1->g2 (written order); g1->g3 (written order); g2->g3 (written order) |
| v14 | two-source-fan-in | ds-flash | 1 | l->ty (written order) |
- readings per bench and task: v13 grep-then-edit 2, v13 two-source-fan-in 3, v14 grep-then-edit 2, v14 two-source-fan-in 1; readings whose every over wait is written order: 8/8
```

### d7_naming_habit.rb

```ruby
# D(5 side): how explicitly the models already write. Over every first compose script that built (the
# evaluator's `steps` on the record, `facts.score.steps`; a g.script stage's own body is a string and is not
# walked), the model steps that name their inputs with `results:` versus the ones that name nothing and so
# read only by position — per tier and task. Run: ruby d7_naming_habit.rb (records only; plain ruby)
require_relative "d_common"

def model_steps(steps, out = [])
  Array(steps).each do |step|
    if step.is_a?(Array) then model_steps(step, out)
    elsif step.key?("parallel") then model_steps(step["parallel"], out)
    elsif step["model"] then out << step["model"]
    end
  end
  out
end

tasks = D::PICTURE_TASKS.keys.select { |t| t.start_with?("compose-") }
%w[v13 v14].each do |bench|
  puts "## D7 #{bench}: model steps naming results / all model steps, first built script (top-level steps; stage bodies not walked)"
  rows = tasks.map do |task|
    [task.delete_prefix("compose-"), *%w[strong floor].map do |tier|
      steps = D.records(bench, "compose").select { |r| r["task"] == task && D::TIER[D.short(r["model"])] == tier }
        .map { |r| r.dig("facts", "score") }.select { |s| s.is_a?(Hash) && s["steps"] }.flat_map { |s| model_steps(s["steps"]) }
      "#{steps.count { |m| Array(m["results"]).any? }}/#{steps.size}"
    end]
  end
  puts D.table(%w[task strong floor], rows)
  all = D.records(bench, "compose").select { |r| tasks.include?(r["task"]) }
    .map { |r| r.dig("facts", "score") }.select { |s| s.is_a?(Hash) && s["steps"] }.flat_map { |s| model_steps(s["steps"]) }
  puts "- #{bench} all picture tasks: #{all.count { |m| Array(m["results"]).any? }}/#{all.size} model steps name results " \
       "(#{(100.0 * all.count { |m| Array(m["results"]).any? } / all.size).round(1)} %)\n\n"
end
```

Output (`d7_naming_habit.out`):

```text
## D7 v13: model steps naming results / all model steps, first built script (top-level steps; stage bodies not walked)
| task | strong | floor |
|---|---|---|
| review-angles | 2/20 | 4/20 |
| grep-then-edit | 1/1 | 1/2 |
| race | 2/2 | 2/2 |
| race-anon | 0/0 | 2/2 |
| background-suite | 9/10 | 10/13 |
| three-stage-pairing | 10/16 | 13/17 |
| two-source-fan-in | 17/18 | 17/18 |
| rendezvous | 15/15 | 10/12 |
- v13 all picture tasks: 115/168 model steps name results (68.5 %)

## D7 v14: model steps naming results / all model steps, first built script (top-level steps; stage bodies not walked)
| task | strong | floor |
|---|---|---|
| review-angles | 5/24 | 5/24 |
| grep-then-edit | 0/0 | 1/2 |
| race | 5/5 | 3/3 |
| race-anon | 4/4 | 3/3 |
| background-suite | 5/7 | 5/7 |
| three-stage-pairing | 10/14 | 14/14 |
| two-source-fan-in | 14/15 | 17/18 |
| rendezvous | 10/10 | 17/18 |
- v14 all picture tasks: 118/168 model steps name results (70.2 %)

```
