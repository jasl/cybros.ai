# B — The pre-registered reads on bench version 13

Bench version 13 (digest `ab836ee0d8be`, kernel `c576fe9c`, records committed at `0649b3dd`): 240 records
(task 72, compose 108, workflow 60) on glm-5.3 and kimi-k3 (strong) and deepseek-flash and glm-5.3-flash
(floor), n = 3. This section executes the reads registered before the bench, as they were written. Every
number below comes from one of the scripts in §B.6, and each script's output sits beside it. The scripts
were run on 2026-09-25 against main `0649b3dd`. Nothing under `nexus/` or `e2e/support/` has changed since
the v13 kernel (§B.6 script 9), so main's compose builder is the one v13 ran. The work was read-only: no paid
calls, no worlds, no suites, and no record was rescored or rewritten.

## Verdicts

| Read | Verdict |
|---|---|
| **B1: L3's rollback rule** | **Keep the `<call>` line.** Clause (a) needs two or more models and fires on one: glm-5.3-flash compose-background-suite #3 has `reissued_calls` 1. `leaked_calls` reads 0 on all 238 records that carry round text; the other 2 are the lane-bug records, where no round settled. Clause (b) needs a compose cell to lose 2 or more of its 3 passes, and the largest loss in any of the 32 shared cells is 1 (6 cells). |
| **B2: race-reference reads** | (1) On the two race cells, every step that reads a race names the race: 24 of 24. No step names a member and no model step reads implicitly. On v11 the 12 reading steps split race 0, member 4, implicit model step 8. (2) `losers_completed` is 0 on 24 of 24 runs (v11: 0 on 8 of 12). (3) `no_wrong_winner` is green on 24 of 24: compose-race 12/12 against v11's 11/12, and compose-race-anon 12/12 (a new cell). (4) Every model reads the same on both cells: race named 3/3, losers stopped 3/3, winner claim right 3/3. |
| **B3: S1's bite on v13** | **Zero.** The census covers 118 compose calls in 107 records across compose, workflow and task. There are no `race_member` refusals at the top level, in stage expansions or in result-reading stage bodies. No failed stage and no world log carries the sentence. No member-naming reference built. On v11's saved records, S1's builder would have refused 4 runs (all GLM). The v12 note and the S1 readout name 3. |
| **B4: T1** | The row's precondition asks for "version 12's compose-race-anon readout". That readout can never exist, because v12 ran only two driver smokes. v13's compose-race-anon (12 runs) meets the precondition in substance: its `<call>` bytes and its 7,863-byte compose text are identical to v12's, and neither carries T1's sentence. The A/B is specified in §B4 and is ready to launch once the owner confirms that substitution and settles six open parameters. |

## B1. L3's rollback rule

### The rule, verbatim

From `e2e/evals/bench.yml` (the version-12 note, lines 182-190):

> PRE-REGISTERED ROLLBACK: the `<call>` line comes out, or the element
> is renamed and measured again, if on version 12 either holds: (a)
> `leaked_calls` above 0, or `reissued_calls` above the model's
> version-11 count (0 on all four), on the runs of two or more models;
> (b) a compose cell loses two or more of its three passes against the
> same model's version-11 cell (the picture on the strong tier, usable
> generation on the floor). Beside the rule, never triggering it:
> `authored_labels` on compose-race against version 11's 9 of 12, and
> whether compose-race-anon's runs that wrote no labels name the winner.

The same note defines the two counts it reads (lines 171-181):

