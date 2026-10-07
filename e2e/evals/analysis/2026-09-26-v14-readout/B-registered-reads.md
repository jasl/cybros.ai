# B. The pre-registered reads of bench version 14

Read-only section. Records: `e2e/evals/runs/2026-09-26-v14-{task,compose,workflow}/records.jsonl` (240 lines,
one per key, every line under bench digest `f69dc4cc6ab4`, `provenance.out`). Version 13 is read as **each
key's LAST line** (v13 was rescored in place by 563a86aa and 5de9f94a; 31 of 108 compose keys, 12 of 72 task
keys and 12 of 60 workflow keys carry more than one line). Every number below comes from a script in
`b/` beside this file; the appendix carries each script and its output, and `b/run_b.sh` re-runs all of them
(offline: no world, no paid call, no test suite; `git status --short` on the repo is empty after it). Where a
record's trace does not hold what a read needs — the sealed request of any round but the one that made the
compose call — the request is **rebuilt from the run's windowed Solid Queue log** (`nexus.jobs.rails.log`
under `logs/<stem>/`): the request body is the `content_bodies` row whose sealed `byte_size` equals the task
row's `request_bytes`, its new entries are the fragment digests the sealing job loaded, and each fragment's
payload is read off a `ContentFragment Bulk Insert` in the family's windows. That method is validated twice
below against a known answer (v13's 10 canceled envelopes, and v13's 32 duplicated history envelopes), and
resolved every digest it met (0 unknown fragments in every run).

## Headline

All six reads execute cleanly and none is a stop. **Q10:** 22 race followers, 0 canceled exits on all three
readings (the recorded fact, a graph restatement, and the bytes rebuilt from the world log); 16/16 composed
followers agree fact-to-bytes; no follower read a stage-exit race, so resolution 5's fallback applies. **T1 in
vivo:** `authored_labels` falls 9/12 → 3/12 (compose-race) and 12/12 → 3/12 (compose-race-anon), the
direction the A/B registered. **Dedup:** 26 of 108 compose and 3 of 60 workflow records carry a reducer row;
29 of 29 rebuilt reducer requests carry no envelope for their history source (the same method finds it on
32 of 32 v13 rows). **Fan of five:** 9/12 both columns; three v14 fans ran detached, and one of them merges on
`woken-1` — the case the driver exists for; both glm-5.3-flash reds are a scorer false positive (`per_file`
counts context mentions). **O2:** `edit_as_stage`
names 6 static readings on v14, all exact on the executed reading; the v13 offline column moves exactly the
note's five readings and keeps its two. **Rulings:** O4 moves 5/12 readings (no verdict), O2's tail moves
10/12 (2 verdicts, pictures 3 → 8 of 12), adversarial-verify flips `did_not_judge_itself` on 3/12.

---

## 1. Q10 — a model after a race reads the race

The rule, verbatim from the VERSION 14 note:

> PRE-REGISTERED: on every version-14 race follower the canceled-exit count is 0 and every delivered exit is in its race's selection — a hit the bytes confirm is a kernel finding, stop-fix-rerun; a canceled mid-arm stage is residue, reported — and the race cells' success, picture, `no_wrong_winner`, `authored_labels`, `success_filter` and `losers_completed` are read beside it, never deciding: both readers of a follower's reads already read a race as its exits, so no picture can move on this rule.

and the resolutions it was read under (the analyzer's header, fixed before the data):

> 2. THE INVARIANT (kernel). On every version-14 race follower `canceled_exits == 0` and `unselected_exits == []`. A violation the record's `follower_requests` confirms (a canceled key among the bytes that is an exit) is a KERNEL FINDING: stop, fix, rerun the cell.

> 3. THE ARITHMETIC (harness). On every COMPOSED version-14 follower (`spine: false`), `follower_requests.envelopes == follower_envelopes.delivered` and its canceled keys are the reader's canceled rows; a disagreement is listed by follower and that record's Q10 column is marked unread until the reader is corrected.

> 4. THE CENSUS. How many version-14 followers there are, how many read a race with a stage exit (version 13: 5 of 18), and the delivered and canceled-exit sums over that subset beside the version-13 column's 18 / 10 → 8 / 0.

> 5. FALLBACK. If version 14 carries zero stage-exit followers, the measurement's floor is the kernel tests (delivered bytes on the five shapes version 13 wrote) and this file's dry run; the readout says the subset was empty and draws nothing from the cells' pictures for this row.

**My own check** (`q10_check.py`, independent of `analyze_q10.rb`): followers restated off each trace's graph
(a `model_task` naming a `join_task` or one of a join's structural parents), each follower's could-be-delivered
exits off the join's `result.outcomes`, the recorded `follower_envelopes` against `follower_requests`, and a
third reading — every follower's sealed request (spine followers included, which `follower_requests` never
reads) rebuilt from the jobs log and its `<task_result …>` entries counted.

| reading | v14 | v13 (control, same script) |
|---|---|---|
| race-cell records | 24 | 24 |
| followers (graph restatement) | **22** — 16 composed, 6 spine | 18 — 8 composed, 10 spine |
| records whose follower keys equal the recorded `follower_envelopes` keys | 24/24 | — (v13 carries no such fact) |
| canceled exits, recorded fact | **0** | — |
| canceled exits, graph restatement | **0** | 10 |
| canceled exits, bytes rebuilt from the world log | **0** | 10 |
| canceled non-exits (residue) | 0 | — |
| unselected exits delivered | 0 | 10 (named directly in `result_from`) |
| composed followers: `follower_requests` == `follower_envelopes` | **16/16** | — |
| all followers: bytes' envelope count == `follower_envelopes.delivered` | **22/22** (28 envelopes) | — (40 envelopes) |
| followers reading a race with a stage exit | **0** | 5 — 18 envelopes, 10 canceled |
| fragments the rebuild could not resolve | 0 | 0 |

The v13 control reproduces the note's scratch column exactly (eighteen followers, five on a stage exit, 18
envelopes / 10 canceled on that subset), so the byte method sees a canceled envelope when there is one.

**Verdict under the resolutions.** (2) holds: 0 canceled exits, no unselected exit, no residue — no kernel
finding, nothing to stop. (3) holds: 16 of 16 composed followers agree; the third reading adds the 6 spine
followers, 22/22. (4) census: 22 followers, **0** reading a race with a stage exit (v13 5 of 18); over that
empty subset, delivered 0 / canceled 0. (5) **the fallback applies**: v14 carried no stage-exit follower, so
the measurement's floor is the kernel tests and the dry run, and nothing is drawn from the cells' pictures
for this row. (6) `q10_beside.py` re-derives analysis.md §6 from the records: **12 of 12 lines identical**.
One of those lines carries a scorer false red (compose-race-anon glm-5.3 #1 `no_wrong_winner`, below and in
the harness list).

**Provenance, plainly** (`provenance.sh`). The analyzer that produced `analysis.md` is `analyze_q10.rb`,
sha256 `1a3d6a9416229e41ebacc05e153327adc1186c18b1bc62d9bcfd5fbc7d1433e6`; that sha was written to
`scratchpad/v14/analyze_q10.sha256` at 2026-09-25T16:01:57Z, **16 s before** the bench started
(`bench-v14.log` line 1: 16:02:13Z, HEAD 4a8cf2ea), and the analyzer file itself was last modified at
15:03:40Z, before both. **The launch stamp was not written at launch**: `--stamp` was skipped, and
`logs/launch.txt` was **reconstructed after the batch** (file mtime 2026-09-26T00:54:46Z, after `BENCH_DONE`
at 00:52:33Z) from those launch-time facts; its own `reconstructed=` line says so. `analysis.md` (mtime
00:54:56Z) reads under the worktree `cybros-ai.alt2-q10read` at 4a8cf2ea with 0 uncommitted lines, bench
f69dc4cc6ab4 — and its header line "stamped 2026-09-25T16:01:57Z … this file is the stamp's" **does not
itself say the stamp was reconstructed**; the readout has to say it. Two more facts a reader should have: the
whole `e2e/artifacts/bench/2026-09-26-q10/` directory is gitignored (`e2e/.gitignore:11`), so neither the
analyzer nor `analysis.md` is committed; and the dry run (resolution 7, `dryrun-v13.md`) ran at e26dad18 with
the Q10 change still uncommitted and bench digest 786bfc5ad3cb, under the same analyzer sha.

## 2. T1 in vivo — `authored_labels` on the race cells

> On this bench the sentence is read by compose-race's and compose-race-anon's `authored_labels`, version 13's 9/12 and 12/12.

> T1's pre-registered race-cell read (`authored_labels`, version 13's 9/12 and 12/12) shares this version with Q10: it reads every compose call's plan (`over_plans`), and a call written after the follower's delivery is written under Q10's bytes.

Recomputed from the records (`labels.py`; v13's last line per key — one race key, glm-5.3-flash #1, has two
lines and the same fact on both):

| cell | glm-5.3 | kimi-k3 | deepseek-flash | glm-5.3-flash | total |
|---|---|---|---|---|---|
| compose-race v13 | 1/3 | 3/3 | 3/3 | 2/3 | **9/12** |
| compose-race v14 | 1/3 | 0/3 | 0/3 | 2/3 | **3/12** |
| compose-race-anon v13 | 3/3 | 3/3 | 3/3 | 3/3 | **12/12** |
| compose-race-anon v14 | 0/3 | 1/3 | 1/3 | 1/3 | **3/12** |

