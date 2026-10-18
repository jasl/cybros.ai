# S1 floor A/B — 2026-09-24 (analysis)

Arms: without `/Users/jasl/Workspaces/cybros-ai.alt2/e2e/artifacts/bench/2026-09-24-s1/without` (re-read under /Users/jasl/Workspaces/cybros-ai.alt2), with `/Users/jasl/Workspaces/cybros-ai.alt2/e2e/artifacts/bench/2026-09-24-s1/with` (re-read under /Users/jasl/Workspaces/cybros-ai.alt2-s1).
Samples: without 192 (deepseek-flash 96, glm-5.3-flash 96); with 192 (deepseek-flash 96, glm-5.3-flash 96).

## Floor gate (usable after repair, pooled over the two floors and the non-control objectives; apart draws out)

| arm | usable after repair | apart (out) | unreached | Δ with − without (90 % one-sided lower) | gate |
|---|---|---|---|---|---|
| without | 163/168 (97.0 %) | 0 | 2 | — | — |
| with | 161/168 (95.8 %) | 0 | 4 | -1.2 pts (lower -4.0) | HOLDS |

**S1 LANDS**: the gate holds (lower bound -4.0 ≥ -5.0) on the pooled two batches.

Per floor (reported, not deciding):

- deepseek-flash: without 81/84 (96.4 %), with 84/84 (100.0 %); Δ 3.6 pts (lower 0.9)
- glm-5.3-flash: without 82/84 (97.6 %), with 77/84 (91.7 %); Δ -6.0 pts (lower -10.9)

Per (floor, objective), usable after repair without → with (a loss ≥ 2/6 is a flag, never a veto):

| floor | O1 | O2 | O3 | O4 | O7 | O7b | T5 |
|---|---|---|---|---|---|---|---|
| deepseek-flash | 12/12→12/12 | 12/12→12/12 | 10/12→12/12 | 12/12→12/12 | 12/12→12/12 | 12/12→12/12 | 11/12→12/12 |
| glm-5.3-flash | 12/12→12/12 | 12/12→12/12 | 12/12→9/12 ⚑ | 12/12→11/12 | 11/12→12/12 | 12/12→12/12 | 11/12→9/12 ⚑ |

Flags: glm-5.3-flash O3 12/12→9/12; glm-5.3-flash T5 11/12→9/12.

`valid_after_repair` (the record's, the ledger's word; reported, the gate reads `usable`):

- without 165/168 (98.2 %), with 163/168 (97.0 %); Δ -1.2 pts (lower -3.6)

## Sensitivities (reported, never deciding)