> Every record
> gains two counts: `leaked_calls`, a settled round that made no tool
> call and wrote the element as its call on a line of its own outside a
> fence — a reply QUOTING the delivered line as its evidence is no leak
> (version-11 records carry no round text, so it has no baseline); and
> `reissued_calls`, a tool call running again a composed tool step its
> own thread read, same name and input, with no edit, write or other
> bash command settled between — a run again after a change is
> verification. Rescored with this definition over the saved traces,
> version 11's 228 compose, workflow and task records read 0 on every
> model (version 10: 1, glm-5.3 compose-background-suite #3).

The weak-models plan (D12, the dated 2026-09-24 sub-bullet) adds only where the rule is measured:

> Measured on bench version 12 on a new cell, compose-race-anon, whose probes print no host; the rollback
> rule is written into the version-12 note.

DEFERRALS adds no term to the rule. Its three L3 rows cover other questions: T1 (quoted in §B4), a model
step's identity, and whether a race counts an `is_error` completion. The T1 row fixes what the anon cell
reads: "Version 12 ships the `<call>` line alone, so compose-race-anon and `authored_labels` read the line
without the sentence."

**Which version the rule is read on.** The rule says "on version 12". Version 12 ran only two driver smokes,
until-ladder and handoff-mid-conversation, both on glm-5.3, and both read `leaked_calls` 0 and
`reissued_calls` 0. Version 13 is therefore the first full bench carrying the `<call>` line, and the rule is
read here. Between v11 and v13 more than the line moved: the race-reference text (+417 bytes), S1, the
novelty brake, the removed candidates, the pairing picture, per-run project directories, `timeout_ms` on
inbox rows, and the Q1 attendant. A firing therefore could not have been pinned on `<call>` alone, but none
fired. v11's baseline was re-verified off the saved traces (§B.6 script 2): `reissued_calls` sums to 0 on
all 228 records, 57 per model. `leaked_calls` reads nil on every one of them because v11 kept no round text,
as the note says.

### (a) `leaked_calls` and `reissued_calls` (script 1)

| model | records | `leaked_calls` > 0 | `leaked_calls` nil | `reissued_calls` > 0 (sum) |
|---|---|---|---|---|
| glm-5.3 | 60 | 0 | 1 (compose-background-suite #3: lane bug, 0 rounds settled) | 0 (0) |
| kimi-k3 | 60 | 0 | 0 | 0 (0) |
| deepseek-flash | 60 | 0 | 0 | 0 (0) |
| glm-5.3-flash | 60 | 0 | 1 (compose-grep-then-edit #1: lane bug, 0 rounds settled) | **1 (1)**, compose-background-suite #3 |

One model is over its v11 count and the clause needs two, so **(a) does not hold.**

The one re-issued call is in glm-5.3-flash compose-background-suite #3 (script 11). The composed fix step
`r2t0-model-1` was handed the lint result `r2t0-tool-2` (`bin/rubocop app`, completed 20:04:05Z). In its
first round it made `r3t1`, the same `bin/rubocop app` (created 20:04:07Z), beside a `read`. The only other
call that settled in between was that `read`, and nothing edited files. The composing model's own brief for
that step allowed it to re-run the lint when the text looks truncated. v10's single re-issue was on the same
task (glm-5.3 #3). This is a task-shaped pattern: a lint handed to a fixer gets re-run by the fixer. It is
not a misreading that spreads across models.

### (b) Compose cells against the same model's v11 cell (script 1)

`verdict.succeeded` is the picture on the strong tier and usable generation on the floor, the same bar on
both versions (the tier fact reads the same in v11 and v13). "L" marks the records classed lane bug in that
v13 cell.

| cell | glm-5.3 | kimi-k3 | deepseek-flash | glm-5.3-flash |
|---|---|---|---|---|
| compose-background-suite | 1→1 (L1) | 0→1 | 3→3 | 3→3 |
| compose-grep-then-edit | 0→0 | 2→1 | 3→3 | 3→2 (L1) |
| compose-race | 2→3 | 2→3 | 3→3 | 3→3 |
| compose-race-anon | new, 3/3 | new, 3/3 | new, 3/3 | new, 3/3 |
| compose-rendezvous | 3→3 | 2→3 | 3→3 | 1→2 |
| compose-review-angles | 3→2 | 3→3 | 3→3 | 3→3 |
| compose-single-read | 3→3 | 3→3 | 3→3 | 3→3 |
| compose-three-stage-pairing | 2→2 | 3→2 | 3→3 | 3→2 |
| compose-two-source-fan-in | 1→0 | 0→0 | 3→3 | 3→3 |

Of the 32 shared cells, 6 moved by −1, 21 held and 5 moved by +1. No cell lost two, so **(b) does not
hold.** The lane-bug runs cannot change this in either direction: counting them as passes still leaves no
cell 2 down. compose-race-anon has no v11 cell, so (b) cannot apply to it, but it reads 3/3 on all four
models.

### Beside the rule (never triggering; scripts 1 and 4)

| | glm-5.3 | kimi-k3 | deepseek-flash | glm-5.3-flash | total |
|---|---|---|---|---|---|
| compose-race `authored_labels`, v11 (re-read under the pre-S1 builder, script 4) | 2/3 | 3/3 | 3/3 | 1/3 | **9/12** (the note's "9 of 12", reproduced) |
| compose-race `authored_labels`, v13 | 1/3 | 3/3 | 3/3 | 2/3 | **9/12** |
| compose-race-anon `authored_labels`, v13 | 3/3 | 3/3 | 3/3 | 3/3 | **12/12** |
| compose-race-anon runs with no labels | 0 | 0 | 0 | 0 | **0**, so the companion read has no runs |
| compose-race-anon `named_bravo` / `no_wrong_winner` | 3/3 / 3/3 | 3/3 / 3/3 | 3/3 / 3/3 | 3/3 / 3/3 | 12/12 / 12/12 |
| `success_filter`: race / anon | 0 / 1 | 0 / 0 | 2 / 2 | 0 / 0 | 2/12 / 3/12 |
| `hedged_brief`: race / anon | 1 / 0 | 0 / 0 | 0 / 0 | 0 / 0 | 1/12 / 0/12 |

The recorded facts equal a fresh re-read on every run (script 4: 0 disagreements on all three facts in both
cells).

**Reading.** The companion read ("whether compose-race-anon's runs that wrote no labels name the winner")
has nothing to read: every one of the 12 anon runs authored its own labels. This is what the design
predicts, not a sign that the line failed. The instruction forbids reading or running anything before the
script is written, so the composing model can learn about the `<call>` line only from the compose text, and
the compose text says nothing about it (T1 is held back). Every anon reply named bravo and none named a
loser, but each run had its own label to read, so the replies cannot show the line's contribution. The
anon cell therefore gives T1 its exe/rho baseline: labels authored in 12 of 12 runs on the cell where only
the `<call>` line names the host.

### Verdict

**Keep the `<call>` line.** Neither clause holds, so neither the rollback nor the rename-and-remeasure is
triggered.

## B2. The race-reference reads

### The reads, verbatim

From `e2e/evals/bench.yml` (the version-12 note, lines 215-234):

> THE READS, registered on version 11's records with version 12's
> readers. Baselines, compose-race at n = 3: kimi-k3 2/3 (both passes a
> race and a `g.model`; #2 refused on `member_not_a_step`, a regroup
> error the race grammar does not touch), glm-5.3 2/3 (#1 a stage inside
> a stage naming every probe, `over_sync`); the floors usable 3/3 each,
> the picture 2/3 (deepseek-flash) and 1/3 (glm-5.3-flash). Only GLM
> wrote a reader naming a member (glm-5.3 #1, glm-5.3-flash #1 and #2).
> (1) Of the steps reading a race, the share naming the race against the
> share naming a member. (2) `losers_completed` 0 on every run whose
> race's reader names the race or is a model step; version 11 reads 0 on
> 8 of 12 — 2 on the three member-naming runs (glm-5.3-flash #2's
> picture read green through the answer-stage dropout, a ledger row) and
> on glm-5.3-flash #3, whose raced value stages completed in the same
> walk. (3) `no_wrong_winner` green on every run whose race members are
> the probes; probes run in sequence outside the race (version 11
> glm-5.3-flash #3, "alpha won") are an expected red. Version 11 reads
> 11/12, that run the red; version 10 10/12 (kimi-k3 #3 and glm-5.3 #3
> read a stage's list order); every reply that corrected a stage reads
> green. (4) The column is the endpoint: a move of 1 in 3 is unread at
> n = 3 (D8), so reads 1-3 are what version 12 is read on.

The note names no workflow record, and no v13 workflow or task route holds a race: the 24 race joins on
every v13 graph are one per run in the two race cells (script 6). The paired text-bench arm registered next
to these reads ("PAIRED THE SAME DAY … R-WO on main against R-RACE on the branch") lies outside the records.
No readout of it exists under `docs/plans/` or `e2e/artifacts/bench/`, and `R-RACE` appears in git history
only in the v12 commit.

### How a reader is classified (script 3)

Each compose call is rebuilt with the builder. Its result-free stages are inlined, and each result-reading
stage body is run once with `results: []`. For every race (`until` any or a count), the script walks the
steps written after it, outside it. Each such step is classified as one of:

- **names the race**: its `after`/`results` holds the race's key;
- **names a member**: its `after`/`results` holds a leaf of the race, at any depth, stage expansions
  included, which is S1's own notion of a member;
- **implicit model step**: the first step after the race is a `g.model` with no reference of its own.

The route gives an independent check: an edge from a leaf of a race's arm into a node outside the race. For
v13 the builder is main's, which is the v13 kernel's, and the kernel and the builder agreed on whether every
one of the 118 calls built. For the v11 baseline the builder is read in memory at `56469b97`. That is v12's
grammar before S1: it mints race keys as main's harness expects, and it agrees with the v11 kernel on every
one of v11's 105 calls. v11's own builder (`320d2050`) mints no race keys, so main's harness cannot lower
its steps.

### (1) Share of reading steps naming the race vs a member

| cell | glm-5.3 | kimi-k3 | deepseek-flash | glm-5.3-flash | all (reading steps) |
|---|---|---|---|---|---|
| v11 compose-race | member 1, implicit 2 | implicit 3 | implicit 2 (#2 has no reader) | **member 3**, implicit 1 | race **0/12**, member **4/12**, implicit model 8/12 (11/12 runs have a reader) |
| v13 compose-race | race 3 | race 3 | race 3 | race 3 | race **12/12**, member **0/12**, implicit 0/12 |
| v13 compose-race-anon | race 3 | race 3 | race 3 | race 3 | race **12/12**, member **0/12**, implicit 0/12 |

On v11, naming the race was not yet in the grammar, which is why that share is 0. On v13, every model on
both tiers names the race in every run. That holds whether the reader is a closing `g.script` or a
`g.model`, and whether the race sits at the top level or inside a whole-plan wrapper stage.
The three race-cell runs whose first compose call did not build a plan (script 8) also wrote `results: [race]`
in their first text: deepseek-flash race #1 (the script carried literal `\n` escapes, refused `syntax`),
glm-5.3-flash race #1 (the script was wrapped in backticks, built 0 steps and placed nothing, so it was not
refused), and deepseek-flash race-anon #3 (refused `member_not_a_step`). **S1 played no part in this share:**
it refused nothing on v13 (§B3), so the models did not write a member reference in the first place.

**Baseline correction: v11 had four member-naming runs, not three.** The note, and after it the S1
readout, list glm-5.3 #1 and glm-5.3-flash #1 and #2. Three independent reads agree on a fourth,
**glm-5.3-flash #3**:

- The pre-S1 builder's plan: the closing stage `script-1/script-4` holds `results: [alphaW, bravoW, charlieW]`,
  which are the three wrap stages the race formed from.
- The route shows 3 waits from those race leaves into that stage.
- Main's builder refuses that stage body with the `race_member` sentence (`results names "script-1", a member
  of the race on line 22`).

The note filed #3 under two other headings: "probes run in sequence outside the race" for read (3), and
"raced value stages completed in the same walk" for read (2). Both descriptions are true. Its probes do sit
outside the race, but its reader also names the race's members. The four `losers_completed` = 2 runs in v11
are exactly the four member-naming runs (script 5 re-reads the losers off the route: glm-5.3 #1 and
glm-5.3-flash #1, #2, #3 read 2, every other run reads 0). Only GLM wrote any of them, as the note says.

### (2) `losers_completed` 0 where the reader names the race or is a model step

| | glm-5.3 | kimi-k3 | deepseek-flash | glm-5.3-flash | total |
|---|---|---|---|---|---|
| v11 (script 5) | 0 on 2 of 3; #1 (member) 2 | 0 on 3 of 3 | 0 on 3 of 3 | #1, #2, #3 (member) 2 | 0 on 8/12; every run with no member reader reads 0 |
| v13 compose-race | 0 on 3/3 | 0 on 3/3 | 0 on 3/3 | 0 on 3/3 | **0 on 12/12** |
| v13 compose-race-anon | 0 on 3/3 | 0 on 3/3 | 0 on 3/3 | 0 on 3/3 | **0 on 12/12** |

Every v13 race stopped its losers. The read holds on all 24 runs it covers, and v13 has no member-naming run
on which to see its converse.

### (3) `no_wrong_winner` green where the race's members are the probes

| | glm-5.3 | kimi-k3 | deepseek-flash | glm-5.3-flash | total |
|---|---|---|---|---|---|
| v11 compose-race (script 5 re-read) | 3/3 | 3/3 | 3/3 | 2/3 (#3 "alpha won", probes outside the race) | **11/12**, matching the note |
| v13 compose-race | 3/3 | 3/3 | 3/3 | 3/3 | **12/12** |
| v13 compose-race-anon | 3/3 | 3/3 | 3/3 | 3/3 | **12/12** |

In all 24 v13 runs every `bin/probe` call is a leaf of the race (script 3's "probes all inside a race" is
`true` 24 of 24). None of them raced value stages over probes that ran outside, so v13 has no expected red,
and none occurred.

### (4) The columns

compose-race, `verdict.succeeded` and the `picture` fact, per model (script 1):

| | glm-5.3 | kimi-k3 | deepseek-flash | glm-5.3-flash |
|---|---|---|---|---|
| v11 succeeded / picture | 2/3 / 2 | 2/3 / 2 | 3/3 / 2 | 3/3 / 1 |
| v13 succeeded / picture | 3/3 / 3 | 3/3 / 3 | 3/3 / 2 | 3/3 / 2 |
| v13 anon succeeded / picture | 3/3 / 3 | 3/3 / 3 | 3/3 / 2 | 3/3 / 3 |

Each picture move is 1 in 3, which the note calls unread at n = 3, so reads 1-3 carry the verdict. Those
reads are uniform: in every column of both cells, the reader names the race, the losers stop and the winner
claim is right. Each floor model's missing picture on compose-race is a first call that did not build a plan
(deepseek-flash #1 `syntax`; glm-5.3-flash #1, the backtick wrapper that placed nothing). Both repaired
within the run, which is why usable reads 3/3.

## B3. S1's bite on v13

**Sources checked.** Four sources were checked, over every v13 compose, workflow and task record:

1. Every compose call (first calls, repairs and later calls) was rebuilt through main's builder, which is
   the v13 kernel's. The refusal detail was matched against
   `/a member of (?:the race on line \d+|an earlier race); a race stops the members it did not select/`.
2. Every result-free stage was inlined. Every result-reading stage body was run once with `results: []`,
   the S1 A/B's own "apart" detector.
3. On the route: every failed stage and its `error_key`, and every wait from a race leaf into a node
   outside the race.
4. `grep` over every saved trace JSON and every world log, with a positive control.

| | v13 compose | v13 workflow | v13 task | total |
|---|---|---|---|---|
| records / with a compose call | 108 / 93 | 60 / 13 | 72 / 1 | 240 / 107 |
| compose calls (first / later) | 104 (93 / 11) | 13 (13 / 0) | 1 (1 / 0) | 118 (107 / 11) |
| built / refused by the builder | 97 / 7 | 13 / 0 | 1 / 0 | 111 / 7 |
| **`race_member` refusals, top level** | **0** | **0** | **0** | **0** |
| **`race_member` in an inlined stage / a result-reading stage run with no results** | **0 / 0** | **0 / 0** | **0 / 0** | **0 / 0** (71 result-reading stages, 1 placing steps on empty results) |
| failed stages on the route | 2 (both `script_syntax_error`) | 0 | 0 | 2 |
| **world logs and traces holding the sentence** | **0** | **0** | **0** | **0** (control: 2 of 2) |
| kernel/builder disagreements on whether a call built | 0 | 0 | 0 | 0 |
| races placed | 24 (compose-race 12, compose-race-anon 12) | 0 | 0 | 24 |
| **member-naming references that built** (static readers + route waits) | **0** | **0** | **0** | **0** |

The 7 refusals and where each occurred (script 3a):

- `syntax` 3: compose-grep-then-edit deepseek-flash #2, compose-race deepseek-flash #1, compose-review-angles glm-5.3 #3;
- `after_in_input`: compose-rendezvous glm-5.3-flash #1;
- `group_reference`: compose-review-angles glm-5.3-flash #1;
- `member_not_a_step`: compose-race-anon deepseek-flash #3;
- `unknown_option`: compose-background-suite deepseek-flash #1.

All 7 were first calls. The 2 static stage refusals are both `syntax`: compose-grep-then-edit glm-5.3 #1
and compose-three-stage-pairing kimi-k3 #1. The same two runs account for the 2 route failures.

**Count: 0.** S1's refusal occurred nowhere on v13: not on a first call, a repair, an inlined stage or a
stage run. No member-naming reference built either. That list was expected to be empty, and it is.

**What S1 would have met on v11** (script 3 under main's builder over v11's saved records): 4 runs, all GLM
compose-race. One is at the top level (glm-5.3-flash #1, which the v11 kernel built). Three are stage bodies
that main's inliner now strikes (glm-5.3 #1, glm-5.3-flash #2, glm-5.3-flash #3). Two sources expected three.
The v13 note in `bench.yml` says "compose-race's member readers (v11: glm-5.3 #1, glm-5.3-flash #1 and #2)
now meet the refusal". The S1 readout counts "The compose-race readers that named a probe". glm-5.3-flash
#3's reader names the raced wrap stages, not a probe, and S1 refuses any leaf of a formed race, so #3 is the
fourth. On v13 none of the four spellings recurred, so the refusal had nothing to
refuse. As the S1 readout itself warned, the A/B could show that S1 costs the floors nothing but not what it
buys. v13 cannot show what it buys either.

## B4. T1: the compose text's sentence about the `<call>` line

### The pre-registered design, verbatim

From `docs/plans/DEFERRALS.md` (the S-V block):

> - **T1, the compose text's sentence about the `<call>` line** (L3's behaviour arm; held back by the owner's Q3 of 2026-09-24, which adopted the L3 critique's sequencing): one sentence in the compose text's ORDER paragraph — "Every tool result, read by a model step or delivered to you, names the call that produced it: the tool and the start of its input." — telling the composing model that a delivered result names its call, so the labels it authors to tell the race's probes apart become redundant. Version 12 ships the `<call>` line alone, so compose-race-anon and `authored_labels` read the line without the sentence. The arm is the text bench's (the weak-models plan §3): R-WO against R-L3 on O3, pooled over the four models; it lands when O3's `authored_labels` share drops with the one-sided 90 % bound of the drop above 0, it holds the floor gate (pooled `usable`, the bound at −5 points or better), and no objective's expanded `first_time_right` falls by 2 or more (n = 6); else it does not land. → **the text bench, after version 12's compose-race-anon readout**

The weak-models plan §3 (the rules the row points at):

> **Floor gate:** pooled `usable`, the arm rejected when the one-sided 90 % bound of the difference is below
> −5 points; a per-objective ≥ 2/6 loss is a flag, never a veto.

and "`E2E_BENCH_MAX_OUTPUT_TOKENS=65536` for every arm", "Arms run from an unmerged bench branch that carries
`Rows::VARIANTS` (main keeps its pin)".

### Is the precondition met?

**In substance, yes. In letter, it cannot be.** The row waits for "version 12's compose-race-anon readout".
Version 12 ran only two driver smokes, so that readout will never exist. The first compose-race-anon cells
ran on version 13. Script 9 shows that between v12 (`bf6e5af0`) and the v13 kernel (`c576fe9c`) the change
touches none of the `<call>` line's bytes: no changed line in `task_result_envelope.rb` mentions `<call>`.
The envelope gains an `origin` helper for the repeat brake and re-points one call
(`ExpandRound.source_round` becomes `InputComposition.source_round`). The compose text is unchanged at 7,863
bytes and holds no T1 sentence. The only builder change is S1, which adds a refusal sentence and changes no
compose text. So v13's compose-race-anon measures what v12's would have measured. Its readout is §B1 of this
document: `authored_labels` 12/12, no run without labels, rollback not triggered. **Decision owed:** the owner should
confirm that v13's compose-race-anon readout stands in for "version 12's". Once confirmed, T1 can launch next.

### The A/B, as prescribed

| | |
|---|---|
| **Arms** | **R-WO**: main's shipped compose bytes (`Rows.shipped`, 7,863 B; `Rows.ids` is `["R-WO"]` on main). **R-L3**: R-WO plus the one sentence, verbatim, in the ORDER paragraph (`nexus/lib/nexus/tool_registry/graph.rb:40`, "STEPS RUN IN THE ORDER YOU WRITE THEM …"). R-L3 is written as a `Rows::VARIANTS` entry through `recut` on an unmerged bench branch, with the row pin checking that the row's diff is exactly its one edit. Both arms launch together, same day. |
| **Models** | The four tier models: `openrouter/z-ai/glm-5.3`, `openrouter/moonshotai/kimi-k3`, `deepseek/deepseek-flash`, `openrouter/z-ai/glm-5.3-flash`. Style `nexus`. |
| **Objectives** | The endpoint is O3. The guard reads "no objective", so every objective runs: O1, O2, O3, O4, O5 (the control), O7, O7b, T5 (`Objectives.ids`). |
| **n** | 6 per (arm, model, objective): O3 has 24 samples per arm, pooled. The whole run is 8 × 4 × 6 = 192 samples per arm, 384 in all. |
| **Cap** | `E2E_BENCH_MAX_OUTPUT_TOKENS=65536`. |
| **Endpoint** | The share of O3 samples whose first script's expanded plan carries `authored_labels` (`Endpoints.read`, recorded per sample by `Probe#reading` on main), pooled over the four models, R-WO against R-L3. |
| **Landing rule** | Lands only if all three hold: (1) the drop, R-WO minus R-L3, has a one-sided 90 % lower bound above 0 (Newcombe hybrid, z = 1.2816, the arithmetic of the S1 and 09-23 analyzers); (2) the floor gate: pooled `usable`, the lower bound of R-L3 minus R-WO at −5 points or better; (3) no objective's expanded `first_time_right` falls by 2 or more (n = 6). Otherwise it does not land. |
| **Launch** | `E2E_LIVE=1 RAILS_ENV=development rake live_compose_matrix` with `E2E_BENCH_ROWS=R-WO,R-L3 E2E_BENCH_MODELS=openrouter/z-ai/glm-5.3,openrouter/moonshotai/kimi-k3,deepseek/deepseek-flash,openrouter/z-ai/glm-5.3-flash E2E_BENCH_SAMPLES=6 E2E_BENCH_MAX_OUTPUT_TOKENS=65536 E2E_BENCH_STYLES=nexus E2E_BENCH_DIR=<bench dir> E2E_BENCH_CAPTURES_DIR=<bench dir>`, run from the bench branch. The captures dir keeps the strong tier's cells out of the nexus fixtures, as the probe test's header asks. |

**Power at 24 per arm** (script 10). If R-WO reads 24/24, R-L3 must read 22/24 or lower. At 21/24 it must
read 17/24 or lower, and at 18/24, 13/24 or lower. In other words, the sentence has to remove labels from
roughly 2 to 5 of the 24 O3 samples. On exe/rho, the anon cell authored labels in 12 of 12 runs and
compose-race in 9 of 12. If the text bench's R-WO sits near the top of that range, a drop of two samples
suffices.

**Parameters the row leaves open. Each needs a ruling before launch, because each can change the verdict.**

1. **The sentence's anchor inside the ORDER paragraph.** The row says only "in the ORDER paragraph".
2. **The floor gate's pool.** The endpoint is pooled over the four models, and the S1 A/B pooled `usable`
   over the two floors and every non-control objective. The T1 row does not say which pool the floor gate
   uses.
3. **Which `usable`.** The text bench's own `usable` reads the first script (`Probe#reading`), while the S1
   A/B's gate read "usable after repair".
4. **The unit of the "falls by 2" guard.** One reading is per (model, objective) cell at n = 6, which the
   "(n = 6)" suggests. The other is per objective pooled over models.
5. **The endpoint's denominator.** The text bench records endpoints only on a first script that built, and
   its report reads them "over the first scripts that built" (`Report#pooled_lines`). The row's "O3's
   `authored_labels` share" names no denominator, so it is either that or every reached O3 sample.
6. **Whether O2 is back in the guard.** Plan §3 held O2 "out of the rule until §6 is ruled", and the
   2026-09-24 ruling (b) answered that question.

## B5. Notes on the harness and the scorer

- **The v12 note and the S1 readout undercount v11's member-naming runs as 3.** By S1's definition, a leaf
  of a formed race, there are 4. glm-5.3-flash #3's closing stage names the three raced wrap stages. The
  ledger baseline for read (1) should read race 0/12, member 4/12, implicit model step 8/12 (runs: 4 of 12).
- **Offline re-reads of pre-v13 race records depend on the builder revision.** `Predicates.over_plans` drops
  any call or stage that the current builder refuses. Re-reading v11 through main's harness with main's
  builder therefore gives `authored_labels` 8/12, because S1 strikes glm-5.3-flash #3's stage and its labels
  disappear. The note's 9/12 reproduces only under the pre-S1 builder. Any later re-read of v11/v12 race
  facts has to name the builder it ran under.
- **The rollback rule is keyed to "version 12" and T1 to "version 12's compose-race-anon readout".** Neither
  version-12 event happened, because v12 ran two smokes, so both are read on v13. For the rule this is
  harmless, since it did not fire. For T1 it is the one decision owed before launch.
- **`leaked_calls` is nil on the two deadline-stopped lane-bug records**, where no round settled. It is
  correctly "not read" rather than 0. The 238 read records are the denominator.
- **In the Bash tool's interactive shell, `grep` is a function that runs ugrep** with `--ignore-files -I`.
  Script 7 is run under `zsh` non-interactively, where `grep` is `/usr/bin/grep`, and it carries a positive
  control, so its zero does not depend on which grep ran.

## B.6 Scripts and their outputs

Paths are relative to the repository root `/Users/jasl/Workspaces/cybros-ai.alt2`. Each script names its
working directory. Ruby runs from `e2e/` with `bundle exec ruby -I.` (it loads `mini_racer` and
`support/compose_bench` as the brief prescribes), and every file is read with `encoding: "UTF-8"`. To re-run
a script, save the block to a file and run it as its header says.

### 1. The rollback rule, clauses (a) and (b), and the facts beside it (python3, cwd `e2e/evals/runs`)

```python
# B(1): L3's pre-registered rollback rule, read on the v13 records (and v12's two smokes), against v11's.
# Usage (cwd = e2e/evals/runs): python3 <this file>
import json, collections, glob, itertools
def load(d): return [json.loads(l) for l in open(f'{d}/records.jsonl', encoding='utf-8')]
short = lambda m: m.split('/')[-1]
MODELS = ['glm-5.3', 'kimi-k3', 'deepseek-flash', 'glm-5.3-flash']
v13 = [r for fam in ('task', 'compose', 'workflow') for r in load(f'2026-09-25-v13-{fam}')]
v12 = [r for d in sorted(glob.glob('2026-09-24-v12-*')) for r in load(d)]
v11c = load('2026-09-24-v11-compose'); v13c = load('2026-09-25-v13-compose')
print(f"v13 records {len(v13)}; digests {sorted(set(r['bench_digest'][:12] for r in v13))}; v12 smokes {len(v12)} ({sorted(set(short(r['model']) for r in v12))})")

print("\n(a) leaked_calls / reissued_calls, per model (v11 reissued baseline 0 on all four, per the v12 note)")
print(f"{'model':15s} {'records':>7s} {'leaked>0':>8s} {'leaked nil':>10s} {'reissued>0':>10s} {'reissued sum':>12s}")
over = collections.defaultdict(list)
for m in MODELS:
    rs = [r for r in v13 if short(r['model']) == m]
    lk = [r for r in rs if (r['facts'].get('leaked_calls') or 0) > 0]
    ln = [r for r in rs if r['facts'].get('leaked_calls') is None]
    ri = [r for r in rs if (r['facts'].get('reissued_calls') or 0) > 0]
    print(f"{m:15s} {len(rs):7d} {len(lk):8d} {len(ln):10d} {len(ri):10d} {sum(r['facts'].get('reissued_calls') or 0 for r in rs):12d}")
    if lk or ri: over[m] = [f"{r['task']} #{r['run']} leaked={r['facts'].get('leaked_calls')} reissued={r['facts'].get('reissued_calls')}" for r in lk + ri]
    for r in ln: print(f"   leaked nil: {r['task']} #{r['run']} rounds_settled={r['facts'].get('rounds_settled')} class={r['verdict']['class']!r} stopped={r.get('stopped')}")
for m, rows in over.items(): print(f"   over: {m}: {rows}")
print("   v12 smokes: " + "; ".join(f"{r['task']} leaked={r['facts'].get('leaked_calls')} reissued={r['facts'].get('reissued_calls')}" for r in v12))
print(f"   models with leaked>0 or reissued>0: {len(over)} -> (a) {'HOLDS' if len(over) >= 2 else 'does not hold'} (needs two or more models)")

print("\n(b) compose cells, passes v11 -> v13 (verdict.succeeded: the picture on strong, usable on the floor)")
key = lambda r: (r['task'], short(r['model']))
cells = lambda recs: {k: list(g) for k, g in itertools.groupby(sorted(recs, key=key), key=key)}
c11, c13 = cells(v11c), cells(v13c)
print(f"   tiers v11 {dict(sorted({short(r['model']): r['facts'].get('tier') for r in v11c}.items()))}; v13 {dict(sorted({short(r['model']): r['facts'].get('tier') for r in v13c}.items()))}")
passes = lambda rs: sum(r['verdict']['succeeded'] is True for r in rs)
print(f"   {'task':29s}" + "".join(f"{m:>17s}" for m in MODELS))
fired, worst, deltas = [], 0, collections.Counter()
for t in sorted({t for t, _ in c13}):
    row = []
    for m in MODELS:
        b = c13[(t, m)]; lane = sum(r['verdict']['class'] == 'lane bug' for r in b)
        if (t, m) not in c11: row.append(f"new {passes(b)}/3"); continue
        a = passes(c11[(t, m)]); d = passes(b) - a; worst = min(worst, d); deltas[d] += 1
        if d <= -2: fired.append((t, m, a, passes(b)))
        row.append(f"{a}->{passes(b)}{' L' + str(lane) if lane else ''}{' (' + format(d, '+d') + ')' if d else ''}")
    print(f"   {t:29s}" + "".join(f"{x:>17s}" for x in row))
print(f"   (L = records classed lane bug in that v13 cell) cells by change: {dict(sorted(deltas.items()))} over {sum(deltas.values())} shared cells")
print(f"   largest loss in a cell: {worst}; cells losing two or more: {fired} -> (b) {'HOLDS' if fired else 'does not hold'}")

print("\nbeside the rule (never triggering)")
for task in ('compose-race', 'compose-race-anon'):
    rs = [r for r in v13c if r['task'] == task]
    for fact in ('authored_labels', 'named_bravo', 'success_filter', 'hedged_brief'):
        by = {m: sum(r['facts'].get(fact) is True for r in rs if short(r['model']) == m) for m in MODELS}
        print(f"   v13 {task} {fact}: {sum(by.values())}/{len(rs)} {by}")
    print(f"   v13 {task} no_wrong_winner green: {sum(r['conduct'].get('no_wrong_winner') is True for r in rs)}/{len(rs)}")
anon = [r for r in v13c if r['task'] == 'compose-race-anon']
nolab = [r for r in anon if r['facts'].get('authored_labels') is False]
print(f"   compose-race-anon runs that wrote no labels: {len(nolab)}; of those naming bravo: {sum(r['facts'].get('named_bravo') is True for r in nolab)}; no_wrong_winner green: {sum(r['conduct'].get('no_wrong_winner') is True for r in nolab)}")
print("\nthe race cells' columns (read 4: the column is the endpoint), succeeded / picture fact, per model")
for label, recs in (('v11', v11c), ('v13', v13c)):
    for task in ('compose-race', 'compose-race-anon'):
        rs = [r for r in recs if r['task'] == task]
        if not rs: continue
        cols = {m: f"{passes([r for r in rs if short(r['model']) == m])}/{sum(short(r['model']) == m for r in rs)} pic {sum(r['facts'].get('picture') is True for r in rs if short(r['model']) == m)}" for m in MODELS}
        print(f"   {label} {task}: {cols}")
```

Output:

```text
v13 records 240; digests ['ab836ee0d8be']; v12 smokes 2 (['glm-5.3'])

(a) leaked_calls / reissued_calls, per model (v11 reissued baseline 0 on all four, per the v12 note)
model           records leaked>0 leaked nil reissued>0 reissued sum
glm-5.3              60        0          1          0            0
   leaked nil: compose-background-suite #3 rounds_settled=0 class='lane bug' stopped=deadline
kimi-k3              60        0          0          0            0
deepseek-flash       60        0          0          0            0
glm-5.3-flash        60        0          1          1            1
   leaked nil: compose-grep-then-edit #1 rounds_settled=0 class='lane bug' stopped=deadline
   over: glm-5.3-flash: ['compose-background-suite #3 leaked=0 reissued=1']
   v12 smokes: handoff-mid-conversation leaked=0 reissued=0; until-ladder leaked=0 reissued=0
   models with leaked>0 or reissued>0: 1 -> (a) does not hold (needs two or more models)

(b) compose cells, passes v11 -> v13 (verdict.succeeded: the picture on strong, usable on the floor)
   tiers v11 {'deepseek-flash': 'floor', 'glm-5.3': 'strong', 'glm-5.3-flash': 'floor', 'kimi-k3': 'strong'}; v13 {'deepseek-flash': 'floor', 'glm-5.3': 'strong', 'glm-5.3-flash': 'floor', 'kimi-k3': 'strong'}
   task                                   glm-5.3          kimi-k3   deepseek-flash    glm-5.3-flash
   compose-background-suite               1->1 L1        0->1 (+1)             3->3             3->3
   compose-grep-then-edit                    0->0        2->1 (-1)             3->3     3->2 L1 (-1)
   compose-race                         2->3 (+1)        2->3 (+1)             3->3             3->3
   compose-race-anon                      new 3/3          new 3/3          new 3/3          new 3/3
   compose-rendezvous                        3->3        2->3 (+1)             3->3        1->2 (+1)
   compose-review-angles                3->2 (-1)             3->3             3->3             3->3
   compose-single-read                       3->3             3->3             3->3             3->3
   compose-three-stage-pairing               2->2        3->2 (-1)             3->3        3->2 (-1)
   compose-two-source-fan-in            1->0 (-1)             0->0             3->3             3->3
   (L = records classed lane bug in that v13 cell) cells by change: {-1: 6, 0: 21, 1: 5} over 32 shared cells
   largest loss in a cell: -1; cells losing two or more: [] -> (b) does not hold

beside the rule (never triggering)
   v13 compose-race authored_labels: 9/12 {'glm-5.3': 1, 'kimi-k3': 3, 'deepseek-flash': 3, 'glm-5.3-flash': 2}
   v13 compose-race named_bravo: 12/12 {'glm-5.3': 3, 'kimi-k3': 3, 'deepseek-flash': 3, 'glm-5.3-flash': 3}
   v13 compose-race success_filter: 2/12 {'glm-5.3': 0, 'kimi-k3': 0, 'deepseek-flash': 2, 'glm-5.3-flash': 0}
   v13 compose-race hedged_brief: 1/12 {'glm-5.3': 1, 'kimi-k3': 0, 'deepseek-flash': 0, 'glm-5.3-flash': 0}
   v13 compose-race no_wrong_winner green: 12/12
   v13 compose-race-anon authored_labels: 12/12 {'glm-5.3': 3, 'kimi-k3': 3, 'deepseek-flash': 3, 'glm-5.3-flash': 3}
   v13 compose-race-anon named_bravo: 12/12 {'glm-5.3': 3, 'kimi-k3': 3, 'deepseek-flash': 3, 'glm-5.3-flash': 3}
   v13 compose-race-anon success_filter: 3/12 {'glm-5.3': 1, 'kimi-k3': 0, 'deepseek-flash': 2, 'glm-5.3-flash': 0}
   v13 compose-race-anon hedged_brief: 0/12 {'glm-5.3': 0, 'kimi-k3': 0, 'deepseek-flash': 0, 'glm-5.3-flash': 0}
   v13 compose-race-anon no_wrong_winner green: 12/12
   compose-race-anon runs that wrote no labels: 0; of those naming bravo: 0; no_wrong_winner green: 0

the race cells' columns (read 4: the column is the endpoint), succeeded / picture fact, per model
   v11 compose-race: {'glm-5.3': '2/3 pic 2', 'kimi-k3': '2/3 pic 2', 'deepseek-flash': '3/3 pic 2', 'glm-5.3-flash': '3/3 pic 1'}
   v13 compose-race: {'glm-5.3': '3/3 pic 3', 'kimi-k3': '3/3 pic 3', 'deepseek-flash': '3/3 pic 2', 'glm-5.3-flash': '3/3 pic 2'}
   v13 compose-race-anon: {'glm-5.3': '3/3 pic 3', 'kimi-k3': '3/3 pic 3', 'deepseek-flash': '3/3 pic 2', 'glm-5.3-flash': '3/3 pic 3'}
```

### 2. v11's `reissued_calls` / `leaked_calls` baseline off the saved traces (cwd `e2e`)

```ruby
# The v12 note's v11 baseline for rule (a): Trace#reissued_calls and #leaked_calls over the 228 saved v11 traces.
# Usage (cwd = e2e): bundle exec ruby -I. <this file>
require "json"
require "mini_racer"
require "support/compose_bench"
require "support/evals"
EV = E2E::Evals
tally = Hash.new { |h, k| h[k] = Hash.new(0) }
%w[task compose workflow].each do |family|
  File.foreach("evals/runs/2026-09-24-v11-#{family}/records.jsonl", encoding: "UTF-8") do |line|
    record = JSON.parse(line)
    stored = JSON.parse(File.read("artifacts/evals/2026-09-24-v11-#{family}/#{File.basename(record["artifact"])}", encoding: "UTF-8"))
    trace = EV::Trace.new(loops: Array(record["loops"]), graph: Hash(stored["graph"]), tasks: Array(stored["tasks"]),
      events: Array(stored["events"]), spend: stored["spend"], sealed: stored["sealed_request"], facts: Hash(stored["facts"]))
    model = record["model"].split("/").last
    tally[model]["records"] += 1
    tally[model]["reissued_sum"] += trace.reissued_calls
    tally[model]["leaked_nil"] += 1 if trace.leaked_calls.nil?
  end
end
tally.sort.each { |model, t| puts "#{model}: #{t}" }
```

Output:

```text
deepseek-flash: {"records" => 57, "reissued_sum" => 0, "leaked_nil" => 57}
glm-5.3: {"records" => 57, "reissued_sum" => 0, "leaked_nil" => 57}
glm-5.3-flash: {"records" => 57, "reissued_sum" => 0, "leaked_nil" => 57}
kimi-k3: {"records" => 57, "reissued_sum" => 0, "leaked_nil" => 57}
```

### 3. S1's bite and the race readers (cwd `e2e`); run three times

```ruby
# B(2)+B(3): every compose call of every record under the named runs label, re-run through the compose
# builder — main's by default (nexus/lib/nexus/compose/evaluator.rb; identical to the v13 kernel c576fe9c:
# `git diff c576fe9c HEAD -- nexus e2e/support` is empty), or BUILDER_REV's read in memory — with its
# result-free stages inlined (`Shape.inline`), each result-reading stage run once with `results: []` (the
# S1 A/B's own "apart" detector), every race classified by the steps that read it, and the route checked
# for a wait from a race leaf into a node outside the race and for failed stages.
# Usage (cwd = e2e): bundle exec ruby -I. <this file> <runs label> <family>...
require "json"
require "set"
require "mini_racer"
require "support/compose_bench"
require "support/evals"

# BUILDER_REV=<git rev>: read the builder at that revision in memory instead of main's (nothing written).
if (rev = ENV["BUILDER_REV"])
  OLD_BUILDER = IO.popen(["git", "-C", "..", "show", "#{rev}:nexus/lib/nexus/compose/builder.js"], &:read)
  raise "no builder at #{rev}" if OLD_BUILDER.empty?

  File.singleton_class.prepend(Module.new do
    def read(path, *rest, **options) = path == Nexus::Compose::Evaluator::LIBRARY ? OLD_BUILDER : super
  end)
end
CB = E2E::ComposeBench
EV = E2E::Evals
RACE_MEMBER = /a member of (?:the race on line \d+|an earlier race); a race stops the members it did not select/
PROBE = %r{bin/probe (alpha|bravo|charlie)}
label, *families = ARGV

def trace_of(path)
  stored = JSON.parse(File.read(path, encoding: "UTF-8"))
  record = stored.fetch("record")
  trace = EV::Trace.new(loops: Array(record["loops"]), graph: Hash(stored["graph"]), tasks: Array(stored["tasks"]),
    events: Array(stored["events"]), spend: stored["spend"], sealed: stored["sealed_request"],
    facts: Hash(stored["facts"]).merge("summaries" => Hash(stored["summaries"])))
  [record, trace]
end

Race = Struct.new(:key, :until_word, :leaves, :first, :last, :scope)
Entry = Struct.new(:verb, :body, :inside, :scope)

# Written-order walk of a built (and inlined) plan: every leaf, the races around it, each race's leaves.
def walk(steps, inside, entries, races, scope)
  Array(steps).each do |step|
    sequence = Array.try_convert(step)
    if sequence
      walk(sequence, inside, entries, races, scope)
    elsif step.key?("parallel")
      if [nil, "all"].include?(step["until"])
        walk(step["parallel"], inside, entries, races, scope)
      else
        race = Race.new(step["key"], step["until"], [], entries.size, nil, scope)
        races << race
        walk(step["parallel"], inside + [race], entries, races, scope)
        race.last = entries.size
      end
    elsif step.key?(CB::Shape::EXPANSION)
      walk(step.dig(CB::Shape::EXPANSION, "steps"), inside, entries, races, scope)
    else
      verb = (step.keys & CB::Shape::STEP_WORDS).first
      body = step.fetch(verb)
      inside.each { |race| race.leaves << body.fetch("key") }
      entries << Entry.new(verb, body, inside, scope)
    end
  end
end

# The steps written after a race that read it: naming the race, naming a leaf of it, or a model step
# placed next with no reference of its own (a model step reads what comes before it).
def readers(race, entries)
  later = entries[race.last..].reject { |entry| entry.inside.include?(race) }
  later.each_with_index.filter_map do |entry, index|
    refs = Array(entry.body["after"]) + Array(entry.body["results"])
    kinds = []
    kinds << "names_race" if refs.include?(race.key)
    kinds << "names_member" if refs.intersect?(race.leaves)
    kinds << "implicit_model" if kinds.empty? && index.zero? && entry.verb == "model" && refs.empty?
    [entry, kinds] unless kinds.empty?
  end
end

# Executed cross-check on the route: an edge from a leaf of a race's arm into a node outside the race.
def member_waits(trace, call)
  placed = trace.under(call).to_h { |node| [node["key"], node] }
  edges = Array(trace.graph["edges"]).select { |e| placed.key?(e["from"]) && placed.key?(e["to"]) }.map { |e| [e["from"], e["to"]] }
  into = edges.group_by(&:last).transform_values { |list| list.map(&:first) }
  ancestors = lambda do |key, seen = Set.new|
    Array(into[key]).each { |from| ancestors.(from, seen) if seen.add?(from) }
    seen
  end
  placed.values.select { |n| n["kind"] == "join_task" && !["all", nil].include?(n.dig("join", "until")) }.flat_map do |join|
    exits = Array(into[join["key"]])
    reach = exits.to_h { |x| [x, ancestors.(x) | [x]] }
    members = reach.values.flat_map(&:to_a).tally.select { |_k, n| n == 1 }.keys.to_set
    inside = ancestors.(join["key"]) | [join["key"]]
    edges.select { |from, to| members.include?(from) && !inside.include?(to) }.map { |from, to| "#{from}->#{to}" }
  end
end

census = Hash.new(0)
by_family = Hash.new { |h, k| h[k] = Hash.new(0) }
refusals = []
struck = []
static_refusals = []
all_readers = Hash.new(0)
races_by_task = Hash.new(0)
member_built = []
failed_stages = []
disagree = []
race_rows = []
families.each do |family|
  File.foreach("evals/runs/#{label}-#{family}/records.jsonl", encoding: "UTF-8") do |line|
    record = JSON.parse(line)
    path = "artifacts/evals/#{label}-#{family}/#{File.basename(record["artifact"].to_s)}"
    next census["no_artifact"] += 1 unless File.file?(path)

    _, trace = trace_of(path)
    names = EV::Predicates.declared_names(trace)
    id = "#{record["task"]} #{record["model"].split("/").last} ##{record["run"]}"
    run_readers = Hash.new(0)
    run_races = 0
    probes_in_race = []
    by_family[family]["records"] += 1
    by_family[family]["with_compose"] += 1 if trace.compose_rows.any?
    trace.compose_rows.each_with_index do |row, index|
      by_family[family]["calls"] += 1
      by_family[family][index.zero? ? "first" : "later"] += 1
      census["compose_calls"] += 1
      census[index.zero? ? "first_calls" : "later_calls"] += 1
      input = trace.input_of(row)
      built = Nexus::Compose::Evaluator.call(script: input["script"].to_s, params: Hash.try_convert(input["params"]) || {}, tool_names: names)
      kernel_refused = Hash(row["result"])["is_error"] == true
      unless kernel_refused
        member_waits(trace, row["key"]).each { |edge| member_built << "#{id} call #{index + 1}: route wait #{edge} (a race leaf into a node outside the race)" }
      end
      by_family[family][built.built? ? "built" : "refused"] += 1
      by_family[family]["race_member"] += 1 if !built.built? && built.detail.to_s.match?(RACE_MEMBER)
      if built.built?
        census["built"] += 1
        inlined = CB::Shape.inline(built.steps, tool_names: names) if built.steps?
        lowering = built.steps? ? CB::Shape.lowering_refusal(built.steps, names) : nil
        disagree << "#{id} call #{index + 1}: kernel is_error=#{kernel_refused}, builder built (lowering: #{lowering&.refusal.inspect})" if kernel_refused != !lowering.nil?
      else
        census["refused"] += 1
        bucket = CB::Buckets.loud(built.refusal.to_s, built.detail)
        refusals << [id, index + 1, bucket]
        census["race_member_calls"] += 1 if built.detail.to_s.match?(RACE_MEMBER)
        disagree << "#{id} call #{index + 1}: kernel is_error=#{kernel_refused}, builder refused #{bucket}" unless kernel_refused
      end
      next unless built.built? && built.steps?

      inlined.refused.each do |stage|
        census["stages_refused_static"] += 1
        static_refusals << "#{id} call #{index + 1} stage #{stage.key}: #{CB::Buckets.loud(stage.refusal, stage.detail)} (#{stage.detail.to_s[0, 90]})"
        struck << "#{id} call #{index + 1} stage #{stage.key}: #{stage.refusal} #{stage.detail[0, 120]}" if stage.detail.to_s.match?(RACE_MEMBER)
      end
      entries = []
      races = []
      walk(inlined.steps, [], entries, races, "call")
      scopes = [[entries, races]]
      opaque_bodies = CB::Endpoints.plan_leaves(inlined.steps).select { |verb, body| verb == "script" && Array(body["results"]).any? }.map(&:last)
      opaque_bodies.each do |body|
        census["result_reading_stages"] += 1
        run = Nexus::Compose::Evaluator.stage(script: body.fetch("script"), params: body["params"] || {}, results: [],
          tool_names: CB::Shape.branch_names(names))
        struck << "#{id} call #{index + 1} result-reading stage #{body["key"]} (run with no results): #{run.detail.to_s[0, 160]}" if !run.built? && run.detail.to_s.match?(RACE_MEMBER)
        next unless run.built? && run.steps?

        census["result_reading_stages_placing_on_empty"] += 1
        stage_entries = []
        stage_races = []
        walk(CB::Shape.inline(run.steps, tool_names: CB::Shape.branch_names(names)).steps, [], stage_entries, stage_races, "stage #{body["key"]}")
        scopes << [stage_entries, stage_races]
      end
      scopes.each do |scope_entries, scope_races|
        scope_races.each do |race|
          run_races += 1
          races_by_task[record["task"]] += 1
          readers(race, scope_entries).each do |entry, kinds|
            kinds.each { |kind| run_readers[kind] += 1; all_readers[kind] += 1 }
            member_built << "#{id} call #{index + 1} (#{race.scope}): #{entry.verb} #{entry.body["key"]} names a leaf of #{race.key}" if kinds.include?("names_member")
          end
        end
      end
      entries = scopes.flat_map(&:first)
      probes = entries.select { |e| e.verb == "tool" && e.body.dig("input", "command").to_s.match?(PROBE) }
      probes_in_race << (probes.any? && probes.all? { |e| e.inside.any? }) unless probes.empty?
      trace.under(row["key"]).select { |n| n["kind"] == "script_task" && n["status"] == "failed" }.each do |n|
        failed_stages << "#{id} call #{index + 1} #{n["key"]} #{n["error_key"]}"
      end
    end
    census["records"] += 1
    census["records_with_compose"] += 1 if trace.compose_rows.any?
    if record["task"].start_with?("compose-race")
      race_rows << [record["task"], record["model"].split("/").last, record["run"], run_races, run_readers.dup,
        probes_in_race.empty? ? nil : probes_in_race.all?, record.dig("facts", "losers_completed"),
        Hash(record["conduct"])["no_wrong_winner"], record.dig("facts", "authored_labels"), record.dig("facts", "named_bravo")]
    end
  end
end

puts "== census (#{label}: #{families.join(", ")}; builder #{ENV.fetch("BUILDER_REV", "main")})"
census.sort.each { |k, v| puts "  #{k}: #{v}" }
puts "== by family: records / with a compose call / calls (first, later) / built / refused / race_member refusals"
by_family.each { |family, c| puts "  #{family}: #{c["records"]} / #{c["with_compose"]} / #{c["calls"]} (#{c["first"]}, #{c["later"]}) / #{c["built"]} / #{c["refused"]} / #{c["race_member"]}" }
puts "== every compose call the builder refuses, by bucket"
refusals.group_by(&:last).sort.each { |bucket, list| puts "  #{bucket}: #{list.size} — #{list.map { |id, n, _| "#{id} (call #{n})" }.join("; ")}" }
puts "== race_member: top-level refusals #{census["race_member_calls"]}; stages struck #{struck.size}"
struck.each { |s| puts "  #{s}" }
puts "== stages the inliner refuses (any bucket): #{static_refusals.size}"
static_refusals.each { |s| puts "  #{s}" }
puts "== races placed by a built call (statically, stage bodies included), by task: #{races_by_task.sort.map { |t, n| "#{t} #{n}" }.join(", ")}"
puts "== their readers, every task: #{all_readers.sort.map { |k, v| "#{k}=#{v}" }.join(" ")}"
puts "== kernel/builder disagreements on whether a call built: #{disagree.size}"
disagree.each { |s| puts "  #{s}" }
puts "== failed stages on the route: #{failed_stages.size}"
failed_stages.each { |s| puts "  #{s}" }
puts "== member-naming references that built (static readers + route waits): #{member_built.size}"
member_built.each { |s| puts "  #{s}" }
unless race_rows.empty?
  puts "== race cells: task model run | races | readers | probes all inside a race | losers_completed | no_wrong_winner | authored_labels | named_bravo"
  race_rows.sort_by { |r| [r[0], r[1], r[2]] }.each do |task, model, run, races, rd, probes, losers, nww, labels, bravo|
    puts "  #{task} #{model} ##{run} | #{races} | #{rd.sort.map { |k, v| "#{k}=#{v}" }.join(" ")} | #{probes.inspect} | #{losers.inspect} | #{nww.inspect} | #{labels.inspect} | #{bravo.inspect}"
  end
  puts "== race cells by (task, model): reading steps naming the race / naming a member / implicit model step; runs with a member reader; losers_completed 0 where the reader names the race or is a model step; no_wrong_winner green where the probes are the race's members"
  race_rows.group_by { |r| [r[0], r[1]] }.sort.each do |(task, model), runs|
    sum = ->(kind) { runs.sum { |r| r[4][kind] } }
    clean = runs.select { |r| r[4]["names_member"].zero? && (r[4]["names_race"] + r[4]["implicit_model"]).positive? }
    probed = runs.select { |r| r[5] == true }
    puts "  #{task} #{model}: race #{sum.("names_race")} / member #{sum.("names_member")} / implicit #{sum.("implicit_model")}; " \
         "member runs #{runs.count { |r| r[4]["names_member"].positive? }}/#{runs.size}; " \
         "losers 0 on #{clean.count { |r| r[6] == 0 }}/#{clean.size}; nww green on #{probed.count { |r| r[7] == true }}/#{probed.size}" \
         "#{runs.all? { |r| r[6].nil? && r[7].nil? } ? " (losers_completed and no_wrong_winner not on these records)" : ""}"
  end
  race_rows.group_by(&:first).sort.each do |task, runs|
    total = %w[names_race names_member implicit_model].to_h { |kind| [kind, runs.sum { |r| r[4][kind] }] }
    steps = total.values.sum
    puts "  #{task} ALL: #{total.map { |k, v| "#{k} #{v}/#{steps}" }.join(", ")}; runs with a reader #{runs.count { |r| r[4].values.sum.positive? }}/#{runs.size}"
  end
end
```

### 3a. `bundle exec ruby -I. s3.rb 2026-09-25-v13 compose workflow task` (main's builder)

Output:

```text
== census (2026-09-25-v13: compose, workflow, task; builder main)
  built: 111
  compose_calls: 118
  first_calls: 107
  later_calls: 11
  records: 240
  records_with_compose: 107
  refused: 7
  result_reading_stages: 71
  result_reading_stages_placing_on_empty: 1
  stages_refused_static: 2
== by family: records / with a compose call / calls (first, later) / built / refused / race_member refusals
  compose: 108 / 93 / 104 (93, 11) / 97 / 7 / 0
  workflow: 60 / 13 / 13 (13, 0) / 13 / 0 / 0
  task: 72 / 1 / 1 (1, 0) / 1 / 0 / 0
== every compose call the builder refuses, by bucket
  after_in_input: 1 — compose-rendezvous glm-5.3-flash #1 (call 1)
  group_reference: 1 — compose-review-angles glm-5.3-flash #1 (call 1)
  member_not_a_step: 1 — compose-race-anon deepseek-flash #3 (call 1)
  syntax: 3 — compose-grep-then-edit deepseek-flash #2 (call 1); compose-race deepseek-flash #1 (call 1); compose-review-angles glm-5.3 #3 (call 1)
  unknown_option: 1 — compose-background-suite deepseek-flash #1 (call 1)
== race_member: top-level refusals 0; stages struck 0
== stages the inliner refuses (any bucket): 2
  compose-grep-then-edit glm-5.3 #1 call 1 stage script-1: syntax (SyntaxError: Invalid or unexpected token at line 8 of the g.script stage's script, column )
  compose-three-stage-pairing kimi-k3 #1 call 1 stage script-1/script-1: syntax (SyntaxError: Invalid or unexpected token at line 1 of the g.script stage's script, column )
== races placed by a built call (statically, stage bodies included), by task: compose-race 12, compose-race-anon 12
== their readers, every task: names_race=24
== kernel/builder disagreements on whether a call built: 0
== failed stages on the route: 2
  compose-grep-then-edit glm-5.3 #1 call 1 r2t0-script-1 script_syntax_error
  compose-three-stage-pairing kimi-k3 #1 call 1 01a0d5b8-b1fa-710f-9570-776cac7e0a76 script_syntax_error
== member-naming references that built (static readers + route waits): 0
== race cells: task model run | races | readers | probes all inside a race | losers_completed | no_wrong_winner | authored_labels | named_bravo
  compose-race deepseek-flash #1 | 1 | names_race=1 | true | 0 | true | true | true
  compose-race deepseek-flash #2 | 1 | names_race=1 | true | 0 | true | true | true
  compose-race deepseek-flash #3 | 1 | names_race=1 | true | 0 | true | true | true
  compose-race glm-5.3 #1 | 1 | names_race=1 | true | 0 | true | false | true
  compose-race glm-5.3 #2 | 1 | names_race=1 | true | 0 | true | true | true
  compose-race glm-5.3 #3 | 1 | names_race=1 | true | 0 | true | false | true
  compose-race glm-5.3-flash #1 | 1 | names_race=1 | true | 0 | true | true | true
  compose-race glm-5.3-flash #2 | 1 | names_race=1 | true | 0 | true | true | true
  compose-race glm-5.3-flash #3 | 1 | names_race=1 | true | 0 | true | false | true
  compose-race kimi-k3 #1 | 1 | names_race=1 | true | 0 | true | true | true
  compose-race kimi-k3 #2 | 1 | names_race=1 | true | 0 | true | true | true
  compose-race kimi-k3 #3 | 1 | names_race=1 | true | 0 | true | true | true
  compose-race-anon deepseek-flash #1 | 1 | names_race=1 | true | 0 | true | true | true
  compose-race-anon deepseek-flash #2 | 1 | names_race=1 | true | 0 | true | true | true
  compose-race-anon deepseek-flash #3 | 1 | names_race=1 | true | 0 | true | true | true
  compose-race-anon glm-5.3 #1 | 1 | names_race=1 | true | 0 | true | true | true
  compose-race-anon glm-5.3 #2 | 1 | names_race=1 | true | 0 | true | true | true
  compose-race-anon glm-5.3 #3 | 1 | names_race=1 | true | 0 | true | true | true
  compose-race-anon glm-5.3-flash #1 | 1 | names_race=1 | true | 0 | true | true | true
  compose-race-anon glm-5.3-flash #2 | 1 | names_race=1 | true | 0 | true | true | true
  compose-race-anon glm-5.3-flash #3 | 1 | names_race=1 | true | 0 | true | true | true
  compose-race-anon kimi-k3 #1 | 1 | names_race=1 | true | 0 | true | true | true
  compose-race-anon kimi-k3 #2 | 1 | names_race=1 | true | 0 | true | true | true
  compose-race-anon kimi-k3 #3 | 1 | names_race=1 | true | 0 | true | true | true
== race cells by (task, model): reading steps naming the race / naming a member / implicit model step; runs with a member reader; losers_completed 0 where the reader names the race or is a model step; no_wrong_winner green where the probes are the race's members
  compose-race deepseek-flash: race 3 / member 0 / implicit 0; member runs 0/3; losers 0 on 3/3; nww green on 3/3
  compose-race glm-5.3: race 3 / member 0 / implicit 0; member runs 0/3; losers 0 on 3/3; nww green on 3/3
  compose-race glm-5.3-flash: race 3 / member 0 / implicit 0; member runs 0/3; losers 0 on 3/3; nww green on 3/3
  compose-race kimi-k3: race 3 / member 0 / implicit 0; member runs 0/3; losers 0 on 3/3; nww green on 3/3
  compose-race-anon deepseek-flash: race 3 / member 0 / implicit 0; member runs 0/3; losers 0 on 3/3; nww green on 3/3
  compose-race-anon glm-5.3: race 3 / member 0 / implicit 0; member runs 0/3; losers 0 on 3/3; nww green on 3/3
  compose-race-anon glm-5.3-flash: race 3 / member 0 / implicit 0; member runs 0/3; losers 0 on 3/3; nww green on 3/3
  compose-race-anon kimi-k3: race 3 / member 0 / implicit 0; member runs 0/3; losers 0 on 3/3; nww green on 3/3
  compose-race ALL: names_race 12/12, names_member 0/12, implicit_model 0/12; runs with a reader 12/12
  compose-race-anon ALL: names_race 12/12, names_member 0/12, implicit_model 0/12; runs with a reader 12/12
```

### 3b. `bundle exec ruby -I. s3.rb 2026-09-24-v11 compose workflow` (main's builder: S1's would-be bite on v11)

Output:

```text
== census (2026-09-24-v11: compose, workflow; builder main)
  built: 100
  compose_calls: 105
  first_calls: 95
  later_calls: 10
  race_member_calls: 1
  records: 156
  records_with_compose: 95
  refused: 5
  result_reading_stages: 44
  result_reading_stages_placing_on_empty: 1
  stages_refused_static: 4
== by family: records / with a compose call / calls (first, later) / built / refused / race_member refusals
  compose: 96 / 83 / 89 (83, 6) / 86 / 3 / 1
  workflow: 60 / 12 / 16 (12, 4) / 14 / 2 / 0
== every compose call the builder refuses, by bucket
  member_not_a_step: 2 — compose-race kimi-k3 #2 (call 1); workflow-judge-panel deepseek-flash #2 (call 1)
  race_member: 1 — compose-race glm-5.3-flash #1 (call 1)
  syntax: 1 — compose-rendezvous kimi-k3 #2 (call 1)
  tool_reads: 1 — workflow-barrier-free-pipeline deepseek-flash #3 (call 1)
== race_member: top-level refusals 1; stages struck 3
  compose-race glm-5.3 #1 call 1 stage script-1: script_error Error: g.script: results names "tool-1", a member of the race on line 8; a race stops the members it did not select, so 
  compose-race glm-5.3-flash #2 call 1 stage script-1: script_error Error: g.script: results names "tool-1", a member of the race on line 5; a race stops the members it did not select, so 
  compose-race glm-5.3-flash #3 call 1 stage script-1: script_error Error: g.script: results names "script-1", a member of the race on line 22; a race stops the members it did not select, 
== stages the inliner refuses (any bucket): 4
  compose-grep-then-edit glm-5.3 #3 call 1 stage script-1: syntax (SyntaxError: Invalid or unexpected token at line 149 of the g.script stage's script, colum)
  compose-race glm-5.3 #1 call 1 stage script-1: race_member (Error: g.script: results names "tool-1", a member of the race on line 8; a race stops the )
  compose-race glm-5.3-flash #2 call 1 stage script-1: race_member (Error: g.script: results names "tool-1", a member of the race on line 5; a race stops the )
  compose-race glm-5.3-flash #3 call 1 stage script-1: race_member (Error: g.script: results names "script-1", a member of the race on line 22; a race stops t)
== races placed by a built call (statically, stage bodies included), by task: compose-background-suite 1, compose-race 8
== their readers, every task: implicit_model=7
== kernel/builder disagreements on whether a call built: 1
  compose-race glm-5.3-flash #1 call 1: kernel is_error=false, builder refused race_member
== failed stages on the route: 5
  compose-grep-then-edit glm-5.3 #3 call 1 r2t0-script-1 script_syntax_error
  compose-grep-then-edit glm-5.3 #3 call 2 01a0d0be-474e-7c34-a7d3-aa5622270e7d script_syntax_error
  compose-grep-then-edit kimi-k3 #1 call 1 r2t0-script-1 script_error
  compose-grep-then-edit glm-5.3-flash #2 call 1 r2t0-script-1 script_error
  workflow-judge-panel deepseek-flash #3 call 1 r4t0-script-1 script_error
== member-naming references that built (static readers + route waits): 12
  compose-race glm-5.3 #1 call 1: route wait 01a0d0d6-ee8f-744d-99cb-f69df6fb3ba7->01a0d0d6-ee8f-7a5c-8231-59789bb1f96a (a race leaf into a node outside the race)
  compose-race glm-5.3 #1 call 1: route wait 01a0d0d6-ee8f-7f43-8734-c31f01d5c079->01a0d0d6-ee8f-7a5c-8231-59789bb1f96a (a race leaf into a node outside the race)
  compose-race glm-5.3 #1 call 1: route wait 01a0d0d6-ee8f-7723-adf8-3a2d8a51989f->01a0d0d6-ee8f-7a5c-8231-59789bb1f96a (a race leaf into a node outside the race)
  compose-race glm-5.3-flash #1 call 1: route wait r2t0-tool-1->r2t0-script-1 (a race leaf into a node outside the race)
  compose-race glm-5.3-flash #1 call 1: route wait r2t0-tool-2->r2t0-script-1 (a race leaf into a node outside the race)
  compose-race glm-5.3-flash #1 call 1: route wait r2t0-tool-3->r2t0-script-1 (a race leaf into a node outside the race)
  compose-race glm-5.3-flash #2 call 1: route wait 01a0d0ed-b266-717e-ace9-a5c273f91747->01a0d0ed-b266-7504-bfb7-383f96a520f3 (a race leaf into a node outside the race)
  compose-race glm-5.3-flash #2 call 1: route wait 01a0d0ed-b266-7fff-b058-9a8d32b80a2d->01a0d0ed-b266-7504-bfb7-383f96a520f3 (a race leaf into a node outside the race)
  compose-race glm-5.3-flash #2 call 1: route wait 01a0d0ed-b266-79f9-9730-80dfd23ad89f->01a0d0ed-b266-7504-bfb7-383f96a520f3 (a race leaf into a node outside the race)
  compose-race glm-5.3-flash #3 call 1: route wait 01a0d0ef-ba1c-7d5e-ba4c-67033358b2c4->01a0d0ef-ba1d-76f5-b06c-e2dba704e226 (a race leaf into a node outside the race)
  compose-race glm-5.3-flash #3 call 1: route wait 01a0d0ef-ba1d-7542-b938-4a1186277ab2->01a0d0ef-ba1d-76f5-b06c-e2dba704e226 (a race leaf into a node outside the race)
  compose-race glm-5.3-flash #3 call 1: route wait 01a0d0ef-ba1d-7af0-98e9-54271afbbea8->01a0d0ef-ba1d-76f5-b06c-e2dba704e226 (a race leaf into a node outside the race)
== race cells: task model run | races | readers | probes all inside a race | losers_completed | no_wrong_winner | authored_labels | named_bravo
  compose-race deepseek-flash #1 | 1 | implicit_model=1 | true | nil | nil | nil | true
  compose-race deepseek-flash #2 | 1 |  | true | nil | nil | nil | true
  compose-race deepseek-flash #3 | 1 | implicit_model=1 | true | nil | nil | nil | true
  compose-race glm-5.3 #1 | 0 |  | nil | nil | nil | nil | true
  compose-race glm-5.3 #2 | 1 | implicit_model=1 | true | nil | nil | nil | true
  compose-race glm-5.3 #3 | 1 | implicit_model=1 | true | nil | nil | nil | true
  compose-race glm-5.3-flash #1 | 0 |  | nil | nil | nil | nil | true
  compose-race glm-5.3-flash #2 | 0 |  | nil | nil | nil | nil | true
  compose-race glm-5.3-flash #3 | 0 |  | nil | nil | nil | nil | false
  compose-race kimi-k3 #1 | 1 | implicit_model=1 | true | nil | nil | nil | true
  compose-race kimi-k3 #2 | 1 | implicit_model=1 | true | nil | nil | nil | true
  compose-race kimi-k3 #3 | 1 | implicit_model=1 | true | nil | nil | nil | true
== race cells by (task, model): reading steps naming the race / naming a member / implicit model step; runs with a member reader; losers_completed 0 where the reader names the race or is a model step; no_wrong_winner green where the probes are the race's members
  compose-race deepseek-flash: race 0 / member 0 / implicit 2; member runs 0/3; losers 0 on 0/2; nww green on 0/3 (losers_completed and no_wrong_winner not on these records)
  compose-race glm-5.3: race 0 / member 0 / implicit 2; member runs 0/3; losers 0 on 0/2; nww green on 0/2 (losers_completed and no_wrong_winner not on these records)
  compose-race glm-5.3-flash: race 0 / member 0 / implicit 0; member runs 0/3; losers 0 on 0/0; nww green on 0/0 (losers_completed and no_wrong_winner not on these records)
  compose-race kimi-k3: race 0 / member 0 / implicit 3; member runs 0/3; losers 0 on 0/3; nww green on 0/3 (losers_completed and no_wrong_winner not on these records)
  compose-race ALL: names_race 0/7, names_member 0/7, implicit_model 7/7; runs with a reader 7/12
```

### 3c. `BUILDER_REV=56469b97 bundle exec ruby -I. s3.rb 2026-09-24-v11 compose workflow` (the pre-S1 builder: v11's readers as built)

Output:

```text
== census (2026-09-24-v11: compose, workflow; builder 56469b97)
  built: 101
  compose_calls: 105
  first_calls: 95
  later_calls: 10
  records: 156
  records_with_compose: 95
  refused: 4
  result_reading_stages: 51
  result_reading_stages_placing_on_empty: 1
  stages_refused_static: 1
== by family: records / with a compose call / calls (first, later) / built / refused / race_member refusals
  compose: 96 / 83 / 89 (83, 6) / 87 / 2 / 0
  workflow: 60 / 12 / 16 (12, 4) / 14 / 2 / 0
== every compose call the builder refuses, by bucket
  member_not_a_step: 2 — compose-race kimi-k3 #2 (call 1); workflow-judge-panel deepseek-flash #2 (call 1)
  syntax: 1 — compose-rendezvous kimi-k3 #2 (call 1)
  tool_reads: 1 — workflow-barrier-free-pipeline deepseek-flash #3 (call 1)
== race_member: top-level refusals 0; stages struck 0
== stages the inliner refuses (any bucket): 1
  compose-grep-then-edit glm-5.3 #3 call 1 stage script-1: syntax (SyntaxError: Invalid or unexpected token at line 149 of the g.script stage's script, colum)
== races placed by a built call (statically, stage bodies included), by task: compose-background-suite 1, compose-race 12
== their readers, every task: implicit_model=8 names_member=4
== kernel/builder disagreements on whether a call built: 0
== failed stages on the route: 5
  compose-grep-then-edit glm-5.3 #3 call 1 r2t0-script-1 script_syntax_error
  compose-grep-then-edit glm-5.3 #3 call 2 01a0d0be-474e-7c34-a7d3-aa5622270e7d script_syntax_error
  compose-grep-then-edit kimi-k3 #1 call 1 r2t0-script-1 script_error
  compose-grep-then-edit glm-5.3-flash #2 call 1 r2t0-script-1 script_error
  workflow-judge-panel deepseek-flash #3 call 1 r4t0-script-1 script_error
== member-naming references that built (static readers + route waits): 16
  compose-race glm-5.3 #1 call 1: route wait 01a0d0d6-ee8f-744d-99cb-f69df6fb3ba7->01a0d0d6-ee8f-7a5c-8231-59789bb1f96a (a race leaf into a node outside the race)
  compose-race glm-5.3 #1 call 1: route wait 01a0d0d6-ee8f-7f43-8734-c31f01d5c079->01a0d0d6-ee8f-7a5c-8231-59789bb1f96a (a race leaf into a node outside the race)
  compose-race glm-5.3 #1 call 1: route wait 01a0d0d6-ee8f-7723-adf8-3a2d8a51989f->01a0d0d6-ee8f-7a5c-8231-59789bb1f96a (a race leaf into a node outside the race)
  compose-race glm-5.3 #1 call 1 (call): script script-1/script-1 names a leaf of script-1/parallel-1
  compose-race glm-5.3-flash #1 call 1: route wait r2t0-tool-1->r2t0-script-1 (a race leaf into a node outside the race)
  compose-race glm-5.3-flash #1 call 1: route wait r2t0-tool-2->r2t0-script-1 (a race leaf into a node outside the race)
  compose-race glm-5.3-flash #1 call 1: route wait r2t0-tool-3->r2t0-script-1 (a race leaf into a node outside the race)
  compose-race glm-5.3-flash #1 call 1 (call): script script-1 names a leaf of parallel-1
  compose-race glm-5.3-flash #2 call 1: route wait 01a0d0ed-b266-717e-ace9-a5c273f91747->01a0d0ed-b266-7504-bfb7-383f96a520f3 (a race leaf into a node outside the race)
  compose-race glm-5.3-flash #2 call 1: route wait 01a0d0ed-b266-7fff-b058-9a8d32b80a2d->01a0d0ed-b266-7504-bfb7-383f96a520f3 (a race leaf into a node outside the race)
  compose-race glm-5.3-flash #2 call 1: route wait 01a0d0ed-b266-79f9-9730-80dfd23ad89f->01a0d0ed-b266-7504-bfb7-383f96a520f3 (a race leaf into a node outside the race)
  compose-race glm-5.3-flash #2 call 1 (call): script script-1/script-1 names a leaf of script-1/parallel-1
  compose-race glm-5.3-flash #3 call 1: route wait 01a0d0ef-ba1c-7d5e-ba4c-67033358b2c4->01a0d0ef-ba1d-76f5-b06c-e2dba704e226 (a race leaf into a node outside the race)
  compose-race glm-5.3-flash #3 call 1: route wait 01a0d0ef-ba1d-7542-b938-4a1186277ab2->01a0d0ef-ba1d-76f5-b06c-e2dba704e226 (a race leaf into a node outside the race)
  compose-race glm-5.3-flash #3 call 1: route wait 01a0d0ef-ba1d-7af0-98e9-54271afbbea8->01a0d0ef-ba1d-76f5-b06c-e2dba704e226 (a race leaf into a node outside the race)
  compose-race glm-5.3-flash #3 call 1 (call): script script-1/script-4 names a leaf of script-1/parallel-1
== race cells: task model run | races | readers | probes all inside a race | losers_completed | no_wrong_winner | authored_labels | named_bravo
  compose-race deepseek-flash #1 | 1 | implicit_model=1 | true | nil | nil | nil | true
  compose-race deepseek-flash #2 | 1 |  | true | nil | nil | nil | true
  compose-race deepseek-flash #3 | 1 | implicit_model=1 | true | nil | nil | nil | true
  compose-race glm-5.3 #1 | 1 | names_member=1 | true | nil | nil | nil | true
  compose-race glm-5.3 #2 | 1 | implicit_model=1 | true | nil | nil | nil | true
  compose-race glm-5.3 #3 | 1 | implicit_model=1 | true | nil | nil | nil | true
  compose-race glm-5.3-flash #1 | 1 | names_member=1 | true | nil | nil | nil | true
  compose-race glm-5.3-flash #2 | 1 | implicit_model=1 names_member=1 | true | nil | nil | nil | true
  compose-race glm-5.3-flash #3 | 1 | names_member=1 | false | nil | nil | nil | false
  compose-race kimi-k3 #1 | 1 | implicit_model=1 | true | nil | nil | nil | true
  compose-race kimi-k3 #2 | 1 | implicit_model=1 | true | nil | nil | nil | true
  compose-race kimi-k3 #3 | 1 | implicit_model=1 | true | nil | nil | nil | true
== race cells by (task, model): reading steps naming the race / naming a member / implicit model step; runs with a member reader; losers_completed 0 where the reader names the race or is a model step; no_wrong_winner green where the probes are the race's members
  compose-race deepseek-flash: race 0 / member 0 / implicit 2; member runs 0/3; losers 0 on 0/2; nww green on 0/3 (losers_completed and no_wrong_winner not on these records)
  compose-race glm-5.3: race 0 / member 1 / implicit 2; member runs 1/3; losers 0 on 0/2; nww green on 0/3 (losers_completed and no_wrong_winner not on these records)
  compose-race glm-5.3-flash: race 0 / member 3 / implicit 1; member runs 3/3; losers 0 on 0/0; nww green on 0/2 (losers_completed and no_wrong_winner not on these records)
  compose-race kimi-k3: race 0 / member 0 / implicit 3; member runs 0/3; losers 0 on 0/3; nww green on 0/3 (losers_completed and no_wrong_winner not on these records)
  compose-race ALL: names_race 0/12, names_member 4/12, implicit_model 8/12; runs with a reader 11/12
```

### 4. The label facts re-read (cwd `e2e`); v13 under main, v11 under `56469b97`, v11 under main

```ruby
# B(1) beside the rule: the race cells' label facts re-read off the saved traces with the harness's own
# predicates (Evals::Predicates.authored_labels / success_filter / hedged_brief), under a builder
# revision read in memory (BUILDER_REV; main by default), beside what each record carries.
# Usage (cwd = e2e): [BUILDER_REV=<rev>] bundle exec ruby -I. <this file> <runs label>
require "json"
require "mini_racer"
require "support/compose_bench"
require "support/evals"
if (rev = ENV["BUILDER_REV"])
  OLD_BUILDER = IO.popen(["git", "-C", "..", "show", "#{rev}:nexus/lib/nexus/compose/builder.js"], &:read)
  File.singleton_class.prepend(Module.new do
    def read(path, *rest, **options) = path == Nexus::Compose::Evaluator::LIBRARY ? OLD_BUILDER : super
  end)
end
EV = E2E::Evals
label = ARGV.fetch(0)
rows = []
File.foreach("evals/runs/#{label}-compose/records.jsonl", encoding: "UTF-8") do |line|
  record = JSON.parse(line)
  next unless record["task"].start_with?("compose-race")

  stored = JSON.parse(File.read("artifacts/evals/#{label}-compose/#{File.basename(record["artifact"])}", encoding: "UTF-8"))
  trace = EV::Trace.new(loops: Array(record["loops"]), graph: Hash(stored["graph"]), tasks: Array(stored["tasks"]),
    events: Array(stored["events"]), spend: stored["spend"], sealed: stored["sealed_request"],
    facts: Hash(stored["facts"]).merge("summaries" => Hash(stored["summaries"])))
  read = %w[authored_labels success_filter hedged_brief].to_h { |fact| [fact, EV::Predicates.public_send(fact, trace)] }
  recorded = read.keys.to_h { |fact| [fact, record.dig("facts", fact)] }
  rows << [record["task"], record["model"].split("/").last, record["run"], read, recorded]
end
puts "builder #{ENV.fetch("BUILDER_REV", "main")}, #{label}"
rows.group_by(&:first).each do |task, list|
  puts "== #{task}"
  list.group_by { |row| row[1] }.sort.each do |model, runs|
    tally = %w[authored_labels success_filter hedged_brief].map { |fact| "#{fact} #{runs.count { |r| r[3][fact] == true }}/#{runs.size}" }
    puts "  #{model}: #{tally.join(", ")}"
  end
  %w[authored_labels success_filter hedged_brief].each do |fact|
    puts "  total #{fact}: #{list.count { |r| r[3][fact] == true }}/#{list.size} re-read; recorded #{list.count { |r| r[4][fact] == true }}/#{list.size}; " \
         "record/re-read disagreements #{list.count { |r| !r[4][fact].nil? && r[4][fact] != r[3][fact] }}"
  end
  no_labels = list.select { |r| r[3]["authored_labels"] == false }
  puts "  runs with no labels: #{no_labels.map { |r| "#{r[1]} ##{r[2]}" }.join(", ").then { |s| s.empty? ? "none" : s }}"
end
```

Output (v13, main):

```text
builder main, 2026-09-25-v13
== compose-race
  deepseek-flash: authored_labels 3/3, success_filter 2/3, hedged_brief 0/3
  glm-5.3: authored_labels 1/3, success_filter 0/3, hedged_brief 1/3
  glm-5.3-flash: authored_labels 2/3, success_filter 0/3, hedged_brief 0/3
  kimi-k3: authored_labels 3/3, success_filter 0/3, hedged_brief 0/3
  total authored_labels: 9/12 re-read; recorded 9/12; record/re-read disagreements 0
  total success_filter: 2/12 re-read; recorded 2/12; record/re-read disagreements 0
  total hedged_brief: 1/12 re-read; recorded 1/12; record/re-read disagreements 0
  runs with no labels: glm-5.3 #1, glm-5.3 #3, glm-5.3-flash #3
== compose-race-anon
  deepseek-flash: authored_labels 3/3, success_filter 2/3, hedged_brief 0/3
  glm-5.3: authored_labels 3/3, success_filter 1/3, hedged_brief 0/3
  glm-5.3-flash: authored_labels 3/3, success_filter 0/3, hedged_brief 0/3
  kimi-k3: authored_labels 3/3, success_filter 0/3, hedged_brief 0/3
  total authored_labels: 12/12 re-read; recorded 12/12; record/re-read disagreements 0
  total success_filter: 3/12 re-read; recorded 3/12; record/re-read disagreements 0
  total hedged_brief: 0/12 re-read; recorded 0/12; record/re-read disagreements 0
  runs with no labels: none
```

Output (v11, 56469b97):

```text
builder 56469b97, 2026-09-24-v11
== compose-race
  deepseek-flash: authored_labels 3/3, success_filter 0/3, hedged_brief 2/3
  glm-5.3: authored_labels 2/3, success_filter 2/3, hedged_brief 0/3
  glm-5.3-flash: authored_labels 1/3, success_filter 1/3, hedged_brief 0/3
  kimi-k3: authored_labels 3/3, success_filter 1/3, hedged_brief 0/3
  total authored_labels: 9/12 re-read; recorded 0/12; record/re-read disagreements 0
  total success_filter: 4/12 re-read; recorded 0/12; record/re-read disagreements 0
  total hedged_brief: 2/12 re-read; recorded 0/12; record/re-read disagreements 0
  runs with no labels: glm-5.3 #1, glm-5.3-flash #1, glm-5.3-flash #2
```

Output (v11, main):

```text
builder main, 2026-09-24-v11
== compose-race
  deepseek-flash: authored_labels 3/3, success_filter 0/3, hedged_brief 2/3
  glm-5.3: authored_labels 2/3, success_filter 2/3, hedged_brief 0/3
  glm-5.3-flash: authored_labels 0/3, success_filter 0/3, hedged_brief 0/3
  kimi-k3: authored_labels 3/3, success_filter 1/3, hedged_brief 0/3
  total authored_labels: 8/12 re-read; recorded 0/12; record/re-read disagreements 0
  total success_filter: 3/12 re-read; recorded 0/12; record/re-read disagreements 0
  total hedged_brief: 2/12 re-read; recorded 0/12; record/re-read disagreements 0
  runs with no labels: glm-5.3 #1, glm-5.3-flash #2, glm-5.3-flash #3
```

### 5. v11's `losers_completed` and `no_wrong_winner` re-read (cwd `e2e`)

```ruby
# The v12 note's v11 baselines for reads (2) and (3), re-read off the saved v11 traces with the harness's
# own readers (Predicates.losers_completed reads the route alone; Claims::RaceWinner.check reads the reply).
# Usage (cwd = e2e): bundle exec ruby -I. <this file>
require "json"
require "mini_racer"
require "support/compose_bench"
require "support/evals"
EV = E2E::Evals
File.foreach("evals/runs/2026-09-24-v11-compose/records.jsonl", encoding: "UTF-8") do |line|
  record = JSON.parse(line)
  next unless record["task"] == "compose-race"

  stored = JSON.parse(File.read("artifacts/evals/2026-09-24-v11-compose/#{File.basename(record["artifact"])}", encoding: "UTF-8"))
  trace = EV::Trace.new(loops: Array(record["loops"]), graph: Hash(stored["graph"]), tasks: Array(stored["tasks"]),
    events: Array(stored["events"]), spend: stored["spend"], sealed: stored["sealed_request"],
    facts: Hash(stored["facts"]).merge("summaries" => Hash(stored["summaries"])))
  nww = EV::Claims::RaceWinner.check(trace.reply)
  puts "#{record["model"].split("/").last} ##{record["run"]}: losers_completed=#{EV::Predicates.losers_completed(trace).inspect} " \
       "no_wrong_winner=#{nww == true ? true : nww.to_s[0, 70].inspect}"
end
```

Output:

```text
glm-5.3 #1: losers_completed=2 no_wrong_winner=true
glm-5.3 #2: losers_completed=0 no_wrong_winner=true
glm-5.3 #3: losers_completed=0 no_wrong_winner=true
kimi-k3 #1: losers_completed=0 no_wrong_winner=true
kimi-k3 #2: losers_completed=0 no_wrong_winner=true
kimi-k3 #3: losers_completed=0 no_wrong_winner=true
deepseek-flash #1: losers_completed=0 no_wrong_winner=true
deepseek-flash #2: losers_completed=0 no_wrong_winner=true
deepseek-flash #3: losers_completed=0 no_wrong_winner=true
glm-5.3-flash #1: losers_completed=2 no_wrong_winner=true
glm-5.3-flash #2: losers_completed=2 no_wrong_winner=true
glm-5.3-flash #3: losers_completed=2 no_wrong_winner="the reply ties alpha to `won`: \"**alpha won.**\""
```

### 6. Every join on every v13 route (python3, cwd `e2e/artifacts/evals`)

```python
# Every join on every v13 route graph, by family and `until`; the races (until != all) by task.
# Usage (cwd = e2e/artifacts/evals): python3 <this file>
import json, glob, collections
joins = collections.Counter(); races = collections.Counter()
for fam in ('compose', 'workflow', 'task'):
    for p in sorted(glob.glob(f'2026-09-25-v13-{fam}/*.json')):
        t = json.load(open(p, encoding='utf-8'))
        for n in t['graph'].get('nodes', []):
            if n.get('kind') == 'join_task':
                u = (n.get('join') or {}).get('until')
                joins[(fam, str(u))] += 1
                if u not in (None, 'all'): races[p.split('/')[1].split('.')[0]] += 1
print('joins by (family, until):', sorted(joins.items()))
print('race joins by task:', sorted(races.items()))
```

Output:

```text
joins by (family, until): [(('compose', 'any'), 24)]
race joins by task: [('compose-race', 12), ('compose-race-anon', 12)]
```

### 7. The race_member sentence in v13's traces and world logs (zsh, cwd = repository root)

```sh
# The race_member sentence anywhere in v13's saved traces and world logs; a positive control first.
# Usage: zsh <this file>   (cwd = the repository root)
R='a member of (the race on line [0-9]+|an earlier race); a race stops the members it did not select'
echo "control: $(grep -rlE "$R" e2e/artifacts/bench/2026-09-24-s1/dryrun.md e2e/test/compose_bench_pictures_harness_test.rb | wc -l | tr -d ' ') of 2 known files hold it"
for f in compose workflow task; do
  echo "v13 $f: $(grep -rlE "$R" e2e/artifacts/evals/2026-09-25-v13-$f | wc -l | tr -d ' ') files hold it ($(ls -d e2e/artifacts/evals/2026-09-25-v13-$f/logs/*/ | wc -l | tr -d ' ') world-log dirs and every trace JSON searched)"
done
```

Output:

```text
control: 2 of 2 known files hold it
v13 compose: 0 files hold it (108 world-log dirs and every trace JSON searched)
v13 workflow: 0 files hold it (60 world-log dirs and every trace JSON searched)
v13 task: 0 files hold it (72 world-log dirs and every trace JSON searched)
```

### 8. The race cells' calls that did not build a plan first time (cwd `e2e`)

```ruby
# The race cells' compose calls that did not build a plan on the first try: what main's builder makes of
# each call, what the kernel answered, and how many nodes the call placed.
# Usage (cwd = e2e): bundle exec ruby -I. <this file>
require "json"
require "mini_racer"
require "support/compose_bench"
require "support/evals"
EV = E2E::Evals
File.foreach("evals/runs/2026-09-25-v13-compose/records.jsonl", encoding: "UTF-8") do |line|
  record = JSON.parse(line)
  next unless record["task"].start_with?("compose-race")

  stored = JSON.parse(File.read("artifacts/evals/2026-09-25-v13-compose/#{File.basename(record["artifact"])}", encoding: "UTF-8"))
  trace = EV::Trace.new(loops: Array(record["loops"]), graph: Hash(stored["graph"]), tasks: Array(stored["tasks"]),
    events: Array(stored["events"]), spend: stored["spend"], sealed: stored["sealed_request"], facts: Hash(stored["facts"]))
  rows = trace.compose_rows
  next if rows.size < 2

  names = EV::Predicates.declared_names(trace)
  rows.each_with_index do |row, index|
    input = trace.input_of(row)
    built = Nexus::Compose::Evaluator.call(script: input["script"].to_s, params: Hash.try_convert(input["params"]) || {}, tool_names: names)
    what = built.built? ? "built #{built.outcome} with #{built.steps.size} top-level steps" : "refused #{E2E::ComposeBench::Buckets.loud(built.refusal.to_s, built.detail)}"
    puts "#{record["task"]} #{record["model"].split("/").last} ##{record["run"]} call #{index + 1}: #{what}; kernel result #{row["result"].to_json}; " \
         "placed #{trace.under(row["key"]).size}; text names `results: [race]`: #{input["script"].to_s.include?("results: [race]")}"
  end
end
```

Output:

```text
compose-race deepseek-flash #1 call 1: refused syntax; kernel result {"is_error":true,"resolved":true}; placed 0; text names `results: [race]`: true
compose-race deepseek-flash #1 call 2: built steps with 2 top-level steps; kernel result {"resolved":true}; placed 11; text names `results: [race]`: true
compose-race glm-5.3-flash #1 call 1: built steps with 0 top-level steps; kernel result {"resolved":true}; placed 0; text names `results: [race]`: true
compose-race glm-5.3-flash #1 call 2: built steps with 2 top-level steps; kernel result {"resolved":true}; placed 5; text names `results: [race]`: true
compose-race-anon deepseek-flash #3 call 1: refused member_not_a_step; kernel result {"is_error":true,"resolved":true}; placed 0; text names `results: [race]`: true
compose-race-anon deepseek-flash #3 call 2: built steps with 2 top-level steps; kernel result {"resolved":true}; placed 8; text names `results: [race]`: true
```

### 9. The `<call>` line, the compose text and main since the v13 kernel (zsh, cwd = repository root)

```sh
# The `<call>` line and the compose text between v12 (bf6e5af0) and the v13 kernel (c576fe9c), and main since.
# Usage: zsh <this file>   (cwd = the repository root)
git diff --stat bf6e5af0 c576fe9c -- nexus/lib/nexus/tool_registry nexus/lib/nexus/compose nexus/app/services/agent_loops/task_result_envelope.rb | cat
echo "the envelope's changed lines, v12 -> v13:"
git diff bf6e5af0 c576fe9c -- nexus/app/services/agent_loops/task_result_envelope.rb | grep '^[-+]' | grep -v '^[-+][-+]'
echo "lines touching <call> in the envelope, v12 -> v13: $(git diff bf6e5af0 c576fe9c -- nexus/app/services/agent_loops/task_result_envelope.rb | grep -c '^[-+].*<call>')"
echo "files changed under nexus/ and e2e/support/ since c576fe9c: $(git diff --name-only c576fe9c HEAD -- nexus e2e/support | wc -l | tr -d ' ')"
(cd e2e && bundle exec ruby -I. -e 'require "mini_racer"; require "support/compose_bench"; s = E2E::ComposeBench::Rows.shipped; puts "shipped compose text: #{s.bytesize} bytes; holds T1 sentence: #{s.include?("names the call that produced it")}; rows on main: #{E2E::ComposeBench::Rows.ids.inspect}; objectives: #{E2E::ComposeBench::Objectives.ids.inspect}; control: #{E2E::ComposeBench::Objectives.ids.select { |i| E2E::ComposeBench::Objectives.find(i).control? }.inspect}; authored_labels an endpoint: #{E2E::ComposeBench::Endpoints::NAMES.include?("authored_labels")}"')
```

Output:

```text
 .../services/agent_loops/task_result_envelope.rb   | 10 ++++++-
 nexus/lib/nexus/compose/builder.js                 | 34 ++++++++++++++++++++--
 2 files changed, 41 insertions(+), 3 deletions(-)
the envelope's changed lines, v12 -> v13:
+      # Where the envelope says the tip came from, as a row: the tip itself
+      # when it is a tool's, the flat call it continues, else the root step
+      # whose brief it carries — never a key or a conversation id, so the
+      # repeat brake knows the same work saying the same thing again.
+      def origin(tip) = new(tip).origin
+
+    def origin = @tip.tool_call? ? @tip : flat_call || root
+
-        while continuation?(node) && (source = ExpandRound.source_round(node))
+        while continuation?(node) && (source = InputComposition.source_round(node))
lines touching <call> in the envelope, v12 -> v13: 0
files changed under nexus/ and e2e/support/ since c576fe9c: 0
shipped compose text: 7863 bytes; holds T1 sentence: false; rows on main: ["R-WO"]; objectives: ["O1", "O2", "O3", "O4", "O5", "O7", "O7b", "T5"]; control: ["O5"]; authored_labels an endpoint: true
```

### 10. T1's endpoint power at 24 an arm (python3)

```python
# T1 endpoint power at n = 24 O3 samples an arm (6 x four models): the largest R-L3 authored_labels count
# whose drop from R-WO clears a one-sided 90 % Newcombe-hybrid lower bound above 0 (the S1 analyzer's
# arithmetic, e2e/artifacts/bench/2026-09-24-s1/analyze_s1.rb `wilson` / `difference`).
import math
Z = 1.2815515655446004
def wilson(k, n):
    p = k / n; c = (p + Z*Z/(2*n)) / (1 + Z*Z/n); h = Z*math.sqrt(p*(1-p)/n + Z*Z/(4*n*n)) / (1 + Z*Z/n)
    return c - h, c + h
def lower(k1, n1, k2, n2):  # (p1 - p2) one-sided 90 % lower bound
    p1, p2 = k1/n1, k2/n2; l1, _ = wilson(k1, n1); _, u2 = wilson(k2, n2)
    return (p1 - p2) - math.sqrt((p1 - l1)**2 + (u2 - p2)**2)
n = 24
for k_wo in (24, 22, 21, 18, 15, 12):
    ok = [k for k in range(k_wo + 1) if lower(k_wo, n, k, n) > 0]
    best = max(ok) if ok else None
    print(f"R-WO {k_wo}/{n}: R-L3 must read <= {best}/{n} (a drop of >= {k_wo - best} samples)" if best is not None else f"R-WO {k_wo}/{n}: no R-L3 count passes")
```

Output:

```text
R-WO 24/24: R-L3 must read <= 22/24 (a drop of >= 2 samples)
R-WO 22/24: R-L3 must read <= 18/24 (a drop of >= 4 samples)
R-WO 21/24: R-L3 must read <= 17/24 (a drop of >= 4 samples)
R-WO 18/24: R-L3 must read <= 13/24 (a drop of >= 5 samples)
R-WO 15/24: R-L3 must read <= 10/24 (a drop of >= 5 samples)
R-WO 12/24: R-L3 must read <= 7/24 (a drop of >= 5 samples)
```

### 11. The one re-issued call (python3, cwd `e2e/artifacts/evals`)

```python
# The one re-issued call on v13 (glm-5.3-flash compose-background-suite #3): the composed lint, the member
# that read it, the member's own call, the calls settled between, and what the brief allowed.
# Usage (cwd = e2e/artifacts/evals): python3 <this file>
import json
t = json.load(open('2026-09-25-v13-compose/compose-background-suite.openrouter_z-ai_glm-5.3-flash.nexus.3.json', encoding='utf-8'))
nodes = {n['key']: n for n in t['graph']['nodes']}
rows = {r['key']: r for r in t['tasks']}
for key in ('r2t0-tool-2', 'r2t0-model-1', 'r3', 'r3t1'):
    n, r = nodes[key], rows.get(key, {})
    print(key, n['kind'], 'parent', n.get('expansion_parent'), 'result_from', n.get('result_from'), 'input_from', n.get('input_from'),
          'command', (r.get('tool_input') or {}).get('command'), 'created', r.get('created_at'), 'completed', r.get('completed_at'))
done, again = rows['r2t0-tool-2']['completed_at'], rows['r3t1']['created_at']
between = [(k, r.get('tool_name'), (r.get('tool_input') or {}).get('command')) for k, r in rows.items()
           if k != 'r3t1' and r.get('kind') == 'tool_task' and r.get('completed_at') and done < r['completed_at'] <= again]
print('other tool calls completed after the lint and by the re-run:', between)
print('the round that fanned the re-run:', [k for k, n in nodes.items() if n['kind'] == 'model_task' and 'r3t1' in (n.get('input_from') or [])], 'reads it; its parent', nodes['r3t1'].get('expansion_parent'), 'made it')
script = rows['r2t0']['tool_input']['script']
print('the brief allows a re-run when truncated:', 're-run bin/rubocop app yourself' in script)
print('record reissued_calls:', t['record']['facts']['reissued_calls'])
```

Output:

```text
r2t0-tool-2 tool_task parent r2t0 result_from [] input_from [] command bin/rubocop app created 2026-09-24T20:04:04Z completed 2026-09-24T20:04:05Z
r2t0-model-1 model_task parent r2t0 result_from ['r2t0-tool-2'] input_from [] command None created 2026-09-24T20:04:04Z completed 2026-09-24T20:04:07Z
r3 model_task parent r2t0-model-1 result_from [] input_from ['r2t0-model-1', 'r3t0', 'r3t1'] command None created 2026-09-24T20:04:07Z completed 2026-09-24T20:04:09Z
r3t1 tool_task parent r2t0-model-1 result_from [] input_from [] command bin/rubocop app created 2026-09-24T20:04:07Z completed 2026-09-24T20:04:07Z
other tool calls completed after the lint and by the re-run: [('r3t0', 'read', None)]
the round that fanned the re-run: ['r3'] reads it; its parent r2t0-model-1 made it
the brief allows a re-run when truncated: True
record reissued_calls: 1
```
