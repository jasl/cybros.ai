# Section A: the cells, bench v14 against v13

Read-only. Nothing was rescored and no committed line was rewritten. The v14 input is the three labels
`2026-09-26-v14-{task,compose,workflow}`: 240 records, one line per key, digest `f69dc4cc6ab4`, 0 error rows. The v13
baseline is `2026-09-25-v13-{task,compose,workflow}` under digest `ab836ee0d8be`. **v13 was rescored in place under
its own digest** (563a86aa, then 5de9f94a), so its files hold 300 lines for 240 keys (task 84, compose 139, workflow
77; 55 keys carry more than one line). This section reads **each v13 record's last line per (task, model, style,
run)**, as `E2E::Evals::Records.read` merges them, and says so wherever a v13 number appears. The v13 readout read the
first lines. The two differ on 9 records and on the totals (A1 "Inputs"):

- first lines, as the v13 readout printed them: green 167/240, mc43 dis9 cuf19 lb2;
- last lines, this section's v13 column: green 173/240, mc40 dis7 cuf20, lb 0.

The rescore moved these: the two `lane bug` deadline stops became model conduct; grep-then-edit glm-5.3 #2
(disagreement to green) and #3 (to cache under floor); rendezvous glm-5.3-flash #1 (model conduct to green); and four
adversarial-verify floor records (model conduct to green, `did_not_judge_itself`). The last lines also carry a
`picture` fact on compose-rendezvous that the first lines lack, so every "picture task" scope below has 9 tasks and
54 runs per tier on both versions, where the v13 readout counted 8 and 48.

Every number below was printed by one of four scripts. Each is embedded verbatim in the appendix with its output
beside it, and each sits as a `.py` file beside this section:

~~~sh
cd /private/tmp/claude-501/-Users-jasl-Workspaces-cybros-ai-alt2/fe6d4094-2f85-4b52-abfc-78043a70e275/scratchpad/v14/readout
python3 A1_cells.py     # cells, totals, moved cells, miss reasons, cost, usable_on_call, picture counts
python3 A2_evidence.py  # the evidence behind flags (1) and (2) and the moved cells (records + artifacts)
python3 A3_cache.py     # the cache-under-floor records, round by round, and our prefix off the world logs
python3 A4_spend.py     # recorded cost by lane against the quoted balances
# or extract one from this file:
R='import re,sys;t=open(sys.argv[1],encoding="utf-8").read();m=re.search(r"<!-- script:"+re.escape(sys.argv[2])+r" -->\n```python\n(.*?)\n```",t,re.S);exec(compile(m.group(1),sys.argv[2],"exec"),{"__name__":"__main__"})'
python3 -c "$R" A-cells.md A1_cells.py
~~~

**Cross-check.** All 80 v14 cells match LEDGER.md's v14 strings (`r`, `s` or `u·x`, `p`, `d`) with 0 mismatches (A1).

## A.1 Headline

- **v14, 240 runs:** reached 215/240, succeeded 194/240, task pass 71/72, green 174/240. Classes: model conduct 41,
  disagreement 9, cache under floor 16. There is no lane bug and no kernel finding. Recorded cost is $22.3517, and
  every record carries a cost. Record time totals 30,701 s (8.53 h).
- **v13, last lines:** reached 215/240, succeeded 193/240, task pass 69/72, green 173/240; mc40 dis7 cuf20;
  $23.2045 (2 null); 29,575 s.
- **The net move is nearly zero: succeeded +1, green +1, passed +2, cost −$0.8528.** It hides two opposite moves:
  - the **strong tier rose**: succeeded +8, green 73 → 83 (+10), model conduct −7;
  - the **floor fell**: succeeded −7, green 100 → 91 (−9), model conduct +8.
- **By family:**
  - task: green 54 → 51, succeeded 56 → 55;
  - compose: green 85 → 87, succeeded 90 → 96, the tier bar 72 → 79 of 96, task pass 11/12 → 12/12;
  - workflow: green 34 → 36, succeeded 47 → 43, reached 53 → 50.
- **By model** (green of 60): kimi-k3 33 → 43 (cache under floor 10 → 5), glm-5.3 40 → 40, deepseek-flash 49 → 46,
  glm-5.3-flash 51 → 45.
- **The strong tier's compose picture is 32/48 exact, against v13's 26/48.** Without compose-rendezvous it is 31/42
  against 26/42.