Both v13 figures reproduce (9/12, 12/12). Pooled 21/24 → 6/24. **The direction matches the T1 A/B** (labels
falling is the intended effect; the A/B's per-model endpoint read glm-5.3 10/12 → 1/12, kimi-k3 3/7 → 2/11,
deepseek-flash 5/9 → 0/11, glm-5.3-flash 1/8 → 1/11). By model: **kimi-k3** (6/6 → 1/6) and
**deepseek-flash** (6/6 → 1/6) fall on both cells; **glm-5.3** falls on anon (3/3 → 0/3) and holds its single
label run on compose-race (1/3 → 1/3); **glm-5.3-flash** holds on compose-race (2/3 → 2/3) and falls on anon
(3/3 → 1/3) — the floor model the A/B also found flat. The six v14 runs that author labels (compose-race
glm-5.3 #2, glm-5.3-flash #1 and #3; anon kimi-k3 #2, deepseek-flash #2, glm-5.3-flash #3) are all runs
without a composed model follower — the race closes on a value stage or on the spine — and none of the 16
runs with a composed follower authors a label. The over_plans caveat is small here: one v14 race run made two
compose calls (compose-race glm-5.3-flash #3, labels true), against three on v13. This is an in-vivo read
beside a landed change, n = 3 per model, with Q10 and the scorer corrections moving in the same version; it
agrees with the A/B, it does not re-decide it.

## 3. The continued-round dedup — the reducer rows

> Version 13 has one such row in 28 of 108 compose records — compose-background-suite 5, compose-rendezvous 9, compose-review-angles 5, compose-three-stage-pairing 2, compose-two-source-fan-in 7 — and in 4 of 60 workflow records, all workflow-judge-panel; on this version each such row's request carries one envelope fewer, the history source's (versions 10 and 11 carry the same shape).

> No race cell has it on version 13, so T1's race-cell read is untouched; every other comparison of those six cells with version 13 reads the reducer's request that one envelope shorter, beside T1's sentence.

A reducer row (`reducers.py`): a model step whose `result_from` names its history source — the first
`model_task` among its `input_from`, the kernel's `model_source` — that source completed. The definition
reproduces the note's v13 census **exactly**: 28 of 108 compose (5 / 9 / 5 / 2 / 7) and 4 of 60 workflow, all
judge-panel.

| column | background-suite | rendezvous | review-angles | three-stage-pairing | two-source-fan-in | compose total | judge-panel (workflow) |
|---|---|---|---|---|---|---|---|
| v13 | 5 | 9 | 5 | 2 | 7 | 28/108 | 4/60 |
| v14 | 2 | 5 | 8 | 4 | 7 | **26/108** | **3/60** |

**From the sealed requests** (`reducer_bytes.py`; the trace's `sealed_request` is the compose-calling round
only, so each reducer's request is rebuilt from the jobs log): **29 of 29** v14 reducer requests carry **no**
`<task_result>` envelope for their history source; the same script over v13 finds it **present on 32 of 32**.
0 unknown fragments on either. The shape of the delivery moves as the note says: six of the seven v13
two-source-fan-in reducers read `r2t0-model-1` (their history) as an envelope beside `r2t0-model-2` and two
tool reads; the six v14 ones on the same keys read `r2t0-model-2` and the two tool reads only.

**Did the six cells move against v13?** (`cells.py`, v13 last lines; success = the record's verdict, picture =
the `picture` fact exactly true; judge-panel carries no picture fact)

| cell | success v13 → v14 | picture v13 → v14 |
|---|---|---|
| compose-background-suite | 8/12 → 8/12 | 3/12 → 4/12 |
| compose-rendezvous | 12/12 → 12/12 | 0/12 → 3/12 |
| compose-review-angles | 11/12 → 12/12 | 10/12 → 12/12 |
| compose-three-stage-pairing | 9/12 → 11/12 | 8/12 → 8/12 |
| compose-two-source-fan-in | 6/12 → 7/12 | 2/12 → 3/12 |
| workflow-judge-panel | 12/12 → 11/12 | — |

Success moved by at most two records a cell (both directions: judge-panel lost deepseek-flash one run to
model conduct); pictures rose on four cells. None of it is attributable to the dedup alone — T1's sentence,
the scorer corrections and Q10 move in the same version, and the reducer shape itself is present in only
some runs of each cell (per-model counts in `cells.out`). On two-source-fan-in, the owner's question stands
as a tier artifact, not a model one: v14 success is strong 1/6 (glm-5.3 1/3, kimi-k3 0/3) against floor 6/6,
while the picture reads strong 1/6 against floor 2/6 (deepseek-flash 0/3, glm-5.3-flash 2/3) — the floors are
held to usable generation, the strong tier to the picture.

## 4. task-fan-five under `settle_receipts`

> task-fan-five's driver moves `plain` -> `settle_receipts`, so the run is read at the quiet point — every loop the receipts woke settled, no task of any of them live — with each loop's reply recorded, and a detached fan's merge that a receipt-woken turn wrote is on the record (v13 glm-5.3-flash #1's merge, written by its fifth woken loop, is on no record, and the run reads red on turn 1's promise).

> The woken loops are traced beside the primary, not appended after the stop as `traced: false`; the run's `reply` is the last loop's, and `orphans_named` counts on the reply the merge is read on.

`fanfive.py` (v13 last lines — each of the 12 v13 fan-five keys carries a second line from 563a86aa, verdict
and reason unchanged, `v13_lines.out`):

| model #run | v13 (plain) verdict · merge_turn · waited | v14 (settle_receipts) verdict · merge_turn · waited · replies · orphans_named |
|---|---|---|
| glm-5.3 #1 | green · primary · yes | green · primary · yes · 1 · 5 |
| glm-5.3 #2 | green · primary · yes | green · primary · yes · 1 · 5 |
| glm-5.3 #3 | green · primary · yes | green · primary · yes · 1 · 5 |
| kimi-k3 #1 | green · primary · yes | green · primary · yes · 1 · 5 |
| kimi-k3 #2 | green · primary · yes | green · primary · yes · 1 · 5 |
| kimi-k3 #3 | green · primary · yes | green · primary · yes · 1 · 5 |
| deepseek-flash #1 | unreached (0 task calls) · primary · no | unreached (0 task calls: `read` ×5) · primary · yes · 1 · 5 |
| deepseek-flash #2 | unreached (0 task calls) · primary · yes | **green · woken-1 · no · 6 · 5** (5 woken loops) |
| deepseek-flash #3 | green · primary · yes | green · primary · no · 1 · 5 |
| glm-5.3-flash #1 | **red "names no lib/a.rb" · none · no** (6 loops) | red "a second task for a.rb, …" · primary · no · 1 · 5 |
| glm-5.3-flash #2 | green · primary · yes | green · primary · yes · 1 · 5 |
| glm-5.3-flash #3 | green · primary · yes | red "a second task for a.rb, …" · primary · yes · 1 · 5 |

Verdicts: **9/12 → 9/12** (glm-5.3 3 → 3, kimi-k3 3 → 3, deepseek-flash 1 → 2, glm-5.3-flash 2 → 1).
`merge_turn` on v14: primary 11, woken-1 1; `waited` 9 of 12; `orphans_named` 5 on all 12. Three v14 fans
did not wait (deepseek-flash #2 and #3, glm-5.3-flash #1), and each drew 5 receipts; two of them consumed
theirs inside turn 1 (no woken loop, merge on `primary`), and deepseek-flash #2's five receipts woke five loops,
its merge read on the first woken turn — exactly the case v13 glm-5.3-flash #1 lost, now on the record. The
nine waited fans merged on turn 1 with 0 receipts.

**Both v14 glm-5.3-flash reds are a scorer false positive.** `per_file` counts every `task` prompt that
*mentions* a file; these runs' prompts each review exactly one file but name the others as context ("a
directory lib/ containing … (lib/a.rb, lib/b.rb, …). Review ONLY lib/a.rb"). `fanfive_perfile.py`: subject
per file 1/1/1/1/1 on both runs, mentions 5/5/5/5/5 (#1) and 5/4/3/3/5 (#3). Read by subject, the floor's
glm-5.3-flash is 3/3 and the cell 11/12. Harness row below; no record is rewritten here.

## 5. O2's `edit_as_stage`

> O2 NAMES A STAGE IN THE EDIT'S PLACE (`edit_as_stage`, the race-text design's Part 2; the owner's 2026-09-25 ruling (2) had left such a stage in the fallback): on a script the builder accepted whose picture is not O2's, a `g.script` stage standing at the edit's label, with no model step and no editing tool among the steps the tail admitted past it, reads `edit_as_stage` where it read `wrong_task_read` — named before the fallback, never over a sharper bucket.

> read offline, five readings move — the static readings of glm-5.3 #2 and #3 and deepseek-flash #3, and kimi-k3 #2's static and executed readings, its reason naming the bucket — and two stay `wrong_task_read`, kimi-k3 #3 and glm-5.3-flash #2, whose stage a model step reads, both exact on the executed reading. The v14 readout carries that column.

**The task** is `e2e/evals/tasks/compose-grep-then-edit` (`expected.rb`: `Predicates.compose_bar(trace,
"O2")`); its `RATIONALE.md:65` names `edit_as_stage` and the five/two.

**v14's O2 records** (records as written; `o2_stage_readers.py` for the stage readers):

| model #run | verdict | static reading | executed reading |
|---|---|---|---|
| glm-5.3 #1 | green | `edit_as_stage` | exact |
| glm-5.3 #2 | red | `over_sync` | `over_sync` |
| glm-5.3 #3 | green | `edit_as_stage` | exact |
| kimi-k3 #1 | green | `edit_as_stage` | exact |
| kimi-k3 #2 | green | `edit_as_stage` | exact |
| kimi-k3 #3 | red | `over_sync` | `over_sync` |
| deepseek-flash #1 | green (floor) | `missing_steps` | exact |
| deepseek-flash #2 | green (floor) | exact | exact |
| deepseek-flash #3 | green (floor) | `edit_as_stage` | exact |
| glm-5.3-flash #1 | green (floor) | `edit_as_tool`, `extra_steps` | `extra_steps` |
| glm-5.3-flash #2 | green (floor) | `edit_as_stage` | exact |
| glm-5.3-flash #3 | green (floor, usable on call 2) | first script refused (`script_syntax_error`) | — |

`edit_as_stage` names **6 of 12 static readings**, every one exact on the executed reading (the stage
placed the edit, which only the executed reading can see); **no v14 O2 record reads `wrong_task_read`**, and
on no v14 O2 record does a model step read a stage. Success 10/12 (strong 4/6, floors 6/6).

**The v13 column read offline** (`rescore.rb main …` over v13's traces in memory, nothing written;
`o2_compare.py`): readings moved **5** — glm-5.3 #2 static, glm-5.3 #3 static, deepseek-flash #3 static
(`wrong_task_read` → `edit_as_stage`), kimi-k3 #2 static **and** executed, its reason now "(silent:
edit_as_stage)". kimi-k3 #3 and glm-5.3-flash #2 stay `wrong_task_read` on the static reading and are exact
on the executed one; `o2_stage_readers.py` confirms each has a model step (`model-1`) reading a stage, and
none of the five movers does. No verdict moves. **The note's five and two are confirmed.**

## 6. The owner's three rulings in use on v14

> (1) O4 — a `start_process` launch's out-edges are no wait on the suite, so `suite_waited_on` and `over_sync` do not fire on them, while a step that reads the launch's receipt reads suite output and `over_read` stands; (2) O2 admits a post-edit verification tail (`tail: "e"`, O4's rule): a step after the edit reading only its chain extends it, and a read a stage placed on the greps takes the edit's label; (3) adversarial-verify's `did_not_judge_itself` calls a spine read of `lib/` judging only when a round later than the first dispatch's made it (every such read when nothing was dispatched), and counts the reads before that dispatch or beside it in its round as the fact `read_before_dispatch`.

Method (`rescore.rb`, `rulings_compare.py`): the v14 records of the three cells re-read in memory under three
reader trees extracted by `git archive` into scratch — **563a86aa** (before the rulings), **fa67ba30** (the
rulings' commit; over the reader paths `git diff 563a86aa fa67ba30` is that commit alone) and **main**
(4a8cf2ea's readers, the records' own). Control: main's re-read equals the record on **36 of 36**. The
rulings' effect is 563a86aa → fa67ba30; fa67ba30 → main is `edit_as_stage` (and Q10's readers, which move
nothing here).

| ruling (cell) | v14 records whose reading moved | what moved | v13 (commit 5de9f94a, `v13_rulings.py`) |
|---|---|---|---|
| (1) O4 launch no wait (compose-background-suite) | **5/12** — glm-5.3 #1 #3, deepseek-flash #2 #3, glm-5.3-flash #2 | `suite_waited_on` dropped on all 5, `over_sync` on 2, `extra_steps` on 1; reason text on 2 (glm-5.3 #1 #3); `over_read` stands on all 5; **no verdict, no picture flip** (success 8/12, picture 4/12 under both) | 6 lines, buckets only |
| (2) O2 tail (compose-grep-then-edit) | **10/12** | executed `extra_steps` dropped on 6 (`over_read` with it on 2: the tail and the edit's label); static `missing_steps` → `wrong_task_read` on 6 (a stage in the edit's place), `missing_steps` dropped on 2, `extra_steps, over_read` cleared on 1; **verdicts 2** (glm-5.3 #1 and #3, red → green); picture 3/12 → **8/12**; success 8/12 → **10/12**. Then `edit_as_stage` (fa67ba30 → main) renames those 6 static `wrong_task_read` | 8 lines, 2 verdicts, 3 picture flips |
| (3) `did_not_judge_itself` / `read_before_dispatch` (workflow-adversarial-verify) | **3/12** conduct, 12/12 facts | `did_not_judge_itself` false → true on deepseek-flash #1, glm-5.3 #2, glm-5.3-flash #3, each `read_before_dispatch` 3; class moves on 1 (glm-5.3 #2, model conduct → cache under floor); `read_before_dispatch` recorded on all 12 (0 on 9, 3 on 3); one record stays false under both trees (deepseek-flash #3, unreached, `spawn` ×12) | 12 lines, conduct 6, verdict class 4 |

So on v14 the rulings changed a reading on 5 + 10 + 3 = 18 of 36 records (fact-only on 9 more
adversarial-verify records), and a verdict or class on 3 (O2 ×2, adversarial-verify ×1). Only O2's moved
success.

## Harness and scorer issues found in this section

1. **`per_file` counts mentions, so a fan whose prompts name the other files as context reads as delegating
   each file five times** — task-fan-five v14 glm-5.3-flash #1 and #3 are red "a second task for a.rb, …"
   with each file the subject of exactly one task (`fanfive_perfile.out`). The floor's fan-five would read 3/3.
2. **`Claims::RaceWinner` strips the probe's command line before reading, which can erase the winner from its
   own winning sentence** — compose-race-anon glm-5.3 #1 replies "**bravo won.**", but "`bin/probe bravo` was
   the first to respond …, so the fan … stopped waiting on alpha and charlie" becomes a sentence whose only
   hosts are alpha and charlie; `racewinner_probe.out`: red as the lane reads it, green without the strip.
   Beside Q10, never deciding, but it is analysis.md §6's one `no_wrong_winner` loss.
3. **No reducer request is on the trace.** The continued-round rule's pre-registered effect ("one envelope
   fewer") can only be checked by rebuilding requests from the windowed jobs log (`reducer_bytes.py`), which
   depends on the SQL log format; the race cells got `follower_requests`, the six reducer cells got nothing.
4. **The Q10 analysis's header does not disclose the reconstructed stamp**, and the analyzer, the dry run and
   `analysis.md` sit in a gitignored directory — the pre-registration's only durable record is the local
   sha file beside the bench scripts.

## Appendix — the scripts and their outputs

All under `/private/tmp/claude-501/-Users-jasl-Workspaces-cybros-ai-alt2/fe6d4094-2f85-4b52-abfc-78043a70e275/scratchpad/v14/readout/b/`. Re-run everything with `/private/tmp/claude-501/-Users-jasl-Workspaces-cybros-ai-alt2/fe6d4094-2f85-4b52-abfc-78043a70e275/scratchpad/v14/readout/b/run_b.sh` (then `python3 build_b.py` to reassemble this file). The in-memory re-reads write `o2_v13_main.jsonl` and `rul_v14_*_{main,563a86aa,fa67ba30}.jsonl` beside them (not reproduced here; the compare scripts' outputs are).

### `run_b.sh`

```zsh
#!/bin/zsh
# SECTION B, end to end, offline: no world, no paid call, no test suite; nothing written into the repo.
# Reads e2e/evals/runs/*, e2e/artifacts/evals/* (traces + the windowed world logs) and git objects.
set -e
B=/private/tmp/claude-501/-Users-jasl-Workspaces-cybros-ai-alt2/fe6d4094-2f85-4b52-abfc-78043a70e275/scratchpad/v14/readout/b
REPO=/Users/jasl/Workspaces/cybros-ai.alt2
for c in 563a86aa fa67ba30; do
  [[ -d "$B/tree-$c" ]] || { mkdir -p "$B/tree-$c"; git -C "$REPO" archive "$c" e2e/support e2e/evals/tasks e2e/evals/bench.yml nexus/lib \
    nexus/app/services/conversations/compaction agents/rho/rho-mcp/test/support | tar -x -C "$B/tree-$c"; }
done
cd "$B"
./provenance.sh > provenance.out
python3 q10_check.py > q10_check.out
python3 q10_check.py 2026-09-25-v13-compose > q10_check.v13.out
python3 q10_beside.py > q10_beside.out
python3 labels.py > labels.out
sed -n '38p;42,43p' "$REPO/docs/plans/2026-09-26-t1-ab-readout.md" > t1_ab_lines.out
python3 reducers.py > reducers.out
python3 reducer_bytes.py > reducer_bytes.v14.out
python3 reducer_bytes.py 2026-09-25-v13-compose 2026-09-25-v13-workflow > reducer_bytes.v13.out
python3 cells.py > cells.out
python3 fanfive.py > fanfive.out
python3 v13_lines.py > v13_lines.out
python3 fanfive_perfile.py > fanfive_perfile.out
cd "$REPO/e2e"
BUNDLE_FROZEN=true bundle exec ruby "$B/racewinner_probe.rb" > "$B/racewinner_probe.out"
BUNDLE_FROZEN=true bundle exec ruby "$B/rescore.rb" main 2026-09-25-v13-compose compose-grep-then-edit "$B/o2_v13_main.jsonl"
for t in main 563a86aa fa67ba30; do
  BUNDLE_FROZEN=true bundle exec ruby "$B/rescore.rb" $t 2026-09-26-v14-compose compose-background-suite,compose-grep-then-edit "$B/rul_v14_compose_$t.jsonl"
  BUNDLE_FROZEN=true bundle exec ruby "$B/rescore.rb" $t 2026-09-26-v14-workflow workflow-adversarial-verify "$B/rul_v14_workflow_$t.jsonl"
done
cd "$B"
python3 o2_compare.py o2_v13_main.jsonl > o2_v13_main.out
python3 o2_stage_readers.py > o2_stage_readers.out
python3 rulings_compare.py > rulings_compare.out
python3 rulings_tally.py > rulings_tally.out
python3 v13_rulings.py > v13_rulings.out
git -C "$REPO" status --short
echo "section B re-run done"
python3 "$B/build_b.py"
```

### `provenance.sh`

```zsh
#!/bin/zsh
# B(1) the Q10 stamp's provenance: hashes, mtimes (UTC), the launch log's first line, the stamp file,
# the read tree's HEAD and cleanliness, and whether the q10 directory is tracked.
S=/private/tmp/claude-501/-Users-jasl-Workspaces-cybros-ai-alt2/fe6d4094-2f85-4b52-abfc-78043a70e275/scratchpad/v14
Q=/Users/jasl/Workspaces/cybros-ai.alt2/e2e/artifacts/bench/2026-09-26-q10
REPO=/Users/jasl/Workspaces/cybros-ai.alt2
echo "sha256 of the analyzer:"; shasum -a 256 "$Q/analyze_q10.rb"
echo "pre-launch sha file:"; cat "$S/analyze_q10.sha256"
echo "mtimes (UTC):"
for f in "$S/analyze_q10.sha256" "$Q/analyze_q10.rb" "$Q/dryrun-v13.md" "$Q/logs/launch.txt" "$Q/analysis.md"; do
  TZ=UTC stat -f '  %Sm %N' -t '%Y-%m-%dT%H:%M:%SZ' "$f"
done
echo "bench log first and last lines:"; head -1 "$S/bench-v14.log"; grep BENCH_DONE "$S/bench-v14.log"
python3 - "$S/analyze_q10.sha256" "$S/bench-v14.log" <<'PY'
import os, sys, datetime, re
sha = datetime.datetime.fromtimestamp(os.path.getmtime(sys.argv[1]), datetime.timezone.utc)
start = re.search(r"bench start (\S+)", open(sys.argv[2]).readline()).group(1)
start = datetime.datetime.strptime(start, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
print(f"sha file written {(start - sha).total_seconds():.0f} s before the bench start")
PY
echo "launch.txt:"; cat "$Q/logs/launch.txt"
echo "analysis.md header:"; sed -n 3,7p "$Q/analysis.md"
echo "read tree:"; git -C /Users/jasl/Workspaces/cybros-ai.alt2-q10read rev-parse HEAD; echo "  uncommitted lines: $(git -C /Users/jasl/Workspaces/cybros-ai.alt2-q10read status --short | wc -l | tr -d ' ')"
echo "tracked files under the q10 dir: $(git -C $REPO ls-files e2e/artifacts/bench/2026-09-26-q10 | wc -l | tr -d ' ') ($(git -C $REPO check-ignore -v $Q/analysis.md))"
echo "records' bench digests:"; cat $REPO/e2e/evals/runs/2026-09-26-v14-*/records.jsonl | python3 -c "import sys,json,collections; print(' ', dict(collections.Counter(json.loads(l)['bench_digest'][:12] for l in sys.stdin)))"
```

Output `provenance.out`:

```text
sha256 of the analyzer:
1a3d6a9416229e41ebacc05e153327adc1186c18b1bc62d9bcfd5fbc7d1433e6  /Users/jasl/Workspaces/cybros-ai.alt2/e2e/artifacts/bench/2026-09-26-q10/analyze_q10.rb
pre-launch sha file:
1a3d6a9416229e41ebacc05e153327adc1186c18b1bc62d9bcfd5fbc7d1433e6  e2e/artifacts/bench/2026-09-26-q10/analyze_q10.rb
mtimes (UTC):
  2026-09-25T16:01:57Z /private/tmp/claude-501/-Users-jasl-Workspaces-cybros-ai-alt2/fe6d4094-2f85-4b52-abfc-78043a70e275/scratchpad/v14/analyze_q10.sha256
  2026-09-25T15:03:40Z /Users/jasl/Workspaces/cybros-ai.alt2/e2e/artifacts/bench/2026-09-26-q10/analyze_q10.rb
  2026-09-25T15:03:40Z /Users/jasl/Workspaces/cybros-ai.alt2/e2e/artifacts/bench/2026-09-26-q10/dryrun-v13.md
  2026-09-26T00:54:46Z /Users/jasl/Workspaces/cybros-ai.alt2/e2e/artifacts/bench/2026-09-26-q10/logs/launch.txt
  2026-09-26T00:54:56Z /Users/jasl/Workspaces/cybros-ai.alt2/e2e/artifacts/bench/2026-09-26-q10/analysis.md
bench log first and last lines:
bench start 2026-09-25T16:02:13Z HEAD 4a8cf2ea
BENCH_DONE 2026-09-26T00:52:33Z
sha file written 16 s before the bench start
launch.txt:
head=4a8cf2ea745028d2d5f2839a4d5db3c997c29386
base=4a8cf2ea745028d2d5f2839a4d5db3c997c29386
bench_digest=f69dc4cc6ab489d473fed1ef3e1956149be842ed74656c7ba74514242b23d4ad
bench_version=14
analyzer_sha256=1a3d6a9416229e41ebacc05e153327adc1186c18b1bc62d9bcfd5fbc7d1433e6
stamped_at=2026-09-25T16:01:57Z
reconstructed=written 2026-09-26 after the batch from launch-time facts: the pre-launch sha file (mtime 2026-09-25T16:01:57Z, 16 s before the launch), bench-v14.log line 1 (HEAD 4a8cf2ea at 16:02:13Z), and the records' bench_digest; --stamp was not run before the launch
analysis.md header:
- tree read: `/Users/jasl/Workspaces/cybros-ai.alt2-q10read` at 4a8cf2ea (branch `HEAD`, on main 4a8cf2ea); uncommitted under nexus/ or e2e/: none
- bench.yml: version 14, digest f69dc4cc6ab4
- this file: sha256 1a3d6a9416229e41
- the harness's reader: `E2E::Evals::Predicates.follower_envelopes`, re-read beside this file's on every follower
- stamped 2026-09-25T16:01:57Z at 4a8cf2ea (bench f69dc4cc6ab4); this file is the stamp's
read tree:
4a8cf2ea745028d2d5f2839a4d5db3c997c29386
  uncommitted lines: 0
tracked files under the q10 dir: 0 (e2e/.gitignore:11:/artifacts/	/Users/jasl/Workspaces/cybros-ai.alt2/e2e/artifacts/bench/2026-09-26-q10/analysis.md)
records' bench digests:
  {'f69dc4cc6ab4': 240}
```

### `q10_check.py`

```python
#!/usr/bin/env python3
"""B(1) Q10 re-check, independent of analyze_q10.rb. Over the 24 v14 race-cell records
(compose-race, compose-race-anon; the records file's last line per (task, model, run)):
  (a) followers restated off each trace's graph: a model_task whose input_from or result_from names a
      join_task or one of a join's exits (its structural parents) -- compared with the record's
      `follower_envelopes` keys;
  (b) per follower, the exits it could be delivered: result_from keys read through a join's
      selection (the join task row's result.outcomes 'completed'), result_from exits as named, and
      input_from exits only when their race selected them; the canceled ones among them;
  (c) the recorded fact `follower_envelopes` against `follower_requests` (composed followers);
  (d) the bytes a third way: each follower's sealed request rebuilt from the run's windowed jobs log
      (reducer_bytes.py's method): its `<task_result ...>` user entries and any status="canceled"."""
import json, os, sys, collections
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from reducer_bytes import lines_of, bodies, payload_map, envelope  # noqa: E402
REPO = "/Users/jasl/Workspaces/cybros-ai.alt2/e2e"
LABEL = sys.argv[1] if len(sys.argv) > 1 else "2026-09-26-v14-compose"
CELLS = ("compose-race", "compose-race-anon")

def last_lines(path):
    out = {}
    for l in open(path, encoding="utf-8"):
        r = json.loads(l)
        out[(r["task"], r["model"], r["run"])] = r
    return out

def graph_followers(t):
    nodes = {n["key"]: n for n in t["graph"]["nodes"]}
    parents = collections.defaultdict(list)
    for e in t["graph"]["edges"]:
        if e.get("structural"):
            parents[e["to"]].append(e["from"])
    joins = [k for k, n in nodes.items() if n["kind"] == "join_task"]
    exits = {j: parents[j] for j in joins}
    exit_of = {x: j for j, xs in exits.items() for x in xs}
    rows = {x["key"]: x for x in t["tasks"]}
    winners = {j: [k for k, o in (rows.get(j, {}).get("result") or {}).get("outcomes", {}).items() if o == "completed"] for j in joins}
    out = {}
    for k, n in nodes.items():
        named = n["input_from"] + n["result_from"]
        if n["kind"] != "model_task" or not any(x in joins or x in exit_of for x in named):
            continue
        could = set()
        for x in n["result_from"]:
            could |= set(winners[x]) if x in joins else ({x} if x in exit_of else set())
        could |= {x for x in n["input_from"] if x in exit_of and x in winners[exit_of[x]]}
        canceled = sorted(x for x in could if nodes[x]["status"] == "canceled")
        unselected = sorted(x for x in could if x in exit_of and x not in winners[exit_of[x]])
        stage_exit = any(nodes[x]["kind"] == "script_task" for j in joins for x in exits[j]
                         if j in named or any(y in exits[j] for y in named))
        out[k] = {"spine": n.get("spine"), "could_exits": len(could), "canceled": canceled,
                  "unselected": unselected, "stage_exit": stage_exit}
    return out

def main():
    recs = {k: r for k, r in last_lines(os.path.join(REPO, "evals/runs", LABEL, "records.jsonl")).items() if k[0] in CELLS}
    payloads = payload_map([LABEL])
    tot = collections.Counter()
    print(f"race-cell records: {len(recs)}")
    for (task, model, run), r in sorted(recs.items()):
        stem = os.path.basename(r["artifact"])[:-5]
        t = json.load(open(os.path.join(REPO, "artifacts/evals", LABEL, stem + ".json"), encoding="utf-8"))
        fe = r["facts"].get("follower_envelopes") or {}
        fr = r["facts"].get("follower_requests") or {}
        mine = graph_followers(t)
        by_size = bodies(lines_of(os.path.join(REPO, "artifacts/evals", LABEL, "logs", stem, "nexus.jobs.rails.log")))
        sizes = {x["key"]: x.get("request_bytes") for x in t["tasks"] if x["kind"] == "model_task"}
        tot["records"] += 1
        tot["keys_agree"] += set(mine) == set(fe)
        for k, m in mine.items():
            f = fe.get(k, {}); q = fr.get(k)
            cand = by_size.get(sizes.get(k), [])
            if len(cand) == 1:
                envs = [envelope(payloads[d]) for d in cand[0][1] if d in payloads]
                envs = [e for e in envs if e]
                b_env, b_can = len(envs), sum(1 for e in envs if e[1])
                unknown = sum(1 for d in cand[0][1] if d not in payloads)
            else:
                b_env = b_can = unknown = None
            tot["followers"] += 1
            tot["composed" if m["spine"] is False else "spine"] += 1
            tot["fe_canceled_exits"] += f.get("canceled_exits", 0)
            tot["fe_canceled_other"] += f.get("canceled_other", 0)
            tot["fe_unselected"] += len(f.get("unselected_exits", []))
            tot["fe_stage_exit"] += bool(f.get("stage_exit"))
            tot["graph_canceled"] += len(m["canceled"])
            tot["graph_unselected"] += len(m["unselected"])
            tot["graph_stage_exit"] += m["stage_exit"]
            if q is not None:
                tot["fr_read"] += 1
                tot["fe_fr_agree"] += (q["envelopes"] == f.get("delivered") and len(q["canceled"]) == f.get("canceled_exits", 0) + f.get("canceled_other", 0))
                tot["fr_canceled"] += len(q["canceled"])
            if b_env is not None:
                tot["bytes_read"] += 1
                tot["bytes_agree_fe"] += (b_env == f.get("delivered"))
                tot["bytes_canceled"] += b_can
                tot["bytes_unknown_fragments"] += unknown
                tot["bytes_envelopes"] += b_env
                if m["stage_exit"]:
                    tot["stage_exit_bytes_envelopes"] += b_env
                    tot["stage_exit_bytes_canceled"] += b_can
            print(f"  {task} {model.split('/')[-1]} #{run} {k[:13]:13} {'composed' if m['spine'] is False else 'spine':8} "
                  f"FE delivered={f.get('delivered')} canceled_exits={f.get('canceled_exits')} other={f.get('canceled_other')} "
                  f"stage_exit={f.get('stage_exit')} | FR envelopes={q and q['envelopes']} canceled={q and q['canceled']} | "
                  f"graph could-exits={m['could_exits']} canceled={m['canceled']} | bytes envelopes={b_env} canceled={b_can}")
    print("totals:", dict(tot))

if __name__ == "__main__":
    main()
```

Output `q10_check.out`:

```text
race-cell records: 24
  compose-race deepseek-flash #1 r2t0-model-1  composed FE delivered=1 canceled_exits=0 other=0 stage_exit=False | FR envelopes=1 canceled=[] | graph could-exits=1 canceled=[] | bytes envelopes=1 canceled=0
  compose-race deepseek-flash #2 r2t0-model-1  composed FE delivered=1 canceled_exits=0 other=0 stage_exit=False | FR envelopes=1 canceled=[] | graph could-exits=1 canceled=[] | bytes envelopes=1 canceled=0
  compose-race deepseek-flash #3 r2t0-model-1  composed FE delivered=1 canceled_exits=0 other=0 stage_exit=False | FR envelopes=1 canceled=[] | graph could-exits=1 canceled=[] | bytes envelopes=1 canceled=0
  compose-race kimi-k3 #1 r2t0-model-1  composed FE delivered=1 canceled_exits=0 other=0 stage_exit=False | FR envelopes=1 canceled=[] | graph could-exits=1 canceled=[] | bytes envelopes=1 canceled=0
  compose-race kimi-k3 #2 r2t0-model-1  composed FE delivered=1 canceled_exits=0 other=0 stage_exit=False | FR envelopes=1 canceled=[] | graph could-exits=1 canceled=[] | bytes envelopes=1 canceled=0
  compose-race kimi-k3 #3 r2t0-model-1  composed FE delivered=1 canceled_exits=0 other=0 stage_exit=False | FR envelopes=1 canceled=[] | graph could-exits=1 canceled=[] | bytes envelopes=1 canceled=0
  compose-race glm-5.3 #1 r2t0-model-1  composed FE delivered=1 canceled_exits=0 other=0 stage_exit=False | FR envelopes=1 canceled=[] | graph could-exits=1 canceled=[] | bytes envelopes=1 canceled=0
  compose-race glm-5.3 #3 r2t0-model-1  composed FE delivered=1 canceled_exits=0 other=0 stage_exit=False | FR envelopes=1 canceled=[] | graph could-exits=1 canceled=[] | bytes envelopes=1 canceled=0
  compose-race glm-5.3-flash #1 r2            spine    FE delivered=2 canceled_exits=0 other=0 stage_exit=False | FR envelopes=None canceled=None | graph could-exits=1 canceled=[] | bytes envelopes=2 canceled=0
  compose-race glm-5.3-flash #2 r2            spine    FE delivered=2 canceled_exits=0 other=0 stage_exit=False | FR envelopes=None canceled=None | graph could-exits=1 canceled=[] | bytes envelopes=2 canceled=0
  compose-race-anon deepseek-flash #1 r2t0-model-1  composed FE delivered=1 canceled_exits=0 other=0 stage_exit=False | FR envelopes=1 canceled=[] | graph could-exits=1 canceled=[] | bytes envelopes=1 canceled=0
  compose-race-anon deepseek-flash #2 r2            spine    FE delivered=2 canceled_exits=0 other=0 stage_exit=False | FR envelopes=None canceled=None | graph could-exits=1 canceled=[] | bytes envelopes=2 canceled=0
  compose-race-anon deepseek-flash #3 r2t0-model-1  composed FE delivered=1 canceled_exits=0 other=0 stage_exit=False | FR envelopes=1 canceled=[] | graph could-exits=1 canceled=[] | bytes envelopes=1 canceled=0
  compose-race-anon kimi-k3 #1 r2t0-model-1  composed FE delivered=1 canceled_exits=0 other=0 stage_exit=False | FR envelopes=1 canceled=[] | graph could-exits=1 canceled=[] | bytes envelopes=1 canceled=0
  compose-race-anon kimi-k3 #2 r2            spine    FE delivered=2 canceled_exits=0 other=0 stage_exit=False | FR envelopes=None canceled=None | graph could-exits=1 canceled=[] | bytes envelopes=2 canceled=0
  compose-race-anon kimi-k3 #3 r2t0-model-1  composed FE delivered=1 canceled_exits=0 other=0 stage_exit=False | FR envelopes=1 canceled=[] | graph could-exits=1 canceled=[] | bytes envelopes=1 canceled=0
  compose-race-anon glm-5.3 #1 r2t0-model-1  composed FE delivered=1 canceled_exits=0 other=0 stage_exit=False | FR envelopes=1 canceled=[] | graph could-exits=1 canceled=[] | bytes envelopes=1 canceled=0
  compose-race-anon glm-5.3 #2 01a0da0d-c77d composed FE delivered=1 canceled_exits=0 other=0 stage_exit=False | FR envelopes=1 canceled=[] | graph could-exits=1 canceled=[] | bytes envelopes=1 canceled=0
  compose-race-anon glm-5.3 #3 r2t0-model-1  composed FE delivered=1 canceled_exits=0 other=0 stage_exit=False | FR envelopes=1 canceled=[] | graph could-exits=1 canceled=[] | bytes envelopes=1 canceled=0
  compose-race-anon glm-5.3-flash #1 r2t0-model-1  composed FE delivered=1 canceled_exits=0 other=0 stage_exit=False | FR envelopes=1 canceled=[] | graph could-exits=1 canceled=[] | bytes envelopes=1 canceled=0
  compose-race-anon glm-5.3-flash #2 r2            spine    FE delivered=2 canceled_exits=0 other=0 stage_exit=False | FR envelopes=None canceled=None | graph could-exits=1 canceled=[] | bytes envelopes=2 canceled=0
  compose-race-anon glm-5.3-flash #3 r2            spine    FE delivered=2 canceled_exits=0 other=0 stage_exit=False | FR envelopes=None canceled=None | graph could-exits=1 canceled=[] | bytes envelopes=2 canceled=0
totals: {'records': 24, 'keys_agree': 24, 'followers': 22, 'composed': 16, 'fe_canceled_exits': 0, 'fe_canceled_other': 0, 'fe_unselected': 0, 'fe_stage_exit': 0, 'graph_canceled': 0, 'graph_unselected': 0, 'graph_stage_exit': 0, 'fr_read': 16, 'fe_fr_agree': 16, 'fr_canceled': 0, 'bytes_read': 22, 'bytes_agree_fe': 22, 'bytes_canceled': 0, 'bytes_unknown_fragments': 0, 'bytes_envelopes': 28, 'spine': 6}
```

Output `q10_check.v13.out`:

```text
race-cell records: 24
  compose-race deepseek-flash #1 r3t0-model-1  composed FE delivered=None canceled_exits=None other=None stage_exit=None | FR envelopes=None canceled=None | graph could-exits=3 canceled=['01a0d536-6fd2-7c01-9f01-48b799c9cae6', '01a0d536-70aa-7f8a-be7b-430b23ebddf3'] | bytes envelopes=3 canceled=2
  compose-race deepseek-flash #2 r2            spine    FE delivered=None canceled_exits=None other=None stage_exit=None | FR envelopes=None canceled=None | graph could-exits=1 canceled=[] | bytes envelopes=2 canceled=0
  compose-race deepseek-flash #3 r2t0-model-1  composed FE delivered=None canceled_exits=None other=None stage_exit=None | FR envelopes=None canceled=None | graph could-exits=3 canceled=['01a0d537-62fb-7bbb-a2b0-3b174a8dcf7f', '01a0d537-63b2-7818-a3c9-34bac1450215'] | bytes envelopes=3 canceled=2
  compose-race kimi-k3 #1 r2            spine    FE delivered=None canceled_exits=None other=None stage_exit=None | FR envelopes=None canceled=None | graph could-exits=1 canceled=[] | bytes envelopes=2 canceled=0
  compose-race kimi-k3 #2 r2            spine    FE delivered=None canceled_exits=None other=None stage_exit=None | FR envelopes=None canceled=None | graph could-exits=1 canceled=[] | bytes envelopes=2 canceled=0
  compose-race kimi-k3 #3 r2            spine    FE delivered=None canceled_exits=None other=None stage_exit=None | FR envelopes=None canceled=None | graph could-exits=1 canceled=[] | bytes envelopes=2 canceled=0
  compose-race glm-5.3 #1 r2t0-model-1  composed FE delivered=None canceled_exits=None other=None stage_exit=None | FR envelopes=None canceled=None | graph could-exits=1 canceled=[] | bytes envelopes=1 canceled=0
  compose-race glm-5.3 #3 r2t0-model-1  composed FE delivered=None canceled_exits=None other=None stage_exit=None | FR envelopes=None canceled=None | graph could-exits=1 canceled=[] | bytes envelopes=1 canceled=0
  compose-race glm-5.3-flash #1 r3            spine    FE delivered=None canceled_exits=None other=None stage_exit=None | FR envelopes=None canceled=None | graph could-exits=1 canceled=[] | bytes envelopes=2 canceled=0
  compose-race glm-5.3-flash #3 r2t0-model-1  composed FE delivered=None canceled_exits=None other=None stage_exit=None | FR envelopes=None canceled=None | graph could-exits=1 canceled=[] | bytes envelopes=1 canceled=0
  compose-race-anon deepseek-flash #1 r2t0-model-1  composed FE delivered=None canceled_exits=None other=None stage_exit=None | FR envelopes=None canceled=None | graph could-exits=3 canceled=['01a0d54b-a7ad-72eb-9724-d9784879cd30', '01a0d54b-a86e-7706-8c6c-2a820d6b3914'] | bytes envelopes=3 canceled=2
  compose-race-anon deepseek-flash #2 r2            spine    FE delivered=None canceled_exits=None other=None stage_exit=None | FR envelopes=None canceled=None | graph could-exits=1 canceled=[] | bytes envelopes=2 canceled=0
  compose-race-anon deepseek-flash #3 r3t0-model-1  composed FE delivered=None canceled_exits=None other=None stage_exit=None | FR envelopes=None canceled=None | graph could-exits=3 canceled=['r3t0-script-1', 'r3t0-script-3'] | bytes envelopes=4 canceled=2
  compose-race-anon kimi-k3 #1 r2            spine    FE delivered=None canceled_exits=None other=None stage_exit=None | FR envelopes=None canceled=None | graph could-exits=1 canceled=[] | bytes envelopes=2 canceled=0
  compose-race-anon kimi-k3 #2 r2            spine    FE delivered=None canceled_exits=None other=None stage_exit=None | FR envelopes=None canceled=None | graph could-exits=1 canceled=[] | bytes envelopes=2 canceled=0
  compose-race-anon kimi-k3 #3 r2            spine    FE delivered=None canceled_exits=None other=None stage_exit=None | FR envelopes=None canceled=None | graph could-exits=1 canceled=[] | bytes envelopes=2 canceled=0
  compose-race-anon glm-5.3 #1 r2            spine    FE delivered=None canceled_exits=None other=None stage_exit=None | FR envelopes=None canceled=None | graph could-exits=3 canceled=['r2t0-script-1', 'r2t0-script-3'] | bytes envelopes=5 canceled=2
  compose-race-anon glm-5.3-flash #2 r2t0-model-1  composed FE delivered=None canceled_exits=None other=None stage_exit=None | FR envelopes=None canceled=None | graph could-exits=1 canceled=[] | bytes envelopes=1 canceled=0
totals: {'records': 24, 'keys_agree': 6, 'followers': 18, 'composed': 8, 'fe_canceled_exits': 0, 'fe_canceled_other': 0, 'fe_unselected': 0, 'fe_stage_exit': 0, 'graph_canceled': 10, 'graph_unselected': 10, 'graph_stage_exit': 5, 'bytes_read': 18, 'bytes_agree_fe': 0, 'bytes_canceled': 10, 'bytes_unknown_fragments': 0, 'bytes_envelopes': 40, 'stage_exit_bytes_envelopes': 18, 'stage_exit_bytes_canceled': 10, 'spine': 10}
```

### `q10_beside.py`

```python
#!/usr/bin/env python3
"""B(1) resolution 6 re-derived: the race cells' success, picture, no_wrong_winner, authored_labels,
success_filter and losers_completed == 0 per model, v14 against v13 (last line per key), printed in
analysis.md §6's own line format and diffed against that file's §6 lines."""
import json, re
RUNS = "/Users/jasl/Workspaces/cybros-ai.alt2/e2e/evals/runs"
ANALYSIS = "/Users/jasl/Workspaces/cybros-ai.alt2/e2e/artifacts/bench/2026-09-26-q10/analysis.md"
MODELS = ["openrouter/z-ai/glm-5.3", "openrouter/moonshotai/kimi-k3", "deepseek/deepseek-flash", "openrouter/z-ai/glm-5.3-flash"]
READS = [("success", lambda r: r["verdict"]["succeeded"] is True), ("picture", lambda r: r["facts"].get("picture") is True),
         ("no_wrong_winner", lambda r: (r.get("conduct") or {}).get("no_wrong_winner") is True),
         ("authored_labels", lambda r: r["facts"].get("authored_labels") is True),
         ("success_filter", lambda r: r["facts"].get("success_filter") is True),
         ("losers_completed == 0", lambda r: r["facts"].get("losers_completed") == 0)]
def last(label):
    d = {}
    for l in open(f"{RUNS}/{label}/records.jsonl", encoding="utf-8"):
        r = json.loads(l); d[(r["task"], r["model"], r["run"])] = r
    return d
v13, v14 = last("2026-09-25-v13-compose"), last("2026-09-26-v14-compose")
mine = []
for cell in ("compose-race", "compose-race-anon"):
    for name, f in READS:
        cols = []
        for recs in (v14, v13):
            cols.append(", ".join(f"{m.split('/')[-1]} {sum(1 for i in (1, 2, 3) if f(recs[(cell, m, i)]))}/3" for m in MODELS))
        mine.append(f"- {cell} {name}: v14 {cols[0]} — v13 {cols[1]}")
theirs = [l.rstrip("\n") for l in open(ANALYSIS, encoding="utf-8") if re.match(r"- compose-race(-anon)? ", l)]
for l in mine:
    print(("same   " if l in theirs else "DIFFERS") + " " + l)
print(f"{sum(1 for l in mine if l in theirs)} of {len(mine)} lines identical to analysis.md §6 ({len(theirs)} lines there)")
```

Output `q10_beside.out`:

```text
same    - compose-race success: v14 glm-5.3 3/3, kimi-k3 3/3, deepseek-flash 3/3, glm-5.3-flash 3/3 — v13 glm-5.3 3/3, kimi-k3 3/3, deepseek-flash 3/3, glm-5.3-flash 3/3
same    - compose-race picture: v14 glm-5.3 3/3, kimi-k3 3/3, deepseek-flash 3/3, glm-5.3-flash 2/3 — v13 glm-5.3 3/3, kimi-k3 3/3, deepseek-flash 2/3, glm-5.3-flash 2/3
same    - compose-race no_wrong_winner: v14 glm-5.3 3/3, kimi-k3 3/3, deepseek-flash 3/3, glm-5.3-flash 3/3 — v13 glm-5.3 3/3, kimi-k3 3/3, deepseek-flash 3/3, glm-5.3-flash 3/3
same    - compose-race authored_labels: v14 glm-5.3 1/3, kimi-k3 0/3, deepseek-flash 0/3, glm-5.3-flash 2/3 — v13 glm-5.3 1/3, kimi-k3 3/3, deepseek-flash 3/3, glm-5.3-flash 2/3
same    - compose-race success_filter: v14 glm-5.3 0/3, kimi-k3 0/3, deepseek-flash 0/3, glm-5.3-flash 1/3 — v13 glm-5.3 0/3, kimi-k3 0/3, deepseek-flash 2/3, glm-5.3-flash 0/3
same    - compose-race losers_completed == 0: v14 glm-5.3 3/3, kimi-k3 3/3, deepseek-flash 3/3, glm-5.3-flash 3/3 — v13 glm-5.3 3/3, kimi-k3 3/3, deepseek-flash 3/3, glm-5.3-flash 3/3
same    - compose-race-anon success: v14 glm-5.3 3/3, kimi-k3 3/3, deepseek-flash 3/3, glm-5.3-flash 3/3 — v13 glm-5.3 3/3, kimi-k3 3/3, deepseek-flash 3/3, glm-5.3-flash 3/3
same    - compose-race-anon picture: v14 glm-5.3 3/3, kimi-k3 3/3, deepseek-flash 3/3, glm-5.3-flash 3/3 — v13 glm-5.3 3/3, kimi-k3 3/3, deepseek-flash 2/3, glm-5.3-flash 3/3
same    - compose-race-anon no_wrong_winner: v14 glm-5.3 2/3, kimi-k3 3/3, deepseek-flash 3/3, glm-5.3-flash 3/3 — v13 glm-5.3 3/3, kimi-k3 3/3, deepseek-flash 3/3, glm-5.3-flash 3/3
same    - compose-race-anon authored_labels: v14 glm-5.3 0/3, kimi-k3 1/3, deepseek-flash 1/3, glm-5.3-flash 1/3 — v13 glm-5.3 3/3, kimi-k3 3/3, deepseek-flash 3/3, glm-5.3-flash 3/3
same    - compose-race-anon success_filter: v14 glm-5.3 0/3, kimi-k3 0/3, deepseek-flash 0/3, glm-5.3-flash 0/3 — v13 glm-5.3 1/3, kimi-k3 0/3, deepseek-flash 2/3, glm-5.3-flash 0/3
same    - compose-race-anon losers_completed == 0: v14 glm-5.3 3/3, kimi-k3 3/3, deepseek-flash 3/3, glm-5.3-flash 3/3 — v13 glm-5.3 3/3, kimi-k3 3/3, deepseek-flash 3/3, glm-5.3-flash 3/3
12 of 12 lines identical to analysis.md §6 (12 lines there)
```

### `racewinner_probe.rb`

```ruby
# B(1) aside: Claims::RaceWinner over compose-race-anon glm-5.3 #1's recorded reply, as recorded and with
# the probe's command line left in (no strip), to show where the red comes from. Reads only.
require "json"
require "/Users/jasl/Workspaces/cybros-ai.alt2/e2e/support/evals"
rec = File.readlines("/Users/jasl/Workspaces/cybros-ai.alt2/e2e/evals/runs/2026-09-26-v14-compose/records.jsonl", encoding: "UTF-8")
  .map { |l| JSON.parse(l) }.reverse.find { |r| r["task"] == "compose-race-anon" && r["model"] == "openrouter/z-ai/glm-5.3" && r["run"] == 1 }
reply = rec.dig("facts", "reply")
C = E2E::Evals::Claims
puts "as the lane reads it: #{C::RaceWinner.check(reply).inspect}"
puts "without the command-line strip: #{C.check(C::RaceWinner::QUESTION, reply).inspect}"
puts "the sentence without its last clause: #{C::RaceWinner.check(reply.sub(/, so the fan settled on it and stopped waiting on alpha and charlie/, '')).inspect}"
```

Output `racewinner_probe.out`:

```text
as the lane reads it: "the reply ties alpha to `won`: \"`bin/probe` was the first to respond (returned \\\"200 OK\\\" in 2 seconds), so the fan settled on it and stopped waiting on alpha and charlie.\""
without the command-line strip: true
the sentence without its last clause: true
```

### `labels.py`

```python
#!/usr/bin/env python3
"""B(2) T1 in vivo: `facts.authored_labels` on compose-race and compose-race-anon, v13 (each key's LAST
line: v13 was rescored in place by 563a86aa and 5de9f94a) against v14, per model. Also prints how many
lines each v13 key carries, and which v14 runs author labels."""
import json, collections
RUNS = "/Users/jasl/Workspaces/cybros-ai.alt2/e2e/evals/runs"
CELLS = ("compose-race", "compose-race-anon")
MODELS = ["openrouter/z-ai/glm-5.3", "openrouter/moonshotai/kimi-k3", "deepseek/deepseek-flash", "openrouter/z-ai/glm-5.3-flash"]

def last(label):
    out, n = {}, collections.Counter()
    for l in open(f"{RUNS}/{label}/records.jsonl", encoding="utf-8"):
        r = json.loads(l)
        k = (r["task"], r["model"], r["run"])
        out[k] = r; n[k] += 1
    return out, n

v13, n13 = last("2026-09-25-v13-compose")
v14, n14 = last("2026-09-26-v14-compose")
for cell in CELLS:
    print(f"== {cell}")
    for label, recs in (("v13", v13), ("v14", v14)):
        row, tot = [], 0
        for m in MODELS:
            vals = [recs[(cell, m, i)]["facts"].get("authored_labels") for i in (1, 2, 3)]
            k = sum(1 for v in vals if v is True); tot += k
            row.append(f"{m.split('/')[-1]} {k}/3 {vals}")
        print(f"  {label}: {tot}/12 | " + " | ".join(row))
    print("  v13 lines per key:", sorted(collections.Counter(n13[(cell, m, i)] for m in MODELS for i in (1, 2, 3)).items()))
    print("  v14 runs authoring labels:", [f"{m.split('/')[-1]}#{i}" for m in MODELS for i in (1, 2, 3) if v14[(cell, m, i)]["facts"].get("authored_labels") is True])
    print("  v14 runs, follower kind:", {f"{m.split('/')[-1]}#{i}": ("none" if not v14[(cell, m, i)]["facts"].get("follower_envelopes") else
          ("spine" if not v14[(cell, m, i)]["facts"].get("follower_requests") else "composed")) for m in MODELS for i in (1, 2, 3)})

# compose calls per run (facts.called.compose) beside the label fact, v13 and v14
for cell in CELLS:
    for label, recs in (("v13", v13), ("v14", v14)):
        calls = collections.Counter(recs[(cell, m, i)]["facts"].get("called", {}).get("compose", 0) for m in MODELS for i in (1, 2, 3))
        multi = [f"{m.split('/')[-1]}#{i}(labels={recs[(cell, m, i)]['facts'].get('authored_labels')})" for m in MODELS for i in (1, 2, 3)
                 if recs[(cell, m, i)]["facts"].get("called", {}).get("compose", 0) > 1]
        print(f"  {cell} {label}: compose calls per run {dict(sorted(calls.items()))}; runs with >1 call {multi}")
```

Output `labels.out`:

```text
== compose-race
  v13: 9/12 | glm-5.3 1/3 [False, True, False] | kimi-k3 3/3 [True, True, True] | deepseek-flash 3/3 [True, True, True] | glm-5.3-flash 2/3 [True, True, False]
  v14: 3/12 | glm-5.3 1/3 [False, True, False] | kimi-k3 0/3 [False, False, False] | deepseek-flash 0/3 [False, False, False] | glm-5.3-flash 2/3 [True, False, True]
  v13 lines per key: [(1, 11), (2, 1)]
  v14 runs authoring labels: ['glm-5.3#2', 'glm-5.3-flash#1', 'glm-5.3-flash#3']
  v14 runs, follower kind: {'glm-5.3#1': 'composed', 'glm-5.3#2': 'none', 'glm-5.3#3': 'composed', 'kimi-k3#1': 'composed', 'kimi-k3#2': 'composed', 'kimi-k3#3': 'composed', 'deepseek-flash#1': 'composed', 'deepseek-flash#2': 'composed', 'deepseek-flash#3': 'composed', 'glm-5.3-flash#1': 'spine', 'glm-5.3-flash#2': 'spine', 'glm-5.3-flash#3': 'none'}
== compose-race-anon
  v13: 12/12 | glm-5.3 3/3 [True, True, True] | kimi-k3 3/3 [True, True, True] | deepseek-flash 3/3 [True, True, True] | glm-5.3-flash 3/3 [True, True, True]
  v14: 3/12 | glm-5.3 0/3 [False, False, False] | kimi-k3 1/3 [False, True, False] | deepseek-flash 1/3 [False, True, False] | glm-5.3-flash 1/3 [False, False, True]
  v13 lines per key: [(1, 12)]
  v14 runs authoring labels: ['kimi-k3#2', 'deepseek-flash#2', 'glm-5.3-flash#3']
  v14 runs, follower kind: {'glm-5.3#1': 'composed', 'glm-5.3#2': 'composed', 'glm-5.3#3': 'composed', 'kimi-k3#1': 'composed', 'kimi-k3#2': 'spine', 'kimi-k3#3': 'composed', 'deepseek-flash#1': 'composed', 'deepseek-flash#2': 'spine', 'deepseek-flash#3': 'composed', 'glm-5.3-flash#1': 'composed', 'glm-5.3-flash#2': 'spine', 'glm-5.3-flash#3': 'spine'}
  compose-race v13: compose calls per run {1: 10, 2: 2}; runs with >1 call ['deepseek-flash#1(labels=True)', 'glm-5.3-flash#1(labels=True)']
  compose-race v14: compose calls per run {1: 11, 2: 1}; runs with >1 call ['glm-5.3-flash#3(labels=True)']
  compose-race-anon v13: compose calls per run {1: 11, 2: 1}; runs with >1 call ['deepseek-flash#3(labels=True)']
  compose-race-anon v14: compose calls per run {1: 12}; runs with >1 call []
```

Output `t1_ab_lines.out`:

```text
| (1) O3 `authored_labels`, built first scripts, four models | 19/36 (52.8 %) | 4/45 (8.9 %) | drop +43.9 (+31.2) | holds (`:36-39`) |
- The endpoint per model (`:36-37`): glm-5.3 went from 10/12 to 1/12, kimi-k3 3/7 → 2/11, deepseek-flash
  5/9 → 0/11 and glm-5.3-flash 1/8 → 1/11. Over judged scripts it reads 27/46 → 7/48 (`:49`).
```

### `v13_lines.py`

```python
#!/usr/bin/env python3
"""The v13 column's shape: keys per family, keys carrying more than one line (rescored in place), the lines
each rescore commit appended per task (`git show <commit>` of the records files), and whether any race key's
`authored_labels` differs between its lines."""
import json, subprocess, collections
REPO = "/Users/jasl/Workspaces/cybros-ai.alt2"
for fam in ("compose", "task", "workflow"):
    lines = collections.defaultdict(list)
    for l in open(f"{REPO}/e2e/evals/runs/2026-09-25-v13-{fam}/records.jsonl", encoding="utf-8"):
        r = json.loads(l); lines[(r["task"], r["model"], r["run"])].append(r)
    multi = {k: v for k, v in lines.items() if len(v) > 1}
    print(f"v13 {fam}: {len(lines)} keys, {len(multi)} with more than one line; by task {dict(collections.Counter(k[0] for k in multi))}")
    moved = sum(1 for v in multi.values() if any((x["verdict"], x.get("reason")) != (v[0]["verdict"], v[0].get("reason")) for x in v))
    print(f"   of those, keys whose verdict or reason differs between lines: {moved}")
    for k, v in multi.items():
        if k[0].startswith("compose-race"):
            print(f"   {k}: authored_labels per line {[x['facts'].get('authored_labels') for x in v]}")
for commit in ("563a86aa", "5de9f94a"):
    diff = subprocess.run(["git", "-C", REPO, "show", commit, "--format=", "--", "e2e/evals/runs/2026-09-25-v13-*/records.jsonl"], capture_output=True, text=True, check=True).stdout
    added, current = collections.Counter(), None
    for l in diff.splitlines():
        if l.startswith("+++ "):
            current = l.split("/")[-2]
        elif l.startswith("+") and not l.startswith("+++") and current and current.startswith("2026-09-25-v13"):
            added[(current, json.loads(l[1:])["task"])] += 1
    print(f"{commit} appended: {dict(added)} (total {sum(added.values())})")
```

Output `v13_lines.out`:

```text
v13 compose: 108 keys, 31 with more than one line; by task {'compose-background-suite': 7, 'compose-grep-then-edit': 10, 'compose-race': 1, 'compose-rendezvous': 12, 'compose-three-stage-pairing': 1}
   of those, keys whose verdict or reason differs between lines: 11
   ('compose-race', 'openrouter/z-ai/glm-5.3-flash', 1): authored_labels per line [True, True]
v13 task: 72 keys, 12 with more than one line; by task {'task-fan-five': 12}
   of those, keys whose verdict or reason differs between lines: 0
v13 workflow: 60 keys, 12 with more than one line; by task {'workflow-adversarial-verify': 12}
   of those, keys whose verdict or reason differs between lines: 9
563a86aa appended: {('2026-09-25-v13-compose', 'compose-background-suite'): 1, ('2026-09-25-v13-compose', 'compose-grep-then-edit'): 2, ('2026-09-25-v13-compose', 'compose-race'): 1, ('2026-09-25-v13-compose', 'compose-rendezvous'): 12, ('2026-09-25-v13-compose', 'compose-three-stage-pairing'): 1, ('2026-09-25-v13-task', 'task-fan-five'): 12, ('2026-09-25-v13-workflow', 'workflow-adversarial-verify'): 5} (total 34)
5de9f94a appended: {('2026-09-25-v13-compose', 'compose-background-suite'): 6, ('2026-09-25-v13-compose', 'compose-grep-then-edit'): 8, ('2026-09-25-v13-workflow', 'workflow-adversarial-verify'): 12} (total 26)
```

### `reducers.py`

```python
#!/usr/bin/env python3
"""B(3) graph census: reducer rows = a model step whose `result_from` names the model step whose round it
continues (its history source: the first model_task among its input_from, the kernel's `model_source`),
that source completed. Counted per (task, model, run) trace, over v13 and v14 compose/workflow."""
import json, glob, os, collections, sys
ROOT = "/Users/jasl/Workspaces/cybros-ai.alt2/e2e/artifacts/evals"
LABELS = sys.argv[1:] or ["2026-09-25-v13-compose", "2026-09-25-v13-workflow", "2026-09-26-v14-compose", "2026-09-26-v14-workflow"]

def reducer_rows(graph):
    nodes = {n["key"]: n for n in graph.get("nodes", [])}
    rows = []
    for n in nodes.values():
        if n.get("kind") != "model_task":
            continue
        hist = next((k for k in n.get("input_from", []) if nodes.get(k, {}).get("kind") == "model_task"), None)
        if hist and hist in n.get("result_from", []) and nodes[hist].get("status") == "completed":
            rows.append((n["key"], hist, n.get("status"), len(n.get("result_from", []))))
    return rows

def main():
  for label in LABELS:
      files = sorted(glob.glob(os.path.join(ROOT, label, "*.nexus.*.json")))
      per_task = collections.Counter(); total = 0; with_shape = 0; detail = []
      for f in files:
          t = json.load(open(f, encoding="utf-8"))
          total += 1
          rows = reducer_rows(t.get("graph") or {})
          if rows:
              with_shape += 1
              per_task[t["record"]["task"]] += 1
              detail.append((os.path.basename(f), rows))
      print(f"{label}: traces {total}, with a reducer row {with_shape}; per task {dict(sorted(per_task.items()))}")
      for name, rows in detail:
          print("   ", name.replace(".nexus.", "#").replace(".json", ""), rows)

if __name__ == "__main__":
    main()
```

Output `reducers.out`:

```text
2026-09-25-v13-compose: traces 108, with a reducer row 28; per task {'compose-background-suite': 5, 'compose-rendezvous': 9, 'compose-review-angles': 5, 'compose-three-stage-pairing': 2, 'compose-two-source-fan-in': 7}
    compose-background-suite.deepseek_deepseek-flash#1 [('r3t0-model-2', 'r12', 'completed', 3)]
    compose-background-suite.openrouter_moonshotai_kimi-k3#2 [('r2t0-model-2', 'r5', 'completed', 3)]
    compose-background-suite.openrouter_moonshotai_kimi-k3#3 [('r2t0-model-3', 'r2t0-model-2', 'completed', 4)]
    compose-background-suite.openrouter_z-ai_glm-5.3-flash#2 [('r2t0-model-3', 'r9', 'completed', 2)]
    compose-background-suite.openrouter_z-ai_glm-5.3#1 [('r2t0-model-2', 'r5', 'completed', 2)]
    compose-rendezvous.deepseek_deepseek-flash#2 [('r2t0-model-3', 'r6', 'completed', 2)]
    compose-rendezvous.deepseek_deepseek-flash#3 [('r2t0-model-3', 'r2t0-model-1', 'completed', 2)]
    compose-rendezvous.openrouter_moonshotai_kimi-k3#1 [('r2t0-model-3', 'r2t0-model-1', 'completed', 2)]
    compose-rendezvous.openrouter_moonshotai_kimi-k3#2 [('r2t0-model-3', 'r10', 'completed', 2)]
    compose-rendezvous.openrouter_moonshotai_kimi-k3#3 [('r2t0-model-3', 'r2t0-model-1', 'completed', 2)]
    compose-rendezvous.openrouter_z-ai_glm-5.3-flash#2 [('01a0d571-e951-7919-a14a-229593ea362d', '01a0d571-e951-77ee-b124-943c2c0ffca7', 'completed', 2)]
    compose-rendezvous.openrouter_z-ai_glm-5.3#1 [('r2t0-model-3', 'r2t0-model-1', 'completed', 2)]
    compose-rendezvous.openrouter_z-ai_glm-5.3#2 [('r2t0-model-3', 'r2t0-model-1', 'completed', 2)]
    compose-rendezvous.openrouter_z-ai_glm-5.3#3 [('01a0d558-3859-7e43-905f-d2cb9fc7f379', '01a0d558-3859-700d-93dd-6fbc8dae820f', 'completed', 2)]
    compose-review-angles.deepseek_deepseek-flash#1 [('r2t0-model-4', 'r5', 'completed', 3)]
    compose-review-angles.deepseek_deepseek-flash#3 [('r2t0-model-4', 'r4', 'completed', 3)]
    compose-review-angles.openrouter_moonshotai_kimi-k3#1 [('r2t0-model-4', 'r4', 'completed', 3)]
    compose-review-angles.openrouter_z-ai_glm-5.3-flash#1 [('r3t0-model-4', 'r9', 'completed', 3)]
    compose-review-angles.openrouter_z-ai_glm-5.3#3 [('r3t0-model-4', 'r4', 'completed', 3)]
    compose-three-stage-pairing.deepseek_deepseek-flash#1 [('r2t0-model-4', 'r2t0-model-1', 'completed', 3)]
    compose-three-stage-pairing.openrouter_moonshotai_kimi-k3#2 [('r2t0-model-4', 'r2t0-model-1', 'completed', 3)]
    compose-two-source-fan-in.openrouter_moonshotai_kimi-k3#1 [('r2t0-model-3', 'r2t0-model-1', 'completed', 2)]
    compose-two-source-fan-in.openrouter_moonshotai_kimi-k3#2 [('r2t0-model-3', 'r2t0-model-1', 'completed', 2)]
    compose-two-source-fan-in.openrouter_moonshotai_kimi-k3#3 [('r2t0-model-3', 'r2t0-model-1', 'completed', 2)]
    compose-two-source-fan-in.openrouter_z-ai_glm-5.3-flash#2 [('r2t0-model-3', 'r2t0-model-1', 'completed', 2)]
    compose-two-source-fan-in.openrouter_z-ai_glm-5.3-flash#3 [('r2t0-model-3', 'r2t0-model-1', 'completed', 2)]
    compose-two-source-fan-in.openrouter_z-ai_glm-5.3#1 [('r2t0-model-3', 'r2t0-model-1', 'completed', 2)]
    compose-two-source-fan-in.openrouter_z-ai_glm-5.3#3 [('r2t0-model-3', 'r2t0-model-2', 'completed', 2)]
2026-09-25-v13-workflow: traces 60, with a reducer row 4; per task {'workflow-judge-panel': 4}
    workflow-judge-panel.deepseek_deepseek-flash#1 [('r3t0-model-4', 'r9', 'completed', 3)]
    workflow-judge-panel.openrouter_z-ai_glm-5.3-flash#2 [('r4t0-model-4', 'r14', 'completed', 3)]
    workflow-judge-panel.openrouter_z-ai_glm-5.3-flash#3 [('r3t1-model-4', 'r7', 'completed', 3)]
    workflow-judge-panel.openrouter_z-ai_glm-5.3#3 [('01a0d636-4ac3-77c7-8c32-333535fbe245', 'r16', 'completed', 3)]
2026-09-26-v14-compose: traces 108, with a reducer row 26; per task {'compose-background-suite': 2, 'compose-rendezvous': 5, 'compose-review-angles': 8, 'compose-three-stage-pairing': 4, 'compose-two-source-fan-in': 7}
    compose-background-suite.deepseek_deepseek-flash#3 [('r2t0-model-2', 'r9', 'completed', 2)]
    compose-background-suite.openrouter_z-ai_glm-5.3#3 [('r2t0-model-2', 'r8', 'completed', 3)]
    compose-rendezvous.deepseek_deepseek-flash#1 [('r2t0-model-3', 'r8', 'completed', 2)]
    compose-rendezvous.deepseek_deepseek-flash#3 [('r2t0-model-3', 'r2t0-model-1', 'completed', 2)]
    compose-rendezvous.openrouter_moonshotai_kimi-k3#2 [('r2t0-model-3', 'r2t0-model-1', 'completed', 2)]
    compose-rendezvous.openrouter_z-ai_glm-5.3#2 [('r2t0-model-3', 'r2t0-model-1', 'completed', 2)]
    compose-rendezvous.openrouter_z-ai_glm-5.3#3 [('r2t0-model-3', 'r2t0-model-1', 'completed', 2)]
    compose-review-angles.deepseek_deepseek-flash#1 [('r2t0-model-4', 'r11', 'completed', 3)]
    compose-review-angles.deepseek_deepseek-flash#2 [('r2t0-model-4', 'r10', 'completed', 3)]
    compose-review-angles.deepseek_deepseek-flash#3 [('r2t0-model-4', 'r4', 'completed', 3)]
    compose-review-angles.openrouter_moonshotai_kimi-k3#1 [('r2t0-model-4', 'r3', 'completed', 3)]
    compose-review-angles.openrouter_moonshotai_kimi-k3#2 [('r2t0-model-4', 'r3', 'completed', 3)]
    compose-review-angles.openrouter_moonshotai_kimi-k3#3 [('r2t0-model-4', 'r3', 'completed', 3)]
    compose-review-angles.openrouter_z-ai_glm-5.3-flash#1 [('r2t0-model-4', 'r8', 'completed', 3)]
    compose-review-angles.openrouter_z-ai_glm-5.3#2 [('r2t0-model-4', 'r10', 'completed', 3)]
    compose-three-stage-pairing.deepseek_deepseek-flash#1 [('r2t0-model-4', 'r2t0-model-1', 'completed', 3)]
    compose-three-stage-pairing.deepseek_deepseek-flash#2 [('r2t0-model-4', 'r2t0-model-1', 'completed', 3)]
    compose-three-stage-pairing.deepseek_deepseek-flash#3 [('01a0da7a-e420-7303-a4cf-338e389b2ebc', '01a0da7a-e41f-7e17-b394-651f2d87a5dc', 'completed', 3)]
    compose-three-stage-pairing.openrouter_z-ai_glm-5.3#1 [('r2t0-model-4', 'r2t0-model-1', 'completed', 3)]
    compose-two-source-fan-in.deepseek_deepseek-flash#2 [('r2t0-model-3', 'r2t0-model-1', 'completed', 2)]
    compose-two-source-fan-in.deepseek_deepseek-flash#3 [('r2t0-model-3', 'r2t0-model-1', 'completed', 2)]
    compose-two-source-fan-in.openrouter_moonshotai_kimi-k3#2 [('r2t0-model-3', 'r2t0-model-1', 'completed', 2)]
    compose-two-source-fan-in.openrouter_moonshotai_kimi-k3#3 [('r2t0-model-3', 'r2t0-model-1', 'completed', 2)]
    compose-two-source-fan-in.openrouter_z-ai_glm-5.3-flash#2 [('r2t0-model-3', 'r2t0-model-1', 'completed', 2)]
    compose-two-source-fan-in.openrouter_z-ai_glm-5.3#1 [('01a0da8a-03d8-767e-a0ac-6b598ba7717b', '01a0da8a-03d8-7d2e-a0da-329f79ccafc5', 'completed', 2)]
    compose-two-source-fan-in.openrouter_z-ai_glm-5.3#3 [('r2t0-model-3', 'r2t0-model-1', 'completed', 2)]
2026-09-26-v14-workflow: traces 60, with a reducer row 3; per task {'workflow-judge-panel': 3}
    workflow-judge-panel.deepseek_deepseek-flash#2 [('r4t0-model-4', 'r6', 'completed', 3)]
    workflow-judge-panel.openrouter_moonshotai_kimi-k3#3 [('r2t0-model-4', 'r7', 'completed', 3)]
    workflow-judge-panel.openrouter_z-ai_glm-5.3#2 [('01a0db02-aa5a-7800-9e3b-91cc990ad02c', 'r41', 'completed', 3)]
```

### `reducer_bytes.py`

```python
#!/usr/bin/env python3
"""B(3) bytes: for every reducer row (reducers.py's definition), rebuild the reducer's sealed request
body from the run's windowed Solid Queue log (nexus.jobs.rails.log): the request body is the
`content_bodies` row whose sealed `byte_size` equals the task row's `request_bytes`; its entries are
the content fragments whose digests the sealing job loaded between that body's `ContentBody Create`
and its `ContentBody Update`; each fragment's payload is read off any `ContentFragment Bulk Insert`
in the family's windows (digests are content addresses). Reports, per row: whether any entry is a
`<task_result task="<history source>"` envelope (the duplicate the continued-round rule removes), and
the envelopes the reducer's body carries beyond its history source's own request body."""
import json, glob, os, re, sys, collections
ROOT = "/Users/jasl/Workspaces/cybros-ai.alt2/e2e/artifacts/evals"
LABELS = sys.argv[1:] or ["2026-09-26-v14-compose", "2026-09-26-v14-workflow"]
ANSI = re.compile(r"\x1b\[[0-9;]*m")
JOB = re.compile(r"^\[ActiveJob\] \[[^\]]+\] \[([0-9a-f-]{36})\]")
FRAG = re.compile(r"\(1, CURRENT_TIMESTAMP, '([0-9a-f]{64})', '((?:[^']|'')*)', CURRENT_TIMESTAMP\)")
LOAD = re.compile(r'"content_fragments"\."digest" IN \(([^)]*)\)')
UPDATE = re.compile(r'ContentBody Update .*"byte_size" = (\d+) WHERE "content_bodies"\."id" = (\d+)')
CREATE_REQ = re.compile(r"ContentBody Create .*VALUES \(1, 'request',")
ENTRIES = re.compile(r'INSERT INTO "content_body_entries" .*? VALUES (.*) RETURNING')
TASK = re.compile(r'^<task_result task="([^"]*)"([^>]*)>')
sys.path.insert(0, os.path.dirname(__file__))
from reducers import reducer_rows  # noqa: E402

def lines_of(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        return [ANSI.sub("", l) for l in f]

def payload_map(labels):
    out = {}
    for label in labels:
        for path in glob.glob(os.path.join(ROOT, label, "logs", "*", "nexus.jobs.rails.log")):
            for l in lines_of(path):
                if "ContentFragment Bulk Insert" in l or 'INSERT INTO "content_fragments"' in l:
                    for d, p in FRAG.findall(l):
                        out[d] = p.replace("''", "'")
    return out

def bodies(lines):
    """byte_size -> [(body_id, digests, entry_count)] for every sealed request body in the window."""
    found = collections.defaultdict(list)
    for i, l in enumerate(lines):
        m = UPDATE.search(l)
        if not m:
            continue
        size, body = int(m.group(1)), m.group(2)
        job = (JOB.match(l) or [None, None])[1]
        digests, entries, j = [], 0, i - 1
        while j >= 0:
            lj = lines[j]
            jm = JOB.match(lj)
            if jm and jm.group(1) == job:
                if CREATE_REQ.search(lj):
                    break
                lm = LOAD.search(lj)
                if lm:  # the first load names every digest, a later one only the inserted
                    digests = list(dict.fromkeys(digests + re.findall(r"'([0-9a-f]{64})'", lm.group(1))))
                em = ENTRIES.search(lj)
                if em and f"(1, {body}, " in em.group(1):
                    entries = em.group(1).count(f"(1, {body}, ")
            j -= 1
        if j >= 0:
            found[size].append((body, digests, entries))
    return found

def envelope(payload):
    try:
        entry = json.loads(payload)
    except ValueError:
        return None
    if entry.get("role") != "user":
        return None
    text = "".join(p.get("text", "") for p in entry.get("parts", []) if isinstance(p, dict))
    m = TASK.match(text)
    return (m.group(1), 'status="canceled"' in m.group(2)) if m else None

def main():
    payloads = payload_map(LABELS)
    print(f"fragments with a known payload across the windows: {len(payloads)}")
    for label in LABELS:
        print(f"== {label}")
        for f in sorted(glob.glob(os.path.join(ROOT, label, "*.nexus.*.json"))):
            t = json.load(open(f, encoding="utf-8"))
            rows = reducer_rows(t.get("graph") or {})
            if not rows:
                continue
            name = os.path.basename(f).replace(".nexus.", "#").replace(".json", "")
            logdir = os.path.join(ROOT, label, "logs", os.path.basename(f)[:-5])
            by_size = bodies(lines_of(os.path.join(logdir, "nexus.jobs.rails.log")))
            sizes = {x["key"]: x.get("request_bytes") for x in t["tasks"] if x.get("kind") == "model_task"}
            for key, hist, _status, _nres in rows:
                cand, hcand = by_size.get(sizes.get(key), []), by_size.get(sizes.get(hist), [])
                if len(cand) != 1:
                    print(f"  {name} {key}<-{hist}: {len(cand)} bodies of {sizes.get(key)} bytes; unread")
                    continue
                _b, digests, n_entries = cand[0]
                unknown = [d for d in digests if d not in payloads]
                envs = {d: envelope(payloads[d]) for d in digests if d in payloads}
                envs = {d: e for d, e in envs.items() if e}
                hist_digests = set(hcand[0][1]) if len(hcand) == 1 else None
                own = [e[0] for d, e in envs.items() if hist_digests is None or d not in hist_digests]
                dup = [e for e in envs.values() if e[0] == hist]
                print(f"  {name} {key}<-{hist}: entries {n_entries}, fragments {len(digests)} (unknown {len(unknown)}), "
                      f"history envelope {'PRESENT' if dup else 'absent'}, envelopes past the history's request "
                      f"{sorted(own)}{'' if hist_digests is not None else ' (history body not found)'}")

if __name__ == "__main__":
    main()
```

Output `reducer_bytes.v14.out`:

```text
fragments with a known payload across the windows: 8701
== 2026-09-26-v14-compose
  compose-background-suite.deepseek_deepseek-flash#3 r2t0-model-2<-r9: entries 25, fragments 25 (unknown 0), history envelope absent, envelopes past the history's request ['r2t0-tool-1']
  compose-background-suite.openrouter_z-ai_glm-5.3#3 r2t0-model-2<-r8: entries 26, fragments 26 (unknown 0), history envelope absent, envelopes past the history's request ['r2t0-tool-1', 'r2t0-tool-3']
  compose-rendezvous.deepseek_deepseek-flash#1 r2t0-model-3<-r8: entries 23, fragments 20 (unknown 0), history envelope absent, envelopes past the history's request ['r10']
  compose-rendezvous.deepseek_deepseek-flash#3 r2t0-model-3<-r2t0-model-1: entries 10, fragments 7 (unknown 0), history envelope absent, envelopes past the history's request ['r2t0-model-2']
  compose-rendezvous.openrouter_moonshotai_kimi-k3#2 r2t0-model-3<-r2t0-model-1: entries 9, fragments 7 (unknown 0), history envelope absent, envelopes past the history's request ['r2t0-model-2', 'r2t0-tool-2']
  compose-rendezvous.openrouter_z-ai_glm-5.3#2 r2t0-model-3<-r2t0-model-1: entries 10, fragments 7 (unknown 0), history envelope absent, envelopes past the history's request ['r2t0-model-2']
  compose-rendezvous.openrouter_z-ai_glm-5.3#3 r2t0-model-3<-r2t0-model-1: entries 9, fragments 7 (unknown 0), history envelope absent, envelopes past the history's request ['r2t0-model-2', 'r2t0-tool-2']
  compose-review-angles.deepseek_deepseek-flash#1 r2t0-model-4<-r11: entries 16, fragments 16 (unknown 0), history envelope absent, envelopes past the history's request ['r16', 'r9']
  compose-review-angles.deepseek_deepseek-flash#2 r2t0-model-4<-r10: entries 13, fragments 13 (unknown 0), history envelope absent, envelopes past the history's request ['r13', 'r7']
  compose-review-angles.deepseek_deepseek-flash#3 r2t0-model-4<-r4: entries 10, fragments 10 (unknown 0), history envelope absent, envelopes past the history's request ['r3', 'r6']
  compose-review-angles.openrouter_moonshotai_kimi-k3#1 r2t0-model-4<-r3: entries 8, fragments 8 (unknown 0), history envelope absent, envelopes past the history's request ['r4', 'r6']
  compose-review-angles.openrouter_moonshotai_kimi-k3#2 r2t0-model-4<-r3: entries 8, fragments 8 (unknown 0), history envelope absent, envelopes past the history's request ['r4', 'r6']
  compose-review-angles.openrouter_moonshotai_kimi-k3#3 r2t0-model-4<-r3: entries 8, fragments 8 (unknown 0), history envelope absent, envelopes past the history's request ['r4', 'r5']
  compose-review-angles.openrouter_z-ai_glm-5.3-flash#1 r2t0-model-4<-r8: entries 16, fragments 16 (unknown 0), history envelope absent, envelopes past the history's request ['r5', 'r7']
  compose-review-angles.openrouter_z-ai_glm-5.3#2 r2t0-model-4<-r10: entries 16, fragments 16 (unknown 0), history envelope absent, envelopes past the history's request ['r11', 'r9']
  compose-three-stage-pairing.deepseek_deepseek-flash#1 r2t0-model-4<-r2t0-model-1: entries 9, fragments 8 (unknown 0), history envelope absent, envelopes past the history's request ['r2t0-model-2', 'r2t0-model-3', 'r2t0-tool-1', 'r2t0-tool-2', 'r2t0-tool-3'] (history body not found)
  compose-three-stage-pairing.deepseek_deepseek-flash#2 r2t0-model-4<-r2t0-model-1: entries 6, fragments 6 (unknown 0), history envelope absent, envelopes past the history's request ['r2t0-model-2', 'r2t0-model-3', 'r2t0-tool-1'] (history body not found)
  compose-three-stage-pairing.deepseek_deepseek-flash#3 01a0da7a-e420-7303-a4cf-338e389b2ebc<-01a0da7a-e41f-7e17-b394-651f2d87a5dc: entries 9, fragments 8 (unknown 0), history envelope absent, envelopes past the history's request ['01a0da7a-e41f-7662-9796-91c94a63e274', '01a0da7a-e420-721c-b433-f5cc9a6c6691', '01a0da7a-e420-7700-a127-0cb3fc5aaf26', '01a0da7a-e420-7833-a15d-4f9d4d8c0074', '01a0da7a-e420-7ecb-ad1c-6cbf5675c63a'] (history body not found)
  compose-three-stage-pairing.openrouter_z-ai_glm-5.3#1 r2t0-model-4<-r2t0-model-1: entries 6, fragments 6 (unknown 0), history envelope absent, envelopes past the history's request ['r2t0-model-2', 'r2t0-model-3', 'r2t0-tool-1'] (history body not found)
  compose-two-source-fan-in.deepseek_deepseek-flash#2 r2t0-model-3<-r2t0-model-1: entries 8, fragments 7 (unknown 0), history envelope absent, envelopes past the history's request ['r2t0-model-2', 'r2t0-tool-2', 'r2t0-tool-3']
  compose-two-source-fan-in.deepseek_deepseek-flash#3 r2t0-model-3<-r2t0-model-1: entries 8, fragments 7 (unknown 0), history envelope absent, envelopes past the history's request ['r2t0-model-2', 'r2t0-tool-2', 'r2t0-tool-3']
  compose-two-source-fan-in.openrouter_moonshotai_kimi-k3#2 r2t0-model-3<-r2t0-model-1: entries 8, fragments 7 (unknown 0), history envelope absent, envelopes past the history's request ['r2t0-model-2', 'r2t0-tool-2', 'r2t0-tool-3']
  compose-two-source-fan-in.openrouter_moonshotai_kimi-k3#3 r2t0-model-3<-r2t0-model-1: entries 8, fragments 7 (unknown 0), history envelope absent, envelopes past the history's request ['r2t0-model-2', 'r2t0-tool-2', 'r2t0-tool-3']
  compose-two-source-fan-in.openrouter_z-ai_glm-5.3-flash#2 r2t0-model-3<-r2t0-model-1: entries 8, fragments 7 (unknown 0), history envelope absent, envelopes past the history's request ['r2t0-model-2', 'r2t0-tool-2', 'r2t0-tool-3']
  compose-two-source-fan-in.openrouter_z-ai_glm-5.3#1 01a0da8a-03d8-767e-a0ac-6b598ba7717b<-01a0da8a-03d8-7d2e-a0da-329f79ccafc5: entries 8, fragments 7 (unknown 0), history envelope absent, envelopes past the history's request ['01a0da8a-03d8-701d-935a-5c14d2cf5c5a', '01a0da8a-03d8-772e-977d-8b4c532dc0ec', '01a0da8a-03d8-7ff5-8ec7-1afe5711a9b1']
  compose-two-source-fan-in.openrouter_z-ai_glm-5.3#3 r2t0-model-3<-r2t0-model-1: entries 8, fragments 7 (unknown 0), history envelope absent, envelopes past the history's request ['r2t0-model-2', 'r2t0-tool-2', 'r2t0-tool-3']
== 2026-09-26-v14-workflow
  workflow-judge-panel.deepseek_deepseek-flash#2 r4t0-model-4<-r6: entries 12, fragments 12 (unknown 0), history envelope absent, envelopes past the history's request ['r12', 'r9'] (history body not found)
  workflow-judge-panel.openrouter_moonshotai_kimi-k3#3 r2t0-model-4<-r7: entries 18, fragments 18 (unknown 0), history envelope absent, envelopes past the history's request ['r10', 'r8']
  workflow-judge-panel.openrouter_z-ai_glm-5.3#2 01a0db02-aa5a-7800-9e3b-91cc990ad02c<-r41: entries 41, fragments 41 (unknown 0), history envelope absent, envelopes past the history's request ['r39', 'r40']
```

Output `reducer_bytes.v13.out`:

```text
fragments with a known payload across the windows: 7855
== 2026-09-25-v13-compose
  compose-background-suite.deepseek_deepseek-flash#1 r3t0-model-2<-r12: entries 34, fragments 33 (unknown 0), history envelope PRESENT, envelopes past the history's request ['r12', 'r3t0-tool-3']
  compose-background-suite.openrouter_moonshotai_kimi-k3#2 r2t0-model-2<-r5: entries 17, fragments 17 (unknown 0), history envelope PRESENT, envelopes past the history's request ['r2t0-tool-1', 'r2t0-tool-3', 'r5']
  compose-background-suite.openrouter_moonshotai_kimi-k3#3 r2t0-model-3<-r2t0-model-2: entries 16, fragments 16 (unknown 0), history envelope PRESENT, envelopes past the history's request ['r2t0-model-2', 'r2t0-tool-1', 'r2t0-tool-4', 'r4']
  compose-background-suite.openrouter_z-ai_glm-5.3-flash#2 r2t0-model-3<-r9: entries 27, fragments 27 (unknown 0), history envelope PRESENT, envelopes past the history's request ['r2t0-tool-3', 'r9']
  compose-background-suite.openrouter_z-ai_glm-5.3#1 r2t0-model-2<-r5: entries 16, fragments 16 (unknown 0), history envelope PRESENT, envelopes past the history's request ['r2t0-tool-3', 'r5']
  compose-rendezvous.deepseek_deepseek-flash#2 r2t0-model-3<-r6: entries 21, fragments 18 (unknown 0), history envelope PRESENT, envelopes past the history's request ['r6', 'r8']
  compose-rendezvous.deepseek_deepseek-flash#3 r2t0-model-3<-r2t0-model-1: entries 11, fragments 8 (unknown 0), history envelope PRESENT, envelopes past the history's request ['r2t0-model-1', 'r2t0-model-2']
  compose-rendezvous.openrouter_moonshotai_kimi-k3#1 r2t0-model-3<-r2t0-model-1: entries 10, fragments 8 (unknown 0), history envelope PRESENT, envelopes past the history's request ['r2t0-model-1', 'r2t0-model-2', 'r2t0-tool-2']
  compose-rendezvous.openrouter_moonshotai_kimi-k3#2 r2t0-model-3<-r10: entries 24, fragments 22 (unknown 0), history envelope PRESENT, envelopes past the history's request ['r10', 'r2t0-tool-2', 'r9']
  compose-rendezvous.openrouter_moonshotai_kimi-k3#3 r2t0-model-3<-r2t0-model-1: entries 10, fragments 8 (unknown 0), history envelope PRESENT, envelopes past the history's request ['r2t0-model-1', 'r2t0-model-2', 'r2t0-tool-2']
  compose-rendezvous.openrouter_z-ai_glm-5.3-flash#2 01a0d571-e951-7919-a14a-229593ea362d<-01a0d571-e951-77ee-b124-943c2c0ffca7: entries 13, fragments 9 (unknown 0), history envelope PRESENT, envelopes past the history's request ['01a0d571-e951-73d4-a563-7c63219925c1', '01a0d571-e951-77ee-b124-943c2c0ffca7']
  compose-rendezvous.openrouter_z-ai_glm-5.3#1 r2t0-model-3<-r2t0-model-1: entries 10, fragments 8 (unknown 0), history envelope PRESENT, envelopes past the history's request ['r2t0-model-1', 'r2t0-model-2', 'r2t0-tool-2']
  compose-rendezvous.openrouter_z-ai_glm-5.3#2 r2t0-model-3<-r2t0-model-1: entries 10, fragments 8 (unknown 0), history envelope PRESENT, envelopes past the history's request ['r2t0-model-1', 'r2t0-model-2', 'r2t0-tool-2']
  compose-rendezvous.openrouter_z-ai_glm-5.3#3 01a0d558-3859-7e43-905f-d2cb9fc7f379<-01a0d558-3859-700d-93dd-6fbc8dae820f: entries 10, fragments 8 (unknown 0), history envelope PRESENT, envelopes past the history's request ['01a0d558-3859-700d-93dd-6fbc8dae820f', '01a0d558-3859-7ae5-b225-855d37325f23', '01a0d558-3859-7f1d-b5c8-bcbc3c8f1e4c']
  compose-review-angles.deepseek_deepseek-flash#1 r2t0-model-4<-r5: entries 11, fragments 11 (unknown 0), history envelope PRESENT, envelopes past the history's request ['r5', 'r6', 'r9']
  compose-review-angles.deepseek_deepseek-flash#3 r2t0-model-4<-r4: entries 11, fragments 11 (unknown 0), history envelope PRESENT, envelopes past the history's request ['r4', 'r6', 'r7']
  compose-review-angles.openrouter_moonshotai_kimi-k3#1 r2t0-model-4<-r4: entries 9, fragments 9 (unknown 0), history envelope PRESENT, envelopes past the history's request ['r4', 'r5', 'r6']
  compose-review-angles.openrouter_z-ai_glm-5.3-flash#1 r3t0-model-4<-r9: entries 12, fragments 12 (unknown 0), history envelope PRESENT, envelopes past the history's request ['r4', 'r8', 'r9']
  compose-review-angles.openrouter_z-ai_glm-5.3#3 r3t0-model-4<-r4: entries 9, fragments 9 (unknown 0), history envelope PRESENT, envelopes past the history's request ['r4', 'r5', 'r8']
  compose-three-stage-pairing.deepseek_deepseek-flash#1 r2t0-model-4<-r2t0-model-1: entries 7, fragments 7 (unknown 0), history envelope PRESENT, envelopes past the history's request ['r2t0-model-1', 'r2t0-model-2', 'r2t0-model-3', 'r2t0-tool-1'] (history body not found)
  compose-three-stage-pairing.openrouter_moonshotai_kimi-k3#2 r2t0-model-4<-r2t0-model-1: entries 7, fragments 7 (unknown 0), history envelope PRESENT, envelopes past the history's request ['r2t0-model-1', 'r2t0-model-2', 'r2t0-model-3', 'r2t0-tool-1'] (history body not found)
  compose-two-source-fan-in.openrouter_moonshotai_kimi-k3#1 r2t0-model-3<-r2t0-model-1: entries 9, fragments 8 (unknown 0), history envelope PRESENT, envelopes past the history's request ['r2t0-model-1', 'r2t0-model-2', 'r2t0-tool-2', 'r2t0-tool-3']
  compose-two-source-fan-in.openrouter_moonshotai_kimi-k3#2 r2t0-model-3<-r2t0-model-1: entries 9, fragments 8 (unknown 0), history envelope PRESENT, envelopes past the history's request ['r2t0-model-1', 'r2t0-model-2', 'r2t0-tool-2', 'r2t0-tool-3']
  compose-two-source-fan-in.openrouter_moonshotai_kimi-k3#3 r2t0-model-3<-r2t0-model-1: entries 9, fragments 8 (unknown 0), history envelope PRESENT, envelopes past the history's request ['r2t0-model-1', 'r2t0-model-2', 'r2t0-tool-2', 'r2t0-tool-3']
  compose-two-source-fan-in.openrouter_z-ai_glm-5.3-flash#2 r2t0-model-3<-r2t0-model-1: entries 9, fragments 8 (unknown 0), history envelope PRESENT, envelopes past the history's request ['r2t0-model-1', 'r2t0-model-2', 'r2t0-tool-2', 'r2t0-tool-3']
  compose-two-source-fan-in.openrouter_z-ai_glm-5.3-flash#3 r2t0-model-3<-r2t0-model-1: entries 9, fragments 8 (unknown 0), history envelope PRESENT, envelopes past the history's request ['r2t0-model-1', 'r2t0-model-2', 'r2t0-tool-2', 'r2t0-tool-3']
  compose-two-source-fan-in.openrouter_z-ai_glm-5.3#1 r2t0-model-3<-r2t0-model-1: entries 9, fragments 8 (unknown 0), history envelope PRESENT, envelopes past the history's request ['r2t0-model-1', 'r2t0-model-2', 'r2t0-tool-2', 'r2t0-tool-3']
  compose-two-source-fan-in.openrouter_z-ai_glm-5.3#3 r2t0-model-3<-r2t0-model-2: entries 12, fragments 10 (unknown 0), history envelope PRESENT, envelopes past the history's request ['r2t0-model-1', 'r2t0-model-2']
== 2026-09-25-v13-workflow
  workflow-judge-panel.deepseek_deepseek-flash#1 r3t0-model-4<-r9: entries 16, fragments 16 (unknown 0), history envelope PRESENT, envelopes past the history's request ['r7', 'r8', 'r9']
  workflow-judge-panel.openrouter_z-ai_glm-5.3-flash#2 r4t0-model-4<-r14: entries 22, fragments 22 (unknown 0), history envelope PRESENT, envelopes past the history's request ['r10', 'r14', 'r17']
  workflow-judge-panel.openrouter_z-ai_glm-5.3-flash#3 r3t1-model-4<-r7: entries 16, fragments 16 (unknown 0), history envelope PRESENT, envelopes past the history's request ['r4', 'r6', 'r7']
  workflow-judge-panel.openrouter_z-ai_glm-5.3#3 01a0d636-4ac3-77c7-8c32-333535fbe245<-r16: entries 27, fragments 27 (unknown 0), history envelope PRESENT, envelopes past the history's request ['r16', 'r18', 'r20']
```

### `cells.py`

```python
#!/usr/bin/env python3
"""B(3) the six cells the continued-round rule touches, v13 (last line per key) against v14, per model:
reached, succeeded, the `picture` fact exactly true, and the reducer rows (reducers.py) per cell."""
import json, glob, os, sys, collections
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from reducers import reducer_rows  # noqa: E402
RUNS = "/Users/jasl/Workspaces/cybros-ai.alt2/e2e/evals/runs"
ART = "/Users/jasl/Workspaces/cybros-ai.alt2/e2e/artifacts/evals"
CELLS = {"compose": ["compose-background-suite", "compose-rendezvous", "compose-review-angles",
                     "compose-three-stage-pairing", "compose-two-source-fan-in"], "workflow": ["workflow-judge-panel"]}
MODELS = ["openrouter/z-ai/glm-5.3", "openrouter/moonshotai/kimi-k3", "deepseek/deepseek-flash", "openrouter/z-ai/glm-5.3-flash"]
LABELS = {"v13": "2026-09-25-v13-", "v14": "2026-09-26-v14-"}

def last(label):
    out = {}
    for l in open(f"{RUNS}/{label}/records.jsonl", encoding="utf-8"):
        r = json.loads(l); out[(r["task"], r["model"], r["run"])] = r
    return out

def reducers(label, task, model):
    n = 0
    for i in (1, 2, 3):
        path = os.path.join(ART, label, f"{task}.{model.replace('/', '_')}.nexus.{i}.json")
        if os.path.exists(path):
            n += bool(reducer_rows(json.load(open(path, encoding="utf-8")).get("graph") or {}))
    return n

for fam, tasks in CELLS.items():
    recs = {v: last(p + fam) for v, p in LABELS.items()}
    for task in tasks:
        print(f"== {task}")
        for m in MODELS:
            cols = []
            for v, p in LABELS.items():
                rs = [recs[v][(task, m, i)] for i in (1, 2, 3)]
                succ = sum(1 for r in rs if r["verdict"]["succeeded"])
                pic = sum(1 for r in rs if r["facts"].get("picture") is True)
                cls = collections.Counter(r["verdict"]["class"] for r in rs)
                cols.append(f"{v} succ {succ}/3 pic {pic}/3 reducer-runs {reducers(p + fam, task, m)}/3 class {dict(cls)}")
            print(f"  {m.split('/')[-1]:15} " + " || ".join(cols))
        for v, p in LABELS.items():
            rs = [recs[v][(task, m, i)] for m in MODELS for i in (1, 2, 3)]
            print(f"  {v} total: succ {sum(1 for r in rs if r['verdict']['succeeded'])}/12, pic {sum(1 for r in rs if r['facts'].get('picture') is True)}/12")
```

Output `cells.out`:

```text
== compose-background-suite
  glm-5.3         v13 succ 1/3 pic 1/3 reducer-runs 1/3 class {None: 1, 'model conduct': 2} || v14 succ 1/3 pic 1/3 reducer-runs 1/3 class {'model conduct': 2, None: 1}
  kimi-k3         v13 succ 1/3 pic 1/3 reducer-runs 2/3 class {None: 1, 'model conduct': 2} || v14 succ 1/3 pic 1/3 reducer-runs 0/3 class {'model conduct': 2, None: 1}
  deepseek-flash  v13 succ 3/3 pic 0/3 reducer-runs 1/3 class {None: 3} || v14 succ 3/3 pic 1/3 reducer-runs 1/3 class {None: 3}
  glm-5.3-flash   v13 succ 3/3 pic 1/3 reducer-runs 1/3 class {None: 3} || v14 succ 3/3 pic 1/3 reducer-runs 0/3 class {None: 3}
  v13 total: succ 8/12, pic 3/12
  v14 total: succ 8/12, pic 4/12
== compose-rendezvous
  glm-5.3         v13 succ 3/3 pic 0/3 reducer-runs 3/3 class {None: 3} || v14 succ 3/3 pic 1/3 reducer-runs 2/3 class {None: 3}
  kimi-k3         v13 succ 3/3 pic 0/3 reducer-runs 3/3 class {None: 3} || v14 succ 3/3 pic 0/3 reducer-runs 1/3 class {None: 3}
  deepseek-flash  v13 succ 3/3 pic 0/3 reducer-runs 2/3 class {None: 2, 'cache under floor': 1} || v14 succ 3/3 pic 0/3 reducer-runs 2/3 class {None: 3}
  glm-5.3-flash   v13 succ 3/3 pic 0/3 reducer-runs 1/3 class {None: 3} || v14 succ 3/3 pic 2/3 reducer-runs 0/3 class {None: 2, 'model conduct': 1}
  v13 total: succ 12/12, pic 0/12
  v14 total: succ 12/12, pic 3/12
== compose-review-angles
  glm-5.3         v13 succ 2/3 pic 2/3 reducer-runs 1/3 class {None: 2, 'model conduct': 1} || v14 succ 3/3 pic 3/3 reducer-runs 1/3 class {None: 3}
  kimi-k3         v13 succ 3/3 pic 3/3 reducer-runs 1/3 class {None: 3} || v14 succ 3/3 pic 3/3 reducer-runs 3/3 class {None: 3}
  deepseek-flash  v13 succ 3/3 pic 3/3 reducer-runs 2/3 class {None: 3} || v14 succ 3/3 pic 3/3 reducer-runs 3/3 class {None: 3}
  glm-5.3-flash   v13 succ 3/3 pic 2/3 reducer-runs 1/3 class {None: 3} || v14 succ 3/3 pic 3/3 reducer-runs 1/3 class {None: 3}
  v13 total: succ 11/12, pic 10/12
  v14 total: succ 12/12, pic 12/12
== compose-three-stage-pairing
  glm-5.3         v13 succ 2/3 pic 2/3 reducer-runs 0/3 class {None: 2, 'model conduct': 1} || v14 succ 3/3 pic 3/3 reducer-runs 1/3 class {None: 3}
  kimi-k3         v13 succ 2/3 pic 2/3 reducer-runs 1/3 class {'model conduct': 1, None: 2} || v14 succ 3/3 pic 3/3 reducer-runs 0/3 class {None: 3}
  deepseek-flash  v13 succ 3/3 pic 3/3 reducer-runs 1/3 class {None: 3} || v14 succ 3/3 pic 1/3 reducer-runs 3/3 class {None: 1, 'cache under floor': 2}
  glm-5.3-flash   v13 succ 2/3 pic 1/3 reducer-runs 0/3 class {'model conduct': 1, None: 2} || v14 succ 2/3 pic 1/3 reducer-runs 0/3 class {'model conduct': 1, None: 2}
  v13 total: succ 9/12, pic 8/12
  v14 total: succ 11/12, pic 8/12
== compose-two-source-fan-in
  glm-5.3         v13 succ 0/3 pic 0/3 reducer-runs 2/3 class {'model conduct': 3} || v14 succ 1/3 pic 1/3 reducer-runs 2/3 class {'model conduct': 2, None: 1}
  kimi-k3         v13 succ 0/3 pic 0/3 reducer-runs 3/3 class {'model conduct': 3} || v14 succ 0/3 pic 0/3 reducer-runs 2/3 class {'model conduct': 3}
  deepseek-flash  v13 succ 3/3 pic 1/3 reducer-runs 0/3 class {None: 3} || v14 succ 3/3 pic 0/3 reducer-runs 2/3 class {None: 3}
  glm-5.3-flash   v13 succ 3/3 pic 1/3 reducer-runs 2/3 class {None: 3} || v14 succ 3/3 pic 2/3 reducer-runs 1/3 class {None: 3}
  v13 total: succ 6/12, pic 2/12
  v14 total: succ 7/12, pic 3/12
== workflow-judge-panel
  glm-5.3         v13 succ 3/3 pic 0/3 reducer-runs 1/3 class {'cache under floor': 3} || v14 succ 3/3 pic 0/3 reducer-runs 1/3 class {'cache under floor': 3}
  kimi-k3         v13 succ 3/3 pic 0/3 reducer-runs 0/3 class {None: 1, 'cache under floor': 2} || v14 succ 3/3 pic 0/3 reducer-runs 1/3 class {None: 3}
  deepseek-flash  v13 succ 3/3 pic 0/3 reducer-runs 1/3 class {None: 3} || v14 succ 2/3 pic 0/3 reducer-runs 1/3 class {None: 2, 'model conduct': 1}
  glm-5.3-flash   v13 succ 3/3 pic 0/3 reducer-runs 2/3 class {None: 3} || v14 succ 3/3 pic 0/3 reducer-runs 0/3 class {None: 3}
  v13 total: succ 12/12, pic 0/12
  v14 total: succ 11/12, pic 0/12
```

### `fanfive.py`

```python
#!/usr/bin/env python3
"""B(4) task-fan-five under settle_receipts: per record the driver, verdict, reason, merge_turn, waited,
the replies recorded (count, and which turn names all five files), orphans_named, woken loops, loops;
v13 (last line per key) beside it."""
import json
RUNS = "/Users/jasl/Workspaces/cybros-ai.alt2/e2e/evals/runs"
MODELS = ["openrouter/z-ai/glm-5.3", "openrouter/moonshotai/kimi-k3", "deepseek/deepseek-flash", "openrouter/z-ai/glm-5.3-flash"]
FILES = ["a.rb", "b.rb", "c.rb", "d.rb", "e.rb"]

def last(label):
    out = {}
    for l in open(f"{RUNS}/{label}/records.jsonl", encoding="utf-8"):
        r = json.loads(l)
        if r["task"] == "task-fan-five":
            out[(r["model"], r["run"])] = r
    return out

v13, v14 = last("2026-09-25-v13-task"), last("2026-09-26-v14-task")
def line(r):
    f = r["facts"]; v = r["verdict"]
    reps = f.get("replies")
    naming = None if reps is None else [i for i, t in enumerate(reps.values()) if all(x in (t or "") for x in FILES)]
    return (f"{r['driver']:15} reached={v['reached']} succ={v['succeeded']} pass={v['task_pass']} class={v['class']} "
            f"merge_turn={f.get('merge_turn')} waited={f.get('waited')} replies={None if reps is None else len(reps)} "
            f"naming-all-five-at={naming} orphans_named={f.get('orphans_named')} woken_loops={len(f.get('woken_loops') or [])} "
            f"receipts={f.get('receipts')} loops={len(r.get('loops') or [])} first_msg_tasks={f.get('task_calls_in_first_message')} per_file={f.get('per_file')} "
            f"reason={(r.get('reason') or '')[:120]!r}")
for m in MODELS:
    for i in (1, 2, 3):
        print(f"{m.split('/')[-1]} #{i}")
        print("   v13", line(v13[(m, i)]))
        print("   v14", line(v14[(m, i)]))
for lab, recs in (("v13", v13), ("v14", v14)):
    print(lab, "succeeded", sum(1 for r in recs.values() if r["verdict"]["succeeded"]), "/", len(recs),
          "| per model", {m.split('/')[-1]: sum(1 for i in (1, 2, 3) if recs[(m, i)]["verdict"]["succeeded"]) for m in MODELS},
          "| waited", sum(1 for r in recs.values() if r["facts"].get("waited")),
          "| merge_turn", {t: sum(1 for r in recs.values() if r["facts"].get("merge_turn") == t) for t in sorted({str(r["facts"].get("merge_turn")) for r in recs.values()}, key=str)} if lab == "v14" else "")
```

Output `fanfive.out`:

```text
glm-5.3 #1
   v13 plain           reached=True succ=True pass=None class=None merge_turn=primary waited=True replies=None naming-all-five-at=None orphans_named=5 woken_loops=0 receipts=0 loops=1 first_msg_tasks=5 per_file={'a.rb': 1, 'b.rb': 1, 'c.rb': 1, 'd.rb': 1, 'e.rb': 1} reason=''
   v14 settle_receipts reached=True succ=True pass=None class=cache under floor merge_turn=primary waited=True replies=1 naming-all-five-at=[0] orphans_named=5 woken_loops=0 receipts=0 loops=1 first_msg_tasks=5 per_file={'a.rb': 1, 'b.rb': 1, 'c.rb': 1, 'd.rb': 1, 'e.rb': 1} reason=''
glm-5.3 #2
   v13 plain           reached=True succ=True pass=None class=None merge_turn=primary waited=True replies=None naming-all-five-at=None orphans_named=5 woken_loops=0 receipts=0 loops=1 first_msg_tasks=5 per_file={'a.rb': 1, 'b.rb': 1, 'c.rb': 1, 'd.rb': 1, 'e.rb': 1} reason=''
   v14 settle_receipts reached=True succ=True pass=None class=None merge_turn=primary waited=True replies=1 naming-all-five-at=[0] orphans_named=5 woken_loops=0 receipts=0 loops=1 first_msg_tasks=5 per_file={'a.rb': 1, 'b.rb': 1, 'c.rb': 1, 'd.rb': 1, 'e.rb': 1} reason=''
glm-5.3 #3
   v13 plain           reached=True succ=True pass=None class=None merge_turn=primary waited=True replies=None naming-all-five-at=None orphans_named=5 woken_loops=0 receipts=0 loops=1 first_msg_tasks=5 per_file={'a.rb': 1, 'b.rb': 1, 'c.rb': 1, 'd.rb': 1, 'e.rb': 1} reason=''
   v14 settle_receipts reached=True succ=True pass=None class=cache under floor merge_turn=primary waited=True replies=1 naming-all-five-at=[0] orphans_named=5 woken_loops=0 receipts=0 loops=1 first_msg_tasks=5 per_file={'a.rb': 1, 'b.rb': 1, 'c.rb': 1, 'd.rb': 1, 'e.rb': 1} reason=''
kimi-k3 #1
   v13 plain           reached=True succ=True pass=None class=None merge_turn=primary waited=True replies=None naming-all-five-at=None orphans_named=5 woken_loops=0 receipts=0 loops=1 first_msg_tasks=5 per_file={'a.rb': 1, 'b.rb': 1, 'c.rb': 1, 'd.rb': 1, 'e.rb': 1} reason=''
   v14 settle_receipts reached=True succ=True pass=None class=None merge_turn=primary waited=True replies=1 naming-all-five-at=[0] orphans_named=5 woken_loops=0 receipts=0 loops=1 first_msg_tasks=5 per_file={'a.rb': 1, 'b.rb': 1, 'c.rb': 1, 'd.rb': 1, 'e.rb': 1} reason=''
kimi-k3 #2
   v13 plain           reached=True succ=True pass=None class=None merge_turn=primary waited=True replies=None naming-all-five-at=None orphans_named=5 woken_loops=0 receipts=0 loops=1 first_msg_tasks=5 per_file={'a.rb': 1, 'b.rb': 1, 'c.rb': 1, 'd.rb': 1, 'e.rb': 1} reason=''
   v14 settle_receipts reached=True succ=True pass=None class=None merge_turn=primary waited=True replies=1 naming-all-five-at=[0] orphans_named=5 woken_loops=0 receipts=0 loops=1 first_msg_tasks=5 per_file={'a.rb': 1, 'b.rb': 1, 'c.rb': 1, 'd.rb': 1, 'e.rb': 1} reason=''
kimi-k3 #3
   v13 plain           reached=True succ=True pass=None class=None merge_turn=primary waited=True replies=None naming-all-five-at=None orphans_named=5 woken_loops=0 receipts=0 loops=1 first_msg_tasks=5 per_file={'a.rb': 1, 'b.rb': 1, 'c.rb': 1, 'd.rb': 1, 'e.rb': 1} reason=''
   v14 settle_receipts reached=True succ=True pass=None class=None merge_turn=primary waited=True replies=1 naming-all-five-at=[0] orphans_named=5 woken_loops=0 receipts=0 loops=1 first_msg_tasks=5 per_file={'a.rb': 1, 'b.rb': 1, 'c.rb': 1, 'd.rb': 1, 'e.rb': 1} reason=''
deepseek-flash #1
   v13 plain           reached=False succ=None pass=None class=model conduct merge_turn=primary waited=False replies=None naming-all-five-at=None orphans_named=5 woken_loops=0 receipts=5 loops=1 first_msg_tasks=0 per_file={'a.rb': 1, 'b.rb': 1, 'c.rb': 1, 'd.rb': 1, 'e.rb': 1} reason='0 task call(s) in the first message, not five: {"bash" => 1, "read" => 1}'
   v14 settle_receipts reached=False succ=None pass=None class=model conduct merge_turn=primary waited=True replies=1 naming-all-five-at=[0] orphans_named=5 woken_loops=0 receipts=0 loops=1 first_msg_tasks=0 per_file={'a.rb': 1, 'b.rb': 1, 'c.rb': 1, 'd.rb': 1, 'e.rb': 1} reason='0 task call(s) in the first message, not five: {"read" => 5}'
deepseek-flash #2
   v13 plain           reached=False succ=None pass=None class=model conduct merge_turn=primary waited=True replies=None naming-all-five-at=None orphans_named=5 woken_loops=0 receipts=0 loops=1 first_msg_tasks=0 per_file={'a.rb': 5, 'b.rb': 5, 'c.rb': 5, 'd.rb': 5, 'e.rb': 5} reason='0 task call(s) in the first message, not five: {"ls" => 1, "bash" => 1}'
   v14 settle_receipts reached=True succ=True pass=None class=None merge_turn=woken-1 waited=False replies=6 naming-all-five-at=[1, 2, 3, 4, 5] orphans_named=5 woken_loops=5 receipts=5 loops=6 first_msg_tasks=5 per_file={'a.rb': 1, 'b.rb': 1, 'c.rb': 1, 'd.rb': 1, 'e.rb': 1} reason=''
deepseek-flash #3
   v13 plain           reached=True succ=True pass=None class=None merge_turn=primary waited=True replies=None naming-all-five-at=None orphans_named=5 woken_loops=0 receipts=0 loops=1 first_msg_tasks=5 per_file={'a.rb': 1, 'b.rb': 1, 'c.rb': 1, 'd.rb': 1, 'e.rb': 1} reason=''
   v14 settle_receipts reached=True succ=True pass=None class=None merge_turn=primary waited=False replies=1 naming-all-five-at=[0] orphans_named=5 woken_loops=0 receipts=5 loops=1 first_msg_tasks=5 per_file={'a.rb': 1, 'b.rb': 1, 'c.rb': 1, 'd.rb': 1, 'e.rb': 1} reason=''
glm-5.3-flash #1
   v13 plain           reached=True succ=False pass=None class=model conduct merge_turn=None waited=False replies=None naming-all-five-at=None orphans_named=0 woken_loops=0 receipts=5 loops=6 first_msg_tasks=5 per_file={'a.rb': 1, 'b.rb': 1, 'c.rb': 1, 'd.rb': 1, 'e.rb': 1} reason='the merged reply names no lib/a.rb'
   v14 settle_receipts reached=True succ=False pass=None class=model conduct merge_turn=primary waited=False replies=1 naming-all-five-at=[0] orphans_named=5 woken_loops=0 receipts=5 loops=1 first_msg_tasks=5 per_file={'a.rb': 5, 'b.rb': 5, 'c.rb': 5, 'd.rb': 5, 'e.rb': 5} reason='a second task for a.rb, b.rb, c.rb, d.rb, e.rb'
glm-5.3-flash #2
   v13 plain           reached=True succ=True pass=None class=None merge_turn=primary waited=True replies=None naming-all-five-at=None orphans_named=5 woken_loops=0 receipts=0 loops=1 first_msg_tasks=5 per_file={'a.rb': 1, 'b.rb': 1, 'c.rb': 1, 'd.rb': 1, 'e.rb': 1} reason=''
   v14 settle_receipts reached=True succ=True pass=None class=None merge_turn=primary waited=True replies=1 naming-all-five-at=[0] orphans_named=5 woken_loops=0 receipts=0 loops=1 first_msg_tasks=5 per_file={'a.rb': 1, 'b.rb': 1, 'c.rb': 1, 'd.rb': 1, 'e.rb': 1} reason=''
glm-5.3-flash #3
   v13 plain           reached=True succ=True pass=None class=None merge_turn=primary waited=True replies=None naming-all-five-at=None orphans_named=5 woken_loops=0 receipts=0 loops=1 first_msg_tasks=5 per_file={'a.rb': 1, 'b.rb': 1, 'c.rb': 1, 'd.rb': 1, 'e.rb': 1} reason=''
   v14 settle_receipts reached=True succ=False pass=None class=model conduct merge_turn=primary waited=True replies=1 naming-all-five-at=[0] orphans_named=5 woken_loops=0 receipts=0 loops=1 first_msg_tasks=5 per_file={'a.rb': 5, 'b.rb': 4, 'c.rb': 3, 'd.rb': 3, 'e.rb': 5} reason='a second task for a.rb, b.rb, c.rb, d.rb, e.rb'
v13 succeeded 9 / 12 | per model {'glm-5.3': 3, 'kimi-k3': 3, 'deepseek-flash': 1, 'glm-5.3-flash': 2} | waited 10 | merge_turn 
v14 succeeded 9 / 12 | per model {'glm-5.3': 3, 'kimi-k3': 3, 'deepseek-flash': 2, 'glm-5.3-flash': 1} | waited 9 | merge_turn {'primary': 11, 'woken-1': 1}
```

### `fanfive_perfile.py`

```python
#!/usr/bin/env python3
"""B(4) aside: the two v14 glm-5.3-flash task-fan-five reds read "a second task for ...". Per `task` call,
the file the prompt says to review (the `Review ONLY lib/x.rb` / `Review the single file lib/x.rb`
clause) against how many prompts merely mention each file (what `per_file` counts)."""
import json, re, collections
ART = "/Users/jasl/Workspaces/cybros-ai.alt2/e2e/artifacts/evals/2026-09-26-v14-task"
SUBJECT = re.compile(r"Review (?:ONLY |the single file )(lib/[a-e]\.rb)")
for run in (1, 3):
    t = json.load(open(f"{ART}/task-fan-five.openrouter_z-ai_glm-5.3-flash.nexus.{run}.json", encoding="utf-8"))
    prompts = [x["tool_input"]["prompt"] for x in t["tasks"] if x.get("tool_name") == "task"]
    subjects = collections.Counter(m.group(1) for p in prompts for m in [SUBJECT.search(p)] if m)
    mentions = {f: sum(1 for p in prompts if f in p) for f in (f"{c}.rb" for c in "abcde")}
    print(f"glm-5.3-flash #{run}: task calls {len(prompts)}, subject per file {dict(sorted(subjects.items()))}, mentions per file {mentions}")
```

Output `fanfive_perfile.out`:

```text
glm-5.3-flash #1: task calls 5, subject per file {'lib/a.rb': 1, 'lib/b.rb': 1, 'lib/c.rb': 1, 'lib/d.rb': 1, 'lib/e.rb': 1}, mentions per file {'a.rb': 5, 'b.rb': 5, 'c.rb': 5, 'd.rb': 5, 'e.rb': 5}
glm-5.3-flash #3: task calls 5, subject per file {'lib/a.rb': 1, 'lib/b.rb': 1, 'lib/c.rb': 1, 'lib/d.rb': 1, 'lib/e.rb': 1}, mentions per file {'a.rb': 5, 'b.rb': 4, 'c.rb': 3, 'd.rb': 3, 'e.rb': 5}
```

### `rescore.rb`

```ruby
# B(5) and B(6): re-read committed records OFFLINE over their saved traces under one reader tree, in
# memory, one JSON line per record to <out.jsonl>. Never writes a record: Records.read and the
# artifacts are read, Rescore.rescored is the pure half of `rake evals_rescore` (Records.append is never
# called). Records.read keeps each key's LAST line (v13's rescored-in-place lines win).
#
#   cd e2e && BUNDLE_FROZEN=true bundle exec ruby <this> <tree> <label> <task,task,...> <out.jsonl>
#   tree  main      the repo's own e2e/support, e2e/evals/tasks, bench.yml, nexus/lib (== 4a8cf2ea's readers)
#         <sha>     tree-<sha>/ beside this file, extracted by `git archive <sha> e2e/support e2e/evals/tasks
#                   e2e/evals/bench.yml nexus/lib nexus/app/services/conversations/compaction
#                   agents/rho/rho-mcp/test/support`
require "json"
require "time"

REPO = "/Users/jasl/Workspaces/cybros-ai.alt2".freeze
HERE = File.dirname(File.expand_path(__FILE__)).freeze
ARTIFACTS = File.join(REPO, "e2e/artifacts/evals").freeze
NOW = Time.utc(2026, 9, 26, 12, 0, 0)

tree, label, tasks, out = ARGV
abort "usage: rescore.rb main|<sha> <label> <tasks,comma> <out.jsonl>" unless tree && label && tasks && out
root = tree == "main" ? File.join(REPO, "e2e") : File.join(HERE, "tree-#{tree}", "e2e")
require File.join(root, "support/evals")

bench = E2E::Evals::Bench.read
corpus = E2E::Evals::Corpus.load(canary: bench.canary)
wanted = tasks.split(",")
records = E2E::Evals::Records.read(File.join(REPO, "e2e/evals/runs", label)).select { |r| wanted.include?(r["task"]) }
warn "#{tree}: #{root}, bench #{bench.digest[0, 12]} v#{bench.version rescue '?'}, #{records.size} records of #{label}"

DROP = %w[replies reply root score follower_envelopes follower_requests woken_loops].freeze
slim = lambda do |rec|
  raw = rec.dig("facts", "score")
  score = raw.respond_to?(:dig) ? raw : { "text" => raw.to_s[0, 200] } # a refused script's score is its refusal text
  static = score["static"] || {}
  { "verdict" => rec["verdict"], "reason" => rec["reason"], "conduct" => rec["conduct"],
    "conduct_reasons" => rec["conduct_reasons"],
    "score" => { "reading" => score["reading"], "silent" => score["silent"], "first_time_right" => score["first_time_right"],
                 "static_silent" => static["silent"], "static_first_time_right" => static["first_time_right"],
                 "text" => score["text"] }.compact,
    "facts" => Hash(rec["facts"]).reject { |k, _| DROP.include?(k) } }
end

lines = records.map do |record|
  row = { "task" => record["task"], "model" => record["model"], "run" => record["run"], "recorded" => slim.(record) }
  begin
    artifact = E2E::Evals::Rescore.artifact_of(record, ARTIFACTS, label)
    raise "no artifact for #{record["artifact"]}" if artifact.nil?

    trace = E2E::Evals::Rescore.trace_of(record, artifact)
    fresh = E2E::Evals::Rescore.rescored(record, corpus.find(record.fetch("task")), trace, NOW)
    row.merge("fresh" => slim.(fresh))
  rescue StandardError, ScriptError => error
    row.merge("raised" => "#{error.class}: #{error.message[0, 300]}", "at" => Array(error.backtrace).first(3))
  end
end
File.write(out, lines.map { |line| JSON.generate(line) }.join("\n") + "\n", encoding: "UTF-8")
warn "#{tree}: wrote #{lines.size} lines to #{out} (#{lines.count { |l| l.key?("raised") }} raised)"
```

### `o2_compare.py`

```python
#!/usr/bin/env python3
"""B(5): O2 (compose-grep-then-edit) readings. Prints, per record of a rescore.rb output, the recorded
(last line) and the in-memory re-read static and executed buckets, verdict and reason, and which moved."""
import json, sys
path = sys.argv[1]
moved_readings = 0
for l in open(path, encoding="utf-8"):
    r = json.loads(l)
    if "raised" in r:
        print(r["task"], r["model"], r["run"], "RAISED", r["raised"]); continue
    a, b = r["recorded"], r["fresh"]
    sa, sb = a["score"], b["score"]
    st = sa.get("static_silent") != sb.get("static_silent")
    ex = sa.get("silent") != sb.get("silent")
    moved_readings += st + ex
    tag = []
    if st: tag.append("STATIC moved")
    if ex: tag.append("EXECUTED moved")
    if a["verdict"] != b["verdict"]: tag.append("VERDICT moved")
    if (a["reason"] or "") != (b["reason"] or ""): tag.append("reason moved")
    print(f"{r['model'].split('/')[-1]:15} #{r['run']} reading={sb.get('reading')} "
          f"static {sa.get('static_silent')} -> {sb.get('static_silent')} | executed {sa.get('silent')} -> {sb.get('silent')} "
          f"| succ {a['verdict']['succeeded']} -> {b['verdict']['succeeded']} | {', '.join(tag) or 'unchanged'}")
    if (a["reason"] or "") != (b["reason"] or ""):
        print(f"      reason: {(a['reason'] or '')[:110]!r}\n          ->  {(b['reason'] or '')[:110]!r}")
print("readings moved:", moved_readings)
```

Output `o2_v13_main.out`:

```text
glm-5.3         #1 reading=executed static ['missing_steps'] -> ['missing_steps'] | executed ['missing_steps'] -> ['missing_steps'] | succ False -> False | unchanged
glm-5.3         #2 reading=executed static ['wrong_task_read'] -> ['edit_as_stage'] | executed [] -> [] | succ True -> True | STATIC moved
glm-5.3         #3 reading=executed static ['wrong_task_read'] -> ['edit_as_stage'] | executed [] -> [] | succ True -> True | STATIC moved
kimi-k3         #1 reading=executed static ['over_sync'] -> ['over_sync'] | executed ['over_sync'] -> ['over_sync'] | succ False -> False | unchanged
kimi-k3         #2 reading=executed static ['wrong_task_read'] -> ['edit_as_stage'] | executed ['wrong_task_read'] -> ['edit_as_stage'] | succ False -> False | STATIC moved, EXECUTED moved, reason moved
      reason: 'the picture is not the objective\'s (silent: wrong_task_read): {"nodes" => ["tool-1:tool", "tool-2:tool", "tool'
          ->  'the picture is not the objective\'s (silent: edit_as_stage): {"nodes" => ["tool-1:tool", "tool-2:tool", "tool-3'
kimi-k3         #3 reading=executed static ['wrong_task_read'] -> ['wrong_task_read'] | executed [] -> [] | succ True -> True | unchanged
deepseek-flash  #1 reading=executed static [] -> [] | executed [] -> [] | succ True -> True | unchanged
deepseek-flash  #2 reading=static static None -> None | executed None -> None | succ True -> True | unchanged
deepseek-flash  #3 reading=executed static ['wrong_task_read'] -> ['edit_as_stage'] | executed [] -> [] | succ True -> True | STATIC moved
glm-5.3-flash   #1 reading=None static None -> None | executed None -> None | succ None -> None | unchanged
glm-5.3-flash   #2 reading=executed static ['wrong_task_read'] -> ['wrong_task_read'] | executed [] -> [] | succ True -> True | unchanged
glm-5.3-flash   #3 reading=executed static ['over_sync'] -> ['over_sync'] | executed ['over_sync'] -> ['over_sync'] | succ True -> True | unchanged
readings moved: 5
```

### `o2_stage_readers.py`

```python
#!/usr/bin/env python3
"""B(5): on the O2 records whose static reading names a stage in the edit's place, does a model step read
a script (stage) node in the static lowering? (records' facts.score.static.graph: nodes and reads)."""
import json, sys
RUNS = "/Users/jasl/Workspaces/cybros-ai.alt2/e2e/evals/runs"
for label in ("2026-09-25-v13-compose", "2026-09-26-v14-compose"):
    last = {}
    for l in open(f"{RUNS}/{label}/records.jsonl", encoding="utf-8"):
        r = json.loads(l)
        if r["task"] == "compose-grep-then-edit":
            last[(r["model"], r["run"])] = r
    print("==", label)
    for (m, i), r in sorted(last.items()):
        s = r["facts"].get("score")
        if not hasattr(s, "get") or not s.get("static"):
            continue
        g = s["static"]["graph"]
        kinds = {n.rsplit(":", 1)[0]: n.rsplit(":", 1)[1] for n in g["nodes"]}
        model_reads_stage = sorted(k for k, reads in g.get("reads", {}).items() if kinds.get(k) == "model" and any(kinds.get(x) == "script" for x in reads))
        print(f"  {m.split('/')[-1]:15} #{i} static {s['static']['silent']} executed {s.get('silent')} "
              f"scripts {[k for k, v in kinds.items() if v == 'script']} model steps reading a stage {model_reads_stage}")
```

Output `o2_stage_readers.out`:

```text
== 2026-09-25-v13-compose
  deepseek-flash  #1 static [] executed [] scripts [] model steps reading a stage []
  deepseek-flash  #3 static ['wrong_task_read'] executed [] scripts ['script-1'] model steps reading a stage []
  kimi-k3         #1 static ['over_sync'] executed ['over_sync'] scripts ['script-1'] model steps reading a stage []
  kimi-k3         #2 static ['wrong_task_read'] executed ['wrong_task_read'] scripts ['script-1'] model steps reading a stage []
  kimi-k3         #3 static ['wrong_task_read'] executed [] scripts ['script-1'] model steps reading a stage ['model-1']
  glm-5.3         #1 static ['missing_steps'] executed ['missing_steps'] scripts ['script-1'] model steps reading a stage []
  glm-5.3         #2 static ['wrong_task_read'] executed [] scripts ['script-1', 'script-2'] model steps reading a stage []
  glm-5.3         #3 static ['wrong_task_read'] executed [] scripts ['script-1'] model steps reading a stage []
  glm-5.3-flash   #2 static ['wrong_task_read'] executed [] scripts ['script-1', 'script-2'] model steps reading a stage ['model-1']
  glm-5.3-flash   #3 static ['over_sync'] executed ['over_sync'] scripts ['script-1'] model steps reading a stage []
== 2026-09-26-v14-compose
  deepseek-flash  #1 static ['missing_steps'] executed [] scripts ['script-1'] model steps reading a stage []
  deepseek-flash  #2 static [] executed [] scripts [] model steps reading a stage []
  deepseek-flash  #3 static ['edit_as_stage'] executed [] scripts ['script-1'] model steps reading a stage []
  kimi-k3         #1 static ['edit_as_stage'] executed [] scripts ['script-1'] model steps reading a stage []
  kimi-k3         #2 static ['edit_as_stage'] executed [] scripts ['script-1'] model steps reading a stage []
  kimi-k3         #3 static ['over_sync'] executed ['over_sync'] scripts ['script-1'] model steps reading a stage []
  glm-5.3         #1 static ['edit_as_stage'] executed [] scripts ['script-1'] model steps reading a stage []
  glm-5.3         #2 static ['over_sync'] executed ['over_sync'] scripts ['script-1'] model steps reading a stage []
  glm-5.3         #3 static ['edit_as_stage'] executed [] scripts ['script-1'] model steps reading a stage []
  glm-5.3-flash   #1 static ['edit_as_tool', 'extra_steps'] executed ['extra_steps'] scripts ['script-1', 'script-2'] model steps reading a stage []
  glm-5.3-flash   #2 static ['edit_as_stage'] executed [] scripts ['script-1'] model steps reading a stage []
```

### `rulings_compare.py`

```python
#!/usr/bin/env python3
"""B(6): the owner's three 2026-09-25 rulings in use on v14. The same v14 records re-read in memory
(rescore.rb) under three reader trees: 563a86aa (before the rulings), fa67ba30 (the rulings' readers
alone: `git diff 563a86aa fa67ba30` over the reader paths is the rulings' commit), and main (the
records' own readers, 4a8cf2ea: + O2's edit_as_stage and Q10's readers). Control: main against the
record as written. The rulings' effect: 563a86aa -> fa67ba30, per record, field by field."""
import json, sys, collections
B = "/private/tmp/claude-501/-Users-jasl-Workspaces-cybros-ai-alt2/fe6d4094-2f85-4b52-abfc-78043a70e275/scratchpad/v14/readout/b"

def load(fam, tree):
    return {(r["task"], r["model"], r["run"]): r for r in map(json.loads, open(f"{B}/rul_v14_{fam}_{tree}.jsonl", encoding="utf-8"))}

def diff(a, b):
    out = []
    for k in ("verdict", "reason", "conduct", "conduct_reasons"):
        if a[k] != b[k]:
            out.append(k)
    for k in ("static_silent", "silent", "first_time_right", "static_first_time_right", "reading", "text"):
        if a["score"].get(k) != b["score"].get(k):
            out.append("score." + k)
    fk = sorted(k for k in set(a["facts"]) | set(b["facts"]) if a["facts"].get(k) != b["facts"].get(k))
    out += ["facts." + k for k in fk]
    return out

def short(x, n=90):
    s = json.dumps(x, ensure_ascii=False) if not isinstance(x, str) else x
    return s[:n]

for fam in ("compose", "workflow"):
    main, pre, rul = load(fam, "main"), load(fam, "563a86aa"), load(fam, "fa67ba30")
    ctrl = sum(1 for k, r in main.items() if diff(r["recorded"], r["fresh"]))
    print(f"== {fam}: {len(main)} records; control (main re-read vs record) differing: {ctrl}")
    per_task = collections.defaultdict(collections.Counter)
    for k in sorted(main):
        task, model, run = k
        a, b, c = pre[k]["fresh"], rul[k]["fresh"], main[k]["fresh"]
        d_rul, d_late = diff(a, b), diff(b, c)
        per_task[task]["records"] += 1
        if d_rul:
            per_task[task]["ruling_moved_any"] += 1
        if any(x in d_rul for x in ("verdict", "reason", "conduct", "conduct_reasons")) or any(x.startswith("score.") for x in d_rul):
            per_task[task]["ruling_moved_reading"] += 1
        if d_late:
            per_task[task]["later_moved_any"] += 1
        if not (d_rul or d_late):
            continue
        print(f"  {task} {model.split('/')[-1]} #{run}")
        if d_rul:
            print(f"    rulings (563a86aa -> fa67ba30): {d_rul}")
            for f in d_rul:
                if f.startswith("facts."):
                    key = f[6:]; print(f"       {f}: {short(a['facts'].get(key))} -> {short(b['facts'].get(key))}")
                elif f.startswith("score."):
                    key = f[6:]; print(f"       {f}: {short(a['score'].get(key))} -> {short(b['score'].get(key))}")
                else:
                    print(f"       {f}: {short(a[f], 160)} -> {short(b[f], 160)}")
        if d_late:
            print(f"    later readers (fa67ba30 -> main): {d_late}")
            for f in d_late:
                if f.startswith("score."):
                    key = f[6:]; print(f"       {f}: {short(b['score'].get(key))} -> {short(c['score'].get(key))}")
                elif not f.startswith("facts."):
                    print(f"       {f}: {short(b[f], 120)} -> {short(c[f], 120)}")
    for t, c in per_task.items():
        print(f"  TOTAL {t}: {dict(c)}")
```

Output `rulings_compare.out`:

```text
== compose: 24 records; control (main re-read vs record) differing: 0
  compose-background-suite deepseek-flash #2
    rulings (563a86aa -> fa67ba30): ['score.static_silent', 'score.silent', 'facts.picture']
       score.static_silent: ["suite_waited_on", "extra_steps", "over_sync", "over_read"] -> ["over_read"]
       score.silent: ["suite_waited_on", "extra_steps", "over_sync", "over_read"] -> ["over_read"]
       facts.picture: the picture is not the objective's (silent: suite_waited_on, extra_steps, over_sync, over_ -> the picture is not the objective's (silent: over_read): {"nodes" => ["tool-1:tool", "tool-
  compose-background-suite deepseek-flash #3
    rulings (563a86aa -> fa67ba30): ['score.static_silent', 'score.silent', 'facts.picture']
       score.static_silent: ["suite_waited_on", "extra_steps", "over_read"] -> ["extra_steps", "over_read"]
       score.silent: ["suite_waited_on", "extra_steps", "over_read"] -> ["extra_steps", "over_read"]
       facts.picture: the picture is not the objective's (silent: suite_waited_on, extra_steps, over_read): {"no -> the picture is not the objective's (silent: extra_steps, over_read): {"nodes" => ["tool-1:
  compose-background-suite glm-5.3 #1
    rulings (563a86aa -> fa67ba30): ['reason', 'score.static_silent', 'score.silent', 'facts.picture']
       reason: the picture is not the objective's (silent: suite_waited_on, extra_steps, over_read): {"nodes" => ["tool-1:tool", "tool-2:tool", "model-1:model", "tool-3:tool", -> the picture is not the objective's (silent: extra_steps, over_read): {"nodes" => ["tool-1:tool", "tool-2:tool", "model-1:model", "tool-3:tool", "model-2:model"]
       score.static_silent: ["suite_waited_on", "extra_steps", "over_read"] -> ["extra_steps", "over_read"]
       score.silent: ["suite_waited_on", "extra_steps", "over_read"] -> ["extra_steps", "over_read"]
       facts.picture: the picture is not the objective's (silent: suite_waited_on, extra_steps, over_read): {"no -> the picture is not the objective's (silent: extra_steps, over_read): {"nodes" => ["tool-1:
  compose-background-suite glm-5.3 #3
    rulings (563a86aa -> fa67ba30): ['reason', 'score.static_silent', 'score.silent', 'facts.picture']
       reason: the picture is not the objective's (silent: suite_waited_on, extra_steps, over_read): {"nodes" => ["tool-1:tool", "tool-2:tool", "model-1:model", "tool-3:tool", -> the picture is not the objective's (silent: extra_steps, over_read): {"nodes" => ["tool-1:tool", "tool-2:tool", "model-1:model", "tool-3:tool", "model-2:model"]
       score.static_silent: ["suite_waited_on", "extra_steps", "over_read"] -> ["extra_steps", "over_read"]
       score.silent: ["suite_waited_on", "extra_steps", "over_read"] -> ["extra_steps", "over_read"]
       facts.picture: the picture is not the objective's (silent: suite_waited_on, extra_steps, over_read): {"no -> the picture is not the objective's (silent: extra_steps, over_read): {"nodes" => ["tool-1:
  compose-background-suite glm-5.3-flash #2
    rulings (563a86aa -> fa67ba30): ['score.static_silent', 'score.silent', 'facts.picture']
       score.static_silent: ["suite_waited_on", "missing_steps"] -> ["missing_steps"]
       score.silent: ["suite_waited_on", "extra_steps", "over_sync", "over_read"] -> ["extra_steps", "over_read"]
       facts.picture: the picture is not the objective's (silent: suite_waited_on, extra_steps, over_sync, over_ -> the picture is not the objective's (silent: extra_steps, over_read): {"nodes" => ["tool-1:
  compose-grep-then-edit deepseek-flash #1
    rulings (563a86aa -> fa67ba30): ['score.silent', 'score.first_time_right', 'facts.picture']
       score.silent: ["extra_steps"] -> []
       score.first_time_right: false -> true
       facts.picture: the picture is not the objective's (silent: extra_steps): {"nodes" => ["script-1/tool-1:to -> true
  compose-grep-then-edit deepseek-flash #2
    rulings (563a86aa -> fa67ba30): ['score.static_silent', 'score.silent', 'score.first_time_right', 'score.static_first_time_right', 'facts.picture']
       score.static_silent: ["extra_steps", "over_read"] -> []
       score.silent: ["extra_steps", "over_read"] -> []
       score.first_time_right: false -> true
       score.static_first_time_right: false -> true
       facts.picture: the picture is not the objective's (silent: extra_steps, over_read): {"nodes" => ["tool-1: -> true
  compose-grep-then-edit deepseek-flash #3
    rulings (563a86aa -> fa67ba30): ['score.static_silent']
       score.static_silent: ["missing_steps"] -> ["wrong_task_read"]
    later readers (fa67ba30 -> main): ['score.static_silent']
       score.static_silent: ["wrong_task_read"] -> ["edit_as_stage"]
  compose-grep-then-edit kimi-k3 #1
    rulings (563a86aa -> fa67ba30): ['score.static_silent']
       score.static_silent: ["missing_steps"] -> ["wrong_task_read"]
    later readers (fa67ba30 -> main): ['score.static_silent']
       score.static_silent: ["wrong_task_read"] -> ["edit_as_stage"]
  compose-grep-then-edit kimi-k3 #2
    rulings (563a86aa -> fa67ba30): ['score.static_silent']
       score.static_silent: ["missing_steps"] -> ["wrong_task_read"]
    later readers (fa67ba30 -> main): ['score.static_silent']
       score.static_silent: ["wrong_task_read"] -> ["edit_as_stage"]
  compose-grep-then-edit kimi-k3 #3
    rulings (563a86aa -> fa67ba30): ['score.static_silent']
       score.static_silent: ["missing_steps", "over_sync"] -> ["over_sync"]
  compose-grep-then-edit glm-5.3 #1
    rulings (563a86aa -> fa67ba30): ['verdict', 'reason', 'score.static_silent', 'score.silent', 'score.first_time_right', 'facts.picture']
       verdict: {"reached": true, "succeeded": false, "task_pass": true, "class": "disagreement"} -> {"reached": true, "succeeded": true, "task_pass": true, "class": "cache under floor"}
       reason: the picture is not the objective's (silent: extra_steps): {"nodes" => ["tool-1:tool", "tool-2:tool", "tool-3:tool", "script-1/tool-1:tool", "script-1/tool-2:too -> null
       score.static_silent: ["missing_steps"] -> ["wrong_task_read"]
       score.silent: ["extra_steps"] -> []
       score.first_time_right: false -> true
       facts.picture: the picture is not the objective's (silent: extra_steps): {"nodes" => ["tool-1:tool", "too -> true
    later readers (fa67ba30 -> main): ['score.static_silent']
       score.static_silent: ["wrong_task_read"] -> ["edit_as_stage"]
  compose-grep-then-edit glm-5.3 #2
    rulings (563a86aa -> fa67ba30): ['reason', 'score.static_silent', 'score.silent', 'facts.picture']
       reason: the picture is not the objective's (silent: extra_steps, over_sync, over_read): {"nodes" => ["tool-1:tool", "tool-2:tool", "tool-3:tool", "script-1/tool-1:tool" -> the picture is not the objective's (silent: over_sync): {"nodes" => ["tool-1:tool", "tool-2:tool", "tool-3:tool", "script-1/tool-1:tool", "script-1/tool-2:tool"
       score.static_silent: ["missing_steps", "over_sync"] -> ["over_sync"]
       score.silent: ["extra_steps", "over_sync", "over_read"] -> ["over_sync"]
       facts.picture: the picture is not the objective's (silent: extra_steps, over_sync, over_read): {"nodes" = -> the picture is not the objective's (silent: over_sync): {"nodes" => ["tool-1:tool", "tool-
  compose-grep-then-edit glm-5.3 #3
    rulings (563a86aa -> fa67ba30): ['verdict', 'reason', 'score.static_silent', 'score.silent', 'score.first_time_right', 'facts.picture']
       verdict: {"reached": true, "succeeded": false, "task_pass": true, "class": "disagreement"} -> {"reached": true, "succeeded": true, "task_pass": true, "class": null}
       reason: the picture is not the objective's (silent: extra_steps): {"nodes" => ["tool-1:tool", "tool-2:tool", "tool-3:tool", "script-1/tool-1:tool", "script-1/tool-2:too -> null
       score.static_silent: ["missing_steps"] -> ["wrong_task_read"]
       score.silent: ["extra_steps"] -> []
       score.first_time_right: false -> true
       facts.picture: the picture is not the objective's (silent: extra_steps): {"nodes" => ["tool-1:tool", "too -> true
    later readers (fa67ba30 -> main): ['score.static_silent']
       score.static_silent: ["wrong_task_read"] -> ["edit_as_stage"]
  compose-grep-then-edit glm-5.3-flash #2
    rulings (563a86aa -> fa67ba30): ['score.static_silent', 'score.silent', 'score.first_time_right', 'facts.picture']
       score.static_silent: ["missing_steps"] -> ["wrong_task_read"]
       score.silent: ["extra_steps"] -> []
       score.first_time_right: false -> true
       facts.picture: the picture is not the objective's (silent: extra_steps): {"nodes" => ["tool-1:tool", "too -> true
    later readers (fa67ba30 -> main): ['score.static_silent']
       score.static_silent: ["wrong_task_read"] -> ["edit_as_stage"]
  TOTAL compose-background-suite: {'records': 12, 'ruling_moved_any': 5, 'ruling_moved_reading': 5}
  TOTAL compose-grep-then-edit: {'records': 12, 'ruling_moved_any': 10, 'ruling_moved_reading': 10, 'later_moved_any': 6}
== workflow: 12 records; control (main re-read vs record) differing: 0
  workflow-adversarial-verify deepseek-flash #1
    rulings (563a86aa -> fa67ba30): ['conduct', 'conduct_reasons', 'facts.read_before_dispatch']
       conduct: {"did_not_judge_itself": false} -> {"did_not_judge_itself": true}
       conduct_reasons: {"did_not_judge_itself": "the spine read lib/wallet.rb, lib/ledger.rb, lib/rate.rb itself"} -> {}
       facts.read_before_dispatch: null -> 3
  workflow-adversarial-verify deepseek-flash #2
    rulings (563a86aa -> fa67ba30): ['facts.read_before_dispatch']
       facts.read_before_dispatch: null -> 0
  workflow-adversarial-verify deepseek-flash #3
    rulings (563a86aa -> fa67ba30): ['facts.read_before_dispatch']
       facts.read_before_dispatch: null -> 0
  workflow-adversarial-verify kimi-k3 #1
    rulings (563a86aa -> fa67ba30): ['facts.read_before_dispatch']
       facts.read_before_dispatch: null -> 0
  workflow-adversarial-verify kimi-k3 #2
    rulings (563a86aa -> fa67ba30): ['facts.read_before_dispatch']
       facts.read_before_dispatch: null -> 0
  workflow-adversarial-verify kimi-k3 #3
    rulings (563a86aa -> fa67ba30): ['facts.read_before_dispatch']
       facts.read_before_dispatch: null -> 0
  workflow-adversarial-verify glm-5.3 #1
    rulings (563a86aa -> fa67ba30): ['facts.read_before_dispatch']
       facts.read_before_dispatch: null -> 0
  workflow-adversarial-verify glm-5.3 #2
    rulings (563a86aa -> fa67ba30): ['verdict', 'conduct', 'conduct_reasons', 'facts.read_before_dispatch']
       verdict: {"reached": true, "succeeded": true, "task_pass": true, "class": "model conduct"} -> {"reached": true, "succeeded": true, "task_pass": true, "class": "cache under floor"}
       conduct: {"did_not_judge_itself": false} -> {"did_not_judge_itself": true}
       conduct_reasons: {"did_not_judge_itself": "the spine read lib/wallet.rb, lib/ledger.rb, lib/rate.rb itself"} -> {}
       facts.read_before_dispatch: null -> 3
  workflow-adversarial-verify glm-5.3 #3
    rulings (563a86aa -> fa67ba30): ['facts.read_before_dispatch']
       facts.read_before_dispatch: null -> 0
  workflow-adversarial-verify glm-5.3-flash #1
    rulings (563a86aa -> fa67ba30): ['facts.read_before_dispatch']
       facts.read_before_dispatch: null -> 0
  workflow-adversarial-verify glm-5.3-flash #2
    rulings (563a86aa -> fa67ba30): ['facts.read_before_dispatch']
       facts.read_before_dispatch: null -> 0
  workflow-adversarial-verify glm-5.3-flash #3
    rulings (563a86aa -> fa67ba30): ['conduct', 'conduct_reasons', 'facts.read_before_dispatch']
       conduct: {"did_not_judge_itself": false} -> {"did_not_judge_itself": true}
       conduct_reasons: {"did_not_judge_itself": "the spine read lib/wallet.rb, lib/ledger.rb, lib/rate.rb itself"} -> {}
       facts.read_before_dispatch: null -> 3
  TOTAL workflow-adversarial-verify: {'records': 12, 'ruling_moved_any': 12, 'ruling_moved_reading': 3}
```

### `rulings_tally.py`

```python
#!/usr/bin/env python3
"""B(6) tally: per reader tree, the three cells' verdicts, picture-true counts, conduct and read_before_dispatch."""
import json, collections
B = "/private/tmp/claude-501/-Users-jasl-Workspaces-cybros-ai-alt2/fe6d4094-2f85-4b52-abfc-78043a70e275/scratchpad/v14/readout/b"
for fam in ("compose", "workflow"):
    for tree in ("563a86aa", "fa67ba30", "main"):
        rows = [json.loads(l) for l in open(f"{B}/rul_v14_{fam}_{tree}.jsonl", encoding="utf-8")]
        by = collections.defaultdict(list)
        for r in rows:
            by[r["task"]].append(r["fresh"])
        for task, fs in sorted(by.items()):
            succ = sum(1 for f in fs if f["verdict"]["succeeded"])
            pic = sum(1 for f in fs if f["facts"].get("picture") is True)
            cls = collections.Counter(f["verdict"]["class"] for f in fs)
            extra = ""
            if task == "workflow-adversarial-verify":
                dj = collections.Counter(f["conduct"].get("did_not_judge_itself") for f in fs)
                rbd = collections.Counter(f["facts"].get("read_before_dispatch") for f in fs)
                extra = f" did_not_judge_itself {dict(dj)} read_before_dispatch {dict(rbd)}"
            buckets = collections.Counter(b for f in fs for b in (f["score"].get("static_silent") or []))
            print(f"{tree:9} {task:28} succ {succ}/12 picture {pic}/12 class {dict(cls)}{extra}"
                  + (f" static buckets {dict(buckets)}" if fam == "compose" else ""))
```

Output `rulings_tally.out`:

```text
563a86aa  compose-background-suite     succ 8/12 picture 4/12 class {'model conduct': 4, None: 8} static buckets {'suite_waited_on': 5, 'extra_steps': 4, 'over_read': 4, 'missing_steps': 2, 'blind_model': 1, 'over_sync': 1}
563a86aa  compose-grep-then-edit       succ 8/12 picture 3/12 class {'disagreement': 4, 'cache under floor': 2, None: 5, 'model conduct': 1} static buckets {'missing_steps': 9, 'over_sync': 2, 'extra_steps': 2, 'over_read': 1, 'edit_as_tool': 1}
fa67ba30  compose-background-suite     succ 8/12 picture 4/12 class {'model conduct': 4, None: 8} static buckets {'extra_steps': 3, 'over_read': 4, 'missing_steps': 2, 'blind_model': 1}
fa67ba30  compose-grep-then-edit       succ 10/12 picture 8/12 class {'cache under floor': 3, 'disagreement': 2, None: 6, 'model conduct': 1} static buckets {'wrong_task_read': 6, 'over_sync': 2, 'missing_steps': 1, 'edit_as_tool': 1, 'extra_steps': 1}
main      compose-background-suite     succ 8/12 picture 4/12 class {'model conduct': 4, None: 8} static buckets {'extra_steps': 3, 'over_read': 4, 'missing_steps': 2, 'blind_model': 1}
main      compose-grep-then-edit       succ 10/12 picture 8/12 class {'cache under floor': 3, 'disagreement': 2, None: 6, 'model conduct': 1} static buckets {'edit_as_stage': 6, 'over_sync': 2, 'missing_steps': 1, 'edit_as_tool': 1, 'extra_steps': 1}
563a86aa  workflow-adversarial-verify  succ 6/12 picture 0/12 class {None: 3, 'model conduct': 3, 'cache under floor': 2, 'disagreement': 4} did_not_judge_itself {True: 8, False: 4} read_before_dispatch {None: 12}
fa67ba30  workflow-adversarial-verify  succ 6/12 picture 0/12 class {None: 3, 'cache under floor': 3, 'disagreement': 4, 'model conduct': 2} did_not_judge_itself {True: 11, False: 1} read_before_dispatch {0: 9, 3: 3}
main      workflow-adversarial-verify  succ 6/12 picture 0/12 class {None: 3, 'cache under floor': 3, 'disagreement': 4, 'model conduct': 2} did_not_judge_itself {True: 11, False: 1} read_before_dispatch {0: 9, 3: 3}
```

### `v13_rulings.py`

```python
#!/usr/bin/env python3
"""B(6) the v13 side: what the rulings' rescore commit (5de9f94a) moved on v13, per task — the last line
per key at 5de9f94a^ against at 5de9f94a (read with `git show`, nothing written)."""
import json, subprocess, collections
REPO = "/Users/jasl/Workspaces/cybros-ai.alt2"
def at(rev, label):
    out = subprocess.run(["git", "-C", REPO, "show", f"{rev}:e2e/evals/runs/{label}/records.jsonl"], capture_output=True, text=True, check=True).stdout
    d = {}
    for l in out.splitlines():
        if l.strip():
            r = json.loads(l); d[(r["task"], r["model"], r["run"])] = r
    return d
def buckets(r):
    s = r["facts"].get("score")
    return (s.get("static", {}).get("silent"), s.get("silent")) if hasattr(s, "get") else (None, None)
for label in ("2026-09-25-v13-compose", "2026-09-25-v13-workflow"):
    a, b = at("5de9f94a^", label), at("5de9f94a", label)
    tally = collections.defaultdict(collections.Counter)
    for k in b:
        if a[k] == b[k]:
            continue
        t = tally[k[0]]; t["lines"] += 1
        if a[k]["verdict"] != b[k]["verdict"]: t["verdict"] += 1
        if a[k].get("conduct") != b[k].get("conduct"): t["conduct"] += 1
        if buckets(a[k]) != buckets(b[k]): t["buckets"] += 1
        if (a[k]["facts"].get("picture") is True) != (b[k]["facts"].get("picture") is True): t["picture_flip"] += 1
    for task, t in sorted(tally.items()):
        print(label, task, dict(t))
```

Output `v13_rulings.out`:

```text
2026-09-25-v13-compose compose-background-suite {'lines': 6, 'buckets': 6}
2026-09-25-v13-compose compose-grep-then-edit {'lines': 8, 'verdict': 2, 'buckets': 8, 'picture_flip': 3}
2026-09-25-v13-workflow workflow-adversarial-verify {'lines': 12, 'conduct': 6, 'verdict': 4}
```

### `quotes.py`

```python
#!/usr/bin/env python3
"""Every blockquote in narrative.md must be verbatim (whitespace-normalized) from bench.yml's VERSION 14 note
or from analyze_q10.rb's resolutions header (comment markers stripped)."""
import re
REPO = "/Users/jasl/Workspaces/cybros-ai.alt2"
norm = lambda s: re.sub(r"\s+", " ", s).strip()
def comment_block(path, start, stop):
    lines = open(path, encoding="utf-8").read().split("\n")
    i = next(n for n, l in enumerate(lines) if start(l))
    j = next(n for n, l in enumerate(lines) if n > i and stop(l))
    return norm(" ".join(re.sub(r"^#\s?", "", l) for l in lines[i:j]))
note = comment_block(f"{REPO}/e2e/evals/bench.yml", lambda l: l.startswith("# VERSION 14"), lambda l: l.startswith("version: 14"))
header = comment_block(f"{REPO}/e2e/artifacts/bench/2026-09-26-q10/analyze_q10.rb", lambda l: l.startswith("# Q10"), lambda l: not l.startswith("#"))
quotes, cur = [], []
for l in open("narrative.md", encoding="utf-8").read().split("\n") + [""]:
    if l.startswith("> "):
        cur.append(l[2:])
    elif cur:
        quotes.append(norm(" ".join(cur))); cur = []
ok = 0
for q in quotes:
    src = "note" if q in note else ("analyzer" if q in header else None)
    ok += src is not None
    print(f"{'verbatim' if src else 'NOT FOUND'} ({src}): {q[:90]}…")
print(f"{ok} of {len(quotes)} quotes verbatim")
```

Output `quotes.out`:

```text
verbatim (note): PRE-REGISTERED: on every version-14 race follower the canceled-exit count is 0 and every d…
verbatim (analyzer): 2. THE INVARIANT (kernel). On every version-14 race follower `canceled_exits == 0` and `un…
verbatim (analyzer): 3. THE ARITHMETIC (harness). On every COMPOSED version-14 follower (`spine: false`), `foll…
verbatim (analyzer): 4. THE CENSUS. How many version-14 followers there are, how many read a race with a stage …
verbatim (analyzer): 5. FALLBACK. If version 14 carries zero stage-exit followers, the measurement's floor is t…
verbatim (note): On this bench the sentence is read by compose-race's and compose-race-anon's `authored_lab…
verbatim (note): T1's pre-registered race-cell read (`authored_labels`, version 13's 9/12 and 12/12) shares…
verbatim (note): Version 13 has one such row in 28 of 108 compose records — compose-background-suite 5, com…
verbatim (note): No race cell has it on version 13, so T1's race-cell read is untouched; every other compar…
verbatim (note): task-fan-five's driver moves `plain` -> `settle_receipts`, so the run is read at the quiet…
verbatim (note): The woken loops are traced beside the primary, not appended after the stop as `traced: fal…
verbatim (note): O2 NAMES A STAGE IN THE EDIT'S PLACE (`edit_as_stage`, the race-text design's Part 2; the …
verbatim (note): read offline, five readings move — the static readings of glm-5.3 #2 and #3 and deepseek-f…
verbatim (note): (1) O4 — a `start_process` launch's out-edges are no wait on the suite, so `suite_waited_o…
14 of 14 quotes verbatim
```