- (a) apart draws restored, usable in `without` as read and NOT usable in `with` (S1's worst case): without 163/168 (97.0 %), with 161/168 (95.8 %); Δ -1.2 pts (lower -4.0) → would hold
- (b) first-call provider errors dropped (without 2, with 4): without 163/166 (98.2 %), with 161/164 (98.2 %); Δ -0.0 pts (lower -2.1) → would hold

Power (zero-difference lower bound at the base rate; the least `with` count that holds against a `without` count):

| n per arm | 84/84 | 81/84 | 79/84 | 78/84 | 77/84 | 76/84 |
|---|---|---|---|---|---|---|
| 84 | -1.9 | -4.0 | -4.9 | -5.3 | -5.6 | -6.0 |
| 168 | -1.0 | -2.7 | -3.4 | -3.7 | -3.9 | -4.2 |

At n = 84, without→least with: 84→≥83, 82→≥82, 80→≥80, 79→≥79, 78→≥79, 76→≥77.

## S1's bite

`with`, first-call `race_member` refusals: 0/164 reached (none).
- repair outcomes: none; exact after repair 0/0; usable after repair 0/0
- the re-read under S1 refuses the same first scripts with the same sentence: 0/0
- `without`, first scripts S1's builder WOULD refuse (race_member): 0/166 reached (none); of them, the record read them none
- `without`, JUDGED scripts S1 would refuse at the top level: 0 (none)
- result-free stages S1's inliner fails with race_member (real under `with`, would-be under `without`): without 0 (none); with 0 (none)
- without, APART (a result-reading stage whose body S1 refuses with race_member when run with no results): 0 (none)
- with, APART (a result-reading stage whose body S1 refuses with race_member when run with no results): 0 (none)

race_member on a non-O3 objective (false-positive candidates; read the script): with 0, without would-be 0

## O3 (the race), each arm as its own kernel read it

| arm | floor | reached | valid first | exact first | expanded exact | silent (first) | loud (first) | usable after repair | exact after repair |
|---|---|---|---|---|---|---|---|---|---|
| without | deepseek-flash | 12/12 | 9 | 4 | 4/5 | exact 4, wrong_task_read 4, blind_model 1 | member_not_a_step 3 | 10 | 4 |
| without | glm-5.3-flash | 12/12 | 10 | 6 | 1/1 | exact 6, wrong_task_read 4 | member_not_a_step 2 | 12 | 6 |
| with | deepseek-flash | 12/12 | 8 | 3 | 3/3 | wrong_task_read 4, exact 3, extra_steps 1, over_sync 1 | member_not_a_step 4 | 12 | 3 |
| with | glm-5.3-flash | 12/12 | 10 | 2 | 1/2 | wrong_task_read 7, exact 2, missing_join 1, missing_steps 1 | member_not_a_step 2 | 9 | 2 |

## Finishes, spend, control

- without deepseek-flash: first finishes completed 96; repair calls 7 (completed 7); tokens in 467081, out 288294
- without glm-5.3-flash: first finishes tool_calls 94, error 1, error (client) 1; repair calls 6 (tool_calls 6); tokens in 416593, out 933027, cost $0.49
- without control O5: compose 0 on 24/24
- with deepseek-flash: first finishes completed 96; repair calls 7 (completed 7); tokens in 472469, out 287689
- with glm-5.3-flash: first finishes tool_calls 92, error 2, error (client) 2; repair calls 4 (tool_calls 4); tokens in 402048, out 1025155, cost $0.55
- with control O5: compose 0 on 24/24

## Record vs re-read (each arm under its own checkout)

- without: 1 draw(s) differ
  - deepseek-flash O2 #2: repair valid true→false, the record says the repaired script built; the re-read refused it (script_error: TypeError: Cannot read properties of undefined (reading 'map')) — counted by the record
- with: 0 draw(s) differ

## Resolutions (this script's header, fixed before the data)

```text
The S1 floor A/B of 2026-09-24 — compose refusing a reference to a member of a formed race — read by
the ledger row's pre-registration (docs/plans/DEFERRALS.md, "Compose refusing a reference to a member
of a formed race (S1)": "it lands only if it holds the floor gate on a text-bench A/B — the two floors'
`valid_after_repair`, the branch with it against the branch without, pooled `usable`'s one-sided 90 %
bound at or above −5 points — with a result-reading outer stage that names a member counted apart
(the static inliner cannot see its body)") under the resolutions below.

The run (launched 2026-09-24 ~14:36Z): test/compose_matrix_probe_test.rb, row R-WO, style nexus, every
objective, n = 6, the 65,536 cap, on deepseek/deepseek-flash and openrouter/z-ai/glm-5.3-flash;
`without` from main's checkout (HEAD 56469b97), `with` from the S1 worktree (same HEAD + the patch).

Resolutions fixed BEFORE the data (written 2026-09-24 while the run was in flight; nothing under
2026-09-24-s1/{with,without} — matrix, results, captures, logs past the header — was opened before
this file was on disk):

1. UNIT. One draw = one (floor, objective, index). The script JUDGED is the first script when the
   arm's own kernel built it (`valid_first`), else the repaired script when the one repair built
   (`repaired == "valid"`), else none. The gate's measure is `usable` READ ON THE JUDGED SCRIPT —
   "usable after repair" — in the probe's own sense (`Probe#usable`, e2e/support/compose_bench/probe.rb):
   the script built through the evaluator and the lowering, its plan places a step once its
   result-free stages are inlined, every stage source parses, and some placed node other than a join
   is not a stage the kernel fails on its own script; a result-reading stage is read for its parse
   alone and survives. A draw with no judged script — unreached (no compose call, a provider error, a
   `length` finish before any script), refused twice, or a refusal the model answered with no script
   (`no_second_call`) — is NOT usable and STAYS in the denominator (the 09-23 rule: unreached = not
   usable). The control O5 is out of the gate. The record's `valid_after_repair` — the ledger names it —
   is reported beside the gate with its own bound, never deciding: the gate's word is `usable`.

2. READER. Each arm is read by ITS OWN kernel and harness. The refusal IS the treatment, so no single
   reader can judge both arms: main's builder builds what S1 refuses and S1's refuses what main
   builds, and re-reading either arm through the other's builder would bias exactly that arm (a
   `without` first script naming a member would be struck by S1; a `with` first script refused as
   `race_member` was never a judged script). Verified before the data: the S1 worktree differs from
   main by the patch's seven files alone (git status of the worktree; `diff -rq` of e2e/support,
   e2e/test, nexus/lib, nexus/app); under e2e/support only buckets.rb differs, by the added
   `race_member` line — probe, scoring, shape, inline, picture, objectives, endpoints, tools are byte
   for byte the same, so the recorded fields of the two arms come from one harness over two builders.
   Validity (built / refused / repaired) is the RECORD's, as the arm's kernel saw the exact call;
   `usable` on the judged script is RE-READ at analysis time under the arm's own checkout (a child
   process rooted there — main's e2e for `without`, the worktree's for `with` — so `Shape.inline`'s
   stage runs go through that arm's builder): the repaired script's `usable` was never recorded, and
   re-reading the first script checks the record. Every record-vs-re-read disagreement is listed; the
   record's validity wins, the re-read's `usable` wins where it builds; a repaired script the re-read
   cannot build while the record says it built (the repair call's params are not recorded) counts by
   the record and is listed by name.

3. COUNTED APART. A result-reading stage's body is opaque to the static inliner
   (`Shape::Inliner#read_later`: run with `results: []` for its parse alone, it stays a stage leaf, so
   `usable` reads it as a survivor in BOTH arms), while the kernel's real stage run would FAIL it
   under S1 and over-sync under main. Operationally: a draw is APART when its judged script's inlined
   plan holds a result-reading `g.script` — at any depth: the top level, a group member, or inside an
   inlined expansion — whose body, run by S1's builder (`Nexus::Compose::Evaluator.stage`, `results:
   []`, the branch's tool set, exactly the inliner's own run) is refused with the race_member sentence
   (/a member of (?:the race on line \d+|an earlier race); a race stops the members it did not
   select/). The same detector runs over BOTH arms' judged scripts (in the S1 worktree's child
   process); apart draws leave the gate's denominator in both arms, and the count per arm is shown
   with each draw named. Stated limit: a body that touches its results before the reference (a
   TypeError on the empty list) is invisible to this detector and stays an ordinary opaque stage in
   both arms. A RESULT-FREE stage naming a member is NOT apart: the inliner runs it exactly as the
   kernel will (`Shape::Inliner#expand`), so S1's kernel records it as `stage_refused` — unusable when
   it was the only survivor — and main's inlines it and reads `over_sync`. That asymmetry is real
   kernel behaviour and the gate measures it; the count per arm is shown.

4. GATE. Pooled over both floors and every non-control objective (O1, O2, O3, O4, O7, O7b, T5: 84
   draws per arm before apart draws leave); difference = with − without in points of usable after
   repair; Newcombe's hybrid score interval (Wilson per arm, z = 1.2816); the one-sided 90 % LOWER
   bound ≥ −5.0 points → the gate HOLDS and S1 lands; below → it does not hold. A per-(floor,
   objective) loss ≥ 2/6 is a flag, never a veto. POWER (arithmetic, printed in the readout): at
   n = 84 per arm and a ZERO difference the bound reads −4.9 at 79/84 (the 09-23 floors' 94.0 %),
   −5.3 at 78/84, −6.0 at 76/84 — a pass needs both arms at 79/84 or better with `with` at most one
   draw below `without` (at 84/84 `without`, `with` may lose one); the gate is non-inferiority S1 must
   SHOW. SECOND BATCH, pre-registered now: if the gate fails with a point estimate ≥ −2.0 points
   (`with` loses at most one draw net of 84), a second batch of the same design — both arms, both
   floors, every objective, n = 6, the 65,536 cap, launched together — is run and the gate is read
   ONCE MORE on the pooled n = 168 per arm (zero-difference bound −3.4 at 94.0 %); that reading
   decides; no third batch. A point estimate below −2.0 does not land and buys no batch. Two
   sensitivities are REPORTED, never deciding: (a) apart draws restored — usable in `without` as read,
   NOT usable in `with` (the kernel would fail the stage) — S1's worst case; (b) first-call provider
   `error` finishes and client exceptions dropped from both denominators (a lane's fault; `length`
   stays, it is the model's).

5. REPORTED BESIDE THE VERDICT: `with`'s first-call `race_member` refusals by (floor, objective) with
   each repair's outcome (valid / refused again + its bucket / no second call), `right_after_repair`
   and usable after repair; every such refusal on a non-O3 objective listed with its sentence (a
   false-positive candidate for the reviewer to read); S1's would-be bite on `without` — its first and
   judged scripts through S1's builder: top-level race_member, result-free stages S1 would fail — as a
   consistency check against `with`'s recorded refusals (same models, same text); O3 per (arm,
   floor): reached, valid first, exact first, expanded exact, silent and loud tallies, usable and exact
   after repair; first-call and repair finishes, tokens and cost per (arm, floor); the control's
   compose-0 count; every record-vs-re-read disagreement.

Bounds: analyze_ab.rb's (2026-09-23) Wilson and Newcombe arithmetic, verbatim.

Usage (from main's e2e):  bundle exec ruby artifacts/bench/2026-09-24-s1/analyze_s1.rb
  → analysis.md beside this file.  A dry run names the two arm directories (each holding
  <model slug>/compose_matrix.json) and writes dryrun.md, never analysis.md:
  bundle exec ruby artifacts/bench/2026-09-24-s1/analyze_s1.rb <without dir> <with dir> [out name]
  S1_WITHOUT_ROOT / S1_WITH_ROOT override the two checkouts the arms are re-read under.

PLUMBING, 2026-09-24 after batch 1 (no rule changes): batch 1 read −1.2 pts (lower −5.1), so the
pre-registered second batch ran under `batch2/<arm>/<model slug>/`. An arm directory's samples are
its own plus its `batch2` sibling's, each tagged with its batch; a draw's id carries the batch; and
once both batches are present the gate's reading is FINAL (resolution 4: no third batch).
```