- **The floor's bar holds.** Floor runs that made a compose call on a picture task were usable 49/49, on both
  versions. Usable on the first compose call reads 43 of the 48 compose picture runs (v13 39).
- **Nine cells moved by ≥ 2 of 3** (A.4):
  - five are cache: three kimi-k3 recoveries, plus the glm-5.3 fan-five and deepseek-flash three-stage-pairing drops;
  - three are adversarial-verify fan choices;
  - one is task-background-suite glm-5.3-flash, which launched the suite with `start_process`.
- **Three red records are harness misreads** (A.11):
  - task-fan-five glm-5.3-flash #1 and #3: `per_file` counts every file a prompt names;
  - compose-race-anon glm-5.3 #1: `RaceWinner`'s substitution deletes the winner's name.

## A.2 The cells, v14 beside v13 (A1)

Notation:

- r and s are k of 3 runs. p is passed/verified, and `—` means no run was verified.
- Classes: mc model conduct, dis disagreement, cuf cache under floor, g green.
- bar is the tier's bar on a picture task:
  - a floor cell reads `u usable/3 (x picture)`, where usable means `usable_on_call` is set, meaning some compose
    call in the run met the bar;
  - a strong cell reads `x picture/3 (u usable)`, where the picture is read on the first compose call;
  - `= s` marks a cell whose bar is its success.
- **compose-rendezvous on the strong tier:** its success reads `valid_first`, not the picture. So its `x` is a fact
  there, and it is the only place where success and the column differ (A1: 5 records, all rendezvous strong).
- v13 is the last line per key.
- Mean s is the mean of `seconds`. Cost is the sum of `cost_amount` in USD.

{{PERCELL}}

## A.3 Totals, v14 against v13 (A1)

`bar` sums the tier's bar over picture cells. That is the picture on the strong tier and usable generation on the
floor, so a mixed-tier row adds two different bars.

{{TOTALS}}

## A.4 Cells that moved by 2 or more of 3, and what moved them (A1, A2, A3)

Nine cells moved by 2 or more on reached, succeeded, task pass or green. Two more moved by 2 on the picture fact
alone. Each cause below is read from the records' reasons and facts, and from the artifacts where the records do not
say it.

| family | task | model | move | v14 | v13 | what moved it |
|---|---|---|---|---|---|---|
| task | background-suite | glm-5.3-flash | r −2, s −2, g −2 | r0 s0 [mc3] | r2 s2 [mc1 g2] | model. All three v14 runs launched `bin/rails test` with `start_process` (r2t0, r2t2 then r58t1, r4t0) and never called `task`. The first request is identical to v13's except for the compose tool's description (A.7) |
| task | fan-five | glm-5.3 | g −2 | r3 s3 [cuf2 g1] | r3 s3 [g3] | cache. After round 1, #1 read 0.5072 and #3 0.7918, with success held. The provider served short while our prefix extended (A.9) |
| compose | three-stage-pairing | deepseek-flash | g −2 | r3 s3 u3 [cuf2 g1] | r3 s3 u3 [g3] | cache. #2 read 0.7718, but its ceiling was 0.7628, so this is the bar's arithmetic. #3 read 0.7624: on r3 the provider served r1's prompt. The picture also fell 3 → 1: #1 `over_read`, and #3's first call was refused `script_syntax_error` and was usable on call 2 |
| workflow | adversarial-verify | glm-5.3 | s +2, g +2 | r3 s3 p3/3 [cuf1 g2] | r3 s1 p3/3 [dis2 cuf1] | model. v13 #2 and #3 waited their fans (`wait: true` 12/12, 0 receipts). All three v14 runs detached, with 12 receipts each |
| workflow | adversarial-verify | kimi-k3 | p +2 | r3 s2 p3/3 [dis1 cuf2] | r3 s1 p1/3 [mc2 cuf1] | model. v13 #1 and #3 waited and marked true claims FALSE. v14 #1 and #3 detached and passed. v14 #2 waited, passed, and is a disagreement |
| workflow | adversarial-verify | deepseek-flash | r −2, s −3, p −1, g −3 | r1 s0 p2/3 [mc2 dis1] | r3 s3 p3/3 [g3] | model. #2 and #3 fanned with `spawn` ×12 instead of `task`, which gives no door (`reached` false). #3 also fails verification and `did_not_judge_itself`. #1 waited 13/13 `task` calls. v13's three green runs are rescored lines (the owner's ruling (3)) |
| workflow | fan-out-finders | kimi-k3 | g +3 | [g3] | [cuf3] | cache. v13 read 0.2869, 0.2983 and 0.0; v14 reads 0.8979, 0.8876 and 0.9468 |
| workflow | judge-panel | kimi-k3 | g +2 | [g3] | [cuf2 g1] | cache. v13 #2 read 0.328 and #3 0.6045; v14 reads 0.8669, 0.9016 and 0.8583 |
| workflow | loop-until-dry | kimi-k3 | g +2 | [g3] | [cuf2 g1] | cache. v13 #1 read 0.6306 and #2 0.7048; v14 reads 0.9156, 0.835 and 0.9477 |

The two picture-fact moves, neither of which moves a bar:

- **compose-rendezvous glm-5.3-flash, picture 0 → 2 of 3.** Usable holds 3/3. On v13, #1's first call was refused
  ("after: goes beside input"), #2 read `extra_steps, over_read`, and #3 `over_read`. On v14, #1 and #3 are exact,
  and #2 (`over_read`) was stopped at the deadline.
- **compose-three-stage-pairing deepseek-flash, picture 3 → 1.** See the table above.

Under 2 and not read as a move:

- task-mail deepseek-flash went 2 → 3 reached and kimi-k3 0 → 1;
- review-angles glm-5.3 and both strong three-stage-pairing cells went 2/3 → 3/3 on the picture;
- compose-grep-then-edit kimi-k3 went 1 → 2 on the picture.

**The cache recovery is kimi-k3's.** kimi-k3's cache-under-floor records went 10 → 5, and its green rose by 10.
Nothing on our side of the prefix moved: the first requests are identical except for T1's sentence, and every
measured round's request extends the one before (A.9). By the records, the recovery is the provider's.

## A.5 Dominant miss reasons per family (A1)

A red is every record whose class is not green, grouped by its own `reason`. A conduct-only red has an empty reason.

{{MISS}}

In short:

- **task: 21 reds (v13 18).** Still one habit: **no `task` call, with `start_process` in the tally, 13 of 21** (v13
  12). That is background-suite 6 and task-mail 7. By model: glm-5.3 2, kimi-k3 2, deepseek-flash 3, glm-5.3-flash 6.
  The rest:
  - cache under floor 4 (kimi-k3 background-suite 2, glm-5.3 fan-five 2);
  - fan-five glm-5.3-flash's two "a second task" reds, a harness misread (A.11);
  - fan-five deepseek-flash #1, which made 0 `task` calls in the first message (5 `read`s);
  - background-suite glm-5.3 #1, which handed the suite to two tasks (A.7).
- **compose: 21 reds (v13 23).**
  - **9 picture reds, all on the strong tier** (glm-5.3 4, kimi-k3 5): two-source-fan-in 5, background-suite 2,
    grep-then-edit 2. Over the 10 records whose reason names buckets, which adds the deadline-stopped background-suite
    glm-5.3 #1: over_read 7, extra_steps 2, over_sync 2, missing_steps 1, blind_model 1. The v13 last lines read
    over_read 9, extra_steps 3, over_sync 3, wrong_task_read 1.
  - cache under floor 6.
  - three 600 s deadline stops (A.11).
  - the rest:
    - background-suite kimi-k3 #1 refused `script_syntax_error` (usable on call 2);
    - three-stage-pairing glm-5.3-flash #1 made no compose call;
    - race-anon glm-5.3 #1's `no_wrong_winner`, a misread (A.11).
- **workflow: 24 reds (v13 26).**
  - **No door, 10 (v13 7):**
    - barrier-free 7 (kimi-k3 3, deepseek-flash 3, glm-5.3-flash 1), every one passing verification;
    - deepseek-flash's `spawn` fans, 3: adversarial #2 and #3, and judge-panel #3 with 4 spawns. `spawn` appears on 0
      v13 records and 3 v14 records, all deepseek-flash (A2 §3f).
  - cache under floor 6 (v13 13), glm-5.3 4 and kimi-k3 2.
  - waited adversarial fans 4 (kimi-k3 1, deepseek-flash 1, glm-5.3-flash 2).
  - barrier-free glm-5.3's `edit_as_tool` ×3 (A.8).
  - loop-until-dry glm-5.3-flash #3's `one_item_per_pass`.
  - `did_not_judge_itself` fails 1/12, on deepseek-flash #3's spawned fan.

## A.6 The strong tier's picture on compose; the floor's `usable_on_call` (A1)

{{USABLE}}

{{PICTURE}}

Reading:

- **The strong tier's compose picture is 32/48 exact (v13 26/48).** Without rendezvous it is 31/42 (v13 26/42).
  - Rendezvous itself reads 1/6 (0/6), with success held by `valid_first`.
  - By model, over the 9 picture tasks: glm-5.3 17 exact of 27 and kimi-k3 15 of 27, where v13 read 14 and 13.
  - The six rises of one run each: three-stage-pairing (2 → 3 on both strong models), review-angles glm-5.3 (2 → 3),
    grep-then-edit kimi-k3 (1 → 2), rendezvous glm-5.3 (0 → 1) and two-source-fan-in glm-5.3 (0 → 1).
  - Every other strong compose cell holds.
- **Two-source-fan-in, the owner's question.** The strong tier reads picture 1/6 (v13 0/6), and every miss is
  `over_read` (5 of 5). The floor reads picture 2/6 (v13 2/6) and succeeded 6/6. So the floor is "better" on this
  cell only because its bar is usable generation (6/6), not the picture. On the picture the two tiers are 1/6 and
  2/6.
- **The floor's `usable_on_call` on the compose picture tasks is 1 / 2 / none = 43 / 4 / 1 of 48** (v13 39 / 7 / 2).
  Over all 9 picture tasks it is 45 / 4 / 5 of 54 (v13 42 / 7 / 5). No run needed a third call.
  - The four call-2 runs: background-suite glm-5.3-flash #3 (`g.parallel: every member …`), grep-then-edit
    glm-5.3-flash #3 (`script_syntax_error`), race glm-5.3-flash #3 (placed stages that failed on their own scripts),
    and three-stage-pairing deepseek-flash #3 (`script_syntax_error`).
  - The five never-usable floor runs made no compose call: three-stage-pairing glm-5.3-flash #1, barrier-free
    deepseek-flash #1–#3 and glm-5.3-flash #1.
  - Every floor run that composed was usable, 49/49 (v13 49/49). On the strong tier it was 51/51 (v13 49/49).

## A.7 Flag (1): task-background-suite is lower than v13 (A1, A2 §1, §1b)

**By how much.** Over the cell's 12 runs:

| | reached | succeeded | green |
|---|---|---|---|
| v14 | 6/12 | 5/12 | 3/12 |
| v13 | 8/12 | 8/12 | 6/12 |

The fall is on the floor and on glm-5.3. kimi-k3 rose.

| model | v14 | v13 |
|---|---|---|
| glm-5.3 | r3 s2 g2 | r3 s3 g3 |
| kimi-k3 | r3 s3 g1 (cuf2) | r2 s2 g0 (mc1 cuf2) |
| deepseek-flash | r0 s0 g0 | r1 s1 g1 |
| glm-5.3-flash | r0 s0 g0 | r2 s2 g2 |

The floor reads **0/6 reached (v13 3/6)**. Over versions (A2 §1):

| | all | floor |
|---|---|---|
| v10 | r7/12 | r2/6 |
| v11 | r9/12 | r3/6 |
| v13 | r8/12 | r3/6 |
| v14 | r6/12 | r0/6 |

**Why, from the reasons and traces:**

- **The floor launched the suite as a process, not a task.** All six floor runs read "no `task` call" with
  `start_process` in the tally. Each one's `start_process` row ran `bin/rails test`: four in the calls right
  after r1 and two after r3, and glm-5.3-flash #2 launched it again at r58t1. The replies report the suite launched in the
  background and the lint fixed; for example, deepseek-flash #3 says "launched in the background (process `p3`) so
  nothing was blocked on it". The task's RATIONALE counts `no_start_process` as part of success, so this is the
  task's red as written.
  - glm-5.3-flash #2 also ran 61 rounds with 54 `bash` calls in 652 s.
- **Nothing in the models' input explains it.** For each model, the first request's system, developer and user
  entries are byte-identical to v13's after the per-run path is normalised. All 25 tool definitions are identical
  except `compose`, which grows 9,258 → 9,391 bytes: T1's sentence, the one v14 text change (A2 §1). The
  `task`/`start_process` choice is the model's, on the same input.
- **At n = 3 it is a low draw, not a trend.** The floor's pooled reach over v10, v11 and v13 is 8/18 (0.444). At that
  rate, 0 of 6 has probability 0.0294 (0.0156 at 0.5) (A2 §1b). No v14 change touched the texts this choice reads.
- **glm-5.3 #1** handed the suite to a task at r2t0. Then at r15t0 it handed it again with the same prompt ("Run
  this Rails project's whole test suite with `bin/rails test` …"), and its reply calls it "the duplicate run". That
  is model conduct under `one_task_for_the_suite`.
- **kimi-k3's +1** is v13 #2's `start_process` run not recurring. Its two v14 reds are cache under floor (0.7993 and
  0.7304), the provider's (A.9).

## A.8 Flag (2): workflow-barrier-free-pipeline is 2/12 green; glm-5.3 reads `edit_as_tool` 3/3 (A1, A2 §2)

**The 12 runs:**

- **2 green:** glm-5.3-flash #2 and #3, floor, usable on call 1. Their picture fact reads `edit_as_tool`.
- **7 no-door reds:** kimi-k3 #1–#3, deepseek-flash #1–#3 and glm-5.3-flash #1. Each did the pipeline with 1–3
  `bash` calls beside `ls`, `read` or `write`, in a mean of 45 s (kimi-k3) and 34 s (deepseek-flash), and 62 s for
  glm-5.3-flash #1. No compose call, no two-`task` fan.
- **3 disagreements:** glm-5.3 #1–#3.
- **Verification passes 12/12.** v13 was 3/12 green, with kimi-k3 no-door 3/3 there too.

**glm-5.3's three plans place O7's edge set exactly:** three [fetch → normalise] pairs, then a merge after the three
normalisers. Each picture names one bucket, `edit_as_tool`, because the merge is a bash tool:

- #1: `cat rec_a.txt rec_b.txt rec_c.txt > merged.txt`, with awk tool normalisers;
- #2: `echo "$(cat normalised/a.txt)" > merged.txt …`, with value-stage normalisers that `write` their files;
- #3: `cat rec/a.rec rec/b.rec rec/c.rec > merged.txt`, with `sh bin/normalise` tool normalisers in a
  `parallel until all`.

O7's picture (objectives.rb) admits a tool normaliser that computes over its fetch's file (`computes: na nb nc`), but
its `merge` node is `model|script` only. So a tool merge over the normalisers' files is `edit_as_tool`.

Across versions, on this task:

- every v14 composed run's picture names `edit_as_tool` as its only bucket (5 of 5, both floor greens included);
- on v13 it was 4 of 5. The fifth, glm-5.3 #3, was exact with a value-stage merge (`script-4 results=[script-1,
  script-2, script-3]`).

**Reading.** O7 was cut for the text bench's "merge the three normalised sets into one list", where there is no file.
This task says "merge the three normalised records into merged.txt", where a tool concatenating the normalisers'
files is the plain dataflow, and the verification passes on it. The three glm-5.3 reds are the picture's rule applied
to a merge the task's own wording invites, and the task pass is true on all three. Under the owner's lenient-scoring
ruling this is a scorer question (A.11 item 3), not model conduct. The 7 no-door runs are the family's recorded door
rule: they did correct work without the door the task measures.

## A.9 Flag (3): the 16 `cache under floor` records (A3)

**Counts.**

- v14: 16 records, task 4, compose 6, workflow 6. By model: glm-5.3 8, kimi-k3 5, deepseek-flash 3.
- v13, last lines: 20 records, task 2, compose 5, workflow 13. By model: kimi-k3 10, glm-5.3 6, deepseek-flash 4.
- v13, first lines: 19. The rescore moved compose-grep-then-edit glm-5.3 #3 into the class.

The bar reads 82 v14 records and 79 v13 records. Under it sit 22 v14 records (16 classed so; 6 carry a red class that
wins) and 29 v13 records (20 + 9).

**The family bar** is 0.80 for task, compose and workflow alike (bench.yml `limits.cache_floor_by_family`), with
`cache_floor_min_rounds` 2. glm-5.3-flash is exempt.

{{CUF}}

**Whose miss it is.** Two reads settle this:

- **Our prefix, off the world logs.** Each spine round's sealed request was rebuilt from the jobs log: the round's
  `request` ContentBody, its ordered `content_body_entries` → `content_fragment` ids, and its `byte_size`, matched to
  the round by `request_bytes_series`. On every measured round of all 16 records:
  - the previous round's entry list is a prefix of this round's (EXTENDS);
  - the ModelInvocation's `request_options` (the tool list) is byte-identical to the previous round's.

  **Across all 240 v14 records, 805 of 805 matched measured spine rounds extend the previous request with the same
  tools.** One record's round 1, adversarial-verify glm-5.3 #3, matched two bodies of the same size and was not read.
  **None of the 16 is our prefix.**
- **The provider, off `cache_read_series`.** A round's read is set against the previous round's whole prompt, the
  most a prefix cache can serve. The ceiling is sum(previous input) / sum(input) over the measured rounds, the rate a
  provider serving every whole previous prompt would give.

| whose | records |
|---|---|
| **the provider served short** and the ceiling clears 0.80 | **12**: grep-then-edit kimi-k3 #1; single-read glm-5.3 #2; three-stage-pairing deepseek-flash #3; background-suite kimi-k3 #1, #2; fan-five glm-5.3 #1, #3; adversarial-verify glm-5.3 #2, kimi-k3 #1, #3; judge-panel glm-5.3 #1, #3 |
| **the ceiling is under 0.80 and the provider served whole**: the bar's arithmetic | **2**: grep-then-edit deepseek-flash #2 (0.7848, ceiling 0.7898), three-stage-pairing deepseek-flash #2 (0.7718, ceiling 0.7628) |
| both | **2**: grep-then-edit glm-5.3 #1 (0.6574, ceiling 0.7006; r2 read 0), judge-panel glm-5.3 #2 (0.7622, ceiling 0.7914) |

The provider's patterns by model:

- **kimi-k3: nothing served, between whole-prompt hits.** adversarial-verify #1 reads 0 on 6 of its 11 measured rounds
  (r2, r19, w1, r29, w3, r31), interleaved with rounds that read the whole previous prompt (r3, r4, r25, r30). background-suite #1's r4
  reads 0 between hits. This is the cache audit's measured-8 reading (a per-request flip across the broker's
  replicas). The records carry no upstream field to name it.
- **glm-5.3: a shorter stored entry served again.**
  - adversarial-verify #2 reads 8,192 on each of r2–r5 while the previous prompt grows 9,717 → 10,235;
  - judge-panel #1–#3 each read 8,192 on r2 after a 9,696 prompt;
  - grep-then-edit #1 and single-read #2 read 0 on r2, then whole prompts.
- **deepseek-flash: whole-prompt reads (≥ 0.99) on every measured round.** The one exception is three-stage-pairing
  #3's r3, which read 9,984, r1's prompt, after a 14,874 prompt.

So the v13 → v14 fall, 20 → 16, is kimi-k3's 10 → 5, the provider's. glm-5.3 rose 6 → 8, also the provider's.

The same classification on v13's 20 gives: provider served short 15, bar's arithmetic 3, both 2. On v13 it was read
off the series alone, not the world logs.

## A.10 Cost, duration and spend (A1, A4)

| model | tier | task $ | compose $ | workflow $ | v14 $ | v13 $ | Δ$ | v14 mean s/run | v13 mean s/run |
|---|---|---|---|---|---|---|---|---|---|
| glm-5.3 | strong | 1.2283 | 4.5970 | 4.1255 | 9.9508 | 8.6416 | +1.3092 | 168 | 162 |
| kimi-k3 | strong | 1.6049 | 4.5811 | 4.3656 | 10.5516 | 12.6364 | −2.0849 | 99 | 86 |
| deepseek-flash | floor | 0.0973 | 0.3800 | 0.2663 | 0.7437 | 0.9393 | −0.1957 | 66 | 73 |
| glm-5.3-flash | floor | 0.1585 | 0.4358 | 0.5113 | 1.1056 | 0.9871 | +0.1185 | 179 | 172 |

- **By family:** v14 task $3.0889, compose $9.9939, workflow $9.2688; v13 $2.9823, $9.5737 and $10.6485.
- **By lane:** v14 OpenRouter $21.6080 and DeepSeek $0.7437 at the catalog USD price.
- **Against the balances:** the quoted OpenRouter balance moved $25.97 (199.30 → 173.33; the task statement's "$26.00"
  is $0.03 off that subtraction). That is **$4.3620 more than the records carry**.
  - The race-text A/B's reruns ran inside the bench window. Their launch outputs were written at 17:26:11Z, 17:47:34Z
    and 19:36:40Z (A4), against records spanning 16:02:32Z → 00:51:17Z.
  - The race-text readout itself says its balance window "less v14's task family".
  - So the balance move carries spend that is not the bench's, and the records cannot split it. DeepSeek moved ¥4.21
    against $0.7437 of records at the catalog price, and does not reconcile without a rate.
- **Duration:** glm-5.3-flash is still the slowest model per run (179 s mean). kimi-k3's mean rose 86 → 99 s. Its
  loop-until-dry #2 took 421 s and its grep-three-control mean went 15 → 66 s.

## A.11 The harness's own readings to correct, and rules to decide

1. **task-fan-five `Predicates.per_file` counts every file a task prompt names** (predicates.rb:259: a prompt counts
   for a file when the file's name appears in it). glm-5.3-flash #1 and #3 each gave one distinct file per task, a–e
   ("Review ONLY lib/b.rb …", "Review the single file lib/b.rb …"). Each prompt also names the other files as the
   places to search for callers. So `per_file` reads {a..e: 5} on #1 and {a: 5, b: 4, c: 3, d: 3, e: 5} on #3, and
   both records read "a second task for a.rb, b.rb, c.rb, d.rb, e.rb", model conduct. Both merged all five in the
   primary turn (`merge_turn` primary, `orphans_named` 5). A reader that counts the file a prompt assigns would not
   red them. That the remaining checks (graph verbs inside branches, loop completed) pass is not re-read here (A2 §3c).
2. **`Claims::RaceWinner` deletes the winner's name before it reads the claim.** `PROBED = %r{bin/probe\s+(?:alpha|bravo|
   charlie)\b}i` is replaced by `bin/probe`. compose-race-anon glm-5.3 #1 wrote "**bravo won.** … `bin/probe bravo` was
   the first to respond …, so the fan settled on it and stopped waiting on alpha and charlie". After the substitution,
   the sentence names only alpha and charlie beside "first to respond", and the checker "ties alpha to `won`". The
   reply is right, so `no_wrong_winner` false is a misread, and it is that record's only red (A2 §3d). The Q10
   analysis's `no_wrong_winner` 2/3 on that cell is the same record.
3. **O7's merge node excludes a tool merge on a task that asks for a file** (A.8). This is the owner's to rule under
   the lenient-scoring ruling: does barrier-free's picture admit a tool merge that waits on the three normalisers and
   computes over their files? The picture already admits that for a normaliser. The rule moves 3 glm-5.3
   disagreements, and it moves the `picture` fact on the two floor greens.
4. **The cache bar's arithmetic reds records whose provider served every whole prompt.** On 2 v14 records (3 on v13)
   the rate cannot reach 0.80: the measured rounds' new content (a large tool result) is more than 20 % of their
   input, and the provider read ≥ 0.99 of each previous prompt. bench.yml's own note on `cache_floor_min_rounds` names
   this bound for a lone measured round. Two measured rounds carry it too. A reader could read the class against
   the ceiling (A3's `ideal`) instead of the flat floor.
5. **Three 600 s deadline stops are classed model conduct:**

   | record | reached / succeeded / pass | usable on call | where the time went |
   |---|---|---|---|
   | compose-background-suite glm-5.3 #1 | reached, not succeeded | 1 | r1 alone ran 601 s; the compose call placed at the stop |
   | compose-grep-then-edit glm-5.3-flash #1 | reached, succeeded, task pass true | 1 | r1 ran 599 s; r2 was streaming (405 frames, the last 4.8 s before the stop) |
   | compose-rendezvous glm-5.3-flash #2 | reached, succeeded | 1 | 27 spine rounds; r27 was streaming (1,474 frames) |

   All three are the models' own time, so no harness fault. But the two glm-5.3-flash records met the floor's bar,
   usable generation, and are red only on the deadline. Whether a floor run that met its bar and was stopped
   mid-final-round is model conduct is the owner's rule (A2 §3e). None of them is `deadline (mid-round)`, since
   rounds had settled. All three carry their spend.
6. **`spawn` is not a door.** deepseek-flash fanned 12 `spawn` subagents (adversarial #2 and #3) and 4 (judge-panel
   #3) where the family reads only `compose` or a two-`task` fan. #2 and judge-panel #3 pass verification. The class
   is right under the family's door rule, since the task measures the `task` receipt loop. `spawn` is new on v14 (0
   v13 records), and its description is unchanged between the two versions (A2 §1: only `compose` differs). It is
   recorded here as a new model behaviour, not as a misread.

## Appendix: scripts and their outputs
