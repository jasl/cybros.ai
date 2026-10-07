# Section A — seven models on one bench (v15's three beside v14's four)

Scope: every (task × model) cell of bench version 15 (digest `772186a893d5`, kernel `cbff8f42`, records at `6b6f49b1`:
claude-opus-5-5 and gpt-6-sol on the strong bar, gpt-6-luna on the floor) beside version 14's four tier models (digest
`f69dc4cc6ab4`: glm-5.3 and kimi-k3 strong, deepseek-flash and glm-5.3-flash floor). Version 15 moved no predicate or
picture (bench.yml VERSION 15 note: "No predicate or picture moved"), so the two columns compare directly. Nothing was
rescored or rewritten; every number below is printed by a script in this directory, named in brackets, whose output
is appended whole at the end. Read-only throughout: no paid call, no world, no test suite; one in-memory re-read
(A3, v14's own O7 candidate script run unchanged on the v15 labels) under `nice`.

Short names: opus = anthropic/claude-opus-5-5, sol = openai_api/gpt-6-sol, luna = openai_api/gpt-6-luna, glm =
openrouter/z-ai/glm-5.3, kimi = openrouter/moonshotai/kimi-k3, ds-flash = deepseek/deepseek-flash, glm-flash =
openrouter/z-ai/glm-5.3-flash. `r` reached, `s` succeeded, `p` verification passed/verified, classes mc model conduct,
dis disagreement, cuf cache under floor, g green. "Picture" = `facts.picture == true` (the strong bar), "usable" =
`facts.usable_on_call` set (the floor's bar); both are on every compose picture record of both versions.

## Headline

**Opus 5.5 is first on every like-for-like reading**: green 52/60, the same 52 on the strong bar, 31/33 on the cells
whose bar does not depend on the tier, 18/21 exact pictures on the compose gate tasks (next best glm 16), at $0.2119 per
green, under both v14 strong models ($0.2488 glm, $0.2454 kimi) and 52 s a run against their 168 s and 99 s.
**GPT-6 Sol is second on green (45) but not on success**: it succeeded 45/60 against glm's 49 and kimi's 48; its green
lead over them is the cache class (glm lost 8 greens to it, kimi 5, sol 0). Sol sends one delegation per message: it
put two or more `task` calls in one spine round on 1 of the 12 records where it delegated twice or more (v14's four:
11/12, 11/11, 7/7, 12/12), which alone reds task-fan-five 0/3 and workflow-judge-panel 0/3. **GPT-6 Luna is the best floor
model on green (48 against 46 and 45) at $0.0040 per green**, a quarter of ds-flash's, with every compose picture run
usable (24/24), but it holds the lowest gate picture of all seven (12/21) and shares sol's one-delegation-per-message
habit on 5 of its 11 multi-delegation records. **Like for like, the new strong pair succeeds exactly as the old pair did** (97/120 each); the
green gap, 97 against 83, is 13 cache-under-floor records plus v14's misread race-anon record.

## A.0 Inputs [A1]

- v15: 180 records (task 54, compose 81, workflow 45), one line per key, all under `772186a893d5`, 0 error rows, 0
  stops, every cost in USD; record starts 2026-09-26T04:23:59Z → 07:10:33Z (the last record's start). Tiers stamped
  opus/sol `strong`, luna `floor` on every record.
- v14: 240 records, one line per key, all under `f69dc4cc6ab4`, 3 deadline stops (compose), 0 error rows.
- 140 cells (v15 60, v14 80), the same 20 tasks on both, 3 runs each. LEDGER.md's v15 section re-derived from the
  records (r, s or u·x, p, d): 60 cells, 0 mismatches. The v14 per-model figures here reproduce the v14 readout's
  (glm $9.9508 g40, kimi $10.5516 g43, ds-flash $0.7437 g46, glm-flash $1.1056 g45).

## A.1 Every cell [A1 §A.1, §A.2]

The full 140-row table (r, s, p, classes, bar, mean seconds, cost) is A1's §A.1 below. The green matrix, green of 3
(picture cells add x = picture exact, u = usable):

| family | task | opus | sol | glm | kimi | luna | ds-flash | glm-flash |
|---|---|---|---|---|---|---|---|---|
| task | background-suite | 2 | 3 | 2 | 1 | 3 | 0 | 0 |
| task | detached-receipt | 3 | 3 | 3 | 3 | 3 | 3 | 3 |
| task | fan-five | 3 | **0** | 1 | 3 | 1 | 2 | 1 |
| task | grep-three-control | 3 | 3 | 3 | 3 | 3 | 3 | 3 |
| task | mail | 2 | 3 | 1 | 1 | 1 | 3 | 0 |
| task | two-calls | 3 | 3 | 3 | 3 | 3 | 3 | 3 |
| compose | background-suite | 3 (x3 u3) | 3 (x3 u3) | 1 (x1 u3) | 1 (x1 u3) | 3 (x1 u3) | 3 (x1 u3) | 3 (x1 u3) |
| compose | grep-then-edit | 3 (x3 u3) | 1 (x1 u3) | 1 (x2 u3) | 1 (x2 u3) | 3 (x1 u3) | 2 (x3 u3) | 2 (x1 u3) |
| compose | race | 3 (x3 u3) | 3 (x3 u3) | 3 (x3 u3) | 3 (x3 u3) | 3 (x3 u3) | 3 (x3 u3) | 3 (x2 u3) |
| compose | race-anon | 3 (x3 u3) | 3 (x3 u3) | 2 (x3 u3) | 3 (x3 u3) | 3 (x3 u3) | 3 (x3 u3) | 3 (x3 u3) |
| compose | rendezvous (T5) | 3 (x0 u3) | 3 (x0 u3) | 3 (x1 u3) | 3 (x0 u3) | 3 (x0 u3) | 3 (x0 u3) | 2 (x2 u3) |
| compose | review-angles | 3 (x3 u3) | 3 (x3 u3) | 3 (x3 u3) | 3 (x3 u3) | 3 (x3 u3) | 3 (x3 u3) | 3 (x3 u3) |
| compose | single-read | 3 | 3 | 2 | 3 | 3 | 3 | 3 |
| compose | three-stage-pairing | 3 (x3 u3) | 1 (x1 u3) | 3 (x3 u3) | 3 (x3 u3) | 2 (x1 u3) | 1 (x1 u3) | 2 (x1 u2) |
| compose | two-source-fan-in | **0** (x0 u3) | 1 (x1 u3) | 1 (x1 u3) | 0 (x0 u3) | 3 (x0 u3) | 3 (x0 u3) | 3 (x2 u3) |
| workflow | adversarial-verify | 3 | 3 | 2 | 0 | 1 | 0 | 1 |
| workflow | barrier-free-pipeline | 0 (x0 u3) | 0 (x0 u2) | 0 (x0 u3) | 0 (x0 u0) | 0 (x0 u0) | 0 (x0 u0) | 2 (x0 u2) |
| workflow | fan-out-finders | 3 | 3 | 3 | 3 | 3 | 3 | 3 |
| workflow | judge-panel | 3 | **0** | 0 | 3 | 1 | 2 | 3 |
| workflow | loop-until-dry | 3 | 3 | 3 | 3 | 3 | 3 | 2 |
| **all** | **green of 60** | **52** | **45** | **40** | **43** | **48** | **46** | **45** |

Opus is green 3/3 on 16 of 20 tasks; its four short cells are task-background-suite and task-mail (2/3 each, a
background job launched through `compose` instead of `task`), two-source-fan-in 0/3 (the picture) and
barrier-free-pipeline 0/3 (O7's tool-merge reading). Barrier-free is green only for glm-flash (2/3, on the floor's
bar). §A.5 carries every flagged cell's reason.

## A.2 Per family and per model [A1 §A.3]

| family | model | tier | green | reached | succeeded | p | classes | cost $ | $ / green | mean s |
|---|---|---|---|---|---|---|---|---|---|---|
| task | opus | strong | 16/18 | 16/18 | 16/18 | - | mc2 | 2.6895 | 0.1681 | 52 |
| task | sol | strong | 15/18 | 15/18 | 15/18 | - | mc3 | 0.7730 | 0.0515 | 52 |
| task | glm | strong | 13/18 | 16/18 | 15/18 | - | mc3 cuf2 | 1.2283 | 0.0945 | 84 |
| task | kimi | strong | 14/18 | 16/18 | 16/18 | - | mc2 cuf2 | 1.6049 | 0.1146 | 66 |
| task | luna | floor | 14/18 | 14/18 | 14/18 | - | mc4 | 0.0474 | 0.0034 | 54 |
| task | ds-flash | floor | 14/18 | 14/18 | 14/18 | - | mc4 | 0.0973 | 0.0070 | 53 |
| task | glm-flash | floor | 10/18 | 12/18 | 10/18 | - | mc8 | 0.1585 | 0.0158 | 94 |
| compose | opus | strong | 24/27 | 27/27 | 24/27 | 3/3 | mc3 | 3.7574 | 0.1566 | 45 |
| compose | sol | strong | 21/27 | 27/27 | 21/27 | 3/3 | mc4 dis2 | 1.2934 | 0.0616 | 39 |
| compose | glm | strong | 19/27 | 27/27 | 22/27 | 3/3 | mc5 dis1 cuf2 | 4.5970 | 0.2419 | 203 |
| compose | kimi | strong | 20/27 | 27/27 | 21/27 | 3/3 | mc5 dis1 cuf1 | 4.5811 | 0.2291 | 96 |
| compose | luna | floor | 26/27 | 27/27 | 27/27 | 3/3 | cuf1 | 0.0770 | 0.0030 | 42 |
| compose | ds-flash | floor | 24/27 | 27/27 | 27/27 | 3/3 | cuf3 | 0.3800 | 0.0158 | 67 |
| compose | glm-flash | floor | 24/27 | 26/27 | 26/27 | 3/3 | mc3 | 0.4358 | 0.0182 | 246 |
| workflow | opus | strong | 12/15 | 15/15 | 12/15 | 15/15 | dis3 | 4.5715 | 0.3810 | 66 |
| workflow | sol | strong | 9/15 | 13/15 | 9/15 | 15/15 | mc2 dis4 | 1.2756 | 0.1417 | 89 |
| workflow | glm | strong | 8/15 | 15/15 | 12/15 | 15/15 | dis3 cuf4 | 4.1255 | 0.5157 | 204 |
| workflow | kimi | strong | 9/15 | 12/15 | 11/15 | 15/15 | mc3 dis1 cuf2 | 4.3656 | 0.4851 | 142 |
| workflow | luna | floor | 8/15 | 10/15 | 10/15 | 13/15 | mc5 dis2 | 0.0668 | 0.0083 | 92 |
| workflow | ds-flash | floor | 8/15 | 9/15 | 8/15 | 14/15 | mc6 dis1 | 0.2663 | 0.0333 | 81 |
| workflow | glm-flash | floor | 11/15 | 14/15 | 12/15 | 15/15 | mc2 dis2 | 0.5113 | 0.0465 | 162 |
| **all** | opus | strong | **52/60** | 58/60 | 52/60 | 18/18 | mc5 dis3 | 11.0183 | 0.2119 | 52 |
| **all** | sol | strong | **45/60** | 55/60 | 45/60 | 18/18 | mc9 dis6 | 3.3420 | 0.0743 | 56 |
| **all** | glm | strong | **40/60** | 58/60 | 49/60 | 18/18 | mc8 dis4 cuf8 | 9.9508 | 0.2488 | 168 |
| **all** | kimi | strong | **43/60** | 55/60 | 48/60 | 18/18 | mc10 dis2 cuf5 | 10.5516 | 0.2454 | 99 |
| **all** | luna | floor | **48/60** | 51/60 | 51/60 | 16/18 | mc9 dis2 cuf1 | 0.1911 | 0.0040 | 58 |
| **all** | ds-flash | floor | **46/60** | 50/60 | 49/60 | 17/18 | mc10 dis1 cuf3 | 0.7437 | 0.0162 | 66 |
| **all** | glm-flash | floor | **45/60** | 52/60 | 48/60 | 18/18 | mc13 dis2 | 1.1056 | 0.0246 | 179 |

| scope | green | reached | succeeded | p | classes | cost $ | $ / green | mean s |
|---|---|---|---|---|---|---|---|---|
| v15 strong (opus, sol) | 97/120 | 113/120 | **97/120** | 36/36 | mc14 dis9 | 14.3603 | 0.1480 | 54 |
| v14 strong (glm, kimi) | 83/120 | 113/120 | **97/120** | 36/36 | mc18 dis6 cuf13 | 20.5024 | 0.2470 | 133 |
| v15 floor (luna) | 48/60 | 51/60 | 51/60 | 16/18 | mc9 dis2 cuf1 | 0.1911 | 0.0040 | 58 |
| v14 floor (ds-flash, glm-flash) | 91/120 | 102/120 | 97/120 | 35/36 | mc23 dis3 cuf3 | 1.8492 | 0.0203 | 123 |
| v15 all | 145/180 | 164/180 | 148/180 | 52/54 | mc23 dis11 cuf1 | 14.5515 | 0.1004 | 55 |

Readings:

- **The strong pairs succeed alike; the cache class makes the green gap.** v15 strong and v14 strong both reach 113/120
  and succeed 97/120 (by family: task 31 and 31, compose 45 and 43, workflow 21 and 23). v14 strong's 14 succeeded
  non-greens are 13 cache-under-floor records and race-anon glm #1 (the `RaceWinner` misread, v14 §7.2); v15 strong
  has none (opus 52 succeeded = 52 green, sol 45 = 45).
- **Verification**: opus and sol 18/18; luna 16/18, its two fails workflow-adversarial-verify #1 and #3 (§A.5).
- **Cost**: v15 strong costs $14.3603 against v14 strong's $20.5024 for the same 120 runs (−30.0 %), $0.1480 per green
  against $0.2470. Per million input tokens opus is $2.1109 (kimi $2.1658), sol $0.9440 (glm $1.0651), luna $0.0522
  (ds-flash $0.1161, glm-flash $0.1393) [A1 tokens table]. Opus's dearest cells are workflow-adversarial-verify
  ($2.6037 over 3 runs), task-fan-five ($1.5600), compose-review-angles ($1.2227) and workflow-judge-panel ($1.1135).
- **Time**: the three new models run 52–58 s a run on average, against 66–179 s for v14's four; the v15 strong pair
  54 s against v14 strong's 133 s.
- **Cache (the direct lanes)**: the bar reads 28 opus, 32 sol and 30 luna records (≥ 2 measured rounds); after-round-1
  medians 0.9624, 0.9754 and 0.9692; under 0.80: opus 0, sol 0, luna 1. Luna's one, compose-three-stage-pairing #1
  (after-r1 0.7744), was served 0.9996 and 0.9998 of each previous prompt, and its ceiling is 0.7746: the bar's own
  arithmetic, the case v14 §7.7 left to the owner, not a short serve [A7]. v14's glm and kimi read 11 and 7 records
  under 0.80 (8 and 5 classed).

## A.3 Every model on both bars [A1 §A.4]

Compose gate tasks (the seven compose picture tasks without T5 rendezvous), 21 runs per model:

| model | tier | official succeeded | usable | picture exact | usable on call 1 / 2 / 3 / none | green |
|---|---|---|---|---|---|---|
| opus | strong | 18 | 21 | **18** | 21 / 0 / 0 / 0 | 18 |
| sol | strong | 15 | 21 | **15** | 20 / 1 / 0 / 0 | 15 |
| glm | strong | 16 | 21 | **16** | 21 / 0 / 0 / 0 | 14 |
| kimi | strong | 15 | 21 | **15** | 20 / 1 / 0 / 0 | 14 |
| luna | floor | 21 | **21** | 12 | 19 / 2 / 0 / 0 | 20 |
| ds-flash | floor | 21 | **21** | 14 | 20 / 1 / 0 / 0 | 18 |
| glm-flash | floor | 20 | **20** | 13 | 17 / 3 / 0 / 1 | 19 |

Pooled: v15 strong picture 33/42, v14 strong 31/42; usable 42/42 on both. Luna usable 21/21 against v14 floor 41/42;
luna picture 12/21 against v14 floor 27/42. Over all eight compose picture tasks (24 runs, rendezvous in): picture opus
18, glm 17, sol 15, kimi 15, glm-flash 15, ds-flash 14, luna 12; usable 24 for all but glm-flash 23. With barrier-free
(27 runs): usable opus 27, glm 27, sol 26, glm-flash 25, kimi 24, luna 24, ds-flash 24.

- **opus/sol against glm/kimi, on the picture**: opus 18/21 leads every model; sol 15 ties kimi and trails glm's 16.
  Opus misses 6 of 24 compose pictures (over_read 5, blind_model 1); sol 9 (over_read 5, blind_model 2, extra_steps 1,
  plus a first-call refusal and a failed stage); glm 7; kimi 9 [A1 bucket list].
- **luna against ds-flash/glm-flash, on usable**: luna 21/21 with 19 on the first call; ds-flash 21 (20 first call),
  glm-flash 20 (17 first call, 1 run with no compose call). On the picture luna is the lowest of the three (12, 14, 13).
- **strong against luna on the same bar**: on usable all four strong models and luna read 21/21, so on the floor's bar
  the strong models are not ahead on these tasks; on the picture opus leads luna by 6 (18 vs 12), sol by 3 (15 vs 12).
  Luna's 12 compose misses: over_read 8, over_sync 3, missing_steps 2, blind_model 1, suite_waited_on 1 (records with
  several buckets count in each), plus 2 first-call refusals.
- Two-source-fan-in, the v14 inversion question, now on seven models: picture opus 0, sol 1, glm 1, kimi 0, luna 0,
  ds-flash 0, glm-flash 2 of 3; usable 3/3 for all seven. The strong newcomers write the same shape the v14 readout
  §8.3 traced to the compose text's example (§A.5).

## A.4 The seven ranked [A1 §A.5]

| rank (official green) | model | tier | official green /60 | strong-bar green /60 | same-bar green /33 | gate picture /21 | gate usable /21 | succeeded | strong-bar succeeded | cost $ | $ / green | mean s |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | opus | strong | 52 | 52 | 31 | 18 | 21 | 52 | 52 | 11.0183 | 0.2119 | 52 |
| 2 | luna | floor | 48 | 37 | 25 | 12 | 21 | 51 | 39 | 0.1911 | 0.0040 | 58 |
| 3 | ds-flash | floor | 46 | 37 | 25 | 14 | 21 | 49 | 39 | 0.7437 | 0.0162 | 66 |
| 4 | sol | strong | 45 | 45 | 27 | 15 | 21 | 45 | 45 | 3.3420 | 0.0743 | 56 |
| 5 | glm-flash | floor | 45 | 37 | 22 | 13 | 20 | 48 | 38 | 1.1056 | 0.0246 | 179 |
| 6 | kimi | strong | 43 | 43 | 26 | 15 | 21 | 48 | 48 | 10.5516 | 0.2454 | 99 |
| 7 | glm | strong | 40 | 40 | 23 | 16 | 21 | 49 | 49 | 9.9508 | 0.2488 | 168 |

Definitions: *official* = each model on its own tier's bar. *Strong-bar green* reads all seven on the picture: a
floor picture record counts only if it is green and its picture is exact (exact for every model, since a floor
record's class follows its success and picture-true implies usable and reached on all 189 picture records of both
versions); strong records as recorded. *Same-bar green* = the 11 tasks whose bar does not depend on the tier (the six
task-family tasks, compose-single-read, workflow's four non-picture tasks), 33 runs. *Strong-bar succeeded* = success
with a floor picture record counting only with its picture exact.

**The ranking, read on one bar (strong-bar green, ties by same-bar green then cost): 1 opus 52, 2 sol 45, 3 kimi 43,
4 glm 40, 5 luna 37, 6 ds-flash 37, 7 glm-flash 37.** Per tier on its own bar: strong opus > sol > kimi > glm; floor
luna 48 > ds-flash 46 > glm-flash 45. The orders that differ, and why:

- by success on the strong bar: opus 52 > glm 49 > kimi 48 > **sol 45** > luna 39 = ds-flash 39 > glm-flash 38. Sol's
  second place on green rests on the cache class (above), not on success.
- by gate picture: opus 18 > glm 16 > sol 15 = kimi 15 > ds-flash 14 > glm-flash 13 > luna 12.
- by cost per green: luna $0.0040 < ds-flash $0.0162 < glm-flash $0.0246 < sol $0.0743 < opus $0.2119 < kimi $0.2454
  < glm $0.2488.

## A.5 Cells where a new model differs from the best v14 model by ≥ 2 of 3 [A1 §A.6, A2, A3, A4, A6]

Best v14 model on a cell = the highest (green, succeeded, reached, passed) of the four, ties listed; compared on
reached, succeeded, task pass and green, v14 §3.1's metrics. On a picture cell a strong newcomer against a floor best
crosses bars (marked *cross*), so the like-for-like picture and usable comparisons follow as (b) and (c), and (d) holds
each newcomer to the best v14 model of its own tier.

### (a) Official: 13 pairs

| task | new | Δr | Δs | Δp | Δg | bars | new | best v14 | best v14 cell | reason (from the records and traces) |
|---|---|---|---|---|---|---|---|---|---|---|
| task-fan-five | sol | −3 | −3 | 0 | −3 | same | r0 s0 [mc3] | kimi | r3 s3 [g3] | "1 task call(s) in the first message, not five" ×3. Sol dispatched one `task` per spine round: #1 at r2, r3, r5, r8, r11; #3 at r2, r4, r7, r9, r11; #2 one, one, then three, all waited. #1 then collected four of them (#3 all five) with a compose of `g.wait` only, and the recorded replies of #1 and #3 name no merged list (`orphans_named` 0, `merge_turn` null); #2 merged all five. kimi sent all five in r2 on every run [A2, A4, A8] |
| task-fan-five | luna | −2 | −2 | 0 | −2 | same | r1 s1 [mc2 g1] | kimi | r3 s3 [g3] | #2, #3: one waited `task` per round (the same reason); both merged all five. #1 sent five waited tasks in r2, green [A2] |
| task-mail | luna | −2 | −2 | 0 | −2 | same | r1 s1 [mc2 g1] | ds-flash | r3 s3 [g3] | #1, #2: "no `task` call: turn 1 called {start_process 1, bash 1}" — `start_process('ruby test/all.rb')` beside `find lib -type f \| wc -l`, the floor's `start_process` habit of v14 §3.3; #3 a detached `task`, green [A2] |
| compose-grep-then-edit | sol | 0 | −2 | 0 | −1 | cross | r3 s1 p3/3 [dis2 g1] | ds-flash, glm-flash | r3 s3 [cuf1 g2] | #1: first compose refused (`g.script: results names an "all" group`, it passed `results: [searches]` for a `g.parallel`), usable on call 2; a refused first call is a strong-bar red. #3: a `g.script` stage of its plan failed (the trace's one failed `script_task` row carries no error detail) and the model then read and edited team.rb itself (spine r3 read, r4 edit). Verification 3/3 ("team.rb renamed; changed elsewhere: []"). Against glm/kimi on the same bar: s 1 vs 2, Δ −1 [A2, A4] |
| compose-three-stage-pairing | sol | 0 | −2 | 0 | −2 | same | r3 s1 [mc2 g1] | glm, kimi | r3 s3 [g3] | #1, #2 `P[T T T Mr1 Mr1 Mr1] Mr3`: fetches and normalisers as peers of one group and the merge after it, so the merge read the three raw fetches as well — `over_read`. #3 `P[(T Mr1) (T Mr1) (T Mr1)] Mr3`, a fetch→normalise sequence per member: exact [A2] |
| compose-two-source-fan-in | opus | 0 | −3 | 0 | −3 | cross | r3 s0 [mc3] | ds-flash, glm-flash | r3 s3 [g3] | All three `P[T T T Mr1 Mr2] Mr2`: the report after the group names `results: [testSummary, qualitySummary]` and reads tests, lint and types too — `over_read`, the peers-group-then-combine shape v14 §8.2–8.3 traced to the compose text's worked example. On the same bar opus 0/3 = kimi 0/3, glm 1/3 [A2] |
| compose-two-source-fan-in | sol | 0 | −2 | 0 | −2 | cross | r3 s1 [mc2 g1] | ds-flash, glm-flash | r3 s3 [g3] | #1, #3 the same shape, `over_read`; #2 put the report inside the group, `P[T T T Mr1 Mr2 Mr2]`: exact. Same bar: sol 1/3 = glm 1/3 [A2] |
| workflow-adversarial-verify | luna | 0 | 0 | −2 | −1 | same | r3 s3 p1/3 [dis2 g1] | glm | r3 s3 p3/3 [cuf1 g2] | Disagreements (succeeded, verification failed): #1 marks C3 FALSE, #3 marks C2 and C3 FALSE, where the oracle reads 1 F, 2 S, 3 S, 4 F, 5 F, 6 S. #1 and #3 dispatched their 12 refuters one detached `task` per round (#1 collected them with a wait-only compose); #2 sent all 12 in one round and marked every claim right [A2, A6, A8] |
| workflow-barrier-free-pipeline | opus | +1 | −2 | 0 | −2 | cross | r3 s0 p3/3 [dis3] | glm-flash | r2 s2 p3/3 [mc1 g2] | Three disagreements on `edit_as_tool`: `P[T S T S T S] S` (#1) and `P[(T S) (T S) (T S)] S` (#2, #3), the merge a script stage that writes merged.txt; verification 3/3. This is O7's pending tool-merge ruling (v14 §3.4, §10): under v14's own candidate picture, re-read in memory, #2 and #3 move to exact and green and #1 to `over_read` (its flat group's merge reads the raw fetches by position). On the same bar glm read 0/3 too [A2, A3] |
| workflow-barrier-free-pipeline | sol | 0 | −2 | 0 | −2 | cross | r2 s0 p3/3 [mc1 dis2] | glm-flash | r2 s2 p3/3 [mc1 g2] | #1, #3 `P[(T T) (T T) (T T)] T`, a bash merge: `edit_as_tool`; both move to exact and green under the O7 candidate. #2 made no compose call: three fetch→normalise `bash` calls in one round, then a `cat` merge — no door. Verification 3/3 [A2, A3] |
| workflow-barrier-free-pipeline | luna | −2 | −2 | 0 | −2 | same | r0 s0 p3/3 [mc3] | glm-flash | r2 s2 p3/3 [mc1 g2] | "no compose call and no round fanned two task calls" ×3: each ran the pipeline in one `bash` call (subshells or a pipe per source); verification 3/3. v14's ds-flash and kimi did the same 3/3 [A2] |
| workflow-judge-panel | sol | −1 | −3 | 0 | −3 | same | r2 s0 p3/3 [mc1 dis2] | kimi, glm-flash | r3 s3 p3/3 [g3] | One judge `task` per spine round (r2, r4, r6). #1, #2 detached them, then composed only `g.wait` over the three and handed the tally to a chair `task`: "r8t0 composed 3 tasks and no step reads two model members". #3 waited each judge and the chair, one per round: no door. Every verdict right (winner: b) [A2, A4] |
| workflow-judge-panel | luna | −2 | −2 | 0 | −2 | same | r1 s1 p3/3 [mc2 g1] | kimi, glm-flash | r3 s3 p3/3 [g3] | #1 three `spawn` judges (no door, v14 §7.5's returning shape); #3 four waited tasks one per round (no door); #2 fanned judges 2 and 3 in one round: task_fan, green [A2] |

### (b) The picture bar, like for like: 11 pairs

| task | new | picture | best v14 picture (who) | Δ | reason |
|---|---|---|---|---|---|
| compose-background-suite | opus | 3/3 | 1/3 (all four) | **+2** | `P[T (T Mr1)]` ×3: the suite a bare leaf, rubocop → fixer in its own sequence, no closing step, no `start_process`. v14's strong misses were a closing report naming the `start_process` receipt (`extra_steps`/`over_read` under O4's ruling, v14 §8.2) [A2] |
| compose-background-suite | sol | 3/3 | 1/3 (all four) | **+2** | `P[T T Mr1]` ×3, exact [A2] |
| compose-grep-then-edit | sol | 1/3 | 3/3 (ds-flash) | −2 | (a) above |
| compose-grep-then-edit | luna | 1/3 | 3/3 (ds-flash) | −2 | #1 `P[T T T] S`, `missing_steps` on the first call (it composed a second time); #3 first call refused `script_syntax_error`; #2 exact. Usable 3/3, green 3/3 on its bar [A2] |
| compose-rendezvous (T5) | opus | 0/3 | 2/3 (glm-flash) | −2 | #1, #3 `P[T T T Mr2 Mr2] Mr2`, the merge after the group: `over_read`; #2 a script-stage merge: `blind_model`. Recorded-only, green 3/3 [A2] |
| compose-rendezvous (T5) | sol | 0/3 | 2/3 (glm-flash) | −2 | #1 `over_read` (same shape); #2 `blind_model`, #3 `extra_steps, blind_model` (script stages) [A2] |
| compose-rendezvous (T5) | luna | 0/3 | 2/3 (glm-flash) | −2 | three `over_read`, merge after the group [A2] |
| compose-three-stage-pairing | sol | 1/3 | 3/3 (glm, kimi) | −2 | (a) above |
| compose-three-stage-pairing | luna | 1/3 | 3/3 (glm, kimi) | −2 | #1 `T T T S S S S`, written in order with no group: `missing_steps, over_sync` (and cache under floor, §A.2); #3 the flat group, `over_read`; #2 exact [A2] |
| compose-two-source-fan-in | opus | 0/3 | 2/3 (glm-flash) | −2 | (a) above |
| compose-two-source-fan-in | luna | 0/3 | 2/3 (glm-flash) | −2 | #1 `T T T P[Mr1 Mr2] Mr2` (`over_sync, over_read`); #2, #3 the flat group then the report (`over_read`) [A2] |

### (c) The usable bar: 1 pair

workflow-barrier-free-pipeline luna 0/3 against glm's 3/3 (Δ −3): no compose call on any run, (a) above.

### (d) Against the best v14 model of the same tier (one bar throughout): 12 pairs

| task | new | Δr | Δs | Δp | Δg | best same-tier v14 | reason |
|---|---|---|---|---|---|---|---|
| task-background-suite | luna | +3 | +3 | 0 | +3 | ds-flash, glm-flash r0 s0 [mc3] | luna handed the suite to a `task` 3/3 where both v14 floors launched it with `start_process` 3/3 (v14 §3.3) |
| task-fan-five | sol | −3 | −3 | 0 | −3 | kimi | (a) |
| task-mail | sol | +2 | +2 | 0 | +2 | glm, kimi r1 s1 [mc2 g1] | sol 3/3 detached `task` |
| task-mail | luna | −2 | −2 | 0 | −2 | ds-flash | (a) |
| compose-background-suite | opus | 0 | +2 | 0 | +2 | glm, kimi r3 s1 [mc2 g1] | (b) |
| compose-background-suite | sol | 0 | +2 | 0 | +2 | glm, kimi | (b) |
| compose-grep-then-edit | opus | 0 | +1 | 0 | +2 | glm, kimi r3 s2 [dis1 cuf1 g1] | opus 3/3 exact, no cache red |
| compose-three-stage-pairing | sol | 0 | −2 | 0 | −2 | glm, kimi | (a) |
| workflow-adversarial-verify | luna | 0 | +2 | −2 | 0 | glm-flash r3 s1 p3/3 [dis2 g1] | luna detached its refuters (glm-flash waited twice, v14 §7.1) but marked 2 of 3 runs wrong (a) |
| workflow-barrier-free-pipeline | luna | −2 | −2 | 0 | −2 | glm-flash | (a) |
| workflow-judge-panel | sol | −1 | −3 | 0 | −3 | kimi | (a) |
| workflow-judge-panel | luna | −2 | −2 | 0 | −2 | glm-flash | (a) |

No cell has a new model ≥ 2 above the best v14 model of all four on the official metrics: opus ties or leads by one
where it is best (fan-five 3 = kimi 3, adversarial-verify 3 vs glm 2, judge-panel 3 = kimi and glm-flash 3); its only
≥ 2 leads are on the picture (background-suite) and against its own tier (background-suite, grep-then-edit).

## A.6 What the records say across cells

1. **One delegation per message (sol nearly always, luna on 5 of 11)** [A2 fan table, spine rounds]. The spine followed
   from r1 (round keys are loop-global, so a child's or a composed step's rounds take the next rN too): the first spine
   tool round carries one call on 53/60 sol records, 49/60 luna, 45/60 opus, against 28–37/60 for v14's four. Among
   records whose spine made ≥ 2 `task` calls (task and workflow families), a round carried ≥ 2 of them on sol 1/12,
   luna 6/11, opus 3/3, glm 11/12, kimi 11/11, ds-flash 7/7, glm-flash 12/12. No Nexus caller sets
   `parallel_tool_calls` (a grep over `nexus/app`, `nexus/lib`, `nexus/config` finds it only in the vendored gem's
   protocol files and tests), and sol did emit 17 multi-call spine rounds, so the lane allows parallel calls; the serial
   dispatch is the model's. It decides sol's fan-five 0/3 and judge-panel 0/3 and luna's fan-five #2, #3 and
   judge-panel #3.
2. **Opus composes where the others delegate** [A5, A6]. On the four door workflow tasks (all but loop-until-dry)
   opus took `compose` 12/12 (task_fan 0); sol compose 10, no door 2; kimi task_fan 8, compose 1, no door 3. On the task family opus twice launched the
   background job as a one-step compose instead of a `task` (task-mail #1: a `g.tool` bash `ruby test/all.rb 2>&1 |
   tail -n 40`; task-background-suite #3: a `g.tool` bash `bin/rails test 2>&1 | tail -n 200`, later a `g.wait` on it)
   [A4], red by the
   family's `task`-only reach — v14 §10's pending leniency question on that reach, now with a compose door beside
   `start_process`.
3. **A compose that builds nothing passes the workflow door** [A6]. `Predicates.door` (`e2e/support/evals/
   predicates.rb:271-276`) returns "compose" for any compose row. 8 sol records (every one over tasks dispatched one per
   message) and 2 luna records (#1 one per message, #2 all 12 in one round) composed only `g.wait`; 4 sol greens reach their door through that alone
   (workflow-fan-out-finders #1–#3, adversarial-verify #2), each with 8 or 12 single detached-`task` rounds [A8]. Right by the rule as
   written; whether a wait-only compose is the compose door is a reader question for the owner. Nothing re-scored.
4. **O7's candidate on v15** [A3]. v14's `c1_o7_merge.rb`, run unchanged on the v15 labels: the shipped re-read
   reproduces all 14 composed barrier-free and three-stage-pairing records; the candidate moves 5, all barrier-free
   (opus #2, #3 and sol #1, #3 disagreement → green exact; opus #1 → `over_read`), and 0 of the 9 three-stage-pairing
   records. With it barrier-free reads opus 2/3, sol 2/3 green.
5. **The cache bar on direct lanes** (§A.2): no opus or sol record is under the bar; luna's one red is the bar's
   arithmetic.

## A.7 Reds by reason [A1 §A.7]

| family | reds opus / sol / glm / kimi / luna / ds-flash / glm-flash | new models' reasons |
|---|---|---|
| task | 2 / 3 / 5 / 4 / 4 / 4 / 8 | opus 2 no `task` call (compose instead); sol 3 fewer than five `task` calls in the first message; luna 2 of those and 2 `start_process` |
| compose | 3 / 6 / 8 / 7 / 1 / 3 / 3 | opus 3 `over_read` (two-source); sol 4 `over_read` (three-stage 2, two-source 2), 1 refusal (`script_error`), 1 failed stage; luna 1 cache under floor |
| workflow | 3 / 6 / 7 / 6 / 7 / 7 / 4 | opus 3 `edit_as_tool`; sol 2 `edit_as_tool`, 2 no door, 2 "composed, but no step reads two model members"; luna 5 no door, 2 verification disagreements |

No v15 record failed a conduct check; no v15 record carries a deadline stop.

## Scripts and outputs (this directory)

| file | prints |
|---|---|
| `A1_cells.py` → `A1_cells.out` | inputs and the LEDGER cross-check (A.0), every cell (A.1), the green matrix (A.2), family × model, tier, tokens and the cache bar (A.3), both bars (A.4), the ranking (A.5), the ≥ 2 comparisons (A.6 a–d), reds by reason and every v15 red (A.7) |
| `A2_evidence.py` → `A2_evidence.out` | per record of every flagged cell: verdict, family facts, verification, the first compose plan's shape and reads, the spine's tool rounds followed from r1, the reply; the spine-round and delegation-fan tables per model |
| `A3_o7_merge.rb` → `A3_o7_merge.out` | v14's `C-scripts/c1_o7_merge.rb` unchanged, run from `e2e/` with `O7_LABELS="2026-09-26-v15-workflow 2026-09-26-v15-compose"` under `bundle exec ruby -E UTF-8:UTF-8`, in memory |
| `A4_scripts.py` → `A4_scripts.out` | the compose scripts and failed rows behind six flagged records |
| `A5_doors.py` → `A5_doors.out` | `facts.door` per workflow task and model |
| `A6_wait_compose.py` → `A6_wait_compose.out` | wait-only versus step-building composes per model, and the records |
| `A7_cache_ceiling.py` → `A7_cache_ceiling.out` | every v15 record under the cache bar with its series and ceiling |
| `A8_checks.py` → `A8_checks.out` | per-run `task` dispatch (per round, `wait`, `g.wait` per compose) on three quoted cells |

The outputs follow whole, then the scripts.

---

## Appendix 1 — outputs, whole

### `A1_cells.out`

### [A1] A.0 Inputs

- 2026-09-26-v15-task: 54 lines -> 54 records (last line per key); digest ['772186a893d5']; models {'opus-5.5/strong': 18, 'gpt-6-sol/strong': 18, 'gpt-6-luna/floor': 18}; error rows 0; stopped {}; cost units {'USD': 54}; started 2026-09-26T04:23:59Z .. 2026-09-26T05:11:36Z
- 2026-09-26-v15-compose: 81 lines -> 81 records (last line per key); digest ['772186a893d5']; models {'opus-5.5/strong': 27, 'gpt-6-sol/strong': 27, 'gpt-6-luna/floor': 27}; error rows 0; stopped {}; cost units {'USD': 81}; started 2026-09-26T05:13:20Z .. 2026-09-26T06:09:23Z
- 2026-09-26-v15-workflow: 45 lines -> 45 records (last line per key); digest ['772186a893d5']; models {'opus-5.5/strong': 15, 'gpt-6-sol/strong': 15, 'gpt-6-luna/floor': 15}; error rows 0; stopped {}; cost units {'USD': 45}; started 2026-09-26T06:10:40Z .. 2026-09-26T07:10:33Z
- 2026-09-26-v14-task: 72 lines -> 72 records (last line per key); digest ['f69dc4cc6ab4']; models {'glm-5.3/strong': 18, 'kimi-k3/strong': 18, 'ds-flash/floor': 18, 'glm-5.3-flash/floor': 18}; error rows 0; stopped {}; cost units {'USD': 72}; started 2026-09-25T16:02:32Z .. 2026-09-25T17:32:02Z
- 2026-09-26-v14-compose: 108 lines -> 108 records (last line per key); digest ['f69dc4cc6ab4']; models {'glm-5.3/strong': 27, 'kimi-k3/strong': 27, 'ds-flash/floor': 27, 'glm-5.3-flash/floor': 27}; error rows 0; stopped {'deadline': 3}; cost units {'USD': 108}; started 2026-09-25T17:34:54Z .. 2026-09-25T22:09:30Z
- 2026-09-26-v14-workflow: 60 lines -> 60 records (last line per key); digest ['f69dc4cc6ab4']; models {'glm-5.3/strong': 15, 'kimi-k3/strong': 15, 'ds-flash/floor': 15, 'glm-5.3-flash/floor': 15}; error rows 0; stopped {}; cost units {'USD': 60}; started 2026-09-25T22:23:50Z .. 2026-09-26T00:51:17Z
- cells: 140 (v15 60, v14 80); same (family, task) set on both versions: True (20 tasks); runs per cell [3]
- LEDGER.md cross-check (v15 section, r / s-or-u·x / p / d): 60 cells, 0 mismatches

### [A1] A.1 Every (task x model) cell, seven models

Columns: r reached, s succeeded, p task pass (passed/verified), classes (mc model conduct, dis disagreement, cuf cache under floor; g green), bar (strong: x picture exact (u usable); floor: u usable (x picture exact)), mean seconds, cost USD over the 3 runs. v15 models: opus-5.5, gpt-6-sol (strong), gpt-6-luna (floor).

#### task

| task | model | ver | tier | r | s | p | classes | bar | mean s | cost $ |
|---|---|---|---|---|---|---|---|---|---|---|
| task-background-suite | opus-5.5 | v15 | strong | 2/3 | 2/3 | - | mc1 g2 | = s | 74 | 0.3763 |
| task-background-suite | gpt-6-sol | v15 | strong | 3/3 | 3/3 | - | g3 | = s | 80 | 0.1659 |
| task-background-suite | glm-5.3 | v14 | strong | 3/3 | 2/3 | - | mc1 g2 | = s | 220 | 0.6201 |
| task-background-suite | kimi-k3 | v14 | strong | 3/3 | 3/3 | - | cuf2 g1 | = s | 96 | 0.6361 |
| task-background-suite | gpt-6-luna | v15 | floor | 3/3 | 3/3 | - | g3 | = s | 76 | 0.0137 |
| task-background-suite | ds-flash | v14 | floor | 0/3 | 0/3 | - | mc3 g0 | = s | 73 | 0.0330 |
| task-background-suite | glm-5.3-flash | v14 | floor | 0/3 | 0/3 | - | mc3 g0 | = s | 314 | 0.0814 |
| task-detached-receipt | opus-5.5 | v15 | strong | 3/3 | 3/3 | - | g3 | = s | 69 | 0.3476 |
| task-detached-receipt | gpt-6-sol | v15 | strong | 3/3 | 3/3 | - | g3 | = s | 68 | 0.1489 |
| task-detached-receipt | glm-5.3 | v14 | strong | 3/3 | 3/3 | - | g3 | = s | 82 | 0.0993 |
| task-detached-receipt | kimi-k3 | v14 | strong | 3/3 | 3/3 | - | g3 | = s | 75 | 0.0713 |
| task-detached-receipt | gpt-6-luna | v15 | floor | 3/3 | 3/3 | - | g3 | = s | 121 | 0.0131 |
| task-detached-receipt | ds-flash | v14 | floor | 3/3 | 3/3 | - | g3 | = s | 68 | 0.0098 |
| task-detached-receipt | glm-5.3-flash | v14 | floor | 3/3 | 3/3 | - | g3 | = s | 77 | 0.0161 |
| task-fan-five | opus-5.5 | v15 | strong | 3/3 | 3/3 | - | g3 | = s | 66 | 1.5600 |
| task-fan-five | gpt-6-sol | v15 | strong | 0/3 | 0/3 | - | mc3 g0 | = s | 68 | 0.2251 |
| task-fan-five | glm-5.3 | v14 | strong | 3/3 | 3/3 | - | cuf2 g1 | = s | 109 | 0.3597 |
| task-fan-five | kimi-k3 | v14 | strong | 3/3 | 3/3 | - | g3 | = s | 99 | 0.5116 |
| task-fan-five | gpt-6-luna | v15 | floor | 1/3 | 1/3 | - | mc2 g1 | = s | 69 | 0.0090 |
| task-fan-five | ds-flash | v14 | floor | 2/3 | 2/3 | - | mc1 g2 | = s | 73 | 0.0397 |
| task-fan-five | glm-5.3-flash | v14 | floor | 3/3 | 1/3 | - | mc2 g1 | = s | 107 | 0.0456 |
| task-grep-three-control | opus-5.5 | v15 | strong | 3/3 | 3/3 | - | g3 | = s | 17 | 0.0525 |
| task-grep-three-control | gpt-6-sol | v15 | strong | 3/3 | 3/3 | - | g3 | = s | 13 | 0.0697 |
| task-grep-three-control | glm-5.3 | v14 | strong | 3/3 | 3/3 | - | g3 | = s | 19 | 0.0408 |
| task-grep-three-control | kimi-k3 | v14 | strong | 3/3 | 3/3 | - | g3 | = s | 66 | 0.0620 |
| task-grep-three-control | gpt-6-luna | v15 | floor | 3/3 | 3/3 | - | g3 | = s | 14 | 0.0036 |
| task-grep-three-control | ds-flash | v14 | floor | 3/3 | 3/3 | - | g3 | = s | 14 | 0.0023 |
| task-grep-three-control | glm-5.3-flash | v14 | floor | 3/3 | 3/3 | - | g3 | = s | 18 | 0.0040 |
| task-mail | opus-5.5 | v15 | strong | 2/3 | 2/3 | - | mc1 g2 | = s | 73 | 0.2977 |
| task-mail | gpt-6-sol | v15 | strong | 3/3 | 3/3 | - | g3 | = s | 70 | 0.0933 |
| task-mail | glm-5.3 | v14 | strong | 1/3 | 1/3 | - | mc2 g1 | = s | 56 | 0.0776 |
| task-mail | kimi-k3 | v14 | strong | 1/3 | 1/3 | - | mc2 g1 | = s | 46 | 0.1712 |
| task-mail | gpt-6-luna | v15 | floor | 1/3 | 1/3 | - | mc2 g1 | = s | 34 | 0.0045 |
| task-mail | ds-flash | v14 | floor | 3/3 | 3/3 | - | g3 | = s | 79 | 0.0107 |
| task-mail | glm-5.3-flash | v14 | floor | 0/3 | 0/3 | - | mc3 g0 | = s | 29 | 0.0075 |
| task-two-calls | opus-5.5 | v15 | strong | 3/3 | 3/3 | - | g3 | = s | 16 | 0.0554 |
| task-two-calls | gpt-6-sol | v15 | strong | 3/3 | 3/3 | - | g3 | = s | 14 | 0.0702 |
| task-two-calls | glm-5.3 | v14 | strong | 3/3 | 3/3 | - | g3 | = s | 19 | 0.0307 |
| task-two-calls | kimi-k3 | v14 | strong | 3/3 | 3/3 | - | g3 | = s | 16 | 0.1526 |
| task-two-calls | gpt-6-luna | v15 | floor | 3/3 | 3/3 | - | g3 | = s | 12 | 0.0035 |
| task-two-calls | ds-flash | v14 | floor | 3/3 | 3/3 | - | g3 | = s | 11 | 0.0018 |
| task-two-calls | glm-5.3-flash | v14 | floor | 3/3 | 3/3 | - | g3 | = s | 16 | 0.0040 |

#### compose

| task | model | ver | tier | r | s | p | classes | bar | mean s | cost $ |
|---|---|---|---|---|---|---|---|---|---|---|
| compose-background-suite | opus-5.5 | v15 | strong | 3/3 | 3/3 | - | g3 | x 3/3 (u 3) | 63 | 0.5607 |
| compose-background-suite | gpt-6-sol | v15 | strong | 3/3 | 3/3 | - | g3 | x 3/3 (u 3) | 71 | 0.2383 |
| compose-background-suite | glm-5.3 | v14 | strong | 3/3 | 1/3 | - | mc2 g1 | x 1/3 (u 3) | 368 | 0.6159 |
| compose-background-suite | kimi-k3 | v14 | strong | 3/3 | 1/3 | - | mc2 g1 | x 1/3 (u 3) | 119 | 0.7700 |
| compose-background-suite | gpt-6-luna | v15 | floor | 3/3 | 3/3 | - | g3 | u 3/3 (x 1) | 78 | 0.0130 |
| compose-background-suite | ds-flash | v14 | floor | 3/3 | 3/3 | - | g3 | u 3/3 (x 1) | 84 | 0.0529 |
| compose-background-suite | glm-5.3-flash | v14 | floor | 3/3 | 3/3 | - | g3 | u 3/3 (x 1) | 241 | 0.0517 |
| compose-grep-then-edit | opus-5.5 | v15 | strong | 3/3 | 3/3 | 3/3 | g3 | x 3/3 (u 3) | 35 | 0.2435 |
| compose-grep-then-edit | gpt-6-sol | v15 | strong | 3/3 | 1/3 | 3/3 | dis2 g1 | x 1/3 (u 3) | 36 | 0.1276 |
| compose-grep-then-edit | glm-5.3 | v14 | strong | 3/3 | 2/3 | 3/3 | dis1 cuf1 g1 | x 2/3 (u 3) | 423 | 1.0991 |
| compose-grep-then-edit | kimi-k3 | v14 | strong | 3/3 | 2/3 | 3/3 | dis1 cuf1 g1 | x 2/3 (u 3) | 73 | 0.4602 |
| compose-grep-then-edit | gpt-6-luna | v15 | floor | 3/3 | 3/3 | 3/3 | g3 | u 3/3 (x 1) | 37 | 0.0080 |
| compose-grep-then-edit | ds-flash | v14 | floor | 3/3 | 3/3 | 3/3 | cuf1 g2 | u 3/3 (x 3) | 100 | 0.0828 |
| compose-grep-then-edit | glm-5.3-flash | v14 | floor | 3/3 | 3/3 | 3/3 | mc1 g2 | u 3/3 (x 1) | 572 | 0.0765 |
| compose-race | opus-5.5 | v15 | strong | 3/3 | 3/3 | - | g3 | x 3/3 (u 3) | 21 | 0.0702 |
| compose-race | gpt-6-sol | v15 | strong | 3/3 | 3/3 | - | g3 | x 3/3 (u 3) | 28 | 0.1251 |
| compose-race | glm-5.3 | v14 | strong | 3/3 | 3/3 | - | g3 | x 3/3 (u 3) | 91 | 0.2132 |
| compose-race | kimi-k3 | v14 | strong | 3/3 | 3/3 | - | g3 | x 3/3 (u 3) | 53 | 0.2743 |
| compose-race | gpt-6-luna | v15 | floor | 3/3 | 3/3 | - | g3 | u 3/3 (x 3) | 21 | 0.0055 |
| compose-race | ds-flash | v14 | floor | 3/3 | 3/3 | - | g3 | u 3/3 (x 3) | 30 | 0.0121 |
| compose-race | glm-5.3-flash | v14 | floor | 3/3 | 3/3 | - | g3 | u 3/3 (x 2) | 152 | 0.0368 |
| compose-race-anon | opus-5.5 | v15 | strong | 3/3 | 3/3 | - | g3 | x 3/3 (u 3) | 21 | 0.0697 |
| compose-race-anon | gpt-6-sol | v15 | strong | 3/3 | 3/3 | - | g3 | x 3/3 (u 3) | 26 | 0.1107 |
| compose-race-anon | glm-5.3 | v14 | strong | 3/3 | 3/3 | - | mc1 g2 | x 3/3 (u 3) | 61 | 0.2191 |
| compose-race-anon | kimi-k3 | v14 | strong | 3/3 | 3/3 | - | g3 | x 3/3 (u 3) | 50 | 0.2616 |
| compose-race-anon | gpt-6-luna | v15 | floor | 3/3 | 3/3 | - | g3 | u 3/3 (x 3) | 23 | 0.0061 |
| compose-race-anon | ds-flash | v14 | floor | 3/3 | 3/3 | - | g3 | u 3/3 (x 3) | 30 | 0.0145 |
| compose-race-anon | glm-5.3-flash | v14 | floor | 3/3 | 3/3 | - | g3 | u 3/3 (x 3) | 118 | 0.0244 |
| compose-rendezvous | opus-5.5 | v15 | strong | 3/3 | 3/3 | - | g3 | x 0/3 (u 3) | 65 | 0.6633 |
| compose-rendezvous | gpt-6-sol | v15 | strong | 3/3 | 3/3 | - | g3 | x 0/3 (u 3) | 44 | 0.1811 |
| compose-rendezvous | glm-5.3 | v14 | strong | 3/3 | 3/3 | - | g3 | x 1/3 (u 3) | 305 | 1.0618 |
| compose-rendezvous | kimi-k3 | v14 | strong | 3/3 | 3/3 | - | g3 | x 0/3 (u 3) | 249 | 0.9095 |
| compose-rendezvous | gpt-6-luna | v15 | floor | 3/3 | 3/3 | - | g3 | u 3/3 (x 0) | 40 | 0.0093 |
| compose-rendezvous | ds-flash | v14 | floor | 3/3 | 3/3 | - | g3 | u 3/3 (x 0) | 87 | 0.0679 |
| compose-rendezvous | glm-5.3-flash | v14 | floor | 3/3 | 3/3 | - | mc1 g2 | u 3/3 (x 2) | 486 | 0.0898 |
| compose-review-angles | opus-5.5 | v15 | strong | 3/3 | 3/3 | - | g3 | x 3/3 (u 3) | 60 | 1.2227 |
| compose-review-angles | gpt-6-sol | v15 | strong | 3/3 | 3/3 | - | g3 | x 3/3 (u 3) | 37 | 0.1556 |
| compose-review-angles | glm-5.3 | v14 | strong | 3/3 | 3/3 | - | g3 | x 3/3 (u 3) | 154 | 0.4667 |
| compose-review-angles | kimi-k3 | v14 | strong | 3/3 | 3/3 | - | g3 | x 3/3 (u 3) | 119 | 0.8657 |
| compose-review-angles | gpt-6-luna | v15 | floor | 3/3 | 3/3 | - | g3 | u 3/3 (x 3) | 53 | 0.0134 |
| compose-review-angles | ds-flash | v14 | floor | 3/3 | 3/3 | - | g3 | u 3/3 (x 3) | 136 | 0.0871 |
| compose-review-angles | glm-5.3-flash | v14 | floor | 3/3 | 3/3 | - | g3 | u 3/3 (x 3) | 197 | 0.0578 |
| compose-single-read | opus-5.5 | v15 | strong | 3/3 | 3/3 | - | g3 | = s | 13 | 0.0501 |
| compose-single-read | gpt-6-sol | v15 | strong | 3/3 | 3/3 | - | g3 | = s | 14 | 0.0729 |
| compose-single-read | glm-5.3 | v14 | strong | 3/3 | 3/3 | - | cuf1 g2 | = s | 14 | 0.1071 |
| compose-single-read | kimi-k3 | v14 | strong | 3/3 | 3/3 | - | g3 | = s | 17 | 0.0957 |
| compose-single-read | gpt-6-luna | v15 | floor | 3/3 | 3/3 | - | g3 | = s | 15 | 0.0036 |
| compose-single-read | ds-flash | v14 | floor | 3/3 | 3/3 | - | g3 | = s | 15 | 0.0025 |
| compose-single-read | glm-5.3-flash | v14 | floor | 3/3 | 3/3 | - | g3 | = s | 15 | 0.0062 |
| compose-three-stage-pairing | opus-5.5 | v15 | strong | 3/3 | 3/3 | - | g3 | x 3/3 (u 3) | 55 | 0.1533 |
| compose-three-stage-pairing | gpt-6-sol | v15 | strong | 3/3 | 1/3 | - | mc2 g1 | x 1/3 (u 3) | 37 | 0.1534 |
| compose-three-stage-pairing | glm-5.3 | v14 | strong | 3/3 | 3/3 | - | g3 | x 3/3 (u 3) | 225 | 0.3677 |
| compose-three-stage-pairing | kimi-k3 | v14 | strong | 3/3 | 3/3 | - | g3 | x 3/3 (u 3) | 70 | 0.4815 |
| compose-three-stage-pairing | gpt-6-luna | v15 | floor | 3/3 | 3/3 | - | cuf1 g2 | u 3/3 (x 1) | 55 | 0.0103 |
| compose-three-stage-pairing | ds-flash | v14 | floor | 3/3 | 3/3 | - | cuf2 g1 | u 3/3 (x 1) | 54 | 0.0339 |
| compose-three-stage-pairing | glm-5.3-flash | v14 | floor | 2/3 | 2/3 | - | mc1 g2 | u 2/3 (x 1) | 262 | 0.0578 |
| compose-two-source-fan-in | opus-5.5 | v15 | strong | 3/3 | 0/3 | - | mc3 g0 | x 0/3 (u 3) | 69 | 0.7239 |
| compose-two-source-fan-in | gpt-6-sol | v15 | strong | 3/3 | 1/3 | - | mc2 g1 | x 1/3 (u 3) | 58 | 0.1286 |
| compose-two-source-fan-in | glm-5.3 | v14 | strong | 3/3 | 1/3 | - | mc2 g1 | x 1/3 (u 3) | 186 | 0.4465 |
| compose-two-source-fan-in | kimi-k3 | v14 | strong | 3/3 | 0/3 | - | mc3 g0 | x 0/3 (u 3) | 112 | 0.4626 |
| compose-two-source-fan-in | gpt-6-luna | v15 | floor | 3/3 | 3/3 | - | g3 | u 3/3 (x 0) | 60 | 0.0076 |
| compose-two-source-fan-in | ds-flash | v14 | floor | 3/3 | 3/3 | - | g3 | u 3/3 (x 0) | 69 | 0.0264 |
| compose-two-source-fan-in | glm-5.3-flash | v14 | floor | 3/3 | 3/3 | - | g3 | u 3/3 (x 2) | 169 | 0.0349 |

#### workflow

| task | model | ver | tier | r | s | p | classes | bar | mean s | cost $ |
|---|---|---|---|---|---|---|---|---|---|---|
| workflow-adversarial-verify | opus-5.5 | v15 | strong | 3/3 | 3/3 | 3/3 | g3 | = s | 113 | 2.6037 |
| workflow-adversarial-verify | gpt-6-sol | v15 | strong | 3/3 | 3/3 | 3/3 | g3 | = s | 149 | 0.5246 |
| workflow-adversarial-verify | glm-5.3 | v14 | strong | 3/3 | 3/3 | 3/3 | cuf1 g2 | = s | 296 | 1.6683 |
| workflow-adversarial-verify | kimi-k3 | v14 | strong | 3/3 | 2/3 | 3/3 | dis1 cuf2 g0 | = s | 224 | 2.0306 |
| workflow-adversarial-verify | gpt-6-luna | v15 | floor | 3/3 | 3/3 | 1/3 | dis2 g1 | = s | 147 | 0.0290 |
| workflow-adversarial-verify | ds-flash | v14 | floor | 1/3 | 0/3 | 2/3 | mc2 dis1 g0 | = s | 182 | 0.1813 |
| workflow-adversarial-verify | glm-5.3-flash | v14 | floor | 3/3 | 1/3 | 3/3 | dis2 g1 | = s | 330 | 0.2902 |
| workflow-barrier-free-pipeline | opus-5.5 | v15 | strong | 3/3 | 0/3 | 3/3 | dis3 g0 | x 0/3 (u 3) | 42 | 0.1522 |
| workflow-barrier-free-pipeline | gpt-6-sol | v15 | strong | 2/3 | 0/3 | 3/3 | mc1 dis2 g0 | x 0/3 (u 2) | 46 | 0.1114 |
| workflow-barrier-free-pipeline | glm-5.3 | v14 | strong | 3/3 | 0/3 | 3/3 | dis3 g0 | x 0/3 (u 3) | 166 | 0.4837 |
| workflow-barrier-free-pipeline | kimi-k3 | v14 | strong | 0/3 | 0/3 | 3/3 | mc3 g0 | x 0/3 (u 0) | 45 | 0.1651 |
| workflow-barrier-free-pipeline | gpt-6-luna | v15 | floor | 0/3 | 0/3 | 3/3 | mc3 g0 | u 0/3 (x 0) | 43 | 0.0059 |
| workflow-barrier-free-pipeline | ds-flash | v14 | floor | 0/3 | 0/3 | 3/3 | mc3 g0 | u 0/3 (x 0) | 34 | 0.0074 |
| workflow-barrier-free-pipeline | glm-5.3-flash | v14 | floor | 2/3 | 2/3 | 3/3 | mc1 g2 | u 2/3 (x 0) | 118 | 0.0247 |
| workflow-fan-out-finders | opus-5.5 | v15 | strong | 3/3 | 3/3 | 3/3 | g3 | = s | 60 | 0.5020 |
| workflow-fan-out-finders | gpt-6-sol | v15 | strong | 3/3 | 3/3 | 3/3 | g3 | = s | 85 | 0.2340 |
| workflow-fan-out-finders | glm-5.3 | v14 | strong | 3/3 | 3/3 | 3/3 | g3 | = s | 67 | 0.1305 |
| workflow-fan-out-finders | kimi-k3 | v14 | strong | 3/3 | 3/3 | 3/3 | g3 | = s | 99 | 0.7978 |
| workflow-fan-out-finders | gpt-6-luna | v15 | floor | 3/3 | 3/3 | 3/3 | g3 | = s | 77 | 0.0105 |
| workflow-fan-out-finders | ds-flash | v14 | floor | 3/3 | 3/3 | 3/3 | g3 | = s | 56 | 0.0196 |
| workflow-fan-out-finders | glm-5.3-flash | v14 | floor | 3/3 | 3/3 | 3/3 | g3 | = s | 83 | 0.0591 |
| workflow-judge-panel | opus-5.5 | v15 | strong | 3/3 | 3/3 | 3/3 | g3 | = s | 58 | 1.1135 |
| workflow-judge-panel | gpt-6-sol | v15 | strong | 2/3 | 0/3 | 3/3 | mc1 dis2 g0 | = s | 62 | 0.1690 |
| workflow-judge-panel | glm-5.3 | v14 | strong | 3/3 | 3/3 | 3/3 | cuf3 g0 | = s | 369 | 1.6750 |
| workflow-judge-panel | kimi-k3 | v14 | strong | 3/3 | 3/3 | 3/3 | g3 | = s | 106 | 0.7648 |
| workflow-judge-panel | gpt-6-luna | v15 | floor | 1/3 | 1/3 | 3/3 | mc2 g1 | = s | 66 | 0.0080 |
| workflow-judge-panel | ds-flash | v14 | floor | 2/3 | 2/3 | 3/3 | mc1 g2 | = s | 80 | 0.0441 |
| workflow-judge-panel | glm-5.3-flash | v14 | floor | 3/3 | 3/3 | 3/3 | g3 | = s | 165 | 0.0809 |
| workflow-loop-until-dry | opus-5.5 | v15 | strong | 3/3 | 3/3 | 3/3 | g3 | = s | 56 | 0.2001 |
| workflow-loop-until-dry | gpt-6-sol | v15 | strong | 3/3 | 3/3 | 3/3 | g3 | = s | 105 | 0.2366 |
| workflow-loop-until-dry | glm-5.3 | v14 | strong | 3/3 | 3/3 | 3/3 | g3 | = s | 123 | 0.1681 |
| workflow-loop-until-dry | kimi-k3 | v14 | strong | 3/3 | 3/3 | 3/3 | g3 | = s | 236 | 0.6073 |
| workflow-loop-until-dry | gpt-6-luna | v15 | floor | 3/3 | 3/3 | 3/3 | g3 | = s | 126 | 0.0134 |
| workflow-loop-until-dry | ds-flash | v14 | floor | 3/3 | 3/3 | 3/3 | g3 | = s | 51 | 0.0140 |
| workflow-loop-until-dry | glm-5.3-flash | v14 | floor | 3/3 | 3/3 | 3/3 | mc1 g2 | = s | 114 | 0.0565 |

### [A1] A.2 Green matrix (green of 3; picture cells also print x = picture exact, u = usable)

| family | task | opus-5.5 | gpt-6-sol | glm-5.3 | kimi-k3 | gpt-6-luna | ds-flash | glm-5.3-flash |
|---|---|---|---|---|---|---|---|---|
| task | task-background-suite | 2 | 3 | 2 | 1 | 3 | 0 | 0 |
| task | task-detached-receipt | 3 | 3 | 3 | 3 | 3 | 3 | 3 |
| task | task-fan-five | 3 | 0 | 1 | 3 | 1 | 2 | 1 |
| task | task-grep-three-control | 3 | 3 | 3 | 3 | 3 | 3 | 3 |
| task | task-mail | 2 | 3 | 1 | 1 | 1 | 3 | 0 |
| task | task-two-calls | 3 | 3 | 3 | 3 | 3 | 3 | 3 |
| compose | compose-background-suite | 3 (x3 u3) | 3 (x3 u3) | 1 (x1 u3) | 1 (x1 u3) | 3 (x1 u3) | 3 (x1 u3) | 3 (x1 u3) |
| compose | compose-grep-then-edit | 3 (x3 u3) | 1 (x1 u3) | 1 (x2 u3) | 1 (x2 u3) | 3 (x1 u3) | 2 (x3 u3) | 2 (x1 u3) |
| compose | compose-race | 3 (x3 u3) | 3 (x3 u3) | 3 (x3 u3) | 3 (x3 u3) | 3 (x3 u3) | 3 (x3 u3) | 3 (x2 u3) |
| compose | compose-race-anon | 3 (x3 u3) | 3 (x3 u3) | 2 (x3 u3) | 3 (x3 u3) | 3 (x3 u3) | 3 (x3 u3) | 3 (x3 u3) |
| compose | compose-rendezvous | 3 (x0 u3) | 3 (x0 u3) | 3 (x1 u3) | 3 (x0 u3) | 3 (x0 u3) | 3 (x0 u3) | 2 (x2 u3) |
| compose | compose-review-angles | 3 (x3 u3) | 3 (x3 u3) | 3 (x3 u3) | 3 (x3 u3) | 3 (x3 u3) | 3 (x3 u3) | 3 (x3 u3) |
| compose | compose-single-read | 3 | 3 | 2 | 3 | 3 | 3 | 3 |
| compose | compose-three-stage-pairing | 3 (x3 u3) | 1 (x1 u3) | 3 (x3 u3) | 3 (x3 u3) | 2 (x1 u3) | 1 (x1 u3) | 2 (x1 u2) |
| compose | compose-two-source-fan-in | 0 (x0 u3) | 1 (x1 u3) | 1 (x1 u3) | 0 (x0 u3) | 3 (x0 u3) | 3 (x0 u3) | 3 (x2 u3) |
| workflow | workflow-adversarial-verify | 3 | 3 | 2 | 0 | 1 | 0 | 1 |
| workflow | workflow-barrier-free-pipeline | 0 (x0 u3) | 0 (x0 u2) | 0 (x0 u3) | 0 (x0 u0) | 0 (x0 u0) | 0 (x0 u0) | 2 (x0 u2) |
| workflow | workflow-fan-out-finders | 3 | 3 | 3 | 3 | 3 | 3 | 3 |
| workflow | workflow-judge-panel | 3 | 0 | 0 | 3 | 1 | 2 | 3 |
| workflow | workflow-loop-until-dry | 3 | 3 | 3 | 3 | 3 | 3 | 2 |
| **all** | **green of 60** | **52** | **45** | **40** | **43** | **48** | **46** | **45** |

### [A1] A.3 Per family and per model

green / reached / succeeded of runs; p = verification passed/verified; cost USD; cost per green = cost / green; mean seconds per run.

| family | model | tier | green | reached | succeeded | p | classes | cost $ | $ / green | mean s |
|---|---|---|---|---|---|---|---|---|---|---|
| task | opus-5.5 | strong | 16/18 | 16/18 | 16/18 | - | mc2 | 2.6895 | 0.1681 | 52 |
| task | gpt-6-sol | strong | 15/18 | 15/18 | 15/18 | - | mc3 | 0.7730 | 0.0515 | 52 |
| task | glm-5.3 | strong | 13/18 | 16/18 | 15/18 | - | mc3 cuf2 | 1.2283 | 0.0945 | 84 |
| task | kimi-k3 | strong | 14/18 | 16/18 | 16/18 | - | mc2 cuf2 | 1.6049 | 0.1146 | 66 |
| task | gpt-6-luna | floor | 14/18 | 14/18 | 14/18 | - | mc4 | 0.0474 | 0.0034 | 54 |
| task | ds-flash | floor | 14/18 | 14/18 | 14/18 | - | mc4 | 0.0973 | 0.0070 | 53 |
| task | glm-5.3-flash | floor | 10/18 | 12/18 | 10/18 | - | mc8 | 0.1585 | 0.0158 | 94 |
| compose | opus-5.5 | strong | 24/27 | 27/27 | 24/27 | 3/3 | mc3 | 3.7574 | 0.1566 | 45 |
| compose | gpt-6-sol | strong | 21/27 | 27/27 | 21/27 | 3/3 | mc4 dis2 | 1.2934 | 0.0616 | 39 |
| compose | glm-5.3 | strong | 19/27 | 27/27 | 22/27 | 3/3 | mc5 dis1 cuf2 | 4.5970 | 0.2419 | 203 |
| compose | kimi-k3 | strong | 20/27 | 27/27 | 21/27 | 3/3 | mc5 dis1 cuf1 | 4.5811 | 0.2291 | 96 |
| compose | gpt-6-luna | floor | 26/27 | 27/27 | 27/27 | 3/3 | cuf1 | 0.0770 | 0.0030 | 42 |
| compose | ds-flash | floor | 24/27 | 27/27 | 27/27 | 3/3 | cuf3 | 0.3800 | 0.0158 | 67 |
| compose | glm-5.3-flash | floor | 24/27 | 26/27 | 26/27 | 3/3 | mc3 | 0.4358 | 0.0182 | 246 |
| workflow | opus-5.5 | strong | 12/15 | 15/15 | 12/15 | 15/15 | dis3 | 4.5715 | 0.3810 | 66 |
| workflow | gpt-6-sol | strong | 9/15 | 13/15 | 9/15 | 15/15 | mc2 dis4 | 1.2756 | 0.1417 | 89 |
| workflow | glm-5.3 | strong | 8/15 | 15/15 | 12/15 | 15/15 | dis3 cuf4 | 4.1255 | 0.5157 | 204 |
| workflow | kimi-k3 | strong | 9/15 | 12/15 | 11/15 | 15/15 | mc3 dis1 cuf2 | 4.3656 | 0.4851 | 142 |
| workflow | gpt-6-luna | floor | 8/15 | 10/15 | 10/15 | 13/15 | mc5 dis2 | 0.0668 | 0.0083 | 92 |
| workflow | ds-flash | floor | 8/15 | 9/15 | 8/15 | 14/15 | mc6 dis1 | 0.2663 | 0.0333 | 81 |
| workflow | glm-5.3-flash | floor | 11/15 | 14/15 | 12/15 | 15/15 | mc2 dis2 | 0.5113 | 0.0465 | 162 |
| all | opus-5.5 | strong | 52/60 | 58/60 | 52/60 | 18/18 | mc5 dis3 | 11.0183 | 0.2119 | 52 |
| all | gpt-6-sol | strong | 45/60 | 55/60 | 45/60 | 18/18 | mc9 dis6 | 3.3420 | 0.0743 | 56 |
| all | glm-5.3 | strong | 40/60 | 58/60 | 49/60 | 18/18 | mc8 dis4 cuf8 | 9.9508 | 0.2488 | 168 |
| all | kimi-k3 | strong | 43/60 | 55/60 | 48/60 | 18/18 | mc10 dis2 cuf5 | 10.5516 | 0.2454 | 99 |
| all | gpt-6-luna | floor | 48/60 | 51/60 | 51/60 | 16/18 | mc9 dis2 cuf1 | 0.1911 | 0.0040 | 58 |
| all | ds-flash | floor | 46/60 | 50/60 | 49/60 | 17/18 | mc10 dis1 cuf3 | 0.7437 | 0.0162 | 66 |
| all | glm-5.3-flash | floor | 45/60 | 52/60 | 48/60 | 18/18 | mc13 dis2 | 1.1056 | 0.0246 | 179 |

#### per tier and version

| scope | green | reached | succeeded | p | classes | cost $ | $ / green | mean s |
|---|---|---|---|---|---|---|---|---|
| v15 strong (opus, sol) | 97/120 | 113/120 | 97/120 | 36/36 | mc14 dis9 | 14.3603 | 0.1480 | 54 |
| v14 strong (glm-5.3, kimi-k3) | 83/120 | 113/120 | 97/120 | 36/36 | mc18 dis6 cuf13 | 20.5024 | 0.2470 | 133 |
| v15 floor (luna) | 48/60 | 51/60 | 51/60 | 16/18 | mc9 dis2 cuf1 | 0.1911 | 0.0040 | 58 |
| v14 floor (ds-flash, glm-5.3-flash) | 91/120 | 102/120 | 97/120 | 35/36 | mc23 dis3 cuf3 | 1.8492 | 0.0203 | 123 |
| v15 all | 145/180 | 164/180 | 148/180 | 52/54 | mc23 dis11 cuf1 | 14.5515 | 0.1004 | 55 |
| v14 all | 174/240 | 215/240 | 194/240 | 71/72 | mc41 dis9 cuf16 | 22.3517 | 0.1285 | 128 |

#### tokens and the cache bar per model (all families)

The bar's own measure (Scorecard.cache_under_floor): the rate after round 1 over the spine's cache_read_series, read only with >= 2 measured rounds, against the family floor 0.80 (task, compose and workflow alike); glm-5.3-flash is exempt. 'under' counts every read record under 0.80 whatever its class (a red class wins over cuf).

| model | input tok | output tok | cache-read tok | cache-read / input | $ per M input tok | records read by the bar | median after-r1 | under 0.80 | classed cuf |
|---|---|---|---|---|---|---|---|---|---|
| opus-5.5 | 5219650 | 151126 | 4325644 | 0.8287 | 2.1109 | 28 | 0.9624 | 0 | 0 |
| gpt-6-sol | 3540226 | 68165 | 2660947 | 0.7516 | 0.9440 | 32 | 0.9754 | 0 | 0 |
| glm-5.3 | 9342360 | 1340466 | 6897664 | 0.7383 | 1.0651 | 24 | 0.8353 | 11 | 8 |
| kimi-k3 | 4871867 | 284607 | 2959720 | 0.6075 | 2.1658 | 24 | 0.8800 | 7 | 5 |
| gpt-6-luna | 3662452 | 102632 | 2734462 | 0.7466 | 0.0522 | 30 | 0.9692 | 1 | 1 |
| ds-flash | 6407564 | 421555 | 5729536 | 0.8942 | 0.1161 | 34 | 0.9254 | 4 | 3 |
| glm-5.3-flash (exempt) | 7938214 | 731963 | 3851520 | 0.4852 | 0.1393 | 29 | 0.5687 | 21 | 0 |

### [A1] A.4 Every model on both bars (compose picture tasks)

picture = facts.picture true (the strong bar); usable = facts.usable_on_call set (the floor's bar); official = verdict.succeeded as recorded (each on its own tier's bar). Gate tasks = the seven compose picture tasks without compose-rendezvous (T5, recorded-only); 21 runs per model.


#### gate tasks (7 compose)

| model | tier | runs | official succeeded | usable | picture exact | usable on call 1 / 2 / 3 / none | green |
|---|---|---|---|---|---|---|---|
| opus-5.5 | strong | 21 | 18 | 21 | 18 | 21 / 0 / 0 / 0 | 18 |
| gpt-6-sol | strong | 21 | 15 | 21 | 15 | 20 / 1 / 0 / 0 | 15 |
| glm-5.3 | strong | 21 | 16 | 21 | 16 | 21 / 0 / 0 / 0 | 14 |
| kimi-k3 | strong | 21 | 15 | 21 | 15 | 20 / 1 / 0 / 0 | 14 |
| gpt-6-luna | floor | 21 | 21 | 21 | 12 | 19 / 2 / 0 / 0 | 20 |
| ds-flash | floor | 21 | 21 | 21 | 14 | 20 / 1 / 0 / 0 | 18 |
| glm-5.3-flash | floor | 21 | 20 | 20 | 13 | 17 / 3 / 0 / 1 | 19 |
- v15 strong: runs 42, official 33, usable 42, picture 33
- v14 strong: runs 42, official 31, usable 42, picture 31
- v15 floor: runs 21, official 21, usable 21, picture 12
- v14 floor: runs 42, official 41, usable 41, picture 27

#### compose picture tasks (8)

| model | tier | runs | official succeeded | usable | picture exact | usable on call 1 / 2 / 3 / none | green |
|---|---|---|---|---|---|---|---|
| opus-5.5 | strong | 24 | 21 | 24 | 18 | 24 / 0 / 0 / 0 | 21 |
| gpt-6-sol | strong | 24 | 18 | 24 | 15 | 23 / 1 / 0 / 0 | 18 |
| glm-5.3 | strong | 24 | 19 | 24 | 17 | 24 / 0 / 0 / 0 | 17 |
| kimi-k3 | strong | 24 | 18 | 24 | 15 | 23 / 1 / 0 / 0 | 17 |
| gpt-6-luna | floor | 24 | 24 | 24 | 12 | 22 / 2 / 0 / 0 | 23 |
| ds-flash | floor | 24 | 24 | 24 | 14 | 23 / 1 / 0 / 0 | 21 |
| glm-5.3-flash | floor | 24 | 23 | 23 | 15 | 20 / 3 / 0 / 1 | 21 |
- v15 strong: runs 48, official 39, usable 48, picture 33
- v14 strong: runs 48, official 37, usable 48, picture 32
- v15 floor: runs 24, official 24, usable 24, picture 12
- v14 floor: runs 48, official 47, usable 47, picture 29

#### all picture tasks (8 compose + barrier-free)

| model | tier | runs | official succeeded | usable | picture exact | usable on call 1 / 2 / 3 / none | green |
|---|---|---|---|---|---|---|---|
| opus-5.5 | strong | 27 | 21 | 27 | 18 | 27 / 0 / 0 / 0 | 21 |
| gpt-6-sol | strong | 27 | 18 | 26 | 15 | 25 / 1 / 0 / 1 | 18 |
| glm-5.3 | strong | 27 | 19 | 27 | 17 | 27 / 0 / 0 / 0 | 17 |
| kimi-k3 | strong | 27 | 18 | 24 | 15 | 23 / 1 / 0 / 3 | 17 |
| gpt-6-luna | floor | 27 | 24 | 24 | 12 | 22 / 2 / 0 / 3 | 23 |
| ds-flash | floor | 27 | 24 | 24 | 14 | 23 / 1 / 0 / 3 | 21 |
| glm-5.3-flash | floor | 27 | 25 | 25 | 15 | 22 / 3 / 0 / 2 | 23 |
- v15 strong: runs 54, official 39, usable 53, picture 33
- v14 strong: runs 54, official 37, usable 51, picture 32
- v15 floor: runs 27, official 24, usable 24, picture 12
- v14 floor: runs 54, official 49, usable 49, picture 29

#### picture exact / usable per picture task and model (of 3)

| task | opus-5.5 | gpt-6-sol | glm-5.3 | kimi-k3 | gpt-6-luna | ds-flash | glm-5.3-flash |
|---|---|---|---|---|---|---|---|
| compose-background-suite | x3 u3 | x3 u3 | x1 u3 | x1 u3 | x1 u3 | x1 u3 | x1 u3 |
| compose-grep-then-edit | x3 u3 | x1 u3 | x2 u3 | x2 u3 | x1 u3 | x3 u3 | x1 u3 |
| compose-race | x3 u3 | x3 u3 | x3 u3 | x3 u3 | x3 u3 | x3 u3 | x2 u3 |
| compose-race-anon | x3 u3 | x3 u3 | x3 u3 | x3 u3 | x3 u3 | x3 u3 | x3 u3 |
| compose-rendezvous | x0 u3 | x0 u3 | x1 u3 | x0 u3 | x0 u3 | x0 u3 | x2 u3 |
| compose-review-angles | x3 u3 | x3 u3 | x3 u3 | x3 u3 | x3 u3 | x3 u3 | x3 u3 |
| compose-three-stage-pairing | x3 u3 | x1 u3 | x3 u3 | x3 u3 | x1 u3 | x1 u3 | x1 u2 |
| compose-two-source-fan-in | x0 u3 | x1 u3 | x1 u3 | x0 u3 | x0 u3 | x0 u3 | x2 u3 |
| workflow-barrier-free-pipeline | x0 u3 | x0 u2 | x0 u3 | x0 u0 | x0 u0 | x0 u0 | x0 u2 |

#### picture-miss buckets per model (compose picture tasks; one count per record per bucket)

- opus-5.5: misses 6; buckets {'over_read': 5, 'blind_model': 1}; non-bucket misses {}
- gpt-6-sol: misses 9; buckets {'over_read': 5, 'blind_model': 2, 'extra_steps': 1}; non-bucket misses {'the script was refused script_error: Error: g.script: result': 1, '01a0dc2e-75c7-7d23-b43e-7b02003b6063(failed) did not complet': 1}
- glm-5.3: misses 7; buckets {'extra_steps': 2, 'over_read': 6, 'over_sync': 1}; non-bucket misses {}
- kimi-k3: misses 9; buckets {'missing_steps': 1, 'blind_model': 3, 'over_sync': 1, 'over_read': 4}; non-bucket misses {'the script was refused script_syntax_error: SyntaxError: Une': 1}
- gpt-6-luna: misses 12; buckets {'suite_waited_on': 1, 'over_sync': 3, 'over_read': 8, 'blind_model': 1, 'missing_steps': 2}; non-bucket misses {'the script was refused script_error: Error: g.parallel: ever': 1, 'the script was refused script_syntax_error: SyntaxError: Une': 1}
- ds-flash: misses 10; buckets {'over_read': 8, 'extra_steps': 1, 'over_sync': 1}; non-bucket misses {'the script was refused script_syntax_error: SyntaxError: Une': 1}
- glm-5.3-flash: misses 9; buckets {'extra_steps': 2, 'over_read': 3, 'missing_steps': 1}; non-bucket misses {'the script was refused script_error: Error: g.parallel: ever': 1, 'the script was refused script_syntax_error: SyntaxError: Une': 1, 'nothing r2t0 placed stands: the stages that did its work fai': 1, 'no compose call to score': 1}

### [A1] A.5 The seven ranked

official green = each model on its own tier's bar (60 runs). same-bar green = green over the 11 tasks whose bar does not depend on the tier (task 6, compose-single-read, workflow's four non-picture tasks: 33 runs). strong-bar succeeded = succeeded, a floor picture record counting only with its picture exact. strong-bar green = green read on the strong bar for all seven (a floor picture record counts only if green AND its picture is exact; strong records as recorded) over 60. gate picture / usable = A.4's gate-task counts of 21.

| rank (official) | model | tier | official green /60 | strong-bar green /60 | same-bar green /33 | gate picture /21 | gate usable /21 | succeeded | strong-bar succeeded | reached | p | cost $ | $ / green | mean s |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | opus-5.5 | strong | 52 | 52 | 31/33 | 18 | 21 | 52 | 52 | 58 | 18/18 | 11.0183 | 0.2119 | 52 |
| 2 | gpt-6-luna | floor | 48 | 37 | 25/33 | 12 | 21 | 51 | 39 | 51 | 16/18 | 0.1911 | 0.0040 | 58 |
| 3 | ds-flash | floor | 46 | 37 | 25/33 | 14 | 21 | 49 | 39 | 50 | 17/18 | 0.7437 | 0.0162 | 66 |
| 4 | gpt-6-sol | strong | 45 | 45 | 27/33 | 15 | 21 | 45 | 45 | 55 | 18/18 | 3.3420 | 0.0743 | 56 |
| 5 | glm-5.3-flash | floor | 45 | 37 | 22/33 | 13 | 20 | 48 | 38 | 52 | 18/18 | 1.1056 | 0.0246 | 179 |
| 6 | kimi-k3 | strong | 43 | 43 | 26/33 | 15 | 21 | 48 | 48 | 55 | 18/18 | 10.5516 | 0.2454 | 99 |
| 7 | glm-5.3 | strong | 40 | 40 | 23/33 | 16 | 21 | 49 | 49 | 58 | 18/18 | 9.9508 | 0.2488 | 168 |
- by strong-bar green: opus-5.5 (52) > gpt-6-sol (45) > kimi-k3 (43) > glm-5.3 (40) > gpt-6-luna (37) > ds-flash (37) > glm-5.3-flash (37)
- by same-bar green: opus-5.5 (31) > gpt-6-sol (27) > kimi-k3 (26) > gpt-6-luna (25) > ds-flash (25) > glm-5.3 (23) > glm-5.3-flash (22)
- by gate picture: opus-5.5 (18) > glm-5.3 (16) > gpt-6-sol (15) > kimi-k3 (15) > ds-flash (14) > glm-5.3-flash (13) > gpt-6-luna (12)
- by strong-bar succeeded: opus-5.5 (52) > glm-5.3 (49) > kimi-k3 (48) > gpt-6-sol (45) > gpt-6-luna (39) > ds-flash (39) > glm-5.3-flash (38)
- by cost per green (lower first): gpt-6-luna (0.004) > ds-flash (0.0162) > glm-5.3-flash (0.0246) > gpt-6-sol (0.0743) > opus-5.5 (0.2119) > kimi-k3 (0.2454) > glm-5.3 (0.2488)

### [A1] A.6 Cells where a new model differs from the best v14 model on that cell by >= 2 of 3

Three readings. (a) OFFICIAL: best v14 model on a cell = the highest (green, succeeded, reached, passed) of the four v14 models (ties listed); compared on reached, succeeded, task pass (passed count) and green, as v14's §3.1 read moves; positive = the new model higher. On a picture cell each model's succeeded and green are on its own tier's bar, so a strong new model against a floor best crosses bars (column 'bars'). (b) PICTURE BAR, like for like: the new model's picture-exact count against the best v14 picture count on the cell. (c) USABLE BAR, like for like: the same on usable generation.

#### (a) official: 13 (cell, new model) pairs

| family | task | new model | Δr | Δs | Δp | Δg | bars | new r s p [classes] | best v14 model(s) | best v14 r s p [classes] |
|---|---|---|---|---|---|---|---|---|---|---|
| task | task-fan-five | gpt-6-sol | -3 | -3 | +0 | -3 | same | r0 s0 p- [mc3 g0] | kimi-k3 | r3 s3 p- [g3] |
| task | task-fan-five | gpt-6-luna | -2 | -2 | +0 | -2 | same | r1 s1 p- [mc2 g1] | kimi-k3 | r3 s3 p- [g3] |
| task | task-mail | gpt-6-luna | -2 | -2 | +0 | -2 | same | r1 s1 p- [mc2 g1] | ds-flash | r3 s3 p- [g3] |
| compose | compose-grep-then-edit | gpt-6-sol | +0 | -2 | +0 | -1 | cross | r3 s1 p3/3 [dis2 g1] | ds-flash, glm-5.3-flash | r3 s3 p3/3 [cuf1 g2] |
| compose | compose-three-stage-pairing | gpt-6-sol | +0 | -2 | +0 | -2 | same | r3 s1 p- [mc2 g1] | glm-5.3, kimi-k3 | r3 s3 p- [g3] |
| compose | compose-two-source-fan-in | opus-5.5 | +0 | -3 | +0 | -3 | cross | r3 s0 p- [mc3 g0] | ds-flash, glm-5.3-flash | r3 s3 p- [g3] |
| compose | compose-two-source-fan-in | gpt-6-sol | +0 | -2 | +0 | -2 | cross | r3 s1 p- [mc2 g1] | ds-flash, glm-5.3-flash | r3 s3 p- [g3] |
| workflow | workflow-adversarial-verify | gpt-6-luna | +0 | +0 | -2 | -1 | same | r3 s3 p1/3 [dis2 g1] | glm-5.3 | r3 s3 p3/3 [cuf1 g2] |
| workflow | workflow-barrier-free-pipeline | opus-5.5 | +1 | -2 | +0 | -2 | cross | r3 s0 p3/3 [dis3 g0] | glm-5.3-flash | r2 s2 p3/3 [mc1 g2] |
| workflow | workflow-barrier-free-pipeline | gpt-6-sol | +0 | -2 | +0 | -2 | cross | r2 s0 p3/3 [mc1 dis2 g0] | glm-5.3-flash | r2 s2 p3/3 [mc1 g2] |
| workflow | workflow-barrier-free-pipeline | gpt-6-luna | -2 | -2 | +0 | -2 | same | r0 s0 p3/3 [mc3 g0] | glm-5.3-flash | r2 s2 p3/3 [mc1 g2] |
| workflow | workflow-judge-panel | gpt-6-sol | -1 | -3 | +0 | -3 | same | r2 s0 p3/3 [mc1 dis2 g0] | kimi-k3, glm-5.3-flash | r3 s3 p3/3 [g3] |
| workflow | workflow-judge-panel | gpt-6-luna | -2 | -2 | +0 | -2 | same | r1 s1 p3/3 [mc2 g1] | kimi-k3, glm-5.3-flash | r3 s3 p3/3 [g3] |

#### (b) picture bar: 11 pairs

| task | new model | new picture | best v14 picture | best v14 model(s) on the picture | Δ |
|---|---|---|---|---|---|
| compose-background-suite | opus-5.5 | 3/3 | 1/3 | glm-5.3, kimi-k3, ds-flash, glm-5.3-flash | +2 |
| compose-background-suite | gpt-6-sol | 3/3 | 1/3 | glm-5.3, kimi-k3, ds-flash, glm-5.3-flash | +2 |
| compose-grep-then-edit | gpt-6-sol | 1/3 | 3/3 | ds-flash | -2 |
| compose-grep-then-edit | gpt-6-luna | 1/3 | 3/3 | ds-flash | -2 |
| compose-rendezvous | opus-5.5 | 0/3 | 2/3 | glm-5.3-flash | -2 |
| compose-rendezvous | gpt-6-sol | 0/3 | 2/3 | glm-5.3-flash | -2 |
| compose-rendezvous | gpt-6-luna | 0/3 | 2/3 | glm-5.3-flash | -2 |
| compose-three-stage-pairing | gpt-6-sol | 1/3 | 3/3 | glm-5.3, kimi-k3 | -2 |
| compose-three-stage-pairing | gpt-6-luna | 1/3 | 3/3 | glm-5.3, kimi-k3 | -2 |
| compose-two-source-fan-in | opus-5.5 | 0/3 | 2/3 | glm-5.3-flash | -2 |
| compose-two-source-fan-in | gpt-6-luna | 0/3 | 2/3 | glm-5.3-flash | -2 |

#### (c) usable bar: 1 pairs

| task | new model | new usable | best v14 usable | best v14 model(s) | Δ |
|---|---|---|---|---|---|
| workflow-barrier-free-pipeline | gpt-6-luna | 0/3 | 3/3 | glm-5.3 | -3 |

#### (d) the official comparison against the best v14 model of the SAME tier (one bar throughout)

| family | task | new model | Δr | Δs | Δp | Δg | new r s p [classes] | best same-tier v14 |
|---|---|---|---|---|---|---|---|---|
| task | task-background-suite | gpt-6-luna | +3 | +3 | +0 | +3 | r3 s3 p- [g3] | ds-flash, glm-5.3-flash r0 s0 p- [mc3 g0] |
| task | task-fan-five | gpt-6-sol | -3 | -3 | +0 | -3 | r0 s0 p- [mc3 g0] | kimi-k3 r3 s3 p- [g3] |
| task | task-mail | gpt-6-sol | +2 | +2 | +0 | +2 | r3 s3 p- [g3] | glm-5.3, kimi-k3 r1 s1 p- [mc2 g1] |
| task | task-mail | gpt-6-luna | -2 | -2 | +0 | -2 | r1 s1 p- [mc2 g1] | ds-flash r3 s3 p- [g3] |
| compose | compose-background-suite | opus-5.5 | +0 | +2 | +0 | +2 | r3 s3 p- [g3] | glm-5.3, kimi-k3 r3 s1 p- [mc2 g1] |
| compose | compose-background-suite | gpt-6-sol | +0 | +2 | +0 | +2 | r3 s3 p- [g3] | glm-5.3, kimi-k3 r3 s1 p- [mc2 g1] |
| compose | compose-grep-then-edit | opus-5.5 | +0 | +1 | +0 | +2 | r3 s3 p3/3 [g3] | glm-5.3, kimi-k3 r3 s2 p3/3 [dis1 cuf1 g1] |
| compose | compose-three-stage-pairing | gpt-6-sol | +0 | -2 | +0 | -2 | r3 s1 p- [mc2 g1] | glm-5.3, kimi-k3 r3 s3 p- [g3] |
| workflow | workflow-adversarial-verify | gpt-6-luna | +0 | +2 | -2 | +0 | r3 s3 p1/3 [dis2 g1] | glm-5.3-flash r3 s1 p3/3 [dis2 g1] |
| workflow | workflow-barrier-free-pipeline | gpt-6-luna | -2 | -2 | +0 | -2 | r0 s0 p3/3 [mc3 g0] | glm-5.3-flash r2 s2 p3/3 [mc1 g2] |
| workflow | workflow-judge-panel | gpt-6-sol | -1 | -3 | +0 | -3 | r2 s0 p3/3 [mc1 dis2 g0] | kimi-k3 r3 s3 p3/3 [g3] |
| workflow | workflow-judge-panel | gpt-6-luna | -2 | -2 | +0 | -2 | r1 s1 p3/3 [mc2 g1] | glm-5.3-flash r3 s3 p3/3 [g3] |

12 pairs against the best same-tier v14 model.

Per-run lines for every flagged cell are A2_evidence.out's.

### [A1] A.7 Reds by reason kind, per family and model (every record whose class is not green)


#### task: reds opus-5.5 2, gpt-6-sol 3, glm-5.3 5, kimi-k3 4, gpt-6-luna 4, ds-flash 4, glm-5.3-flash 8

| reason kind | opus-5.5 | gpt-6-sol | glm-5.3 | kimi-k3 | gpt-6-luna | ds-flash | glm-5.3-flash |
|---|---|---|---|---|---|---|---|
| no `task` call; start_process in the tally | 0 | 0 | 2 | 2 | 2 | 3 | 6 |
| fewer than five `task` calls in the first message | 0 | 3 | 0 | 0 | 2 | 1 | 0 |
| cache under floor (success held) | 0 | 0 | 2 | 2 | 0 | 0 | 0 |
| a second `task` for files already handed out | 0 | 0 | 0 | 0 | 0 | 0 | 2 |
| no `task` call; no start_process | 2 | 0 | 0 | 0 | 0 | 0 | 0 |
| the suite handed to more than one `task` | 0 | 0 | 1 | 0 | 0 | 0 | 0 |

conduct checks failed: opus-5.5 0; gpt-6-sol 0; glm-5.3 0; kimi-k3 0; gpt-6-luna 0; ds-flash 0; glm-5.3-flash 0

#### compose: reds opus-5.5 3, gpt-6-sol 6, glm-5.3 8, kimi-k3 7, gpt-6-luna 1, ds-flash 3, glm-5.3-flash 3

| reason kind | opus-5.5 | gpt-6-sol | glm-5.3 | kimi-k3 | gpt-6-luna | ds-flash | glm-5.3-flash |
|---|---|---|---|---|---|---|---|
| picture red (over_read) | 3 | 4 | 2 | 3 | 0 | 0 | 0 |
| cache under floor (success held) | 0 | 0 | 2 | 1 | 1 | 3 | 0 |
| 600 s deadline stop | 0 | 0 | 1 | 0 | 0 | 0 | 2 |
| picture red (over_sync) | 0 | 0 | 1 | 1 | 0 | 0 | 0 |
| a composed step failed (did not complete) | 0 | 1 | 0 | 0 | 0 | 0 | 0 |
| compose refused (script_error) | 0 | 1 | 0 | 0 | 0 | 0 | 0 |
| compose refused (script_syntax_error) | 0 | 0 | 0 | 1 | 0 | 0 | 0 |
| conduct only: no_wrong_winner | 0 | 0 | 1 | 0 | 0 | 0 | 0 |
| no compose call (did it with tools) | 0 | 0 | 0 | 0 | 0 | 0 | 1 |
| picture red (extra_steps, over_read) | 0 | 0 | 1 | 0 | 0 | 0 | 0 |
| picture red (missing_steps, blind_model) | 0 | 0 | 0 | 1 | 0 | 0 | 0 |

conduct checks failed: opus-5.5 0; gpt-6-sol 0; glm-5.3 {'no_wrong_winner': 1}; kimi-k3 0; gpt-6-luna 0; ds-flash 0; glm-5.3-flash 0

#### workflow: reds opus-5.5 3, gpt-6-sol 6, glm-5.3 7, kimi-k3 6, gpt-6-luna 7, ds-flash 7, glm-5.3-flash 4

| reason kind | opus-5.5 | gpt-6-sol | glm-5.3 | kimi-k3 | gpt-6-luna | ds-flash | glm-5.3-flash |
|---|---|---|---|---|---|---|---|
| no door: no compose call and no two-`task` fan | 0 | 2 | 0 | 3 | 5 | 6 | 1 |
| picture red (edit_as_tool) | 3 | 2 | 3 | 0 | 0 | 0 | 0 |
| cache under floor (success held) | 0 | 0 | 4 | 2 | 0 | 0 | 0 |
| no task_result receipt: every `task` call waited | 0 | 0 | 0 | 1 | 0 | 1 | 2 |
| composed, but no step reads two model members | 0 | 2 | 0 | 0 | 0 | 0 | 0 |
| disagreement: succeeded, verification failed | 0 | 0 | 0 | 0 | 2 | 0 | 0 |
| conduct only: one_item_per_pass | 0 | 0 | 0 | 0 | 0 | 0 | 1 |

conduct checks failed: opus-5.5 0; gpt-6-sol 0; glm-5.3 0; kimi-k3 0; gpt-6-luna 0; ds-flash {'did_not_judge_itself': 1}; glm-5.3-flash {'one_item_per_pass': 1}

#### every v15 red, in full

- task-background-suite opus-5.5 #3 r=N s=- p=- model conduct 70s $0.0773 rounds 7 calls 9 hit 0.968667 after-r1 0.9714 called {'compose': 2, 'bash': 5, 'read': 1, 'write': 1} :: no `task` call: the model called {"compose" => 2, "bash" => 5, "read" => 1, "write" => 1}
- task-fan-five gpt-6-sol #1 r=N s=- p=- model conduct 72s $0.0801 rounds 8 calls 21 hit 0.73041 after-r1 0.9745 called {'task': 5, 'bash': 14, 'find': 1, 'compose': 1} :: 1 task call(s) in the first message, not five: {"task" => 1}
- task-fan-five gpt-6-sol #2 r=N s=- p=- model conduct 68s $0.0655 rounds 4 calls 17 hit 0.542419 after-r1 0.9676 called {'task': 5, 'read': 3, 'find': 3, 'bash': 5, 'grep': 1} :: 1 task call(s) in the first message, not five: {"task" => 1}
- task-fan-five gpt-6-sol #3 r=N s=- p=- model conduct 63s $0.0795 rounds 8 calls 18 hit 0.726735 after-r1 0.97 called {'task': 5, 'read': 4, 'find': 1, 'bash': 5, 'grep': 2, 'compose': 1} :: 1 task call(s) in the first message, not five: {"task" => 1}
- task-fan-five gpt-6-luna #2 r=N s=- p=- model conduct 76s $0.0034 rounds 6 calls 16 hit 0.679001 after-r1 0.9815 called {'task': 5, 'read': 5, 'grep': 6} :: 1 task call(s) in the first message, not five: {"task" => 1}
- task-fan-five gpt-6-luna #3 r=N s=- p=- model conduct 82s $0.0030 rounds 6 calls 20 hit 0.693994 after-r1 0.9836 called {'task': 5, 'find': 1, 'read': 10, 'grep': 4} :: 1 task call(s) in the first message, not five: {"task" => 1}
- task-mail opus-5.5 #1 r=N s=- p=- model conduct 62s $0.0408 rounds 2 calls 3 hit 0.944627 after-r1 0.9542 called {'compose': 1, 'bash': 2} :: no `task` call: turn 1 called {"compose" => 1, "bash" => 2}
- task-mail gpt-6-luna #1 r=N s=- p=- model conduct 15s $0.0014 rounds 2 calls 2 hit 0.482475 after-r1 0.9326 called {'start_process': 1, 'bash': 1} :: no `task` call: turn 1 called {"start_process" => 1, "bash" => 1}
- task-mail gpt-6-luna #2 r=N s=- p=- model conduct 15s $0.0015 rounds 2 calls 2 hit 0.476073 after-r1 0.909 called {'start_process': 1, 'bash': 1} :: no `task` call: turn 1 called {"start_process" => 1, "bash" => 1}
- compose-grep-then-edit gpt-6-sol #1 r=Y s=N p=Y disagreement 32s $0.0450 rounds 3 calls 6 hit 0.627535 after-r1 0.8883 called {'compose': 2, 'grep': 3, 'edit': 1} :: the script was refused script_error: Error: g.script: results names an "all" group, which is not one step; list its steps instead: results: [a, b]. {picture: the script was refused script_error: Error: g.script: results names an; usable_on_call: 2}
- compose-grep-then-edit gpt-6-sol #3 r=Y s=N p=Y disagreement 43s $0.0462 rounds 4 calls 9 hit 0.733219 after-r1 0.93 called {'compose': 1, 'grep': 5, 'edit': 2, 'read': 1} :: 01a0dc2e-75c7-7d23-b43e-7b02003b6063(failed) did not complete under r2t0 {picture: 01a0dc2e-75c7-7d23-b43e-7b02003b6063(failed) did not complete under r2; usable_on_call: 1}
- compose-three-stage-pairing gpt-6-sol #1 r=Y s=N p=- model conduct 36s $0.0506 rounds 2 calls 4 hit 0.598976 after-r1 0.8889 called {'compose': 1, 'bash': 3} :: the picture is not the objective's (silent: over_read): {"nodes" => ["tool-1:tool", "tool-2:tool", "tool-3:tool", "model-1:model", "model-2:model", "model-3:model", "mode... {picture: the picture is not the objective's (silent: over_read): {"nodes" => ["; usable_on_call: 1}
- compose-three-stage-pairing gpt-6-sol #2 r=Y s=N p=- model conduct 38s $0.0529 rounds 2 calls 4 hit 0.59607 after-r1 0.8739 called {'compose': 1, 'bash': 3} :: the picture is not the objective's (silent: over_read): {"nodes" => ["tool-1:tool", "tool-2:tool", "tool-3:tool", "model-1:model", "model-2:model", "model-3:model", "mode... {picture: the picture is not the objective's (silent: over_read): {"nodes" => ["; usable_on_call: 1}
- compose-three-stage-pairing gpt-6-luna #1 r=Y s=Y p=- cache under floor 88s $0.0047 rounds 3 calls 8 hit 0.59117 after-r1 0.7744 called {'compose': 2, 'bash': 6} ::  {picture: the picture is not the objective's (silent: missing_steps, over_sync):; usable_on_call: 1}
- compose-two-source-fan-in opus-5.5 #1 r=Y s=N p=- model conduct 68s $0.2333 rounds 2 calls 4 hit 0.633737 after-r1 0.902 called {'compose': 1, 'bash': 3} :: the picture is not the objective's (silent: over_read): {"nodes" => ["tool-1:tool", "tool-2:tool", "tool-3:tool", "model-1:model", "model-2:model", "model-3:model"], "edg... {picture: the picture is not the objective's (silent: over_read): {"nodes" => ["; usable_on_call: 1}
- compose-two-source-fan-in opus-5.5 #2 r=Y s=N p=- model conduct 66s $0.2376 rounds 3 calls 4 hit 0.704706 after-r1 0.9424 called {'compose': 1, 'bash': 3} :: the picture is not the objective's (silent: over_read): {"nodes" => ["tool-1:tool", "tool-2:tool", "tool-3:tool", "model-1:model", "model-2:model", "model-3:model"], "edg... {picture: the picture is not the objective's (silent: over_read): {"nodes" => ["; usable_on_call: 1}
- compose-two-source-fan-in opus-5.5 #3 r=Y s=N p=- model conduct 72s $0.2531 rounds 3 calls 4 hit 0.700069 after-r1 0.9325 called {'compose': 1, 'bash': 3} :: the picture is not the objective's (silent: over_read): {"nodes" => ["tool-1:tool", "tool-2:tool", "tool-3:tool", "model-1:model", "model-2:model", "model-3:model"], "edg... {picture: the picture is not the objective's (silent: over_read): {"nodes" => ["; usable_on_call: 1}
- compose-two-source-fan-in gpt-6-sol #1 r=Y s=N p=- model conduct 59s $0.0513 rounds 2 calls 4 hit 0.54105 after-r1 0.8917 called {'compose': 1, 'bash': 3} :: the picture is not the objective's (silent: over_read): {"nodes" => ["tool-1:tool", "tool-2:tool", "tool-3:tool", "model-1:model", "model-2:model", "model-3:model"], "edg... {picture: the picture is not the objective's (silent: over_read): {"nodes" => ["; usable_on_call: 1}
- compose-two-source-fan-in gpt-6-sol #3 r=Y s=N p=- model conduct 59s $0.0396 rounds 2 calls 4 hit 0.439881 after-r1 0.8833 called {'compose': 1, 'bash': 3} :: the picture is not the objective's (silent: over_read): {"nodes" => ["tool-1:tool", "tool-2:tool", "tool-3:tool", "model-1:model", "model-2:model", "model-3:model"], "edg... {picture: the picture is not the objective's (silent: over_read): {"nodes" => ["; usable_on_call: 1}
- workflow-adversarial-verify gpt-6-luna #1 r=Y s=Y p=N disagreement 159s $0.0097 rounds 20 calls 54 hit 0.834086 after-r1 0.9692 called {'read': 22, 'todo_write': 3, 'task': 12, 'find': 12, 'grep': 3, 'compose': 1, 'write': 1} :: 
- workflow-adversarial-verify gpt-6-luna #3 r=Y s=Y p=N disagreement 155s $0.0113 rounds 17 calls 53 hit 0.775258 after-r1 0.9636 called {'read': 24, 'task': 12, 'find': 12, 'grep': 3, 'compose': 1, 'write': 1} :: 
- workflow-barrier-free-pipeline opus-5.5 #1 r=Y s=N p=Y disagreement 44s $0.0572 rounds 4 calls 7 hit 0.952877 after-r1 0.9556 called {'bash': 5, 'compose': 1, 'write': 1} :: the picture is not the objective's (silent: edit_as_tool): {"nodes" => ["tool-1:tool", "script-1:script", "tool-2:tool", "script-2:script", "tool-3:tool", "script-3:scrip... {picture: the picture is not the objective's (silent: edit_as_tool): {"nodes" =>; usable_on_call: 1}
- workflow-barrier-free-pipeline opus-5.5 #2 r=Y s=N p=Y disagreement 37s $0.0415 rounds 3 calls 6 hit 0.948067 after-r1 0.9501 called {'bash': 4, 'compose': 1, 'write': 1} :: the picture is not the objective's (silent: edit_as_tool): {"nodes" => ["tool-1:tool", "script-1:script", "tool-2:tool", "script-2:script", "tool-3:tool", "script-3:scrip... {picture: the picture is not the objective's (silent: edit_as_tool): {"nodes" =>; usable_on_call: 1}
- workflow-barrier-free-pipeline opus-5.5 #3 r=Y s=N p=Y disagreement 44s $0.0534 rounds 4 calls 7 hit 0.958285 after-r1 0.9627 called {'bash': 4, 'compose': 1, 'write': 1, 'read': 1} :: the picture is not the objective's (silent: edit_as_tool): {"nodes" => ["tool-1:tool", "script-1:script", "tool-2:tool", "script-2:script", "tool-3:tool", "script-3:scrip... {picture: the picture is not the objective's (silent: edit_as_tool): {"nodes" =>; usable_on_call: 1}
- workflow-barrier-free-pipeline gpt-6-sol #1 r=Y s=N p=Y disagreement 47s $0.0364 rounds 4 calls 12 hit 0.717835 after-r1 0.9351 called {'ls': 2, 'read': 1, 'bash': 8, 'compose': 1} :: the picture is not the objective's (silent: edit_as_tool): {"nodes" => ["tool-1:tool", "tool-2:tool", "tool-3:tool", "tool-4:tool", "tool-5:tool", "tool-6:tool", "tool-7:... {picture: the picture is not the objective's (silent: edit_as_tool): {"nodes" =>; usable_on_call: 1}
- workflow-barrier-free-pipeline gpt-6-sol #2 r=N s=- p=Y model conduct 41s $0.0361 rounds 4 calls 7 hit 0.735963 after-r1 0.9602 called {'ls': 1, 'read': 1, 'bash': 5} :: no compose call and no round fanned two task calls: {"ls" => 1, "read" => 1, "bash" => 5} {picture: no compose call to score; usable_on_call: None}
- workflow-barrier-free-pipeline gpt-6-sol #3 r=Y s=N p=Y disagreement 50s $0.0390 rounds 5 calls 11 hit 0.771583 after-r1 0.9524 called {'ls': 2, 'read': 1, 'compose': 1, 'bash': 7} :: the picture is not the objective's (silent: edit_as_tool): {"nodes" => ["tool-1:tool", "tool-2:tool", "tool-3:tool", "tool-4:tool", "tool-5:tool", "tool-6:tool", "tool-7:... {picture: the picture is not the objective's (silent: edit_as_tool): {"nodes" =>; usable_on_call: 1}
- workflow-barrier-free-pipeline gpt-6-luna #1 r=N s=- p=Y model conduct 45s $0.0021 rounds 6 calls 7 hit 0.820467 after-r1 0.9707 called {'todo_write': 3, 'ls': 1, 'find': 1, 'read': 1, 'bash': 1} :: no compose call and no round fanned two task calls: {"todo_write" => 3, "ls" => 1, "find" => 1, "read" => 1, "bash" => 1} {picture: no compose call to score; usable_on_call: None}
- workflow-barrier-free-pipeline gpt-6-luna #2 r=N s=- p=Y model conduct 44s $0.0020 rounds 6 calls 5 hit 0.821084 after-r1 0.9759 called {'ls': 2, 'read': 2, 'bash': 1} :: no compose call and no round fanned two task calls: {"ls" => 2, "read" => 2, "bash" => 1} {picture: no compose call to score; usable_on_call: None}
- workflow-barrier-free-pipeline gpt-6-luna #3 r=N s=- p=Y model conduct 39s $0.0018 rounds 5 calls 4 hit 0.787209 after-r1 0.9769 called {'ls': 2, 'read': 1, 'bash': 1} :: no compose call and no round fanned two task calls: {"ls" => 2, "read" => 1, "bash" => 1} {picture: no compose call to score; usable_on_call: None}
- workflow-judge-panel gpt-6-sol #1 r=Y s=N p=Y disagreement 59s $0.0576 rounds 8 calls 15 hit 0.838217 after-r1 0.9753 called {'task': 4, 'read': 9, 'compose': 1, 'write': 1} :: r8t0 composed 3 tasks and no step reads two model members
- workflow-judge-panel gpt-6-sol #2 r=Y s=N p=Y disagreement 59s $0.0601 rounds 8 calls 15 hit 0.834795 after-r1 0.97 called {'task': 4, 'read': 9, 'compose': 1, 'write': 1} :: r8t0 composed 3 tasks and no step reads two model members
- workflow-judge-panel gpt-6-sol #3 r=N s=- p=Y model conduct 67s $0.0513 rounds 6 calls 14 hit 0.790457 after-r1 0.9767 called {'task': 4, 'read': 9, 'write': 1} :: no compose call and no round fanned two task calls: {"task" => 4, "read" => 9, "write" => 1}
- workflow-judge-panel gpt-6-luna #1 r=N s=- p=Y model conduct 67s $0.0018 rounds 5 calls 4 hit 0.788172 after-r1 0.9677 called {'spawn': 3, 'write': 1} :: no compose call and no round fanned two task calls: {"spawn" => 3, "write" => 1}
- workflow-judge-panel gpt-6-luna #3 r=N s=- p=Y model conduct 73s $0.0032 rounds 6 calls 14 hit 0.788431 after-r1 0.9693 called {'task': 4, 'read': 9, 'write': 1} :: no compose call and no round fanned two task calls: {"task" => 4, "read" => 9, "write" => 1}

### `A5_doors.out`

| task | opus-5.5 | gpt-6-sol | glm-5.3 | kimi-k3 | gpt-6-luna | ds-flash | glm-5.3-flash |
|---|---|---|---|---|---|---|---|
| workflow-adversarial-verify | compose 3 | compose 3 | task_fan 3 | task_fan 3 | compose 3 | None 2, task_fan 1 | task_fan 3 |
| workflow-barrier-free-pipeline | compose 3 | None 1, compose 2 | compose 3 | None 3 | None 3 | None 3 | None 1, compose 2 |
| workflow-fan-out-finders | compose 3 | compose 3 | task_fan 3 | task_fan 3 | task_fan 3 | task_fan 3 | task_fan 3 |
| workflow-judge-panel | compose 3 | None 1, compose 2 | compose 1, task_fan 2 | compose 1, task_fan 2 | None 2, task_fan 1 | None 1, compose 2 | task_fan 3 |
| workflow-loop-until-dry | None 3 | None 3 | None 3 | None 3 | None 3 | None 3 | None 3 |
| **all** | None 3, compose 12 | None 5, compose 10 | None 3, compose 4, task_fan 8 | None 6, compose 1, task_fan 8 | None 8, compose 3, task_fan 4 | None 9, compose 2, task_fan 4 | None 4, compose 2, task_fan 9 |

### `A6_wait_compose.out`

| model | family | records | with a compose call | every compose only g.wait | compose builds steps | spine task calls (sum) | records with >=2 task calls in one spine round |
|---|---|---|---|---|---|---|---|
| opus-5.5 | task | 18 | 2 | 0 | 2 | 22 | 3 |
| opus-5.5 | workflow | 15 | 12 | 0 | 12 | 0 | 0 |
| gpt-6-sol | task | 18 | 2 | 2 | 0 | 24 | 1 |
| gpt-6-sol | workflow | 15 | 10 | 6 | 4 | 72 | 0 |
| gpt-6-luna | task | 18 | 0 | 0 | 0 | 22 | 1 |
| gpt-6-luna | workflow | 15 | 3 | 2 | 1 | 67 | 5 |
| glm-5.3 | task | 18 | 0 | 0 | 0 | 23 | 3 |
| glm-5.3 | workflow | 15 | 4 | 0 | 4 | 68 | 8 |
| kimi-k3 | task | 18 | 0 | 0 | 0 | 22 | 3 |
| kimi-k3 | workflow | 15 | 1 | 0 | 1 | 68 | 8 |
| ds-flash | task | 18 | 1 | 1 | 0 | 21 | 3 |
| ds-flash | workflow | 15 | 2 | 0 | 2 | 37 | 4 |
| glm-5.3-flash | task | 18 | 0 | 0 | 0 | 18 | 3 |
| glm-5.3-flash | workflow | 15 | 2 | 0 | 2 | 73 | 9 |

wait-only compose records:
- gpt-6-sol task-fan-five #1: wait-only compose; class model conduct; spine task calls per round [1, 1, 1, 1, 1]
- gpt-6-sol task-fan-five #3: wait-only compose; class model conduct; spine task calls per round [1, 1, 1, 1, 1]
- gpt-6-sol workflow-adversarial-verify #2: wait-only compose; class green; spine task calls per round [1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1]
- gpt-6-sol workflow-fan-out-finders #1: wait-only compose; class green; spine task calls per round [1, 1, 1, 1, 1, 1, 1, 1]
- gpt-6-sol workflow-fan-out-finders #2: wait-only compose; class green; spine task calls per round [1, 1, 1, 1, 1, 1, 1, 1]
- gpt-6-sol workflow-fan-out-finders #3: wait-only compose; class green; spine task calls per round [1, 1, 1, 1, 1, 1, 1, 1]
- gpt-6-sol workflow-judge-panel #1: wait-only compose; class disagreement; spine task calls per round [1, 1, 1, 1]
- gpt-6-sol workflow-judge-panel #2: wait-only compose; class disagreement; spine task calls per round [1, 1, 1, 1]
- gpt-6-luna workflow-adversarial-verify #1: wait-only compose; class disagreement; spine task calls per round [1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1]
- gpt-6-luna workflow-adversarial-verify #2: wait-only compose; class green; spine task calls per round [12]
- ds-flash task-fan-five #3: wait-only compose; class green; spine task calls per round [5]

### `A2_evidence.out`

```text
## A2 evidence: 21 flagged (cell, new model) pairs; every record of the new model and of the best v14 model(s) on the cell

### task-fan-five / gpt-6-sol (best v14: kimi-k3)

**gpt-6-sol**
#1 model conduct r=False s=None p=None 72s $0.0801 :: 1 task call(s) in the first message, not five: {"task" => 1}
   facts {"called": {"task": 5, "bash": 14, "find": 1, "compose": 1}, "waited": true, "woken_loops": [], "merge_turn": null, "orphans_named": 0}
   spine r2: task(wait=False, 'Review lib/a.rb: identify the one method defined there but n...')
   spine r3: task(wait=False, 'Review lib/b.rb: identify the one method defined there but n...')
   spine r5: task(wait=False, 'Review lib/c.rb: identify the one method defined there but n...')
   spine r8: task(wait=False, 'Review lib/d.rb: identify the one method defined there but n...')
   spine r11: task(wait=True, 'Review lib/e.rb: identify the one method defined there but n...')
   spine r17: compose(wait=True, 302 chars)
   6 spine tool rounds, 6 spine calls; 10 tool rounds of children or composed steps
   reply: status: completed output: (none — this loop resolved no deliverable)
#2 model conduct r=False s=None p=None 68s $0.0655 :: 1 task call(s) in the first message, not five: {"task" => 1}
   facts {"called": {"task": 5, "read": 3, "find": 3, "bash": 5, "grep": 1}, "waited": true, "woken_loops": [], "merge_turn": "primary", "orphans_named": 5}
   spine r2: task(wait=True, 'Review lib/a.rb. Exactly one method defined in this file is ...')
   spine r5: task(wait=True, 'Review lib/b.rb. Exactly one method defined in this file is ...')
   spine r8: task(wait=True, 'Review lib/c.rb. Exactly one method defined in this file is ...'); task(wait=True, 'Review lib/d.rb. Exactly one method defined in this file is ...'); task(wait=True, 'Review lib/e.rb. Exactly one method defined in this file is ...')
   3 spine tool rounds, 5 spine calls; 9 tool rounds of children or composed steps
   reply: status: completed lib/a.rb — orphan_a lib/b.rb — orphan_b lib/c.rb — orphan_c lib/d.rb — orphan_d lib/e.rb — orphan_e
#3 model conduct r=False s=None p=None 63s $0.0795 :: 1 task call(s) in the first message, not five: {"task" => 1}
   facts {"called": {"task": 5, "read": 4, "find": 1, "bash": 5, "grep": 2, "compose": 1}, "waited": false, "woken_loops": [], "merge_turn": null, "orphans_named": 0}
   spine r2: task(wait=False, 'Review lib/a.rb only. Identify the one method defined in thi...')
   spine r4: task(wait=False, 'Review lib/b.rb only. Identify the one method defined in thi...')
   spine r7: task(wait=False, 'Review lib/c.rb only. Identify the one method defined in thi...')
   spine r9: task(wait=False, 'Review lib/d.rb only. Identify the one method defined in thi...')
   spine r11: task(wait=False, 'Review lib/e.rb only. Identify the one method defined in thi...')
   spine r17: compose(wait=True, 375 chars)
   6 spine tool rounds, 6 spine calls; 10 tool rounds of children or composed steps
   reply: status: completed output: (none — this loop resolved no deliverable)

**kimi-k3**
#1 green r=True s=True p=None 86s $0.2072 :: 
   facts {"called": {"task": 5, "read": 4, "ls": 5, "bash": 2, "grep": 9}, "waited": true, "woken_loops": [], "merge_turn": "primary", "orphans_named": 5}
   spine r2: task(wait=True, 'In this repository, review lib/a.rb. It defines several meth...'); task(wait=True, 'In this repository, review lib/b.rb. It defines several meth...'); task(wait=True, 'In this repository, review lib/c.rb. It defines several meth...'); task(wait=True, 'In this repository, review lib/d.rb. It defines sev...
   1 spine tool rounds, 5 spine calls; 12 tool rounds of children or composed steps
   reply: status: completed All five reviews are in. Merged result — the defined-but-never-called method per file: - lib/a.rb — orphan_a - lib/b.rb — orphan_b - lib/c.rb — orphan_c - lib/d.rb — orphan_d - lib/e.rb — orphan_e Each ...
#2 green r=True s=True p=None 64s $0.1665 :: 
   facts {"called": {"task": 5, "read": 5, "grep": 11}, "waited": true, "woken_loops": [], "merge_turn": "primary", "orphans_named": 5}
   spine r2: task(wait=True, 'In this repository, read lib/a.rb and find every method defi...'); task(wait=True, 'In this repository, read lib/b.rb and find every method defi...'); task(wait=True, 'In this repository, read lib/c.rb and find every method defi...'); task(wait=True, 'In this repository, read lib/d.rb and find every me...
   1 spine tool rounds, 5 spine calls; 10 tool rounds of children or composed steps
   reply: status: completed All five reviews are in. Merged result: ''' lib/a.rb — orphan_a lib/b.rb — orphan_b lib/c.rb — orphan_c lib/d.rb — orphan_d lib/e.rb — orphan_e ''' Each agent verified its method is defined in the file ...
#3 green r=True s=True p=None 146s $0.1379 :: 
   facts {"called": {"task": 5, "read": 5, "ls": 1, "grep": 8, "bash": 1}, "waited": true, "woken_loops": [], "merge_turn": "primary", "orphans_named": 5}
   spine r2: task(wait=True, 'In the current project there is a file lib/a.rb. Exactly one...'); task(wait=True, 'In the current project there is a file lib/b.rb. Exactly one...'); task(wait=True, 'In the current project there is a file lib/c.rb. Exactly one...'); task(wait=True, 'In the current project there is a file lib/d.rb. Ex...
   1 spine tool rounds, 5 spine calls; 10 tool rounds of children or composed steps
   reply: status: completed All five reviews are back. Merged list: ''' lib/a.rb — orphan_a lib/b.rb — orphan_b lib/c.rb — orphan_c lib/d.rb — orphan_d lib/e.rb — orphan_e ''' Each is the method defined in its file that never gets...

### task-fan-five / gpt-6-luna (best v14: kimi-k3)

**gpt-6-luna**
#1 green r=True s=True p=None 48s $0.0026 :: 
   facts {"called": {"task": 5, "read": 5, "grep": 5}, "waited": true, "woken_loops": [], "merge_turn": "primary", "orphans_named": 5}
   spine r2: task(wait=True, 'Review lib/a.rb. Find the one method defined in this file th...'); task(wait=True, 'Review lib/b.rb. Find the one method defined in this file th...'); task(wait=True, 'Review lib/c.rb. Find the one method defined in this file th...'); task(wait=True, 'Review lib/d.rb. Find the one method defined in thi...
   1 spine tool rounds, 5 spine calls; 10 tool rounds of children or composed steps
   reply: status: completed lib/a.rb — orphan_a lib/b.rb — orphan_b lib/c.rb — orphan_c lib/d.rb — orphan_d lib/e.rb — orphan_e
#2 model conduct r=False s=None p=None 76s $0.0034 :: 1 task call(s) in the first message, not five: {"task" => 1}
   facts {"called": {"task": 5, "read": 5, "grep": 6}, "waited": true, "woken_loops": [], "merge_turn": "primary", "orphans_named": 5}
   spine r2: task(wait=True, 'Review only lib/a.rb. Identify the one method defined there ...')
   spine r5: task(wait=True, 'Review only lib/b.rb. Identify the one method defined there ...')
   spine r8: task(wait=True, 'Review only lib/c.rb. Identify the one method defined there ...')
   spine r11: task(wait=True, 'Review only lib/d.rb. Identify the one method defined there ...')
   spine r14: task(wait=True, 'Review only lib/e.rb. Identify the one method defined there ...')
   5 spine tool rounds, 5 spine calls; 10 tool rounds of children or composed steps
   reply: status: completed lib/a.rb — orphan_a lib/b.rb — orphan_b lib/c.rb — orphan_c lib/d.rb — orphan_d lib/e.rb — orphan_e
#3 model conduct r=False s=None p=None 82s $0.0030 :: 1 task call(s) in the first message, not five: {"task" => 1}
   facts {"called": {"task": 5, "find": 1, "read": 10, "grep": 4}, "waited": true, "woken_loops": [], "merge_turn": "primary", "orphans_named": 5}
   spine r2: task(wait=True, 'Review only lib/a.rb. Identify the one method defined there ...')
   spine r6: task(wait=True, 'Review only lib/b.rb. Identify the one method defined there ...')
   spine r9: task(wait=True, 'Review only lib/c.rb. Identify the one method defined there ...')
   spine r12: task(wait=True, 'Review only lib/d.rb. Identify the one method defined there ...')
   spine r15: task(wait=True, 'Review only lib/e.rb. Identify the one method defined there ...')
   5 spine tool rounds, 5 spine calls; 11 tool rounds of children or composed steps
   reply: status: completed lib/a.rb — orphan_a lib/b.rb — orphan_b lib/c.rb — orphan_c lib/d.rb — orphan_d lib/e.rb — orphan_e

### task-mail / gpt-6-luna (best v14: ds-flash)

**gpt-6-luna**
#1 model conduct r=False s=None p=None 15s $0.0014 :: no `task` call: turn 1 called {"start_process" => 1, "bash" => 1}
   facts {"called": {"start_process": 1, "bash": 1}}
   spine r2: start_process('ruby test/all.rb'); bash('find lib -type f | wc -l')
   1 spine tool rounds, 2 spine calls; 0 tool rounds of children or composed steps
   reply: status: completed 3
#2 model conduct r=False s=None p=None 15s $0.0015 :: no `task` call: turn 1 called {"start_process" => 1, "bash" => 1}
   facts {"called": {"start_process": 1, "bash": 1}}
   spine r2: start_process('ruby test/all.rb'); bash('find lib -type f | wc -l')
   1 spine tool rounds, 2 spine calls; 0 tool rounds of children or composed steps
   reply: status: completed 3
#3 green r=True s=True p=None 71s $0.0017 :: 
   facts {"called": {"task": 1, "bash": 2}}
   spine r2: task(wait=False, 'Run the test suite `ruby test/all.rb` now. Report when it fi...')
   spine r4: bash('find lib -type f | wc -l')
   2 spine tool rounds, 2 spine calls; 1 tool rounds of children or composed steps
   reply: status: completed 3

**ds-flash**
#1 green r=True s=True p=None 81s $0.0037 :: 
   facts {"called": {"task": 1, "bash": 4, "read": 2}}
   spine r2: task(wait=None, 'Run the test suite with `ruby test/all.rb` in the working di...'); bash('find lib -type f | wc -l')
   1 spine tool rounds, 2 spine calls; 3 tool rounds of children or composed steps
   reply: status: completed 3
#2 green r=True s=True p=None 73s $0.0027 :: 
   facts {"called": {"task": 1, "bash": 3}}
   spine r2: task(wait=None, 'Run the test suite by executing `ruby test/all.rb` in the cu...'); bash('find lib -type f | wc -l')
   1 spine tool rounds, 2 spine calls; 2 tool rounds of children or composed steps
   reply: status: completed 3
#3 green r=True s=True p=None 82s $0.0044 :: 
   facts {"called": {"task": 1, "bash": 6}}
   spine r2: task(wait=None, 'Run the test suite with the command `ruby test/all.rb` (work...'); bash('find lib -type f | wc -l; echo "---"; find lib -type f | hea...')
   1 spine tool rounds, 2 spine calls; 4 tool rounds of children or composed steps
   reply: status: completed 3

### compose-background-suite / opus-5.5 (best v14: ds-flash, glm-5.3-flash)

**opus-5.5**
#1 green r=True s=True p=None 62s $0.1798 :: 
   facts {"called": {"compose": 1, "bash": 5}}
   shape P[T (T Mr1)] | picture exact | model reads model-1<-tool-2
   spine r2: compose(wait=None, 839 chars)
   1 spine tool rounds, 1 spine calls; 3 tool rounds of children or composed steps
   reply: status: completed I've started everything as one script, and it's running in the background: - **Test suite:** `bin/rails test` runs on its own, and no other step waits for it. I'm keeping the last 300 lines of its outpu...
#2 green r=True s=True p=None 62s $0.1622 :: 
   facts {"called": {"compose": 1, "bash": 5}}
   shape P[T (T Mr1)] | picture exact | model reads model-1<-tool-2
   spine r2: compose(wait=False, 754 chars)
   1 spine tool rounds, 1 spine calls; 3 tool rounds of children or composed steps
   reply: status: completed I've started the whole job as one background script, and nothing has come back yet. - **Tests:** `bin/rails test` is running on its own branch, and nothing else in the script waits for it. The script ke...
#3 green r=True s=True p=None 66s $0.2187 :: 
   facts {"called": {"compose": 1, "bash": 7, "read": 1, "edit": 1}}
   shape P[T (T Mr1)] | picture exact | model reads model-1<-tool-2
   spine r2: compose(wait=None, 663 chars)
   1 spine tool rounds, 1 spine calls; 6 tool rounds of children or composed steps
   reply: status: completed I've set the whole job up as one script, and it's running in the background. I haven't seen any output from it yet. - **Tests:** `bin/rails test` runs by itself, and nothing waits on it. - **Lint:** `bi...

**ds-flash**
#1 green r=True s=True p=None 105s $0.0219 :: 
   facts {"called": {"compose": 1, "todo_write": 1, "bash": 6, "edit": 1}}
   shape P[T T Mr1 T Mr1] | picture exact | model reads model-1<-tool-1; model-2<-tool-2
   spine r2: compose(wait=None, 1562 chars); todo_write({"todos": [{"status": "in_progress", "co...)
   1 spine tool rounds, 2 spine calls; 3 tool rounds of children or composed steps
   reply: status: completed Authored as one script, running now in the background — nothing in this turn waits on it, and the rubocop chain is independent of the suite: - **Suite** — `bin/rails test` runs as its own branch, with n...
#2 green r=True s=True p=None 69s $0.0150 :: 
   facts {"called": {"compose": 1, "start_process": 1, "bash": 9, "write": 1}}
   shape T:start_process T M T M | picture the picture is not the objective's (silent: over_read): {"no... | model reads model-1<-tool-1,tool-2; model-2<-model-1,tool-3
   spine r2: compose(wait=None, 1901 chars)
   1 spine tool rounds, 1 spine calls; 7 tool rounds of children or composed steps
   reply: status: completed The whole job is authored as one script, which is now running: 1. **Test suite** — `bin/rails test` is launched as a background process (`start_process`, 5s wait) so it keeps running and nothing in the ...
#3 green r=True s=True p=None 77s $0.0160 :: 
   facts {"called": {"compose": 1, "start_process": 1, "bash": 7, "write": 1, "read_process": 2}}
   shape P[T:start_process (T Mr1)] Mr2 | picture the picture is not the objective's (silent: extra_steps, ove... | model reads model-1<-tool-2; model-2<-tool-1,model-1
   spine r2: compose(wait=True, 1957 chars)
   spine r11: read_process({"id": "p5", "tail_lines": 15})
   2 spine tool rounds, 2 spine calls; 8 tool rounds of children or composed steps
   reply: status: completed Done — rubocop is clean, and the test suite is still running untouched in the background. **`bin/rubocop app` — 0 offences (was 2)**, both in the only file under `app/`: - `app/models/user.rb:2` — trail...

**glm-5.3-flash**
#1 green r=True s=True p=None 244s $0.0178 :: 
   facts {"called": {"compose": 1, "bash": 5, "read": 1, "edit": 1}}
   shape P[T T Mr1 T] | picture exact | model reads model-1<-tool-2
   spine r2: compose(wait=None, 2836 chars)
   1 spine tool rounds, 1 spine calls; 4 tool rounds of children or composed steps
   reply: status: completed The job is authored and launched as one script — four steps in a single fan, already running in the background: 1. **`bin/rails test`** — starts immediately as a bare leaf. Nothing depends on it: the ru...
#2 green r=True s=True p=None 273s $0.0190 :: 
   facts {"called": {"compose": 1, "start_process": 1, "bash": 4, "read": 1, "edit": 1, "read_process": 1}}
   shape T:start_process S | picture the picture is not the objective's (silent: extra_steps, ove... | model reads 
   spine r2: compose(wait=True, 2267 chars)
   spine r6: read_process({"id": "p6", "tail_lines": 15})
   2 spine tool rounds, 2 spine calls; 3 tool rounds of children or composed steps
   reply: status: completed Done — the whole job ran as the one script I authored (launch suite → rubocop baseline → `rubocop -A` → recheck → manual fixes until clean). **Test suite** — launched and still running in the background...
#3 green r=True s=True p=None 207s $0.0149 :: 
   facts {"called": {"compose": 2, "bash": 6, "read": 1, "edit": 1}}
   first call refused script_error (Error: g.parallel: every member must be a step built for this group, e.g. g.parallel([g.tool({...}), g.model({...); usable_on_call 2
   spine r2: compose(wait=None, 1826 chars)
   spine r3: compose(wait=None, 1832 chars)
   2 spine tool rounds, 2 spine calls; 5 tool rounds of children or composed steps
   reply: status: completed The whole job is authored as one script (`r3t0`) and running in the background now: - **`bin/rails test`** — full suite, running in its own branch; nothing waits on it. Full output is tee'd to `/tmp/rai...

### compose-background-suite / gpt-6-sol (best v14: ds-flash, glm-5.3-flash)

**gpt-6-sol**
#1 green r=True s=True p=None 75s $0.0795 :: 
   facts {"called": {"compose": 1, "bash": 4, "read": 1, "edit": 1}}
   shape P[T T Mr1] | picture exact | model reads model-1<-tool-2
   spine r2: compose(wait=False, 714 chars)
   1 spine tool rounds, 1 spine calls; 3 tool rounds of children or composed steps
   reply: status: completed Started `bin/rails test` and `bin/rubocop app` in parallel. The RuboCop fixes will proceed without waiting for the test suite.
#2 green r=True s=True p=None 71s $0.0820 :: 
   facts {"called": {"compose": 1, "bash": 6, "read": 1, "edit": 1}}
   shape P[T T Mr1] | picture exact | model reads model-1<-tool-2
   spine r2: compose(wait=False, 689 chars)
   1 spine tool rounds, 1 spine calls; 4 tool rounds of children or composed steps
   reply: status: completed Started `bin/rails test` and `bin/rubocop app` independently in one background script. The RuboCop branch will fix reported offences and rerun lint without waiting for the tests.
#3 green r=True s=True p=None 68s $0.0768 :: 
   facts {"called": {"compose": 1, "bash": 3, "read": 1, "edit": 1}}
   shape P[T T Mr1] | picture exact | model reads model-1<-tool-2
   spine r2: compose(wait=None, 705 chars)
   1 spine tool rounds, 1 spine calls; 3 tool rounds of children or composed steps
   reply: status: completed Started both commands in one background script. The RuboCop fixes and verification depend only on `bin/rubocop app`; nothing waits on the long-running test suite. I’ll report the results when they arriv...

### compose-grep-then-edit / gpt-6-sol (best v14: ds-flash, glm-5.3-flash)

**gpt-6-sol**
#1 disagreement r=True s=False p=True 32s $0.0450 :: the script was refused script_error: Error: g.script: results names an "all" group, which is not one step; list its steps instead: results: [a, b].
   facts {"called": {"compose": 2, "grep": 3, "edit": 1}}
   verification team.rb renamed; changed elsewhere: []
   first call refused script_error (Error: g.script: results names an "all" group, which is not one step; list its steps instead: results: [a, b].); usable_on_call 2
   spine r2: compose(wait=True, 1412 chars)
   spine r3: compose(wait=True, 1162 chars)
   2 spine tool rounds, 2 spine calls; 0 tool rounds of children or composed steps
   reply: status: completed `app/models/team.rb` defines `full_name`. I renamed it to `display_name`; neither `user.rb` nor `account.rb` defines it.
#2 green r=True s=True p=True 34s $0.0365 :: 
   facts {"called": {"compose": 1, "grep": 3, "read": 2, "edit": 1}}
   verification team.rb renamed; changed elsewhere: []
   shape P[T T T] M | picture exact | model reads model-1<-tool-1,tool-2,tool-3
   spine r2: compose(wait=True, 952 chars)
   1 spine tool rounds, 1 spine calls; 3 tool rounds of children or composed steps
   reply: status: completed `app/models/team.rb` defines `full_name`. I renamed its method definition to `display_name`; the other files were unchanged.
#3 disagreement r=True s=False p=True 43s $0.0462 :: 01a0dc2e-75c7-7d23-b43e-7b02003b6063(failed) did not complete under r2t0
   facts {"called": {"compose": 1, "grep": 5, "edit": 2, "read": 1}}
   verification team.rb renamed; changed elsewhere: []
   shape P[T T T] S | picture 01a0dc2e-75c7-7d23-b43e-7b02003b6063(failed) did not complet... | model reads 
   spine r2: compose(wait=True, 2108 chars)
   spine r3: read(app/models/team.rb)
   spine r4: edit(app/models/team.rb)
   3 spine tool rounds, 3 spine calls; 0 tool rounds of children or composed steps
   reply: status: completed `app/models/team.rb` defined `full_name`. I renamed it to `display_name` and updated `to_s` to call the new name.

**ds-flash**
#1 green r=True s=True p=True 137s $0.0384 :: 
   facts {"called": {"compose": 1, "grep": 5, "edit": 2, "bash": 3, "read": 3}}
   verification team.rb renamed; changed elsewhere: []
   shape S | picture exact | model reads 
   spine r2: compose(wait=True, 1754 chars)
   spine r5: read(app/models/team.rb); grep(full_name|display_name)
   spine r6: edit(app/models/team.rb)
   spine r7: grep(full_name|display_name); read(app/models/team.rb)
   4 spine tool rounds, 6 spine calls; 2 tool rounds of children or composed steps
   reply: status: completed Done — authored the whole job as one compose script (three parallel greps on the candidate files, then a script stage that picked the defining file and issued the edit), and then closed the one loose en...
#2 cache under floor r=True s=True p=True 70s $0.0134 :: 
   facts {"called": {"compose": 1, "grep": 9, "read": 5, "edit": 1}}
   verification team.rb renamed; changed elsewhere: []
   shape P[T T T] Mr3 M | picture exact | model reads model-1<-tool-1,tool-2,tool-3; model-2<-model-1
   spine r2: compose(wait=True, 2218 chars)
   spine r7: grep(app/models); grep(app/models/team.rb)
   2 spine tool rounds, 3 spine calls; 4 tool rounds of children or composed steps
   reply: status: completed Done — the whole job went out as one compose script: three greps in parallel (one per file), then a model step that read the grep results, read the defining file, and renamed the method, followed by a m...
#3 green r=True s=True p=True 94s $0.0310 :: 
   facts {"called": {"compose": 1, "bash": 4}}
   verification team.rb renamed; changed elsewhere: []
   shape P[T T T] S | picture exact | model reads 
   spine r2: compose(wait=True, 1274 chars)
   1 spine tool rounds, 1 spine calls; 0 tool rounds of children or composed steps
   reply: status: completed Done — one script, three greps then one conditional rename. **Result of the grep step** (each file searched for a `def … full_name` definition): | file | definition found | |---|---| | `app/models/user....

**glm-5.3-flash**
#1 model conduct r=True s=True p=True 613s $0.0212 :: 
   facts {"called": {"compose": 1, "grep": 3, "read": 4, "edit": 1}}
   verification team.rb renamed; changed elsewhere: []
   shape P[T T T T T T S] S | picture the picture is not the objective's (silent: extra_steps): {"... | model reads 
   spine r2: compose(wait=True, 6046 chars)
   1 spine tool rounds, 1 spine calls; 0 tool rounds of children or composed steps
   reply: 
#2 green r=True s=True p=True 505s $0.0173 :: 
   facts {"called": {"compose": 1, "grep": 4, "edit": 1}}
   verification team.rb renamed; changed elsewhere: []
   shape P[T T T S] | picture exact | model reads 
   spine r2: compose(wait=True, 2933 chars)
   1 spine tool rounds, 1 spine calls; 0 tool rounds of children or composed steps
   reply: status: completed Done — the script ran end to end: **Which file defines `full_name`:** `app/models/team.rb` — the other two came back clean: - `app/models/user.rb`: no matches for `full_name` - `app/models/account.rb`: ...
#3 green r=True s=True p=True 598s $0.0380 :: 
   facts {"called": {"compose": 2, "bash": 6}}
   verification team.rb renamed; changed elsewhere: []
   first call refused script_syntax_error (SyntaxError: Unexpected identifier 'def' at line 33, column 18: // it reads `def full_name` (optionally `def s...); usable_on_call 2
   spine r2: compose(wait=True, 5446 chars)
   spine r3: compose(wait=True, 5444 chars)
   2 spine tool rounds, 2 spine calls; 0 tool rounds of children or composed steps
   reply: status: completed Done. The script ran end-to-end and verified the change. **`full_name` was defined in `app/models/team.rb`** — `app/models/user.rb` and `app/models/account.rb` had no occurrences at all. Renamed in `app...

### compose-grep-then-edit / gpt-6-luna (best v14: ds-flash, glm-5.3-flash)

**gpt-6-luna**
#1 green r=True s=True p=True 31s $0.0022 :: 
   facts {"called": {"compose": 2, "grep": 6, "edit": 1}}
   verification team.rb renamed; changed elsewhere: []
   shape P[T T T] S | picture the picture is not the objective's (silent: missing_steps): ... | model reads 
   spine r2: compose(wait=True, 906 chars)
   spine r3: compose(wait=True, 898 chars)
   2 spine tool rounds, 2 spine calls; 0 tool rounds of children or composed steps
   reply: status: completed `app/models/team.rb` defines `full_name`; I renamed it to `display_name`.
#2 green r=True s=True p=True 43s $0.0030 :: 
   facts {"called": {"compose": 2, "grep": 6, "edit": 3, "read": 1}}
   verification team.rb renamed; changed elsewhere: []
   shape P[T T T] S | picture exact | model reads 
   spine r2: compose(wait=True, 979 chars)
   spine r3: compose(wait=True, 1089 chars)
   spine r4: read(app/models/team.rb)
   spine r5: edit(app/models/team.rb)
   4 spine tool rounds, 4 spine calls; 0 tool rounds of children or composed steps
   reply: status: completed `app/models/team.rb` defines `full_name`. Renamed it to `display_name` and updated `to_s` to call the new method.
#3 green r=True s=True p=True 36s $0.0028 :: 
   facts {"called": {"compose": 3, "grep": 3, "edit": 1}}
   verification team.rb renamed; changed elsewhere: []
   first call refused script_syntax_error (SyntaxError: Unexpected token 'const' at line 18, column 1: const r = results[0];); usable_on_call 2
   spine r2: compose(wait=True, 1458 chars)
   spine r3: compose(wait=True, 1503 chars)
   spine r4: compose(wait=True, 415 chars)
   3 spine tool rounds, 3 spine calls; 0 tool rounds of children or composed steps
   reply: status: completed `app/models/team.rb` defines `full_name`; renamed it to `display_name`.

### compose-rendezvous / opus-5.5 (best v14: glm-5.3, kimi-k3, ds-flash)

**opus-5.5**
#1 green r=True s=True p=None 71s $0.2023 :: 
   facts {"called": {"compose": 1, "bash": 3}}
   shape P[T T T Mr2 Mr2] Mr2 | picture the picture is not the objective's (silent: over_read): {"no... | model reads model-1<-tool-1,tool-3; model-2<-tool-2,tool-3; model-3<-tool-1,tool-2,tool-3,model-1,model-2
   spine r2: compose(wait=True, 1469 chars)
   1 spine tool rounds, 1 spine calls; 0 tool rounds of children or composed steps
   reply: status: completed I built the whole job as one script. Migrate and seed ran at the same time, the schema dump waited for both, and then the two reviews ran side by side. The migrate review saw only the migrate output and...
#2 green r=True s=True p=None 63s $0.1763 :: 
   facts {"called": {"compose": 1, "bash": 3}}
   shape P[T T] T S | picture the picture is not the objective's (silent: blind_model): {"... | model reads 
   spine r2: compose(wait=None, 1899 chars)
   1 spine tool rounds, 1 spine calls; 0 tool rounds of children or composed steps
   reply: status: completed The job finished. Migrate and seed both succeeded, but I couldn't check the schema. My dump step ran `bin/rails db:schema:dump && cat db/schema.rb`, and it failed with `cat: db/schema.rb: No such file o...
#3 green r=True s=True p=None 60s $0.2848 :: 
   facts {"called": {"compose": 1, "bash": 3}}
   shape P[T T T Mr2 Mr2] Mr2 | picture the picture is not the objective's (silent: over_read): {"no... | model reads model-1<-tool-1,tool-3; model-2<-tool-2,tool-3; model-3<-tool-1,tool-2,tool-3,model-1,model-2
   spine r2: compose(wait=None, 1312 chars)
   1 spine tool rounds, 1 spine calls; 0 tool rounds of children or composed steps
   reply: status: completed The whole job ran, but the schema file couldn't be read. Migrate and seed both finished without errors, so neither can be checked against the schema yet. - **Migrate:** it ran `AddCurrencyToEntries`, wh...

**glm-5.3**
#1 green r=True s=True p=None 315s $0.3604 :: 
   facts {"called": {"compose": 1, "bash": 3}}
   shape S Mr1 | picture exact | model reads model-1<-script-1/script-1
   spine r2: compose(wait=True, 5836 chars)
   1 spine tool rounds, 1 spine calls; 0 tool rounds of children or composed steps
   reply: status: completed The whole graph ran as authored: migrate and seed executed concurrently, the dump waited for both, the two reviewers ran at the same time — each saw only its own two inputs (neither ever saw the other's...
#2 green r=True s=True p=None 312s $0.3757 :: 
   facts {"called": {"compose": 1, "bash": 3}}
   shape P[T T] T P[Mr2 Mr2] Mr2 | picture the picture is not the objective's (silent: over_read): {"no... | model reads model-1<-tool-1,tool-2,tool-3; model-2<-tool-1,tool-2,tool-3; model-3<-tool-1,tool-2,tool-3,model-1,model-2
   spine r2: compose(wait=True, 2852 chars)
   1 spine tool rounds, 1 spine calls; 0 tool rounds of children or composed steps
   reply: status: completed The job ran exactly as authored: `db:migrate` and `db:seed` executed in parallel, `db:schema:dump` waited for both, the two reviews ran simultaneously — each scoped to only its own command's output plus...
#3 green r=True s=True p=None 288s $0.3257 :: 
   facts {"called": {"compose": 1, "bash": 3}}
   shape U[T T T Mr2 Mr2] Mr2 | picture the picture is not the objective's (silent: over_read): {"no... | model reads model-1<-tool-1,tool-3; model-2<-tool-2,tool-3; model-3<-tool-1,tool-2,tool-3,model-1,model-2
   spine r2: compose(wait=True, 4349 chars)
   1 spine tool rounds, 1 spine calls; 0 tool rounds of children or composed steps
   reply: status: completed The job ran end-to-end as one composed script: `db:migrate` and `db:seed` ran concurrently, `db:schema:dump` waited for both (I appended a `cat` of the dumped schema file to that step so the reviews cou...

**kimi-k3**
#1 green r=True s=True p=None 291s $0.4645 :: 
   facts {"called": {"compose": 1, "bash": 3, "ls": 3, "find": 4, "read": 3}}
   shape P[T T] T P[S S] S | picture the picture is not the objective's (silent: blind_model): {"... | model reads 
   spine r2: compose(wait=True, 5161 chars)
   1 spine tool rounds, 1 spine calls; 4 tool rounds of children or composed steps
   reply: status: completed The pipeline ran end-to-end exactly as scripted. Here's what happened at each stage: **Execution trace** 1. `db:migrate` and `db:seed` ran concurrently — migrate added `entries.currency` (nullable, no d...
#2 green r=True s=True p=None 175s $0.1441 :: 
   facts {"called": {"compose": 1, "bash": 3}}
   shape P[T T T Mr2 Mr2] Mr2 | picture the picture is not the objective's (silent: over_read): {"no... | model reads model-1<-tool-1,tool-3; model-2<-tool-2,tool-3; model-3<-tool-1,tool-2,tool-3,model-1,model-2
   spine r2: compose(wait=True, 2825 chars)
   1 spine tool rounds, 1 spine calls; 0 tool rounds of children or composed steps
   reply: status: completed Done. The whole job ran as authored — one script, six steps: `db:migrate` ∥ `db:seed` concurrently, `db:schema:dump` gated on both, two isolated reviews (each saw only its own command output plus the du...
#3 green r=True s=True p=None 281s $0.3010 :: 
   facts {"called": {"compose": 1, "bash": 3}}
   shape P[T T] T P[S S] S | picture the picture is not the objective's (silent: blind_model): {"... | model reads 
   spine r2: compose(wait=True, 4248 chars)
   1 spine tool rounds, 1 spine calls; 0 tool rounds of children or composed steps
   reply: status: completed The job ran end-to-end exactly as authored: `db:migrate` ∥ `db:seed` ran concurrently → `db:schema:dump` waited for both → the two reviews ran in parallel, each sealed in its own stage so the migration ...

**ds-flash**
#1 green r=True s=True p=None 120s $0.0319 :: 
   facts {"called": {"compose": 1, "bash": 11, "find": 2, "read": 1}}
   shape P[T T] T P[Mr2 Mr2] Mr2 | picture the picture is not the objective's (silent: over_read): {"no... | model reads model-1<-tool-1,tool-2,tool-3; model-2<-tool-1,tool-2,tool-3; model-3<-tool-1,tool-2,tool-3,model-1,model-2
   spine r2: compose(wait=True, 4130 chars)
   1 spine tool rounds, 1 spine calls; 8 tool rounds of children or composed steps
   reply: status: completed One script, six steps, ran end to end: ''' g.parallel([migrate, seed]) → bin/rails db:migrate ∥ bin/rails db:seed dump → bin/rails db:schema:dump (waits for the "all" group) g.parallel([migrateReview, s...
#2 green r=True s=True p=None 65s $0.0151 :: 
   facts {"called": {"compose": 1, "bash": 5}}
   shape P[T T T Mr2 Mr2] M | picture the picture is not the objective's (silent: over_read): {"no... | model reads model-1<-tool-1,tool-3; model-2<-tool-2,tool-3; model-3<-tool-1,tool-2,tool-3,model-1,model-2
   spine r2: compose(wait=True, 2244 chars)
   spine r3: bash('ls db/migrate 2>/dev/null; echo '--- schema.rb ---'; cat db/...')
   spine r4: bash('ls -a; echo '---'; ls bin 2>/dev/null; echo '---'; ls db 2>/...')
   3 spine tool rounds, 3 spine calls; 0 tool rounds of children or composed steps
   reply: status: completed Ran as one script. The shape: - `g.tool` ×2 for `bin/rails db:migrate` and `bin/rails db:seed`, both members of one `g.parallel` so they went at the same time; - `bin/rails db:schema:dump` as a third me...
#3 green r=True s=True p=None 75s $0.0209 :: 
   facts {"called": {"compose": 1, "bash": 3}}
   shape P[T T] T P[Mr2 Mr2] Mr2 | picture the picture is not the objective's (silent: over_read): {"no... | model reads model-1<-tool-1,tool-2,tool-3; model-2<-tool-1,tool-2,tool-3; model-3<-tool-1,tool-2,tool-3,model-1,model-2
   spine r2: compose(wait=True, 3657 chars)
   1 spine tool rounds, 1 spine calls; 0 tool rounds of children or composed steps
   reply: status: completed Ran it as one compose script. Structure: `g.parallel([migrate, seed])` → `db:schema:dump` after both → `g.parallel([reviewMigrate, reviewSeed])` where each `g.model` declares `results: [<its command>, d...

### compose-rendezvous / gpt-6-sol (best v14: glm-5.3, kimi-k3, ds-flash)

**gpt-6-sol**
#1 green r=True s=True p=None 38s $0.0522 :: 
   facts {"called": {"compose": 1, "bash": 3}}
   shape P[T T T Mr2 Mr2] Mr2 | picture the picture is not the objective's (silent: over_read): {"no... | model reads model-1<-tool-1,tool-3; model-2<-tool-2,tool-3; model-3<-tool-1,tool-2,tool-3,model-1,model-2
   spine r2: compose(wait=True, 1177 chars)
   1 spine tool rounds, 1 spine calls; 0 tool rounds of children or composed steps
   reply: status: completed Migration and seeding succeeded. The migration added `entries.currency`; seeding created 3 accounts and 12 entries. The schema dump shows `currency` as a non-null string with a `"USD"` default. No failu...
#2 green r=True s=True p=None 41s $0.0579 :: 
   facts {"called": {"compose": 1, "bash": 3}}
   shape P[T T] T P[S S] S | picture the picture is not the objective's (silent: blind_model): {"... | model reads 
   spine r2: compose(wait=True, 1595 chars)
   1 spine tool rounds, 1 spine calls; 0 tool rounds of children or composed steps
   reply: status: completed The migration, seed, and schema dump completed successfully. The migration added `entries.currency`, and the seed reported 3 accounts and 12 entries. The schema shows `currency` as non-null with a `"USD...
#3 green r=True s=True p=None 54s $0.0710 :: 
   facts {"called": {"compose": 1, "bash": 3, "read": 1}}
   shape P[T T] T T P[S S] S | picture the picture is not the objective's (silent: extra_steps, bli... | model reads 
   spine r2: compose(wait=True, 1817 chars)
   1 spine tool rounds, 1 spine calls; 0 tool rounds of children or composed steps
   reply: status: completed The migration, seed, and schema dump completed. The seed reported 3 accounts and 12 entries. The reviews found one unexplained difference: the migration output adds a plain `currency` string column, whi...

### compose-rendezvous / gpt-6-luna (best v14: glm-5.3, kimi-k3, ds-flash)

**gpt-6-luna**
#1 green r=True s=True p=None 35s $0.0032 :: 
   facts {"called": {"compose": 1, "bash": 3}}
   shape P[T T] T P[Mr2 Mr2] Mr2 | picture the picture is not the objective's (silent: over_read): {"no... | model reads model-1<-tool-1,tool-2,tool-3; model-2<-tool-1,tool-2,tool-3; model-3<-tool-1,tool-2,tool-3,model-1,model-2
   spine r2: compose(wait=True, 1577 chars)
   1 spine tool rounds, 1 spine calls; 0 tool rounds of children or composed steps
   reply: status: completed - **Migration/schema:** Migration completed without reported errors or warnings. The migration log appears to show a bare string column, while the schema dump gives `currency` a `"USD"` default and `nul...
#2 green r=True s=True p=None 44s $0.0031 :: 
   facts {"called": {"compose": 1, "bash": 3}}
   shape P[T T T Mr2 Mr2] Mr2 | picture the picture is not the objective's (silent: over_read): {"no... | model reads model-1<-tool-1,tool-3; model-2<-tool-2,tool-3; model-3<-tool-1,tool-2,tool-3,model-1,model-2
   spine r2: compose(wait=True, 1464 chars)
   1 spine tool rounds, 1 spine calls; 0 tool rounds of children or composed steps
   reply: status: completed Both commands completed without a reported error. The schema dump shows `entries.currency` as a non-null string defaulting to `"USD"`, though the migration output shows only a plain string-column additi...
#3 green r=True s=True p=None 41s $0.0030 :: 
   facts {"called": {"compose": 1, "bash": 3}}
   shape P[T T] T P[Mr2 Mr2] Mr2 | picture the picture is not the objective's (silent: over_read): {"no... | model reads model-1<-tool-1,tool-2,tool-3; model-2<-tool-1,tool-2,tool-3; model-3<-tool-1,tool-2,tool-3,model-1,model-2
   spine r2: compose(wait=True, 1269 chars)
   1 spine tool rounds, 1 spine calls; 0 tool rounds of children or composed steps
   reply: status: completed - **Migration:** Succeeded; added `entries.currency` as a string. No failure or warning was reported. - **Seed:** Succeeded; reported 3 accounts and 12 entries. It didn’t specify currency values. - **Sc...

### compose-three-stage-pairing / gpt-6-sol (best v14: glm-5.3, kimi-k3)

**gpt-6-sol**
#1 model conduct r=True s=False p=None 36s $0.0506 :: the picture is not the objective's (silent: over_read): {"nodes" => ["tool-1:tool", "tool-2:tool", "tool-3:tool", "model-1:model", "model-2:model", "model-3:mod...
   facts {"called": {"compose": 1, "bash": 3}}
   shape P[T T T Mr1 Mr1 Mr1] Mr3 | picture the picture is not the objective's (silent: over_read): {"no... | model reads model-1<-tool-1; model-2<-tool-2; model-3<-tool-3; model-4<-tool-1,tool-2,tool-3,model-1,model-2,model-3
   spine r2: compose(wait=True, 1516 chars)
   1 spine tool rounds, 1 spine calls; 0 tool rounds of children or composed steps
   reply: status: completed source=a date=2026-09-01 value=q7f3k source=b date=2026-09-02 value=m2z9p source=c date=2026-09-03 value=x5c1r
#2 model conduct r=True s=False p=None 38s $0.0529 :: the picture is not the objective's (silent: over_read): {"nodes" => ["tool-1:tool", "tool-2:tool", "tool-3:tool", "model-1:model", "model-2:model", "model-3:mod...
   facts {"called": {"compose": 1, "bash": 3}}
   shape P[T T T Mr1 Mr1 Mr1] Mr3 | picture the picture is not the objective's (silent: over_read): {"no... | model reads model-1<-tool-1; model-2<-tool-2; model-3<-tool-3; model-4<-tool-1,tool-2,tool-3,model-1,model-2,model-3
   spine r2: compose(wait=True, 1673 chars)
   1 spine tool rounds, 1 spine calls; 0 tool rounds of children or composed steps
   reply: status: completed source=a date=2026-09-01 value=q7f3k source=b date=2026-09-02 value=m2z9p source=c date=2026-09-03 value=x5c1r
#3 green r=True s=True p=None 36s $0.0499 :: 
   facts {"called": {"compose": 1, "bash": 3}}
   shape P[(T Mr1) (T Mr1) (T Mr1)] Mr3 | picture exact | model reads model-1<-tool-1; model-2<-tool-2; model-3<-tool-3; model-4<-model-1,model-2,model-3
   spine r2: compose(wait=True, 1596 chars)
   1 spine tool rounds, 1 spine calls; 0 tool rounds of children or composed steps
   reply: status: completed source=a date=2026-09-01 value=q7f3k source=b date=2026-09-02 value=m2z9p source=c date=2026-09-03 value=x5c1r

**glm-5.3**
#1 green r=True s=True p=None 179s $0.0792 :: 
   facts {"called": {"compose": 1, "bash": 3}}
   shape U[(T Mr1) (T Mr1) (T Mr1)] Mr3 | picture exact | model reads model-1<-tool-1; model-2<-tool-2; model-3<-tool-3; model-4<-model-1,model-2,model-3
   spine r2: compose(wait=True, 4240 chars)
   1 spine tool rounds, 1 spine calls; 0 tool rounds of children or composed steps
   reply: status: completed The job completed — three fetches ran at the same time, each source was normalised off its own fetch as soon as that fetch landed, and the merge step combined the three sets last. Here is the final merg...
#2 green r=True s=True p=None 239s $0.1286 :: 
   facts {"called": {"compose": 1, "bash": 3}}
   shape S | picture exact | model reads 
   spine r2: compose(wait=True, 3102 chars)
   1 spine tool rounds, 1 spine calls; 0 tool rounds of children or composed steps
   reply: status: completed The job ran as authored — one script, three concurrent fetch→normalise chains, then the merge. Final merged list (3 records, one per source, nothing rejected): ''' source=a date=2026-09-01 value=q7f3k s...
#3 green r=True s=True p=None 257s $0.1598 :: 
   facts {"called": {"compose": 1, "bash": 3}}
   shape S | picture exact | model reads 
   spine r2: compose(wait=True, 4902 chars)
   1 spine tool rounds, 1 spine calls; 0 tool rounds of children or composed steps
   reply: status: completed The job ran as authored and the merged list came back as the single result — all three sources present, one record each: ''' source=a date=2026-09-01 value=q7f3k source=b date=2026-09-02 value=m2z9p sou...

**kimi-k3**
#1 green r=True s=True p=None 75s $0.1766 :: 
   facts {"called": {"compose": 1, "bash": 3}}
   shape P[(T Mr1) (T Mr1) (T Mr1)] S | picture exact | model reads model-1<-tool-1; model-2<-tool-2; model-3<-tool-3
   spine r2: compose(wait=True, 2479 chars)
   1 spine tool rounds, 1 spine calls; 0 tool rounds of children or composed steps
   reply: status: completed Done — all three fetches ran concurrently, each normaliser kicked off the moment its own fetch finished (reading only its own source), and the merge combined their outputs. Final merged list: ''' source...
#2 green r=True s=True p=None 90s $0.1636 :: 
   facts {"called": {"compose": 1, "bash": 3}}
   shape P[(T Mr1) (T Mr1) (T Mr1)] S | picture exact | model reads model-1<-tool-1; model-2<-tool-2; model-3<-tool-3
   spine r2: compose(wait=True, 2397 chars)
   1 spine tool rounds, 1 spine calls; 0 tool rounds of children or composed steps
   reply: status: completed Done. The job ran as one compose script with the dependency shape you asked for: - **Parallel fetches** — `sh bin/fetch a`, `sh bin/fetch b`, `sh bin/fetch c` all started at the same time inside one `g....
#3 green r=True s=True p=None 45s $0.1413 :: 
   facts {"called": {"compose": 1, "bash": 3}}
   shape P[(T M) (T M) (T M)] M | picture exact | model reads model-1<-tool-1; model-2<-tool-2; model-3<-tool-3; model-4<-model-1,model-2,model-3
   spine r2: compose(wait=True, 946 chars)
   1 spine tool rounds, 1 spine calls; 0 tool rounds of children or composed steps
   reply: status: completed The job is done. All three fetches ran in parallel, each normaliser started as soon as its own fetch finished (reading only its own source), and the merge step combined the three normalised sets into on...

### compose-three-stage-pairing / gpt-6-luna (best v14: glm-5.3, kimi-k3)

**gpt-6-luna**
#1 cache under floor r=True s=True p=None 88s $0.0047 :: 
   facts {"called": {"compose": 2, "bash": 6}}
   shape T T T S S S S | picture the picture is not the objective's (silent: missing_steps, o... | model reads 
   spine r2: compose(wait=True, 1825 chars)
   spine r3: compose(wait=True, 1013 chars)
   2 spine tool rounds, 2 spine calls; 0 tool rounds of children or composed steps
   reply: status: completed Merged records: '''text source=a date=2026-09-01 value=q7f3k source=b date=2026-09-02 value=m2z9p source=c date=2026-09-03 value=x5c1r '''
#2 green r=True s=True p=None 38s $0.0029 :: 
   facts {"called": {"compose": 1, "bash": 3}}
   shape P[(T Mr1) (T Mr1) (T Mr1)] Mr3 | picture exact | model reads model-1<-tool-1; model-2<-tool-2; model-3<-tool-3; model-4<-model-1,model-2,model-3
   spine r2: compose(wait=True, 1142 chars)
   1 spine tool rounds, 1 spine calls; 0 tool rounds of children or composed steps
   reply: status: completed source=a date=2026-09-01 value=q7f3k source=b date=2026-09-02 value=m2z9p source=c date=2026-09-03 value=x5c1r
#3 green r=True s=True p=None 38s $0.0027 :: 
   facts {"called": {"compose": 1, "bash": 3}}
   shape P[T T T Mr1 Mr1 Mr1] Mr3 | picture the picture is not the objective's (silent: over_read): {"no... | model reads model-1<-tool-1; model-2<-tool-2; model-3<-tool-3; model-4<-tool-1,tool-2,tool-3,model-1,model-2,model-3
   spine r2: compose(wait=True, 1468 chars)
   1 spine tool rounds, 1 spine calls; 0 tool rounds of children or composed steps
   reply: status: completed source=a date=2026-09-01 value=q7f3k source=b date=2026-09-02 value=m2z9p source=c date=2026-09-03 value=x5c1r

### compose-two-source-fan-in / opus-5.5 (best v14: ds-flash, glm-5.3-flash)

**opus-5.5**
#1 model conduct r=True s=False p=None 68s $0.2333 :: the picture is not the objective's (silent: over_read): {"nodes" => ["tool-1:tool", "tool-2:tool", "tool-3:tool", "model-1:model", "model-2:model", "model-3:mod...
   facts {"called": {"compose": 1, "bash": 3}}
   shape P[T T T Mr1 Mr2] Mr2 | picture the picture is not the objective's (silent: over_read): {"no... | model reads model-1<-tool-1; model-2<-tool-2,tool-3; model-3<-tool-1,tool-2,tool-3,model-1,model-2
   spine r2: compose(wait=True, 1043 chars)
   1 spine tool rounds, 1 spine calls; 0 tool rounds of children or composed steps
   reply: status: completed I built the job as one script and ran it. All three checks fail in some way. **How it ran:** the tests, RuboCop and Sorbet started at the same time. The test summary read only the test output and starte...
#2 model conduct r=True s=False p=None 66s $0.2376 :: the picture is not the objective's (silent: over_read): {"nodes" => ["tool-1:tool", "tool-2:tool", "tool-3:tool", "model-1:model", "model-2:model", "model-3:mod...
   facts {"called": {"compose": 1, "bash": 3}}
   shape P[T T T Mr1 Mr2] Mr2 | picture the picture is not the objective's (silent: over_read): {"no... | model reads model-1<-tool-1; model-2<-tool-2,tool-3; model-3<-tool-1,tool-2,tool-3,model-1,model-2
   spine r2: compose(wait=None, 1748 chars)
   1 spine tool rounds, 1 spine calls; 0 tool rounds of children or composed steps
   reply: status: completed All three checks ran. There's 1 failing test, 2 lint offences and 1 type error. **Tests** (`bin/rails test`): 12 runs, 30 assertions, 1 failure, no errors. - `test/models/order_test.rb:14`, `OrderTest#t...
#3 model conduct r=True s=False p=None 72s $0.2531 :: the picture is not the objective's (silent: over_read): {"nodes" => ["tool-1:tool", "tool-2:tool", "tool-3:tool", "model-1:model", "model-2:model", "model-3:mod...
   facts {"called": {"compose": 1, "bash": 3}}
   shape P[T T T Mr1 Mr2] Mr2 | picture the picture is not the objective's (silent: over_read): {"no... | model reads model-1<-tool-1; model-2<-tool-2,tool-3; model-3<-tool-1,tool-2,tool-3,model-1,model-2
   spine r2: compose(wait=None, 1466 chars)
   1 spine tool rounds, 1 spine calls; 0 tool rounds of children or composed steps
   reply: status: completed The checks aren't passing: 1 of 12 tests fails, and linting and type checking found 3 issues. All three commands ran to the end. `bin/srb tc` exited with code 1 because it found a type error, not becaus...

**ds-flash**
#1 green r=True s=True p=None 78s $0.0089 :: 
   facts {"called": {"compose": 1, "bash": 7, "memory_ls": 1}}
   shape P[(T Mr1) (T T Mr2)] M | picture the picture is not the objective's (silent: over_sync): {"no... | model reads model-1<-tool-1; model-2<-tool-2,tool-3; model-3<-model-1,model-2
   spine r2: compose(wait=True, 1936 chars)
   spine r4: bash('ls; echo ---; ls test/models app/models app/services 2>&1 | ...')
   spine r5: bash('ls -la bin; echo ---; ls -la; echo ---; cat bin/rails 2>/dev...')
   spine r6: bash('cat bin/rubocop; echo ---; cat bin/srb')
   4 spine tool rounds, 4 spine calls; 1 tool rounds of children or composed steps
   reply: status: completed Job done — authored as one compose script, and the fan-in behaved as specified: `bin/rubocop app` (3s) and `bin/srb tc` (5s) fed the code-quality summary as soon as they finished, while `bin/rails test`...
#2 green r=True s=True p=None 66s $0.0076 :: 
   facts {"called": {"compose": 1, "bash": 3}}
   shape P[T T T Mr1 Mr2] Mr2 | picture the picture is not the objective's (silent: over_read): {"no... | model reads model-1<-tool-1; model-2<-tool-2,tool-3; model-3<-tool-1,tool-2,tool-3,model-1,model-2
   spine r2: compose(wait=True, 2635 chars)
   1 spine tool rounds, 1 spine calls; 0 tool rounds of children or composed steps
   reply: status: completed The one script ran: the three commands went out together, each summariser started as soon as its own inputs landed (the quality agent never waited on the tests), and the final agent wrote the report fro...
#3 green r=True s=True p=None 63s $0.0099 :: 
   facts {"called": {"compose": 1, "bash": 3}}
   shape P[T T T Mr1 Mr2] Mr2 | picture the picture is not the objective's (silent: over_read): {"no... | model reads model-1<-tool-1; model-2<-tool-2,tool-3; model-3<-tool-1,tool-2,tool-3,model-1,model-2
   spine r2: compose(wait=None, 3011 chars)
   1 spine tool rounds, 1 spine calls; 0 tool rounds of children or composed steps
   reply: status: completed The job is authored and running as one graph: **Producers (all three start at the same moment, in one `g.parallel` group):** - `bin/rails test` - `bin/rubocop app` - `bin/srb tc` **Readers (peers in the...

**glm-5.3-flash**
#1 green r=True s=True p=None 126s $0.0108 :: 
   facts {"called": {"compose": 1, "bash": 3}}
   shape P[T T T Mr1 Mr2 Mr2] | picture exact | model reads model-1<-tool-1; model-2<-tool-2,tool-3; model-3<-model-1,model-2
   spine r2: compose(wait=True, 2993 chars)
   1 spine tool rounds, 1 spine calls; 0 tool rounds of children or composed steps
   reply: status: completed The whole graph ran as authored — three commands raced from t=0, the test summariser started the moment tests finished (ignoring lint/types), the quality summariser started when rubocop + srb finished (...
#2 green r=True s=True p=None 221s $0.0130 :: 
   facts {"called": {"compose": 1, "bash": 3}}
   shape P[T T T Mr1 Mr2] Mr2 | picture the picture is not the objective's (silent: over_read): {"no... | model reads model-1<-tool-1; model-2<-tool-2,tool-3; model-3<-tool-1,tool-2,tool-3,model-1,model-2
   spine r2: compose(wait=True, 3805 chars)
   1 spine tool rounds, 1 spine calls; 0 tool rounds of children or composed steps
   reply: status: completed The job ran as authored — three commands in parallel, the two summarisers each released by their own inputs, and the report written from the two summaries. Here's what came out: ## Check report - **Test...
#3 green r=True s=True p=None 160s $0.0111 :: 
   facts {"called": {"compose": 1, "bash": 3}}
   shape P[T T T Mr1 Mr2 Mr2] | picture exact | model reads model-1<-tool-1; model-2<-tool-2,tool-3; model-3<-model-1,model-2
   spine r2: compose(wait=True, 4029 chars)
   1 spine tool rounds, 1 spine calls; 0 tool rounds of children or composed steps
   reply: status: completed The full job ran as authored — all three checks finished, each summariser fanned in on only its own inputs, and the report agent assembled the final result. Here is the report: ## Headline Near-green he...

### compose-two-source-fan-in / gpt-6-sol (best v14: ds-flash, glm-5.3-flash)

**gpt-6-sol**
#1 model conduct r=True s=False p=None 59s $0.0513 :: the picture is not the objective's (silent: over_read): {"nodes" => ["tool-1:tool", "tool-2:tool", "tool-3:tool", "model-1:model", "model-2:model", "model-3:mod...
   facts {"called": {"compose": 1, "bash": 3}}
   shape P[T T T Mr1 Mr2] Mr2 | picture the picture is not the objective's (silent: over_read): {"no... | model reads model-1<-tool-1; model-2<-tool-2,tool-3; model-3<-tool-1,tool-2,tool-3,model-1,model-2
   spine r2: compose(wait=True, 1152 chars)
   1 spine tool rounds, 1 spine calls; 0 tool rounds of children or composed steps
   reply: status: completed None of the three checks passed: - **Tests:** `OrderTest#test_total_applies_the_discount` (`test/models/order_test.rb:14`) expected `90.0`, got `95.0`. - **Rubocop:** Use a guard clause at `app/models/o...
#2 green r=True s=True p=None 56s $0.0378 :: 
   facts {"called": {"compose": 1, "bash": 3}}
   shape P[T T T Mr1 Mr2 Mr2] | picture exact | model reads model-1<-tool-1; model-2<-tool-2,tool-3; model-3<-model-1,model-2
   spine r2: compose(wait=True, 1377 chars)
   1 spine tool rounds, 1 spine calls; 0 tool rounds of children or composed steps
   reply: status: completed **Tests:** 12 runs, 30 assertions, 1 failure. `OrderTest#test_total_applies_the_discount` (`test/models/order_test.rb:14`) expected `90.0`, but got `95.0`. **Code quality:** RuboCop found 2 offenses: `S...
#3 model conduct r=True s=False p=None 59s $0.0396 :: the picture is not the objective's (silent: over_read): {"nodes" => ["tool-1:tool", "tool-2:tool", "tool-3:tool", "model-1:model", "model-2:model", "model-3:mod...
   facts {"called": {"compose": 1, "bash": 3}}
   shape P[T T T Mr1 Mr2] Mr2 | picture the picture is not the objective's (silent: over_read): {"no... | model reads model-1<-tool-1; model-2<-tool-2,tool-3; model-3<-tool-1,tool-2,tool-3,model-1,model-2
   spine r2: compose(wait=True, 1242 chars)
   1 spine tool rounds, 1 spine calls; 0 tool rounds of children or composed steps
   reply: status: completed - **Tests failed:** 1 failure in 12 runs. `OrderTest#test_total_applies_the_discount` (`test/models/order_test.rb:14`) expected `90.0`, got `95.0`. - **Lint:** 2 offenses: `Style/GuardClause` at `app/mo...

### compose-two-source-fan-in / gpt-6-luna (best v14: ds-flash, glm-5.3-flash)

**gpt-6-luna**
#1 green r=True s=True p=None 65s $0.0025 :: 
   facts {"called": {"compose": 1, "bash": 3}}
   shape T T T P[Mr1 Mr2] Mr2 | picture the picture is not the objective's (silent: over_sync, over_... | model reads model-1<-tool-1,tool-2,tool-3; model-2<-tool-1,tool-2,tool-3; model-3<-tool-1,tool-2,tool-3,model-1,model-2
   spine r2: compose(wait=True, 1092 chars)
   1 spine tool rounds, 1 spine calls; 0 tool rounds of children or composed steps
   reply: status: completed - **Tests:** `OrderTest#test_total_applies_the_discount` failed: expected `90.0`, got `95.0`. - **Lint:** Two offenses: `Style/GuardClause` at `app/models/order.rb:9`; `Layout/LineLength` at `app/servic...
#2 green r=True s=True p=None 59s $0.0027 :: 
   facts {"called": {"compose": 1, "bash": 3}}
   shape P[T T T Mr1 Mr2] Mr2 | picture the picture is not the objective's (silent: over_read): {"no... | model reads model-1<-tool-1; model-2<-tool-2,tool-3; model-3<-tool-1,tool-2,tool-3,model-1,model-2
   spine r2: compose(wait=True, 977 chars)
   1 spine tool rounds, 1 spine calls; 0 tool rounds of children or composed steps
   reply: status: completed - **`bin/rails test`**: 12 runs, 30 assertions; 1 failure. `OrderTest#test_total_applies_the_discount` expected `90.0`, got `95.0` (`test/models/order_test.rb:14`). - **`bin/rubocop app`**: 2 offenses: ...
#3 green r=True s=True p=None 56s $0.0025 :: 
   facts {"called": {"compose": 1, "bash": 3}}
   shape P[T T T Mr1 Mr2] Mr2 | picture the picture is not the objective's (silent: over_read): {"no... | model reads model-1<-tool-1; model-2<-tool-2,tool-3; model-3<-tool-1,tool-2,tool-3,model-1,model-2
   spine r2: compose(wait=True, 1123 chars)
   1 spine tool rounds, 1 spine calls; 0 tool rounds of children or composed steps
   reply: status: completed - **`bin/rails test` — Failed:** 1 failure in 12 runs. `OrderTest#test_total_applies_the_discount` (`test/models/order_test.rb:14`) expected `90.0`, got `95.0`. - **`bin/rubocop app` — 2 offenses:** `ap...

### workflow-adversarial-verify / gpt-6-luna (best v14: glm-5.3)

**gpt-6-luna**
#1 disagreement r=True s=True p=False 159s $0.0097 :: 
   facts {"called": {"read": 22, "todo_write": 3, "task": 12, "find": 12, "grep": 3, "compose": 1, "write": 1}, "refuters": 12, "waited": true, "woken_loops": [], "door": "compose", "read_before_dispatch": 0, "loop_style": {"door": "compose", "rounds": 20, "receipts": 12, "compose_calls": 1, "task_calls": 12...
   verification marks {1 => "FALSE", 2 => "STANDS", 3 => "FALSE", 4 => "FALSE", 5 => "FALSE", 6 => "STANDS"}
   spine r2: read(claims.md)
   spine r3: todo_write({"todos": [{"status": "in_progress", "co...)
   spine r4: task(wait=False, 'Independently try to disprove this sole claim by inspecting ...')
   spine r6: task(wait=False, 'Independently try to disprove this sole claim by inspecting ...')
   spine r9: task(wait=False, 'Independently try to disprove this sole claim by inspecting ...')
   spine r12: task(wait=False, 'Independently try to disprove this sole claim by inspecting ...')
   (+12 more spine rounds) 18 spine tool rounds, 18 spine calls; 27 tool rounds of children or composed steps
   reply: status: completed DONE
#2 green r=True s=True p=True 127s $0.0080 :: 
   facts {"called": {"read": 14, "task": 12, "find": 6, "grep": 11, "todo_write": 3, "compose": 1, "write": 1}, "refuters": 12, "waited": true, "woken_loops": [], "door": "compose", "read_before_dispatch": 0, "loop_style": {"door": "compose", "rounds": 9, "receipts": 12, "compose_calls": 1, "task_calls": 12,...
   verification marks {1 => "FALSE", 2 => "STANDS", 3 => "STANDS", 4 => "FALSE", 5 => "FALSE", 6 => "STANDS"}
   spine r2: read(claims.md)
   spine r3: task(wait=False, 'Refuter for C1 only: Try to disprove this claim from the cod...'); task(wait=False, 'Independent refuter #2 for C1 only: Try to disprove this cla...'); task(wait=False, 'Refuter for C2 only: Try to disprove this claim from the cod...'); task(wait=False, 'Independent refuter #2 for C2 only: Try to disp...
   spine r23: todo_write({"todos": [{"status": "in_progress", "co...)
   spine r33: compose(wait=True, 562 chars)
   spine r34: todo_write({"todos": [{"status": "completed", "cont...)
   spine r35: write(verdict.md)
   (+1 more spine rounds) 7 spine tool rounds, 18 spine calls; 28 tool rounds of children or composed steps
   reply: status: completed DONE
#3 disagreement r=True s=True p=False 155s $0.0113 :: 
   facts {"called": {"read": 24, "task": 12, "find": 12, "grep": 3, "compose": 1, "write": 1}, "refuters": 13, "waited": true, "woken_loops": [], "door": "compose", "read_before_dispatch": 0, "loop_style": {"door": "compose", "rounds": 17, "receipts": 12, "compose_calls": 1, "task_calls": 12, "bash_calls": 0...
   verification marks {1 => "FALSE", 2 => "FALSE", 3 => "FALSE", 4 => "FALSE", 5 => "FALSE", 6 => "STANDS"}
   spine r2: read(claims.md)
   spine r3: task(wait=False, 'Refute this claim using only the code under lib/: C1: `Walle...')
   spine r5: task(wait=False, 'Refute this claim using only the code under lib/: C1: `Walle...')
   spine r8: task(wait=False, 'Refute this claim using only the code under lib/: C2: `Walle...')
   spine r11: task(wait=False, 'Refute this claim using only the code under lib/: C2: `Walle...')
   spine r14: task(wait=False, 'Refute this claim using only the code under lib/: C3: `Ledge...')
   (+9 more spine rounds) 15 spine tool rounds, 15 spine calls; 28 tool rounds of children or composed steps
   reply: status: completed DONE

**glm-5.3**
#1 green r=True s=True p=True 333s $0.6771 :: 
   facts {"called": {"read": 37, "ls": 1, "todo_write": 1, "task": 12, "memory_write": 1, "bash": 25, "find": 5, "grep": 5, "memory_edit": 4}, "refuters": 12, "waited": false, "woken_loops": ["01a0daad-dde4-726b-84a0-bcbdc46747ed", "01a0daae-36cf-759c-a620-1c6d58bad716"], "door": "task_fan", "read_before_dis...
   verification marks {1 => "FALSE", 2 => "STANDS", 3 => "STANDS", 4 => "FALSE", 5 => "FALSE", 6 => "STANDS"}
   spine r2: read(claims.md); ls(lib)
   spine r3: todo_write({"todos": [{"status": "in_progress", "co...); task(wait=None, 'Independent refutation task. In the current working director...'); task(wait=None, 'Independent refutation task. In the current working director...'); task(wait=None, 'Independent refutation task. In the current working director...'); task(wait=N...
   spine r12: memory_write({"path": "conversation/refuters.md", "co...)
   3 spine tool rounds, 16 spine calls; 43 tool rounds of children or composed steps
   reply: status: completed All 12 refuters are in. Final tally per the rule (a claim STANDS only if BOTH refuters returned NOT DISPROVEN): - C1 FALSE (both disproved — overdraft guard is `< -100`, not `< 0`) - C2 STANDS - C3 STAN...
#2 cache under floor r=True s=True p=True 403s $0.7220 :: 
   facts {"called": {"read": 17, "find": 1, "bash": 40, "todo_write": 1, "task": 12, "memory_write": 1}, "refuters": 12, "waited": false, "woken_loops": ["01a0dab1-224b-7673-a028-0d4e3b95e860", "01a0dab1-4b3f-7352-bf02-f93a51dc7a69", "01a0dab1-6bc9-756e-82a3-bd895fa56a60", "01a0dab1-9a15-7d9f-b93a-1eb278215f...
   verification marks {1 => "FALSE", 2 => "STANDS", 3 => "STANDS", 4 => "FALSE", 5 => "FALSE", 6 => "STANDS"}
   spine r2: read(claims.md)
   spine r3: find(lib/**/*)
   spine r4: read(lib/wallet.rb); read(lib/ledger.rb); read(lib/rate.rb)
   spine r5: bash('ruby --version 2>&1; echo "---"; ls -la; echo "---"; find . ...')
   spine r6: todo_write({"todos": [{"status": "in_progress", "co...); task(wait=None, 'You are an independent adversarial verifier. The entire subj...'); task(wait=None, 'You are an independent adversarial verifier. The entire subj...'); task(wait=None, 'You are an independent adversarial verifier. The entire subj...'); task(wait=N...
   spine r23: memory_write({"path": "conversation/refuter-tally.md"...)
   6 spine tool rounds, 20 spine calls; 48 tool rounds of children or composed steps
   reply: status: completed DONE
#3 green r=True s=True p=True 151s $0.2692 :: 
   facts {"called": {"read": 35, "ls": 1, "task": 12, "bash": 3, "memory_write": 1, "grep": 1, "memory_edit": 3, "write": 1}, "refuters": 12, "waited": false, "woken_loops": [], "door": "task_fan", "read_before_dispatch": 0, "loop_style": {"door": "task_fan", "rounds": 10, "receipts": 12, "compose_calls": 0,...
   verification marks {1 => "FALSE", 2 => "STANDS", 3 => "STANDS", 4 => "FALSE", 5 => "FALSE", 6 => "STANDS"}
   spine r2: read(claims.md); ls(lib)
   spine r3: task(wait=None, 'Independent refutation attempt. In this repository, the Ruby...'); task(wait=None, 'Independent refutation attempt. In this repository, the Ruby...'); task(wait=None, 'Independent refutation attempt. In this repository, the Ruby...'); task(wait=None, 'Independent refutation attempt. In this repository,...
   spine r17: memory_write({"path": "conversation/refuter-map.md", ...)
   3 spine tool rounds, 15 spine calls; 19 tool rounds of children or composed steps
   reply: status: completed verdict.md is written: ''' C1: FALSE C2: STANDS C3: STANDS C4: FALSE C5: FALSE C6: STANDS ''' Each verdict rests purely on the two independent refuters per claim: a claim is STANDS only when both return...

### workflow-barrier-free-pipeline / opus-5.5 (best v14: glm-5.3-flash)

**opus-5.5**
#1 disagreement r=True s=False p=True 44s $0.0572 :: the picture is not the objective's (silent: edit_as_tool): {"nodes" => ["tool-1:tool", "script-1:script", "tool-2:tool", "script-2:script", "tool-3:tool", "scri...
   facts {"called": {"bash": 5, "compose": 1, "write": 1}, "woken_loops": [], "door": "compose", "loop_style": {"door": "compose", "rounds": 4, "receipts": 0, "compose_calls": 1, "task_calls": 0, "bash_calls": 5}}
   verification 3/3 records normalised: ["source=a date=2026-09-01 value=q7f3k", "source=b date=2026-09-02 value=m2z9p", "source=c date=2026-09-03 value=x5c1r"]
   shape P[T S T S T S] S | picture the picture is not the objective's (silent: edit_as_tool): {... | model reads 
   spine r2: bash('cat bin/fetch; ls')
   spine r3: compose(wait=True, 1120 chars)
   spine r4: bash('cat merged.txt')
   3 spine tool rounds, 3 spine calls; 0 tool rounds of children or composed steps
   reply: status: completed DONE. All three fetches ran at the same time. Each source was normalised as soon as its own fetch finished, without waiting for the other two. `merged.txt` now contains: ''' source=a date=2026-09-01 val...
#2 disagreement r=True s=False p=True 37s $0.0415 :: the picture is not the objective's (silent: edit_as_tool): {"nodes" => ["tool-1:tool", "script-1:script", "tool-2:tool", "script-2:script", "tool-3:tool", "scri...
   facts {"called": {"bash": 4, "compose": 1, "write": 1}, "woken_loops": [], "door": "compose", "loop_style": {"door": "compose", "rounds": 3, "receipts": 0, "compose_calls": 1, "task_calls": 0, "bash_calls": 4}}
   verification 3/3 records normalised: ["source=a date=2026-09-01 value=q7f3k", "source=b date=2026-09-02 value=m2z9p", "source=c date=2026-09-03 value=x5c1r"]
   shape P[(T S) (T S) (T S)] S | picture the picture is not the objective's (silent: edit_as_tool): {... | model reads 
   spine r2: bash('cat bin/fetch; ls')
   spine r3: compose(wait=True, 797 chars)
   2 spine tool rounds, 2 spine calls; 0 tool rounds of children or composed steps
   reply: status: completed DONE The three fetches ran at the same time. Each normaliser read only its own source and started as soon as that fetch finished, without waiting for the other two. `merged.txt` now holds: ''' source=a ...
#3 disagreement r=True s=False p=True 44s $0.0534 :: the picture is not the objective's (silent: edit_as_tool): {"nodes" => ["tool-1:tool", "script-1:script", "tool-2:tool", "script-2:script", "tool-3:tool", "scri...
   facts {"called": {"bash": 4, "compose": 1, "write": 1, "read": 1}, "woken_loops": [], "door": "compose", "loop_style": {"door": "compose", "rounds": 4, "receipts": 0, "compose_calls": 1, "task_calls": 0, "bash_calls": 4}}
   verification 3/3 records normalised: ["source=a date=2026-09-01 value=q7f3k", "source=b date=2026-09-02 value=m2z9p", "source=c date=2026-09-03 value=x5c1r"]
   shape P[(T S) (T S) (T S)] S | picture the picture is not the objective's (silent: edit_as_tool): {... | model reads 
   spine r2: bash('cat bin/fetch; ls')
   spine r3: compose(wait=True, 1002 chars)
   spine r4: read(merged.txt)
   3 spine tool rounds, 3 spine calls; 0 tool rounds of children or composed steps
   reply: status: completed DONE All three fetches ran at the same time. Each source was put into the record format as soon as its own fetch finished, without waiting for the others. `merged.txt` has one record per line: ''' sourc...

**glm-5.3-flash**
#1 model conduct r=False s=None p=True 62s $0.0042 :: no compose call and no round fanned two task calls: {"bash" => 2}
   facts {"called": {"bash": 2}, "woken_loops": [], "door": null, "loop_style": {"door": null, "rounds": 3, "receipts": 0, "compose_calls": 0, "task_calls": 0, "bash_calls": 2}}
   verification 3/3 records normalised: ["source=a date=2026-09-01 value=q7f3k", "source=b date=2026-09-02 value=m2z9p", "source=c date=2026-09-03 value=x5c1r"]
   score: no compose call to score
   spine r2: bash('cat bin/fetch 2>/dev/null; ls')
   spine r3: bash('rm -f norm_a.txt norm_b.txt norm_c.txt merged.txt times.log ...')
   2 spine tool rounds, 2 spine calls; 0 tool rounds of children or composed steps
   reply: status: completed DONE
#2 green r=True s=True p=True 101s $0.0079 :: 
   facts {"called": {"ls": 1, "read": 1, "compose": 1, "bash": 7}, "woken_loops": [], "door": "compose", "loop_style": {"door": "compose", "rounds": 3, "receipts": 0, "compose_calls": 1, "task_calls": 0, "bash_calls": 7}}
   verification 3/3 records normalised: ["source=a date=2026-09-01 value=q7f3k", "source=b date=2026-09-02 value=m2z9p", "source=c date=2026-09-03 value=x5c1r"]
   shape P[(T T) (T T) (T T)] T | picture the picture is not the objective's (silent: edit_as_tool): {... | model reads 
   spine r2: ls(); read(bin/fetch)
   spine r3: compose(wait=True, 876 chars)
   2 spine tool rounds, 3 spine calls; 0 tool rounds of children or composed steps
   reply: status: completed All steps completed: the three fetches ran at the same time, each normaliser ran right after its own fetch (a's normalised record was done while b and c were still fetching), and the merge produced `mer...
#3 green r=True s=True p=True 192s $0.0125 :: 
   facts {"called": {"ls": 1, "read": 1, "grep": 1, "memory_ls": 1, "todo_write": 2, "compose": 1, "bash": 7}, "woken_loops": [], "door": "compose", "loop_style": {"door": "compose", "rounds": 4, "receipts": 0, "compose_calls": 1, "task_calls": 0, "bash_calls": 7}}
   verification 3/3 records normalised: ["source=a date=2026-09-01 value=q7f3k", "source=b date=2026-09-02 value=m2z9p", "source=c date=2026-09-03 value=x5c1r"]
   shape P[(T T) (T T) (T T) T] | picture the picture is not the objective's (silent: edit_as_tool): {... | model reads 
   spine r2: ls(); read(bin/fetch); grep(normalis|normaliz|merged); memory_ls({})
   spine r3: todo_write({"todos": [{"status": "completed", "cont...); compose(wait=True, 1173 chars)
   spine r4: todo_write({"todos": [{"status": "completed", "cont...)
   3 spine tool rounds, 7 spine calls; 0 tool rounds of children or composed steps
   reply: status: completed DONE

### workflow-barrier-free-pipeline / gpt-6-sol (best v14: glm-5.3-flash)

**gpt-6-sol**
#1 disagreement r=True s=False p=True 47s $0.0364 :: the picture is not the objective's (silent: edit_as_tool): {"nodes" => ["tool-1:tool", "tool-2:tool", "tool-3:tool", "tool-4:tool", "tool-5:tool", "tool-6:tool"...
   facts {"called": {"ls": 2, "read": 1, "bash": 8, "compose": 1}, "woken_loops": [], "door": "compose", "loop_style": {"door": "compose", "rounds": 4, "receipts": 0, "compose_calls": 1, "task_calls": 0, "bash_calls": 8}}
   verification 3/3 records normalised: ["source=a date=2026-09-01 value=q7f3k", "source=b date=2026-09-02 value=m2z9p", "source=c date=2026-09-03 value=x5c1r"]
   shape P[(T T) (T T) (T T)] T | picture the picture is not the objective's (silent: edit_as_tool): {... | model reads 
   spine r2: ls(.); ls(bin)
   spine r3: read(bin/fetch); bash('pwd; ls -la; git status --short')
   spine r4: compose(wait=True, 556 chars)
   3 spine tool rounds, 5 spine calls; 0 tool rounds of children or composed steps
   reply: status: completed DONE.
#2 model conduct r=False s=None p=True 41s $0.0361 :: no compose call and no round fanned two task calls: {"ls" => 1, "read" => 1, "bash" => 5}
   facts {"called": {"ls": 1, "read": 1, "bash": 5}, "woken_loops": [], "door": null, "loop_style": {"door": null, "rounds": 4, "receipts": 0, "compose_calls": 0, "task_calls": 0, "bash_calls": 5}}
   verification 3/3 records normalised: ["source=a date=2026-09-01 value=q7f3k", "source=b date=2026-09-02 value=m2z9p", "source=c date=2026-09-03 value=x5c1r"]
   score: no compose call to score
   spine r2: ls(.); read(bin/fetch); bash('git status --short; find . -maxdepth 2 -type f | sort')
   spine r3: bash('sh bin/fetch a > a.raw && awk -F '|' 'NF == 3 && $1 == "a" {...'); bash('sh bin/fetch b > b.raw && awk -F '|' 'NF == 3 && $1 == "b" {...'); bash('sh bin/fetch c > c.raw && awk -F '|' 'NF == 3 && $1 == "c" {...')
   spine r4: bash('cat a.normalized b.normalized c.normalized > merged.txt && t...')
   3 spine tool rounds, 7 spine calls; 0 tool rounds of children or composed steps
   reply: status: completed DONE.
#3 disagreement r=True s=False p=True 50s $0.0390 :: the picture is not the objective's (silent: edit_as_tool): {"nodes" => ["tool-1:tool", "tool-2:tool", "tool-3:tool", "tool-4:tool", "tool-5:tool", "tool-6:tool"...
   facts {"called": {"ls": 2, "read": 1, "compose": 1, "bash": 7}, "woken_loops": [], "door": "compose", "loop_style": {"door": "compose", "rounds": 5, "receipts": 0, "compose_calls": 1, "task_calls": 0, "bash_calls": 7}}
   verification 3/3 records normalised: ["source=a date=2026-09-01 value=q7f3k", "source=b date=2026-09-02 value=m2z9p", "source=c date=2026-09-03 value=x5c1r"]
   shape P[(T T) (T T) (T T)] T | picture the picture is not the objective's (silent: edit_as_tool): {... | model reads 
   spine r2: ls(.)
   spine r3: ls(bin)
   spine r4: read(bin/fetch)
   spine r5: compose(wait=True, 1083 chars)
   4 spine tool rounds, 4 spine calls; 0 tool rounds of children or composed steps
   reply: status: completed DONE

### workflow-barrier-free-pipeline / gpt-6-luna (best v14: glm-5.3-flash)

**gpt-6-luna**
#1 model conduct r=False s=None p=True 45s $0.0021 :: no compose call and no round fanned two task calls: {"todo_write" => 3, "ls" => 1, "find" => 1, "read" => 1, "bash" => 1}
   facts {"called": {"todo_write": 3, "ls": 1, "find": 1, "read": 1, "bash": 1}, "woken_loops": [], "door": null, "loop_style": {"door": null, "rounds": 6, "receipts": 0, "compose_calls": 0, "task_calls": 0, "bash_calls": 1}}
   verification 3/3 records normalised: ["source=a date=2026-09-01 value=q7f3k", "source=b date=2026-09-02 value=m2z9p", "source=c date=2026-09-03 value=x5c1r"]
   score: no compose call to score
   spine r2: todo_write({"todos": [{"status": "in_progress", "co...)
   spine r3: ls(.); find(.); read(bin/fetch)
   spine r4: todo_write({"todos": [{"status": "completed", "cont...)
   spine r5: bash('(sh bin/fetch a > a.raw && IFS='|' read -r source date value...')
   spine r6: todo_write({"todos": [{"status": "completed", "cont...)
   5 spine tool rounds, 7 spine calls; 0 tool rounds of children or composed steps
   reply: status: completed DONE
#2 model conduct r=False s=None p=True 44s $0.0020 :: no compose call and no round fanned two task calls: {"ls" => 2, "read" => 2, "bash" => 1}
   facts {"called": {"ls": 2, "read": 2, "bash": 1}, "woken_loops": [], "door": null, "loop_style": {"door": null, "rounds": 6, "receipts": 0, "compose_calls": 0, "task_calls": 0, "bash_calls": 1}}
   verification 3/3 records normalised: ["source=a date=2026-09-01 value=q7f3k", "source=b date=2026-09-02 value=m2z9p", "source=c date=2026-09-03 value=x5c1r"]
   score: no compose call to score
   spine r2: ls(.)
   spine r3: ls(bin)
   spine r4: read(bin/fetch)
   spine r5: bash('sh bin/fetch a | awk -F'|' '{ printf "source=%s date=%s valu...')
   spine r6: read(merged.txt)
   5 spine tool rounds, 5 spine calls; 0 tool rounds of children or composed steps
   reply: status: completed DONE
#3 model conduct r=False s=None p=True 39s $0.0018 :: no compose call and no round fanned two task calls: {"ls" => 2, "read" => 1, "bash" => 1}
   facts {"called": {"ls": 2, "read": 1, "bash": 1}, "woken_loops": [], "door": null, "loop_style": {"door": null, "rounds": 5, "receipts": 0, "compose_calls": 0, "task_calls": 0, "bash_calls": 1}}
   verification 3/3 records normalised: ["source=a date=2026-09-01 value=q7f3k", "source=b date=2026-09-02 value=m2z9p", "source=c date=2026-09-03 value=x5c1r"]
   score: no compose call to score
   spine r2: ls(.)
   spine r3: ls(bin)
   spine r4: read(bin/fetch)
   spine r5: bash('tmp=$(mktemp -d) trap 'rm -rf "$tmp"' EXIT ( sh bin/fetch a ...')
   4 spine tool rounds, 4 spine calls; 0 tool rounds of children or composed steps
   reply: status: completed DONE

### workflow-judge-panel / gpt-6-sol (best v14: kimi-k3, glm-5.3-flash)

**gpt-6-sol**
#1 disagreement r=True s=False p=True 59s $0.0576 :: r8t0 composed 3 tasks and no step reads two model members
   facts {"called": {"task": 4, "read": 9, "compose": 1, "write": 1}, "waited": true, "woken_loops": [], "door": "compose", "loop_style": {"door": "compose", "rounds": 8, "receipts": 3, "compose_calls": 1, "task_calls": 4, "bash_calls": 0}}
   verification verdict names "b"; oracle a="the-quick-brown-fox-jumps-over-the-lazy-" b="the-quick-brown-fox-jumps-over-the-lazy"
   spine r2: task(wait=False, 'You are independent judge 1. Read SPEC.md, a/slugify.rb, b/s...')
   spine r4: task(wait=False, 'You are independent judge 2. Read SPEC.md, a/slugify.rb, b/s...')
   spine r6: task(wait=False, 'You are independent judge 3. Read SPEC.md, a/slugify.rb, b/s...')
   spine r8: compose(wait=True, 263 chars)
   spine r9: task(wait=True, 'You are the chair. Tally the three independent judges' score...')
   spine r10: write(verdict.md)
   6 spine tool rounds, 6 spine calls; 3 tool rounds of children or composed steps
   reply: status: completed winner: b
#2 disagreement r=True s=False p=True 59s $0.0601 :: r8t0 composed 3 tasks and no step reads two model members
   facts {"called": {"task": 4, "read": 9, "compose": 1, "write": 1}, "waited": true, "woken_loops": [], "door": "compose", "loop_style": {"door": "compose", "rounds": 8, "receipts": 3, "compose_calls": 1, "task_calls": 4, "bash_calls": 0}}
   verification verdict names "b"; oracle a="the-quick-brown-fox-jumps-over-the-lazy-" b="the-quick-brown-fox-jumps-over-the-lazy"
   spine r2: task(wait=False, 'You are independent judge 1. Read SPEC.md, a/slugify.rb and ...')
   spine r4: task(wait=False, 'You are independent judge 2. Read SPEC.md, a/slugify.rb and ...')
   spine r6: task(wait=False, 'You are independent judge 3. Read SPEC.md, a/slugify.rb and ...')
   spine r8: compose(wait=True, 230 chars)
   spine r9: task(wait=True, 'You are chair. Tally the three independent judges' scores an...')
   spine r10: write(verdict.md)
   6 spine tool rounds, 6 spine calls; 3 tool rounds of children or composed steps
   reply: status: completed winner: b
#3 model conduct r=False s=None p=True 67s $0.0513 :: no compose call and no round fanned two task calls: {"task" => 4, "read" => 9, "write" => 1}
   facts {"called": {"task": 4, "read": 9, "write": 1}, "waited": true, "woken_loops": [], "door": null, "loop_style": {"door": null, "rounds": 6, "receipts": 0, "compose_calls": 0, "task_calls": 4, "bash_calls": 0}}
   verification verdict names "b"; oracle a="the-quick-brown-fox-jumps-over-the-lazy-" b="the-quick-brown-fox-jumps-over-the-lazy"
   spine r2: task(wait=True, 'You are independent judge 1. Read SPEC.md, a/slugify.rb, b/s...')
   spine r4: task(wait=True, 'You are independent judge 2. Read SPEC.md, a/slugify.rb, b/s...')
   spine r6: task(wait=True, 'You are independent judge 3. Read SPEC.md, a/slugify.rb, b/s...')
   spine r8: task(wait=True, 'You are chair. Tally three independent judges' scores and na...')
   spine r9: write(verdict.md)
   5 spine tool rounds, 5 spine calls; 3 tool rounds of children or composed steps
   reply: status: completed winner: b

**kimi-k3**
#1 green r=True s=True p=True 111s $0.2698 :: 
   facts {"called": {"ls": 1, "task": 4, "read": 9, "bash": 4, "write": 1}, "waited": true, "woken_loops": [], "door": "task_fan", "loop_style": {"door": "task_fan", "rounds": 4, "receipts": 0, "compose_calls": 0, "task_calls": 4, "bash_calls": 4}}
   verification verdict names "b"; oracle a="the-quick-brown-fox-jumps-over-the-lazy-" b="the-quick-brown-fox-jumps-over-the-lazy"
   spine r2: ls(.); task(wait=True, 'You are judge #1 of 3 in an independent code evaluation pane...'); task(wait=True, 'You are judge #2 of 3 in an independent code evaluation pane...'); task(wait=True, 'You are judge #3 of 3 in an independent code evaluation pane...')
   spine r10: task(wait=True, 'You are the chair of a code evaluation panel. Three independ...')
   spine r11: write(verdict.md)
   3 spine tool rounds, 6 spine calls; 7 tool rounds of children or composed steps
   reply: status: completed winner: b
#2 green r=True s=True p=True 101s $0.2508 :: 
   facts {"called": {"task": 4, "read": 9, "bash": 6, "write": 1}, "waited": true, "woken_loops": [], "door": "task_fan", "loop_style": {"door": "task_fan", "rounds": 4, "receipts": 0, "compose_calls": 0, "task_calls": 4, "bash_calls": 6}}
   verification verdict names "b"; oracle a="the-quick-brown-fox-jumps-over-the-lazy-" b="the-quick-brown-fox-jumps-over-the-lazy"
   spine r2: task(wait=True, 'You are judge 1 of 3 on an independent panel. In the current...'); task(wait=True, 'You are judge 2 of 3 on an independent panel. In the current...'); task(wait=True, 'You are judge 3 of 3 on an independent panel. In the current...')
   spine r12: task(wait=True, 'You are the chair of a three-judge panel. You do not re-judg...')
   spine r13: write(verdict.md)
   3 spine tool rounds, 5 spine calls; 9 tool rounds of children or composed steps
   reply: status: completed winner: b
#3 green r=True s=True p=True 107s $0.2442 :: 
   facts {"called": {"compose": 1, "read": 9, "bash": 7, "write": 1}, "waited": true, "woken_loops": [], "door": "compose", "loop_style": {"door": "compose", "rounds": 3, "receipts": 0, "compose_calls": 1, "task_calls": 0, "bash_calls": 7}}
   verification verdict names "b"; oracle a="the-quick-brown-fox-jumps-over-the-lazy-" b="the-quick-brown-fox-jumps-over-the-lazy"
   spine r2: compose(wait=True, 1626 chars)
   spine r11: write(verdict.md)
   2 spine tool rounds, 2 spine calls; 8 tool rounds of children or composed steps
   reply: status: completed winner: b

**glm-5.3-flash**
#1 green r=True s=True p=True 165s $0.0263 :: 
   facts {"called": {"todo_write": 4, "bash": 3, "task": 5, "read": 12, "write": 1}, "waited": true, "woken_loops": [], "door": "task_fan", "loop_style": {"door": "task_fan", "rounds": 6, "receipts": 0, "compose_calls": 0, "task_calls": 5, "bash_calls": 3}}
   verification verdict names "b"; oracle a="the-quick-brown-fox-jumps-over-the-lazy-" b="the-quick-brown-fox-jumps-over-the-lazy"
   spine r2: todo_write({"todos": [{"status": "in_progress", "co...); bash('ls -la && echo --- && ls -la a b 2>/dev/null && echo --- && ...')
   spine r3: todo_write({"todos": [{"status": "completed", "cont...); task(wait=True, 'You are Judge 1 of three independent judges on a code review...'); task(wait=True, 'You are Judge 2 of three independent judges on a code review...'); task(wait=True, 'You are Judge 3 of three independent judges on a code review...')
   spine r9: task(wait=True, 'You are one of three independent judges on a code review pan...')
   spine r11: todo_write({"todos": [{"status": "completed", "cont...); task(wait=True, 'You are the chair of a three-judge code review panel. Three ...')
   spine r12: write(verdict.md); todo_write({"todos": [{"status": "completed", "cont...)
   5 spine tool rounds, 11 spine calls; 6 tool rounds of children or composed steps
   reply: status: completed Panel verdict — three independent judges each scored both candidates against SPEC.md, and the chair tallied: - Judge 1: a=7, b=9 - Judge 2: a=7, b=9 - Judge 3: a=7, b=9 - Totals: a=21, b=27 All three ju...
#2 green r=True s=True p=True 124s $0.0198 :: 
   facts {"called": {"todo_write": 5, "ls": 1, "bash": 1, "task": 4, "read": 9, "write": 1}, "waited": true, "woken_loops": [], "door": "task_fan", "loop_style": {"door": "task_fan", "rounds": 7, "receipts": 0, "compose_calls": 0, "task_calls": 4, "bash_calls": 1}}
   verification verdict names "b"; oracle a="the-quick-brown-fox-jumps-over-the-lazy-" b="the-quick-brown-fox-jumps-over-the-lazy"
   spine r2: todo_write({"todos": [{"status": "in_progress", "co...); ls()
   spine r3: bash('ls a b && wc -l SPEC.md a/slugify.rb b/slugify.rb')
   spine r4: todo_write({"todos": [{"status": "completed", "cont...); task(wait=True, 'You are Judge 1 on an independent three-judge panel. Score t...'); task(wait=True, 'You are Judge 2 on an independent three-judge panel. Score t...'); task(wait=True, 'You are Judge 3 on an independent three-judge panel. Score t...')
   spine r8: todo_write({"todos": [{"status": "completed", "cont...); task(wait=True, 'You are the chair of a three-judge panel. Your only job is t...')
   spine r9: todo_write({"todos": [{"status": "completed", "cont...); write(verdict.md)
   spine r10: todo_write({"todos": [{"status": "completed", "cont...)
   6 spine tool rounds, 12 spine calls; 3 tool rounds of children or composed steps
   reply: status: completed Three independent judges read SPEC.md and both candidates; all three scored b at 10 and preferred b (a scored 8, 7, 8). The chair tallied totals a=23 vs b=30, preferences 0–3, and named the winner. verd...
#3 green r=True s=True p=True 205s $0.0349 :: 
   facts {"called": {"todo_write": 4, "bash": 9, "task": 4, "read": 9, "find": 1, "memory_write": 1, "write": 1}, "waited": true, "woken_loops": [], "door": "task_fan", "loop_style": {"door": "task_fan", "rounds": 5, "receipts": 0, "compose_calls": 0, "task_calls": 4, "bash_calls": 9}}
   verification verdict names "b"; oracle a="the-quick-brown-fox-jumps-over-the-lazy-" b="the-quick-brown-fox-jumps-over-the-lazy"
   spine r2: todo_write({"todos": [{"status": "in_progress", "co...); bash('ls -la && echo '---' && find . -maxdepth 3 \( -name 'SPEC.md...')
   spine r3: todo_write({"todos": [{"status": "completed", "cont...); task(wait=True, 'You are one of three independent judges on a panel. Working ...'); task(wait=True, 'You are one of three independent judges on a panel. Working ...'); task(wait=True, 'You are one of three independent judges on a panel. Working ...')
   spine r16: todo_write({"todos": [{"status": "completed", "cont...); memory_write({"path": "conversation/panel-state.md", ...); task(wait=True, 'You are the chair of a three-judge panel. Three independent ...')
   spine r17: write(verdict.md); todo_write({"todos": [{"status": "completed", "cont...)
   4 spine tool rounds, 11 spine calls; 12 tool rounds of children or composed steps
   reply: status: completed winner: b

### workflow-judge-panel / gpt-6-luna (best v14: kimi-k3, glm-5.3-flash)

**gpt-6-luna**
#1 model conduct r=False s=None p=True 67s $0.0018 :: no compose call and no round fanned two task calls: {"spawn" => 3, "write" => 1}
   facts {"called": {"spawn": 3, "write": 1}, "waited": false, "woken_loops": [], "door": null, "loop_style": {"door": null, "rounds": 5, "receipts": 0, "compose_calls": 0, "task_calls": 0, "bash_calls": 0}}
   verification verdict names "b"; oracle a="the-quick-brown-fox-jumps-over-the-lazy-" b="the-quick-brown-fox-jumps-over-the-lazy"
   spine r2: spawn('Independently judge candidate implementations a/sl...')
   spine r3: spawn('Serve as an independent judge. Read SPEC.md, a/slu...')
   spine r4: spawn('As a third independent judge, read SPEC.md and bot...')
   spine r5: write(verdict.md)
   4 spine tool rounds, 4 spine calls; 0 tool rounds of children or composed steps
   reply: status: completed winner: b
#2 green r=True s=True p=True 58s $0.0030 :: 
   facts {"called": {"task": 3, "read": 9, "write": 1}, "waited": true, "woken_loops": [], "door": "task_fan", "loop_style": {"door": "task_fan", "rounds": 4, "receipts": 0, "compose_calls": 0, "task_calls": 3, "bash_calls": 0}}
   verification verdict names "b"; oracle a="the-quick-brown-fox-jumps-over-the-lazy-" b="the-quick-brown-fox-jumps-over-the-lazy"
   spine r2: task(wait=True, 'Act as independent judge 1. Read SPEC.md, a/slugify.rb, and ...')
   spine r4: task(wait=True, 'Act as independent judge 2. Read SPEC.md, a/slugify.rb, and ...'); task(wait=True, 'Act as independent judge 3. Read SPEC.md, a/slugify.rb, and ...')
   spine r7: write(verdict.md)
   3 spine tool rounds, 4 spine calls; 3 tool rounds of children or composed steps
   reply: status: completed winner: b
#3 model conduct r=False s=None p=True 73s $0.0032 :: no compose call and no round fanned two task calls: {"task" => 4, "read" => 9, "write" => 1}
   facts {"called": {"task": 4, "read": 9, "write": 1}, "waited": true, "woken_loops": [], "door": null, "loop_style": {"door": null, "rounds": 6, "receipts": 0, "compose_calls": 0, "task_calls": 4, "bash_calls": 0}}
   verification verdict names "b"; oracle a="the-quick-brown-fox-jumps-over-the-lazy-" b="the-quick-brown-fox-jumps-over-the-lazy"
   spine r2: task(wait=True, 'You are independent Judge 1. Read SPEC.md, a/slugify.rb, and...')
   spine r4: task(wait=True, 'You are independent Judge 2. Read SPEC.md, a/slugify.rb, and...')
   spine r6: task(wait=True, 'You are independent Judge 3. Read SPEC.md, a/slugify.rb, and...')
   spine r8: task(wait=True, 'You are the chair, not a fourth judge. Tally these three ind...')
   spine r9: write(verdict.md)
   5 spine tool rounds, 5 spine calls; 3 tool rounds of children or composed steps
   reply: status: completed winner: b


## every v15 red not in a flagged cell

**task-background-suite opus-5.5**
#3 model conduct r=False s=None p=None 70s $0.0773 :: no `task` call: the model called {"compose" => 2, "bash" => 5, "read" => 1, "write" => 1}
   facts {"called": {"compose": 2, "bash": 5, "read": 1, "write": 1}, "task_calls": 0, "suite_in_background": false}
   spine r2: compose(wait=None, 96 chars); bash('bin/rubocop app 2>&1 | tail -n 100')
   spine r3: read(app/models/user.rb); bash('cat bin/rubocop; ls -la; cat .rubocop.yml 2>/dev/null')
   spine r4: write(app/models/user.rb); bash('bin/rubocop app')
   spine r5: bash('cat -A app/models/user.rb; bin/rubocop app')
   spine r6: compose(wait=True, 77 chars)
   5 spine tool rounds, 8 spine calls; 0 tool rounds of children or composed steps
   reply: status: completed This is the same test result I already reported (20 runs, 0 failures, 0 errors). Nothing has changed. Both Rubocop offences are still fixed. That run may have started before my edit to `app/models/user....

**task-mail opus-5.5**
#1 model conduct r=False s=None p=None 62s $0.0408 :: no `task` call: turn 1 called {"compose" => 1, "bash" => 2}
   facts {"called": {"compose": 1, "bash": 2}}
   spine r2: compose(wait=None, 246 chars); bash('find lib -type f | wc -l; ls -A lib | wc -l')
   1 spine tool rounds, 2 spine calls; 0 tool rounds of children or composed steps
   reply: status: completed 3


## spine tool rounds per model, every family (the spine followed from r1, not read off the key)

- opus-5.5: first spine tool round's call count {1: 45, 2: 9, 3: 3, 5: 3}; spine tool rounds 124, with >1 call 19 (0.153); calls per spine tool round 1.25; records with no spine call 0; no trace 0
- gpt-6-sol: first spine tool round's call count {1: 53, 2: 1, 3: 6}; spine tool rounds 266, with >1 call 17 (0.064); calls per spine tool round 1.11; records with no spine call 0; no trace 0
- gpt-6-luna: first spine tool round's call count {1: 49, 2: 4, 3: 6, 5: 1}; spine tool rounds 255, with >1 call 22 (0.086); calls per spine tool round 1.25; records with no spine call 0; no trace 0
- glm-5.3: first spine tool round's call count {1: 37, 2: 12, 3: 6, 4: 1, 5: 4}; spine tool rounds 192, with >1 call 45 (0.234); calls per spine tool round 1.63; records with no spine call 0; no trace 0
- kimi-k3: first spine tool round's call count {1: 36, 2: 14, 3: 6, 4: 1, 5: 3}; spine tool rounds 176, with >1 call 43 (0.244); calls per spine tool round 1.61; records with no spine call 0; no trace 0
- ds-flash: first spine tool round's call count {1: 28, 2: 23, 3: 6, 5: 1, 6: 2}; spine tool rounds 170, with >1 call 67 (0.394); calls per spine tool round 1.87; records with no spine call 0; no trace 0
- glm-5.3-flash: first spine tool round's call count {1: 31, 2: 19, 3: 6, 4: 1, 6: 1, 11: 2}; spine tool rounds 229, with >1 call 59 (0.258); calls per spine tool round 1.64; records with no spine call 0; no trace 0

## the delegation fan per model: records whose spine made >= 2 `task` calls in all, and whether any one spine round carried >= 2 of them (task and workflow families)

| model | records with >= 2 spine task calls | of those, a round with >= 2 task calls | max task calls in one spine round (distribution) | records with a spawn call |
|---|---|---|---|---|
| opus-5.5 | 3 | 3 | {5: 3} | 0 |
| gpt-6-sol | 12 | 1 | {1: 11, 3: 1} | 0 |
| gpt-6-luna | 11 | 6 | {1: 5, 2: 1, 5: 1, 6: 1, 8: 2, 12: 1} | 1 |
| glm-5.3 | 12 | 11 | {1: 1, 3: 2, 5: 3, 8: 3, 12: 3} | 0 |
| kimi-k3 | 11 | 11 | {3: 2, 5: 3, 8: 3, 12: 3} | 0 |
| ds-flash | 7 | 7 | {5: 3, 8: 3, 12: 1} | 3 |
| glm-5.3-flash | 12 | 12 | {3: 3, 5: 3, 8: 3, 12: 3} | 0 |
```

### `A3_o7_merge.out`

```text
  start workflow-barrier-free-pipeline claude-opus-5-5 #1 (2026-09-26-v15-workflow)
  workflow-barrier-free-pipeline claude-opus-5-5 #1 (2026-09-26-v15-workflow): shipped re-read 0.74 s -> {"succeeded" => false, "class" => "disagreement"} edit_as_tool; candidate re-read starting
2026-09-26-v15-workflow workflow-barrier-free-pipeline claude-opus-5-5 #1 tier=strong pass=true shipped=[{"succeeded" => false, "class" => "disagreement"}, "edit_as_tool"] MOVES -> [{"succeeded" => false, "class" => "disagreement"}, "over_read"]
  start workflow-barrier-free-pipeline claude-opus-5-5 #2 (2026-09-26-v15-workflow)
  workflow-barrier-free-pipeline claude-opus-5-5 #2 (2026-09-26-v15-workflow): shipped re-read 0.22 s -> {"succeeded" => false, "class" => "disagreement"} edit_as_tool; candidate re-read starting
2026-09-26-v15-workflow workflow-barrier-free-pipeline claude-opus-5-5 #2 tier=strong pass=true shipped=[{"succeeded" => false, "class" => "disagreement"}, "edit_as_tool"] MOVES -> [{"succeeded" => true, "class" => nil}, "exact"]
  start workflow-barrier-free-pipeline claude-opus-5-5 #3 (2026-09-26-v15-workflow)
  workflow-barrier-free-pipeline claude-opus-5-5 #3 (2026-09-26-v15-workflow): shipped re-read 0.72 s -> {"succeeded" => false, "class" => "disagreement"} edit_as_tool; candidate re-read starting
2026-09-26-v15-workflow workflow-barrier-free-pipeline claude-opus-5-5 #3 tier=strong pass=true shipped=[{"succeeded" => false, "class" => "disagreement"}, "edit_as_tool"] MOVES -> [{"succeeded" => true, "class" => nil}, "exact"]
  start workflow-barrier-free-pipeline gpt-6-sol #1 (2026-09-26-v15-workflow)
  workflow-barrier-free-pipeline gpt-6-sol #1 (2026-09-26-v15-workflow): shipped re-read 2.91 s -> {"succeeded" => false, "class" => "disagreement"} edit_as_tool; candidate re-read starting
2026-09-26-v15-workflow workflow-barrier-free-pipeline gpt-6-sol #1 tier=strong pass=true shipped=[{"succeeded" => false, "class" => "disagreement"}, "edit_as_tool"] MOVES -> [{"succeeded" => true, "class" => nil}, "exact"]
  start workflow-barrier-free-pipeline gpt-6-sol #3 (2026-09-26-v15-workflow)
  workflow-barrier-free-pipeline gpt-6-sol #3 (2026-09-26-v15-workflow): shipped re-read 2.94 s -> {"succeeded" => false, "class" => "disagreement"} edit_as_tool; candidate re-read starting
2026-09-26-v15-workflow workflow-barrier-free-pipeline gpt-6-sol #3 tier=strong pass=true shipped=[{"succeeded" => false, "class" => "disagreement"}, "edit_as_tool"] MOVES -> [{"succeeded" => true, "class" => nil}, "exact"]
  start compose-three-stage-pairing claude-opus-5-5 #1 (2026-09-26-v15-compose)
  compose-three-stage-pairing claude-opus-5-5 #1 (2026-09-26-v15-compose): shipped re-read 0.01 s -> {"succeeded" => true, "class" => nil} exact; candidate re-read starting
2026-09-26-v15-compose compose-three-stage-pairing claude-opus-5-5 #1 tier=strong pass= shipped=[{"succeeded" => true, "class" => nil}, "exact"]
  start compose-three-stage-pairing claude-opus-5-5 #2 (2026-09-26-v15-compose)
  compose-three-stage-pairing claude-opus-5-5 #2 (2026-09-26-v15-compose): shipped re-read 0.01 s -> {"succeeded" => true, "class" => nil} exact; candidate re-read starting
2026-09-26-v15-compose compose-three-stage-pairing claude-opus-5-5 #2 tier=strong pass= shipped=[{"succeeded" => true, "class" => nil}, "exact"]
  start compose-three-stage-pairing claude-opus-5-5 #3 (2026-09-26-v15-compose)
  compose-three-stage-pairing claude-opus-5-5 #3 (2026-09-26-v15-compose): shipped re-read 0.01 s -> {"succeeded" => true, "class" => nil} exact; candidate re-read starting
2026-09-26-v15-compose compose-three-stage-pairing claude-opus-5-5 #3 tier=strong pass= shipped=[{"succeeded" => true, "class" => nil}, "exact"]
  start compose-three-stage-pairing gpt-6-sol #1 (2026-09-26-v15-compose)
  compose-three-stage-pairing gpt-6-sol #1 (2026-09-26-v15-compose): shipped re-read 0.14 s -> {"succeeded" => false, "class" => "model conduct"} over_read; candidate re-read starting
2026-09-26-v15-compose compose-three-stage-pairing gpt-6-sol #1 tier=strong pass= shipped=[{"succeeded" => false, "class" => "model conduct"}, "over_read"]
  start compose-three-stage-pairing gpt-6-sol #2 (2026-09-26-v15-compose)
  compose-three-stage-pairing gpt-6-sol #2 (2026-09-26-v15-compose): shipped re-read 0.14 s -> {"succeeded" => false, "class" => "model conduct"} over_read; candidate re-read starting
2026-09-26-v15-compose compose-three-stage-pairing gpt-6-sol #2 tier=strong pass= shipped=[{"succeeded" => false, "class" => "model conduct"}, "over_read"]
  start compose-three-stage-pairing gpt-6-sol #3 (2026-09-26-v15-compose)
  compose-three-stage-pairing gpt-6-sol #3 (2026-09-26-v15-compose): shipped re-read 0.01 s -> {"succeeded" => true, "class" => nil} exact; candidate re-read starting
2026-09-26-v15-compose compose-three-stage-pairing gpt-6-sol #3 tier=strong pass= shipped=[{"succeeded" => true, "class" => nil}, "exact"]
  start compose-three-stage-pairing gpt-6-luna #1 (2026-09-26-v15-compose)
  compose-three-stage-pairing gpt-6-luna #1 (2026-09-26-v15-compose): shipped re-read 0.13 s -> {"succeeded" => true, "class" => "cache under floor"} missing_steps, over_sync; candidate re-read starting
2026-09-26-v15-compose compose-three-stage-pairing gpt-6-luna #1 tier=floor pass= shipped=[{"succeeded" => true, "class" => "cache under floor"}, "missing_steps, over_sync"]
  start compose-three-stage-pairing gpt-6-luna #2 (2026-09-26-v15-compose)
  compose-three-stage-pairing gpt-6-luna #2 (2026-09-26-v15-compose): shipped re-read 0.01 s -> {"succeeded" => true, "class" => nil} exact; candidate re-read starting
2026-09-26-v15-compose compose-three-stage-pairing gpt-6-luna #2 tier=floor pass= shipped=[{"succeeded" => true, "class" => nil}, "exact"]
  start compose-three-stage-pairing gpt-6-luna #3 (2026-09-26-v15-compose)
  compose-three-stage-pairing gpt-6-luna #3 (2026-09-26-v15-compose): shipped re-read 0.14 s -> {"succeeded" => true, "class" => nil} over_read; candidate re-read starting
2026-09-26-v15-compose compose-three-stage-pairing gpt-6-luna #3 tier=floor pass= shipped=[{"succeeded" => true, "class" => nil}, "over_read"]
14 composed records re-read twice in memory; 5 move under the candidate
```

### `A4_scripts.out`

```text
### task-background-suite anthropic/claude-opus-5-5 #3: {'reached': False, 'succeeded': None, 'task_pass': None, 'class': 'model conduct'} :: no `task` call: the model called {"compose" => 2, "bash" => 5, "read" => 1, "write" => 1}

- r2t0 compose status=completed wait=None:
'''js
g.tool({ name: "bash", input: { command: "bin/rails test 2>&1 | tail -n 200", timeout: 540 } });
'''
- r6t0 compose status=completed wait=True:
'''js
g.wait({ task: "r2t0", agent_loop: "01a0dbf6-fdbc-7b6a-881c-1c4c79e16ba4" });
'''

### task-mail anthropic/claude-opus-5-5 #1: {'reached': False, 'succeeded': None, 'task_pass': None, 'class': 'model conduct'} :: no `task` call: turn 1 called {"compose" => 1, "bash" => 2}

- r2t0 compose status=completed wait=None:
'''js
g.tool({ name: "bash", input: { command: "ruby test/all.rb 2>&1 | tail -n 40", workdir: "/var/folders/_6/7vgpkxd14klg0lpvxyh5nk2h0000gn/T/rho-evals-e2e20260926-49006-u6uh5p/projects/task-mail.anthropic_claude-opus-5-5.nexus.1", timeout: 540 } });
'''

### compose-grep-then-edit openai_api/gpt-6-sol #1: {'reached': True, 'succeeded': False, 'task_pass': True, 'class': 'disagreement'} :: the script was refused script_error: Error: g.script: results names an "all" group, which is not one step; list its steps instead: results: [a, b].

- r2t0 compose status=completed wait=True:
'''js
const files = ["app/models/user.rb", "app/models/account.rb", "app/models/team.rb"];
const searches = g.parallel(files.map(path => g.tool({name: "grep", input: {path, glob: "*.rb", pattern: "^[[:space:]]*def[[:space:]]+full_name([[:space:](;]|$)", literal: false, ignoreCase: false, context: 0, limit: 20}})));
g.script({results: [searches], params: {files}, script: `
const r = results[0];
if (r.status !== "completed" || r.is_error) throw new Error("Grep failed: " + r.output);
const searches = r.selected;
if (!searches || searches.length !== 3) throw new Error("Expected three grep results: " + JSON.stringify(r));
const matches = searches.map((item, i) => ({file: params.files[i], result: item})).filter(({result}) => result.status === "completed" && !result.is_error && /def\\s+full_name(?=[\\s(;]|$)/m.test(result.output));
if (matches.length !== 1) throw new Error("Expected exactly one defining file; grep results: " + JSON.stringify(searches.map((x, i) => ({file: params.files[i], output: x.output, error: x.error}))));
const file = matches[0].file;
const edit = g.tool({name: "edit", input: {path: file, edits: [{oldText: "def full_name", newText: "def display_name"}]}});
g.script({results: [edit], params: {file}, script: "const r = results[0]; if (r.status !== 'completed' || r.is_error) throw new Error('Edit failed: ' + (r.output || r.error)); return {file: params.file, edit: r.output};"});
`});
'''
- r3t0 compose status=completed wait=True:
'''js
const files = ["app/models/user.rb", "app/models/account.rb", "app/models/team.rb"];
const searches = files.map(path => g.tool({name: "grep", input: {path, glob: "*.rb", pattern: "^[[:space:]]*def[[:space:]]+full_name([[:space:](;]|$)", literal: false, ignoreCase: false, context: 0, limit: 20}}));
g.parallel(searches);
g.script({results: searches, params: {files}, script: `
const matches = results.map((r, i) => ({file: params.files[i], result: r})).filter(({result}) => result.status === "completed" && !result.is_error && /def\\s+full_name(?=[\\s(;]|$)/m.test(result.output));
if (matches.length !== 1) throw new Error("Expected exactly one defining file; grep results: " + JSON.stringify(results.map((r, i) => ({file: params.files[i], output: r.output, error: r.error}))));
const file = matches[0].file;
const edit = g.tool({name: "edit", input: {path: file, edits: [{oldText: "def full_name", newText: "def display_name"}]}});
g.script({results: [edit], params: {file}, script: "const r = results[0]; if (r.status !== 'completed' || r.is_error) throw new Error('Edit failed: ' + (r.output || r.error)); return {file: params.file, edit: r.output};"});
`});
'''

### compose-grep-then-edit openai_api/gpt-6-sol #3: {'reached': True, 'succeeded': False, 'task_pass': True, 'class': 'disagreement'} :: 01a0dc2e-75c7-7d23-b43e-7b02003b6063(failed) did not complete under r2t0

- r2t0 compose status=completed wait=True:
'''js
const files = ['app/models/user.rb', 'app/models/account.rb', 'app/models/team.rb'];
const checks = files.map(path => g.tool({name:'grep', input:{path, glob:'*.rb', pattern:'^[[:space:]]*def[[:space:]]+(self\\.)?full_name\\b', literal:false, ignoreCase:false, context:0, limit:100}}));
g.parallel(checks);
g.script({results:checks, params:{files}, script:`
const hits = results.map((r,i) => {
  if (r.status !== 'completed' || r.is_error) throw new Error('grep failed for '+params.files[i]+': '+r.output);
  return {path:params.files[i], text:r.output};
}).filter(x => /:\\d+:\\s*def\\s+(?:self\\.)?full_name\\b/m.test(x.text));
if (hits.length !== 1) throw new Error('Expected exactly one defining file, found '+hits.length+': '+JSON.stringify(hits));
const hit = hits[0];
const selfMethod = /:\\d+:\\s*def\\s+self\\.full_name\\b/m.test(hit.text);
const oldText = selfMethod ? 'def self.full_name' : 'def full_name';
const newText = selfMethod ? 'def self.display_name' : 'def display_name';
const edit = g.tool({name:'edit', input:{path:hit.path, edits:[{oldText,newText}]}});
const newCheck = g.tool({name:'grep', input:{path:hit.path, glob:'*.rb', pattern:'^[[:space:]]*def[[:space:]]+(self\\.)?display_name\\b',literal:false,ignoreCase:false,context:0,limit:100}, after:[edit]});
const oldCheck = g.tool({name:'grep', input:{path:hit.path, glob:'*.rb', pattern:'^[[:space:]]*def[[:space:]]+(self\\.)?full_name\\b',literal:false,ignoreCase:false,context:0,limit:100}, after:[edit]});
g.parallel([newCheck,oldCheck]);
g.script({results:[edit,newCheck,oldCheck],params:{path:hit.path},script:"if (results[0].status !== 'completed' || results[0].is_error) throw new Error('Edit failed: '+results[0].output); if (results[1].status !== 'completed' || results[1].is_error || !/display_name/.test(results[1].output)) throw new Error('New definition not verified: '+results[1].output); if (results[2].status !== 'completed' || results[2].is_error || /full_name/.test(results[2].output)) throw new Error('Old definition remains: '+results[2].output); return {renamedIn:params.path,verification:'passed'};"});
`});
'''
- FAILED 01a0dc2e-75c7-7d23-b43e-7b02003b6063 kind=script_task tool=None error=None detail=null input=null

### workflow-judge-panel openai_api/gpt-6-sol #1: {'reached': True, 'succeeded': False, 'task_pass': True, 'class': 'disagreement'} :: r8t0 composed 3 tasks and no step reads two model members

- r8t0 compose status=completed wait=True:
'''js
const a=g.wait({task:'r2t0',agent_loop:'01a0dc7b-ffc9-7a39-9aa5-72ef00782573'}); const b=g.wait({task:'r4t0',agent_loop:'01a0dc7b-ffc9-7a39-9aa5-72ef00782573'}); const c=g.wait({task:'r6t0',agent_loop:'01a0dc7b-ffc9-7a39-9aa5-72ef00782573'}); g.parallel([a,b,c]);
'''

### task-fan-five openai_api/gpt-6-sol #1: {'reached': False, 'succeeded': None, 'task_pass': None, 'class': 'model conduct'} :: 1 task call(s) in the first message, not five: {"task" => 1}

- r17t0 compose status=completed wait=True:
'''js
g.parallel([g.wait({task:'r2t0',agent_loop:'01a0dc0e-08de-7798-9e3a-a9e3afe3161a'}),g.wait({task:'r3t0',agent_loop:'01a0dc0e-08de-7798-9e3a-a9e3afe3161a'}),g.wait({task:'r5t0',agent_loop:'01a0dc0e-08de-7798-9e3a-a9e3afe3161a'}),g.wait({task:'r8t0',agent_loop:'01a0dc0e-08de-7798-9e3a-a9e3afe3161a'})]);
'''
```

### `A7_cache_ceiling.out`

```text
compose-three-stage-pairing gpt-6-luna #1 class=cache under floor after-r1 0.7744 ceiling 0.7746 series {'r1': [8171, 0], 'r2': [12254, 8168], 'r3': [14115, 12251]} read/previous-input per measured round [0.9996, 0.9998]
```

### `A8_checks.out`

```text
workflow-adversarial-verify gpt-6-luna 1 [1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1] waits [False, False, False, False, False, False, False, False, False, False, False, False] g.wait per compose [1]
workflow-adversarial-verify gpt-6-luna 2 [12] waits [False, False, False, False, False, False, False, False, False, False, False, False] g.wait per compose [12]
workflow-adversarial-verify gpt-6-luna 3 [1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1] waits [False, False, False, False, False, False, False, False, False, False, False, False] g.wait per compose [1]
task-fan-five gpt-6-sol 1 [1, 1, 1, 1, 1] waits [False, False, False, False, True] g.wait per compose [4]
task-fan-five gpt-6-sol 2 [1, 1, 3] waits [True, True, True, True, True] g.wait per compose []
task-fan-five gpt-6-sol 3 [1, 1, 1, 1, 1] waits [False, False, False, False, False] g.wait per compose [5]
workflow-fan-out-finders gpt-6-sol 1 [1, 1, 1, 1, 1, 1, 1, 1] waits [False, False, False, False, False, False, False, False] g.wait per compose [8]
workflow-fan-out-finders gpt-6-sol 2 [1, 1, 1, 1, 1, 1, 1, 1] waits [False, False, False, False, False, False, False, False] g.wait per compose [1]
workflow-fan-out-finders gpt-6-sol 3 [1, 1, 1, 1, 1, 1, 1, 1] waits [False, False, False, False, False, False, False, False] g.wait per compose [8]
```

## Appendix 2 — scripts

### `A1_cells.py`

```python
#!/usr/bin/env python3
"""SECTION A, SEVEN MODELS ON ONE BENCH (read-only).

Reads the three v15 labels (claude-opus-5-5, gpt-6-sol strong; gpt-6-luna floor)
and the three v14 labels (glm-5.3, kimi-k3 strong; deepseek-flash, glm-5.3-flash
floor). Same 20 tasks, same predicates and pictures (bench.yml VERSION 15 note:
"No predicate or picture moved"). Records are merged the way
E2E::Evals::Records.read merges them: the LAST line per (task, model, style, run);
both versions hold one line per key (checked below). Nothing is re-scored: every
verdict, class, fact and cost is read as recorded.

Per cell: reached / succeeded / task_pass (passed/verified, '-' when none was
verified) as k/3, the recorded classes, green, the tier's bar (a floor picture
cell reads usable generation = facts.usable_on_call set, a strong picture cell the
picture = facts.picture is true; the other bar is printed beside it), mean seconds
and total cost (efficiency.cost_amount, USD on every record).
"""
import json
import os
import re
from collections import Counter, OrderedDict

REPO = "/Users/jasl/Workspaces/cybros-ai.alt2"
RUNS = os.path.join(REPO, "e2e/evals/runs")
V15 = ["2026-09-26-v15-task", "2026-09-26-v15-compose", "2026-09-26-v15-workflow"]
V14 = ["2026-09-26-v14-task", "2026-09-26-v14-compose", "2026-09-26-v14-workflow"]
KEY = ("task", "model", "style", "run")
FAMILIES = ["task", "compose", "workflow"]
NEW = ["anthropic/claude-opus-5-5", "openai_api/gpt-6-sol", "openai_api/gpt-6-luna"]
OLD = ["openrouter/z-ai/glm-5.3", "openrouter/moonshotai/kimi-k3",
       "deepseek/deepseek-flash", "openrouter/z-ai/glm-5.3-flash"]
ORDER = ["anthropic/claude-opus-5-5", "openai_api/gpt-6-sol", "openrouter/z-ai/glm-5.3",
         "openrouter/moonshotai/kimi-k3", "openai_api/gpt-6-luna", "deepseek/deepseek-flash",
         "openrouter/z-ai/glm-5.3-flash"]
SHORT = {"anthropic/claude-opus-5-5": "opus-5.5", "openai_api/gpt-6-sol": "gpt-6-sol",
         "openai_api/gpt-6-luna": "gpt-6-luna", "openrouter/z-ai/glm-5.3": "glm-5.3",
         "openrouter/moonshotai/kimi-k3": "kimi-k3", "deepseek/deepseek-flash": "ds-flash",
         "openrouter/z-ai/glm-5.3-flash": "glm-5.3-flash"}
CLASSES = OrderedDict([("model conduct", "mc"), ("disagreement", "dis"), ("cache under floor", "cuf"),
                       ("kernel finding", "kf"), ("lane bug", "lb")])
GATE_EXCLUDED = "compose-rendezvous"  # T5, recorded-only: "gate tasks" = the other seven compose picture tasks


def version(model):
    return "v15" if model in NEW else "v14"


def read_label(label):
    merged, lines = OrderedDict(), 0
    with open(os.path.join(RUNS, label, "records.jsonl"), encoding="utf-8") as fh:
        for line in fh:
            if not line.strip():
                continue
            lines += 1
            row = json.loads(line)
            merged[tuple(row[k] for k in KEY)] = row
    return lines, list(merged.values())


def load():
    cells, meta = OrderedDict(), OrderedDict()
    for label in V15 + V14:
        lines, rows = read_label(label)
        meta[label] = (lines, rows)
        for row in rows:
            cells.setdefault((row["family"], row["task"], row["model"]), []).append(row)
    for rows in cells.values():
        rows.sort(key=lambda r: r["run"])
    return cells, meta


def cost(row):
    amount = (row.get("efficiency") or {}).get("cost_amount")
    return None if amount is None else float(amount)


def tier_of(rows):
    tiers = {(r.get("facts") or {}).get("tier") for r in rows}
    assert len(tiers) == 1, tiers
    return next(iter(tiers))


def is_pic(row):
    return "picture" in (row.get("facts") or {})


def strong_bar_green(row):
    """Green read on the STRONG bar. Exact for every model: a strong record is already read there;
    a floor picture record's class is a function of success, and success on the strong bar is the
    picture, so it is green there iff it is green now AND its picture is exact (picture true implies
    usable and reached on all 189 picture records of both versions)."""
    green = row["verdict"].get("class") is None
    if row["facts"].get("tier") == "floor" and is_pic(row):
        return green and row["facts"].get("picture") is True
    return green


def stats(rows):
    v = [r["verdict"] for r in rows]
    facts = [r.get("facts") or {} for r in rows]
    verified = [x for x in v if x.get("task_pass") is not None]
    return {
        "n": len(rows),
        "reached": sum(1 for x in v if x.get("reached") is True),
        "succ": sum(1 for x in v if x.get("succeeded") is True),
        "verified": len(verified),
        "passed": sum(1 for x in verified if x.get("task_pass") is True),
        "classes": Counter(x.get("class") for x in v),
        "green": sum(1 for x in v if x.get("class") is None),
        "sgreen": sum(1 for r in rows if strong_bar_green(r)),
        "picture_cell": any("picture" in f for f in facts),
        "usable": sum(1 for f in facts if "picture" in f and f.get("usable_on_call") is not None),
        "pictured": sum(1 for f in facts if f.get("picture") is True),
        "seconds": sum(r["seconds"] for r in rows),
        "cost": sum(cost(r) or 0.0 for r in rows),
        "null_cost": sum(1 for r in rows if cost(r) is None),
    }


def fmt_classes(s):
    parts = [f"{abbr}{s['classes'][name]}" for name, abbr in CLASSES.items() if s["classes"].get(name)]
    parts.append(f"g{s['green']}")
    return " ".join(parts)


def fmt_p(s):
    return f"{s['passed']}/{s['verified']}" if s["verified"] else "-"


def fmt_bar(s, the_tier):
    if not s["picture_cell"]:
        return "= s"
    if the_tier == "floor":
        return f"u {s['usable']}/{s['n']} (x {s['pictured']})"
    return f"x {s['pictured']}/{s['n']} (u {s['usable']})"


def sort_key(key):
    family, task, model = key
    return (FAMILIES.index(family), task, ORDER.index(model))


def reason_head(row, width=170):
    text = " ".join((row.get("reason") or "").split())
    failed = [k for k, ok in (row.get("conduct") or {}).items() if ok is False]
    if failed:
        text = (text + " " if text else "") + f"[conduct failed: {', '.join(failed)}]"
    if row.get("stopped"):
        text = f"[stopped {row['stopped']} at {row['seconds']} s] {text}"
    return text[:width] + ("..." if len(text) > width else "")


def after_r1(series):
    rest = list((series or {}).values())[1:]
    tokens = sum(int(t or 0) for t, _ in rest)
    return None if tokens == 0 else round(sum(int(c or 0) for _, c in rest) / tokens, 4)


def run_line(row):
    v, f = row["verdict"], row.get("facts") or {}
    yn = lambda x: "-" if x is None else ("Y" if x else "N")
    cls = v.get("class") or "green"
    extra = ""
    if "picture" in f:
        pic = "true" if f["picture"] is True else " ".join(str(f["picture"]).split())[:70]
        extra = f" {{picture: {pic}; usable_on_call: {f.get('usable_on_call')}}}"
    c = cost(row)
    eff = row.get("efficiency") or {}
    return (f"#{row['run']} r={yn(v.get('reached'))} s={yn(v.get('succeeded'))} p={yn(v.get('task_pass'))} {cls}"
            f" {row['seconds']}s ${'null' if c is None else f'{c:.4f}'} rounds {eff.get('rounds')} calls {eff.get('calls')}"
            f" hit {eff.get('cache_hit_rate')} after-r1 {after_r1(eff.get('cache_read_series'))}"
            f" called {f.get('called')} :: {reason_head(row)}{extra}")


# ---------------------------------------------------------------- A.0 inputs

def inputs(cells, meta):
    print("## A.0 Inputs\n")
    for label, (lines, rows) in meta.items():
        print(f"- {label}: {lines} lines -> {len(rows)} records (last line per key); digest "
              f"{sorted({r['bench_digest'][:12] for r in rows})}; models "
              f"{dict(Counter(SHORT[r['model']] + '/' + str(r['facts'].get('tier')) for r in rows))}; "
              f"error rows {sum(1 for r in rows if r.get('error'))}; "
              f"stopped {dict(Counter(r.get('stopped') for r in rows if r.get('stopped')))}; "
              f"cost units {dict(Counter(r['efficiency'].get('cost_unit') for r in rows))}; "
              f"started {min(r['started_at'] for r in rows)} .. {max(r['started_at'] for r in rows)}")
    tasks15 = {(k[0], k[1]) for k in cells if k[2] in NEW}
    tasks14 = {(k[0], k[1]) for k in cells if k[2] in OLD}
    print(f"- cells: {len(cells)} (v15 {sum(1 for k in cells if k[2] in NEW)}, v14 {sum(1 for k in cells if k[2] in OLD)}); "
          f"same (family, task) set on both versions: {tasks15 == tasks14} ({len(tasks15)} tasks); runs per cell "
          f"{sorted({len(v) for v in cells.values()})}")
    check_ledger(cells)


def check_ledger(cells):
    with open(os.path.join(RUNS, "LEDGER.md"), encoding="utf-8") as fh:
        text = fh.read()
    section = next(s for s in text.split("\n## ") if s.startswith("bench `772186a893d5`"))
    checked, bad = 0, []
    for line in section.splitlines():
        cols = [c.strip() for c in line.strip("|").split("|")]
        if len(cols) < 7 or cols[0] not in FAMILIES:
            continue
        family, task, model = cols[0], cols[1], cols[2].split(" ")[0]
        value = next(v for v in cols[4:] if v != "·")
        rows = cells[(family, task, model)]
        s = stats(rows)
        reached = s["reached"]
        floor_pic = s["picture_cell"] and tier_of(rows) == "floor"
        want = (f"r{reached}/{s['n']} " +
                (f"u{s['usable']}/{reached}·x{s['pictured']}/{reached}" if floor_pic else f"s{s['succ']}/{reached}")
                + f" p{fmt_p(s).replace('-', '—')}")
        got = " ".join(value.split(" ")[:3])
        d = re.search(r" d(\d+)", value)
        checked += 1
        if want != got or int(d.group(1) if d else 0) != s["classes"].get("disagreement", 0):
            bad.append(f"{task} {SHORT[model]}: ledger '{value}' vs records '{want}' d{s['classes'].get('disagreement', 0)}")
    print(f"- LEDGER.md cross-check (v15 section, r / s-or-u·x / p / d): {checked} cells, {len(bad)} mismatches")
    for b in bad:
        print(f"    - {b}")


# ---------------------------------------------------------------- A.1 cells

def per_cell_tables(cells):
    print("\n## A.1 Every (task x model) cell, seven models\n")
    print("Columns: r reached, s succeeded, p task pass (passed/verified), classes (mc model conduct, dis disagreement, "
          "cuf cache under floor; g green), bar (strong: x picture exact (u usable); floor: u usable (x picture exact)), "
          "mean seconds, cost USD over the 3 runs. v15 models: opus-5.5, gpt-6-sol (strong), gpt-6-luna (floor).")
    for family in FAMILIES:
        print(f"\n### {family}\n")
        print("| task | model | ver | tier | r | s | p | classes | bar | mean s | cost $ |")
        print("|---|---|---|---|---|---|---|---|---|---|---|")
        for key in sorted((k for k in cells if k[0] == family), key=sort_key):
            rows = cells[key]
            s, t = stats(rows), tier_of(rows)
            print(f"| {key[1]} | {SHORT[key[2]]} | {version(key[2])} | {t} | {s['reached']}/{s['n']} | {s['succ']}/{s['n']} | "
                  f"{fmt_p(s)} | {fmt_classes(s)} | {fmt_bar(s, t)} | {s['seconds'] / s['n']:.0f} | {s['cost']:.4f} |")


def green_matrix(cells):
    print("\n## A.2 Green matrix (green of 3; picture cells also print x = picture exact, u = usable)\n")
    head = " | ".join(SHORT[m] for m in ORDER)
    print(f"| family | task | {head} |")
    print("|---|---|" + "---|" * len(ORDER))
    tasks = OrderedDict()
    for key in sorted(cells, key=sort_key):
        tasks.setdefault((key[0], key[1]), None)
    col_tot = Counter()
    for family, task in tasks:
        cols = []
        for m in ORDER:
            s = stats(cells[(family, task, m)])
            col_tot[m] += s["green"]
            cell = f"{s['green']}"
            if s["picture_cell"]:
                cell += f" (x{s['pictured']} u{s['usable']})"
            cols.append(cell)
        print(f"| {family} | {task} | " + " | ".join(cols) + " |")
    print(f"| **all** | **green of 60** | " + " | ".join(f"**{col_tot[m]}**" for m in ORDER) + " |")


# ---------------------------------------------------------------- A.3 family x model

def aggregate(rows):
    s = stats(rows) if rows else None
    return s


def agg_rows(cells, pred):
    return [r for k, rows in cells.items() if pred(k) for r in rows]


def summary_line(rows):
    s = stats(rows)
    classes = " ".join(f"{abbr}{s['classes'][name]}" for name, abbr in CLASSES.items() if s["classes"].get(name))
    cpg = f"{s['cost'] / s['green']:.4f}" if s["green"] else "n/a"
    return s, (f"{s['green']}/{s['n']} | {s['reached']}/{s['n']} | {s['succ']}/{s['n']} | {fmt_p(s)} | "
               f"{classes or '-'} | {s['cost']:.4f} | {cpg} | {s['seconds'] / s['n']:.0f}")


def family_model(cells):
    print("\n## A.3 Per family and per model\n")
    print("green / reached / succeeded of runs; p = verification passed/verified; cost USD; cost per green = cost / green; "
          "mean seconds per run.\n")
    print("| family | model | tier | green | reached | succeeded | p | classes | cost $ | $ / green | mean s |")
    print("|---|---|---|---|---|---|---|---|---|---|---|")
    for family in FAMILIES + ["all"]:
        for m in ORDER:
            rows = agg_rows(cells, lambda k: (family == "all" or k[0] == family) and k[2] == m)
            _, line = summary_line(rows)
            t = rows[0]["facts"]["tier"]
            print(f"| {family} | {SHORT[m]} | {t} | {line} |")
    print("\n### per tier and version\n")
    print("| scope | green | reached | succeeded | p | classes | cost $ | $ / green | mean s |")
    print("|---|---|---|---|---|---|---|---|---|")
    for name, pred in (("v15 strong (opus, sol)", lambda k: k[2] in NEW[:2]),
                       ("v14 strong (glm-5.3, kimi-k3)", lambda k: k[2] in OLD[:2]),
                       ("v15 floor (luna)", lambda k: k[2] == NEW[2]),
                       ("v14 floor (ds-flash, glm-5.3-flash)", lambda k: k[2] in OLD[2:]),
                       ("v15 all", lambda k: k[2] in NEW), ("v14 all", lambda k: k[2] in OLD)):
        _, line = summary_line(agg_rows(cells, pred))
        print(f"| {name} | {line} |")
    print("\n### tokens and the cache bar per model (all families)\n")
    print("The bar's own measure (Scorecard.cache_under_floor): the rate after round 1 over the spine's "
          "cache_read_series, read only with >= 2 measured rounds, against the family floor 0.80 (task, compose and "
          "workflow alike); glm-5.3-flash is exempt. 'under' counts every read record under 0.80 whatever its class "
          "(a red class wins over cuf).\n")
    print("| model | input tok | output tok | cache-read tok | cache-read / input | $ per M input tok | records read by the bar | median after-r1 "
          "| under 0.80 | classed cuf |")
    print("|---|---|---|---|---|---|---|---|---|---|")
    for m in ORDER:
        rows = agg_rows(cells, lambda k: k[2] == m)
        eff = [r["efficiency"] for r in rows]
        inp = sum(int(e.get("input_tokens") or 0) for e in eff)
        out = sum(int(e.get("output_tokens") or 0) for e in eff)
        cr = sum(int(e.get("cache_read_tokens") or 0) for e in eff)
        read = [after_r1(e.get("cache_read_series")) for e in eff
                if len(e.get("cache_read_series") or {}) - 1 >= 2 and after_r1(e.get("cache_read_series")) is not None]
        read.sort()
        med = (read[len(read) // 2] if len(read) % 2 else (read[len(read) // 2 - 1] + read[len(read) // 2]) / 2) if read else None
        under = sum(1 for x in read if x < 0.80)
        cuf = sum(1 for r in rows if r["verdict"].get("class") == "cache under floor")
        exempt = " (exempt)" if m == "openrouter/z-ai/glm-5.3-flash" else ""
        usd = sum(cost(r) or 0.0 for r in rows)
        print(f"| {SHORT[m]}{exempt} | {inp} | {out} | {cr} | {cr / inp:.4f} | {usd / inp * 1e6:.4f} | {len(read)} | "
              f"{'-' if med is None else f'{med:.4f}'} | {under} | {cuf} |")


# ---------------------------------------------------------------- A.4 both bars

def both_bars(cells):
    print("\n## A.4 Every model on both bars (compose picture tasks)\n")
    print("picture = facts.picture true (the strong bar); usable = facts.usable_on_call set (the floor's bar); "
          "official = verdict.succeeded as recorded (each on its own tier's bar). Gate tasks = the seven compose picture "
          "tasks without compose-rendezvous (T5, recorded-only); 21 runs per model.\n")
    scopes = OrderedDict([
        ("gate tasks (7 compose)", lambda k: k[0] == "compose" and k[1] != GATE_EXCLUDED),
        ("compose picture tasks (8)", lambda k: k[0] == "compose"),
        ("all picture tasks (8 compose + barrier-free)", lambda k: True),
    ])
    for scope, pred in scopes.items():
        print(f"\n### {scope}\n")
        print("| model | tier | runs | official succeeded | usable | picture exact | usable on call 1 / 2 / 3 / none | green |")
        print("|---|---|---|---|---|---|---|---|")
        for m in ORDER:
            rows = [r for k, rs in cells.items() if k[2] == m and pred(k) for r in rs if is_pic(r)]
            on = Counter(r["facts"].get("usable_on_call") for r in rows)
            print(f"| {SHORT[m]} | {rows[0]['facts']['tier']} | {len(rows)} | "
                  f"{sum(1 for r in rows if r['verdict'].get('succeeded') is True)} | "
                  f"{sum(1 for r in rows if r['facts'].get('usable_on_call') is not None)} | "
                  f"{sum(1 for r in rows if r['facts'].get('picture') is True)} | "
                  f"{on.get(1, 0)} / {on.get(2, 0)} / {on.get(3, 0)} / {on.get(None, 0)} | "
                  f"{sum(1 for r in rows if r['verdict'].get('class') is None)} |")
        for name, ms in (("v15 strong", NEW[:2]), ("v14 strong", OLD[:2]), ("v15 floor", NEW[2:]), ("v14 floor", OLD[2:])):
            rows = [r for k, rs in cells.items() if k[2] in ms and pred(k) for r in rs if is_pic(r)]
            print(f"- {name}: runs {len(rows)}, official {sum(1 for r in rows if r['verdict'].get('succeeded') is True)}, "
                  f"usable {sum(1 for r in rows if r['facts'].get('usable_on_call') is not None)}, "
                  f"picture {sum(1 for r in rows if r['facts'].get('picture') is True)}")
    print("\n### picture exact / usable per picture task and model (of 3)\n")
    print("| task | " + " | ".join(SHORT[m] for m in ORDER) + " |")
    print("|---|" + "---|" * len(ORDER))
    for key in sorted({(k[0], k[1]) for k, rs in cells.items() if any(is_pic(r) for r in rs)},
                      key=lambda x: (FAMILIES.index(x[0]), x[1])):
        cols = []
        for m in ORDER:
            s = stats(cells[(key[0], key[1], m)])
            cols.append(f"x{s['pictured']} u{s['usable']}")
        print(f"| {key[1]} | " + " | ".join(cols) + " |")
    print("\n### picture-miss buckets per model (compose picture tasks; one count per record per bucket)\n")
    for m in ORDER:
        rows = [r for k, rs in cells.items() if k[2] == m and k[0] == "compose" for r in rs if is_pic(r)]
        b = Counter(x for r in rows for x in pic_buckets(r))
        other = Counter(" ".join(str(r["facts"]["picture"]).split())[:60] for r in rows
                        if r["facts"]["picture"] is not True and not pic_buckets(r))
        print(f"- {SHORT[m]}: misses {sum(1 for r in rows if r['facts']['picture'] is not True)}; buckets {dict(b)}; "
              f"non-bucket misses {dict(other)}")


def pic_buckets(row):
    m = re.search(r"\(silent: ([^)]*)\)", str((row.get("facts") or {}).get("picture") or ""))
    return [b.strip() for b in m.group(1).split(",")] if m else []


# ---------------------------------------------------------------- A.5 ranking

def ranking(cells):
    print("\n## A.5 The seven ranked\n")
    print("official green = each model on its own tier's bar (60 runs). same-bar green = green over the 11 tasks whose bar "
          "does not depend on the tier (task 6, compose-single-read, workflow's four non-picture tasks: 33 runs). "
          "strong-bar succeeded = succeeded, a floor picture record counting only with its picture exact. "
          "strong-bar green = green read on the strong bar for all seven (a floor picture record counts only if green AND "
          "its picture is exact; strong records as recorded) over 60. gate picture / usable = A.4's gate-task counts of 21.\n")
    rows_out = []
    for m in ORDER:
        rows = agg_rows(cells, lambda k: k[2] == m)
        same = [r for r in rows if not is_pic(r)]
        gate = [r for r in rows if is_pic(r) and r["family"] == "compose" and r["task"] != GATE_EXCLUDED]
        s = stats(rows)
        ssucc = sum(1 for r in rows if r["verdict"].get("succeeded") is True
                    and not (r["facts"].get("tier") == "floor" and is_pic(r) and r["facts"].get("picture") is not True))
        rows_out.append({"ssucc": ssucc,
            "m": m, "tier": rows[0]["facts"]["tier"], "green": s["green"], "sgreen": s["sgreen"],
            "same": sum(1 for r in same if r["verdict"].get("class") is None), "same_n": len(same),
            "gpic": sum(1 for r in gate if r["facts"].get("picture") is True),
            "guse": sum(1 for r in gate if r["facts"].get("usable_on_call") is not None),
            "succ": s["succ"], "reached": s["reached"], "p": fmt_p(s), "cost": s["cost"],
            "cpg": s["cost"] / s["green"] if s["green"] else float("inf"), "mean": s["seconds"] / s["n"],
        })
    print("| rank (official) | model | tier | official green /60 | strong-bar green /60 | same-bar green /33 | gate picture /21 "
          "| gate usable /21 | succeeded | strong-bar succeeded | reached | p | cost $ | $ / green | mean s |")
    print("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
    ranked = sorted(rows_out, key=lambda x: (-x["green"], -x["sgreen"], -x["same"], x["cost"]))
    for i, x in enumerate(ranked, 1):
        print(f"| {i} | {SHORT[x['m']]} | {x['tier']} | {x['green']} | {x['sgreen']} | {x['same']}/{x['same_n']} | {x['gpic']} | "
              f"{x['guse']} | {x['succ']} | {x['ssucc']} | {x['reached']} | {x['p']} | {x['cost']:.4f} | {x['cpg']:.4f} | {x['mean']:.0f} |")
    for name, keyf in (("strong-bar green", lambda x: (-x["sgreen"], -x["same"], x["cost"])),
                       ("same-bar green", lambda x: (-x["same"], -x["sgreen"], x["cost"])),
                       ("gate picture", lambda x: (-x["gpic"], -x["guse"], x["cost"])),
                       ("strong-bar succeeded", lambda x: (-x["ssucc"], -x["sgreen"], x["cost"])),
                       ("cost per green (lower first)", lambda x: (x["cpg"],))):
        val = {"strong-bar green": "sgreen", "same-bar green": "same", "gate picture": "gpic", "strong-bar succeeded": "ssucc"}
        print(f"- by {name}: " + " > ".join(f"{SHORT[x['m']]} ({x[val[name]] if name in val else round(x['cpg'], 4)})"
                                           for x in sorted(rows_out, key=keyf)))


# ---------------------------------------------------------------- A.6 differs from the best v14 model

def cell_score(s):
    return (s["green"], s["succ"], s["reached"], s["passed"])


def differs(cells):
    print("\n## A.6 Cells where a new model differs from the best v14 model on that cell by >= 2 of 3\n")
    print("Three readings. (a) OFFICIAL: best v14 model on a cell = the highest (green, succeeded, reached, passed) of "
          "the four v14 models (ties listed); compared on reached, succeeded, task pass (passed count) and green, as "
          "v14's §3.1 read moves; positive = the new model higher. On a picture cell each model's succeeded and green "
          "are on its own tier's bar, so a strong new model against a floor best crosses bars (column 'bars'). "
          "(b) PICTURE BAR, like for like: the new model's picture-exact count against the best v14 picture count on "
          "the cell. (c) USABLE BAR, like for like: the same on usable generation.\n")
    tasks = OrderedDict()
    for key in sorted(cells, key=sort_key):
        tasks.setdefault((key[0], key[1]), None)
    fmt = lambda s: f"r{s['reached']} s{s['succ']} p{fmt_p(s)} [{fmt_classes(s)}]"
    official, pic, use = [], [], []
    for family, task in tasks:
        olds = [(m, stats(cells[(family, task, m)])) for m in OLD]
        top = max(cell_score(s) for _, s in olds)
        best = [(m, s) for m, s in olds if cell_score(s) == top]
        bm, bs = best[0]
        for m in NEW:
            s = stats(cells[(family, task, m)])
            d = {"r": s["reached"] - bs["reached"], "s": s["succ"] - bs["succ"], "p": s["passed"] - bs["passed"],
                 "g": s["green"] - bs["green"]}
            if any(abs(x) >= 2 for x in d.values()):
                cross = s["picture_cell"] and cells[(family, task, m)][0]["facts"]["tier"] != cells[(family, task, bm)][0]["facts"]["tier"]
                official.append((family, task, m, s, best, d, "cross" if cross else "same"))
            if s["picture_cell"]:
                bp = max(x["pictured"] for _, x in olds)
                bu = max(x["usable"] for _, x in olds)
                who_p = [SHORT[o] for o, x in olds if x["pictured"] == bp]
                who_u = [SHORT[o] for o, x in olds if x["usable"] == bu]
                if abs(s["pictured"] - bp) >= 2:
                    pic.append((task, m, s["pictured"], bp, who_p))
                if abs(s["usable"] - bu) >= 2:
                    use.append((task, m, s["usable"], bu, who_u))
    print(f"### (a) official: {len(official)} (cell, new model) pairs\n")
    print("| family | task | new model | Δr | Δs | Δp | Δg | bars | new r s p [classes] | best v14 model(s) | best v14 r s p [classes] |")
    print("|---|---|---|---|---|---|---|---|---|---|---|")
    for family, task, m, s, best, d, bars in official:
        print(f"| {family} | {task} | {SHORT[m]} | {d['r']:+d} | {d['s']:+d} | {d['p']:+d} | {d['g']:+d} | {bars} | {fmt(s)} | "
              f"{', '.join(SHORT[x] for x, _ in best)} | {fmt(best[0][1])} |")
    print(f"\n### (b) picture bar: {len(pic)} pairs\n")
    print("| task | new model | new picture | best v14 picture | best v14 model(s) on the picture | Δ |")
    print("|---|---|---|---|---|---|")
    for task, m, x, bp, who in pic:
        print(f"| {task} | {SHORT[m]} | {x}/3 | {bp}/3 | {', '.join(who)} | {x - bp:+d} |")
    print(f"\n### (c) usable bar: {len(use)} pairs\n")
    print("| task | new model | new usable | best v14 usable | best v14 model(s) | Δ |")
    print("|---|---|---|---|---|---|")
    for task, m, x, bu, who in use:
        print(f"| {task} | {SHORT[m]} | {x}/3 | {bu}/3 | {', '.join(who)} | {x - bu:+d} |")
    print("\n### (d) the official comparison against the best v14 model of the SAME tier (one bar throughout)\n")
    same_tier = {"anthropic/claude-opus-5-5": OLD[:2], "openai_api/gpt-6-sol": OLD[:2], "openai_api/gpt-6-luna": OLD[2:]}
    print("| family | task | new model | Δr | Δs | Δp | Δg | new r s p [classes] | best same-tier v14 |")
    print("|---|---|---|---|---|---|---|---|---|")
    n = 0
    for family, task in tasks:
        for m in NEW:
            olds = [(o, stats(cells[(family, task, o)])) for o in same_tier[m]]
            top = max(cell_score(x) for _, x in olds)
            best = [(o, x) for o, x in olds if cell_score(x) == top]
            bs = best[0][1]
            s = stats(cells[(family, task, m)])
            d = {"r": s["reached"] - bs["reached"], "s": s["succ"] - bs["succ"], "p": s["passed"] - bs["passed"],
                 "g": s["green"] - bs["green"]}
            if any(abs(x) >= 2 for x in d.values()):
                n += 1
                print(f"| {family} | {task} | {SHORT[m]} | {d['r']:+d} | {d['s']:+d} | {d['p']:+d} | {d['g']:+d} | {fmt(s)} | "
                      f"{', '.join(SHORT[o] for o, _ in best)} {fmt(bs)} |")
    print(f"\n{n} pairs against the best same-tier v14 model.")
    print("\nPer-run lines for every flagged cell are A2_evidence.out's.")


# ---------------------------------------------------------------- A.7 reds

def reason_kind(row):
    reason = " ".join((row.get("reason") or "").split())
    cls = row["verdict"].get("class")
    failed = [k for k, ok in (row.get("conduct") or {}).items() if ok is False]
    if row.get("stopped") == "deadline":
        return "600 s deadline stop"
    if reason.startswith("no `task` call"):
        return "no `task` call; start_process in the tally" if "start_process" in reason else "no `task` call; no start_process"
    if re.match(r"the suite was handed to \d+ tasks", reason):
        return "the suite handed to more than one `task`"
    if reason.startswith("a second task for"):
        return "a second `task` for files already handed out"
    if re.match(r"\d+ task call\(s\) in the first message, not five", reason):
        return "fewer than five `task` calls in the first message"
    if reason.startswith("the merged reply names no"):
        return "the merged reply misses a finding"
    if reason.startswith("the picture is not the objective's"):
        m = re.search(r"\(silent: ([^)]*)\)", reason)
        return f"picture red ({m.group(1) if m else '?'})"
    if reason.startswith("the script was refused"):
        m = re.match(r"the script was refused (\w+)", reason)
        return f"compose refused ({m.group(1)})"
    if reason.startswith("no compose call and no round fanned two task calls"):
        return "no door: no compose call and no two-`task` fan"
    if reason.startswith("no compose call: the model called"):
        return "no compose call (did it with tools)"
    if reason.startswith("no input_accepted{origin: task_result}"):
        return "no task_result receipt: every `task` call waited"
    if re.search(r"composed \d+ tasks and no step reads two model members", reason):
        return "composed, but no step reads two model members"
    if re.search(r"did not complete under", reason):
        return "a composed step failed (did not complete)"
    if not reason and failed:
        return "conduct only: " + ", ".join(failed)
    if not reason and cls == "cache under floor":
        return "cache under floor (success held)"
    if not reason and cls == "disagreement":
        return "disagreement: succeeded, verification failed"
    if not reason:
        return f"(no reason) class {cls}"
    return reason[:80]


def reds(cells):
    print("\n## A.7 Reds by reason kind, per family and model (every record whose class is not green)\n")
    for family in FAMILIES:
        c = {m: Counter(reason_kind(r) for k, rows in cells.items() if k[0] == family and k[2] == m
                        for r in rows if r["verdict"].get("class") is not None) for m in ORDER}
        kinds = sorted({x for m in ORDER for x in c[m]}, key=lambda x: (-sum(c[m][x] for m in ORDER), x))
        print(f"\n### {family}: reds " + ", ".join(f"{SHORT[m]} {sum(c[m].values())}" for m in ORDER) + "\n")
        print("| reason kind | " + " | ".join(SHORT[m] for m in ORDER) + " |")
        print("|---|" + "---|" * len(ORDER))
        for kind in kinds:
            print(f"| {kind} | " + " | ".join(str(c[m].get(kind, 0)) for m in ORDER) + " |")
        cf = {m: Counter(k2 for k, rows in cells.items() if k[0] == family and k[2] == m for r in rows
                         for k2, ok in (r.get("conduct") or {}).items() if ok is False) for m in ORDER}
        print("\nconduct checks failed: " + "; ".join(f"{SHORT[m]} {dict(cf[m]) or 0}" for m in ORDER))
    print("\n### every v15 red, in full\n")
    for key in sorted(cells, key=sort_key):
        if key[2] not in NEW:
            continue
        for r in cells[key]:
            if r["verdict"].get("class") is not None:
                print(f"- {key[1]} {SHORT[key[2]]} {run_line(r)}")


def main():
    cells, meta = load()
    inputs(cells, meta)
    per_cell_tables(cells)
    green_matrix(cells)
    family_model(cells)
    both_bars(cells)
    ranking(cells)
    differs(cells)
    reds(cells)


if __name__ == "__main__":
    main()
```

### `A2_evidence.py`

```python
#!/usr/bin/env python3
"""SECTION A, the evidence behind the flagged cells (read-only).

For every record of the cells A1 flags (a new model >= 2 of 3 from the best v14
model on reached / succeeded / task pass / green, or on the picture or usable
count), and for every v15 red, print what the record and its trace say:

- the spine's tool rounds in order (spine rN: name(input head) ...), the spine
  FOLLOWED from r1 through each round's calls (round keys are loop-global: a
  delegated child's or a composed model step's rounds take the next rN too);
- on a compose record, the first compose call's plan as a shape (T tool,
  M model with rN = N named results, S script stage, P[...] an "all" group,
  U[...] an until/any group, (...) a sequence inside a group) and the picture fact;
- the verdict, reason, verification output and the family facts that decide it.

Traces: e2e/artifacts/evals/<label>/<task>.<model slug>.nexus.<n>.json.
"""
import json
import os
import re
import sys
from collections import Counter

sys.path.insert(0, os.path.dirname(__file__))
from A1_cells import (NEW, OLD, SHORT, load, stats, cell_score, is_pic, sort_key)  # noqa: E402

REPO = "/Users/jasl/Workspaces/cybros-ai.alt2"
ART = os.path.join(REPO, "e2e/artifacts/evals")
LABEL = {"v15": "2026-09-26-v15-", "v14": "2026-09-26-v14-"}


def trace_path(row):
    ver = "v15" if row["model"] in NEW else "v14"
    slug = row["model"].replace("/", "_")
    return os.path.join(ART, LABEL[ver] + row["family"], f"{row['task']}.{slug}.{row['style']}.{row['run']}.json")


def load_trace(row):
    path = trace_path(row)
    if not os.path.exists(path):
        return None
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def head(text, n=70):
    text = " ".join(str(text).split())
    return text[:n] + ("..." if len(text) > n else "")


def call_summary(row):
    name, inp = row.get("tool_name"), row.get("tool_input") or {}
    if name == "task":
        return f"task(wait={inp.get('wait')}, '{head(inp.get('prompt'), 60)}')"
    if name in ("bash", "start_process"):
        return f"{name}('{head(inp.get('command'), 60)}')"
    if name == "compose":
        return f"compose(wait={inp.get('wait')}, {len(inp.get('script') or '')} chars)"
    if name == "spawn":
        return f"spawn('{head(inp.get('prompt') or inp.get('task') or inp, 50)}')"
    if name in ("read", "write", "edit", "ls", "find", "grep"):
        return f"{name}({head(inp.get('path') or inp.get('pattern') or '', 40)})"
    return f"{name}({head(json.dumps(inp), 40)})"


def spine_rounds(trace):
    """The spine's own tool rounds, in order. Round keys are loop-global: a delegated child's or a
    composed model step's rounds take the next rN too, so the spine is FOLLOWED, not read off the key:
    from r1, a spine round's calls are the rNtM rows whose `after` names that round, and the next
    spine round is the rN those calls belong to. Returns [(n, [rows])] and the number of other
    rNtM tool rounds (children's and composed steps')."""
    tool_rows = [r for r in trace["tasks"] if r.get("kind") == "tool_task" and re.fullmatch(r"r\d+t\d+", r["key"])]
    out, cur, seen = [], "r1", set()
    while cur not in seen:
        seen.add(cur)
        calls = [r for r in tool_rows if cur in (r.get("after") or [])]
        if not calls:
            break
        n = int(re.match(r"r(\d+)t", calls[0]["key"]).group(1))
        calls = [r for r in calls if r["key"].startswith(f"r{n}t")]
        out.append((n, sorted(calls, key=lambda r: int(r["key"].split("t")[1]))))
        cur = f"r{n}"
    spine_n = {n for n, _ in out}
    others = {int(re.match(r"r(\d+)t", r["key"]).group(1)) for r in tool_rows} - spine_n
    return out, len(others)


def spine_calls(trace, limit_rounds=6):
    rounds, others = spine_rounds(trace)
    out = []
    for n, rows in rounds[:limit_rounds]:
        out.append(f"spine r{n}: " + "; ".join(call_summary(r) for r in rows))
    more = len(rounds) - limit_rounds
    tail = f"{len(rounds)} spine tool rounds, {sum(len(r) for _, r in rounds)} spine calls; {others} tool rounds of children or composed steps"
    out.append(("(+%d more spine rounds) " % more if more > 0 else "") + tail)
    return out


def shape(steps):
    out = []
    for step in steps or []:
        if isinstance(step, list):
            out.append("(" + " ".join(shape(step)) + ")")
            continue
        if not isinstance(step, dict):
            continue
        if "parallel" in step:
            inner = shape(step["parallel"])
            out.append(("U[" if "until" in step else "P[") + " ".join(inner) + "]")
        elif "tool" in step:
            out.append("T" if step["tool"].get("name") in ("bash", "grep", "read") else f"T:{step['tool'].get('name')}")
        elif "model" in step:
            res = step["model"].get("results") or []
            out.append("M" + (f"r{len(res)}" if res else ""))
        elif "script" in step:
            out.append("S")
        else:
            out.append("?" + ",".join(step))
    return out


def compose_line(row):
    f = row.get("facts") or {}
    score = f.get("score")
    if score is None:
        return None
    if not isinstance(score, dict):
        return f"score: {score}"
    if score.get("refusal"):
        return f"first call refused {score.get('refusal')} ({head(score.get('detail'), 110)}); usable_on_call {f.get('usable_on_call')}"
    pic = "exact" if f.get("picture") is True else head(f.get("picture"), 60)
    reads = (score.get("graph") or {}).get("reads") or {}
    reads_s = "; ".join(f"{k}<-{','.join(v)}" for k, v in reads.items() if k.startswith("model"))
    return f"shape {' '.join(shape(score.get('steps')))} | picture {pic} | model reads {reads_s}"


FACT_KEYS = ("called", "task_calls", "suite_in_background", "refuters", "waited", "woken_loops", "door",
             "read_before_dispatch", "loop_style", "merge_turn", "orphans_named")


def evidence(row, rounds=6):
    v, f = row["verdict"], row.get("facts") or {}
    lines = [f"#{row['run']} {v.get('class') or 'green'} r={v.get('reached')} s={v.get('succeeded')} p={v.get('task_pass')} "
             f"{row['seconds']}s ${float(row['efficiency']['cost_amount']):.4f} :: {head(row.get('reason') or '', 160)}"]
    facts = {k: f[k] for k in FACT_KEYS if k in f}
    if facts:
        lines.append("   facts " + head(json.dumps(facts), 300))
    if f.get("verification_output"):
        lines.append("   verification " + head(f["verification_output"], 200))
    c = compose_line(row)
    if c:
        lines.append("   " + c)
    t = load_trace(row)
    if t is None:
        lines.append("   (no trace)")
    else:
        for x in spine_calls(t, rounds):
            lines.append("   " + head(x, 330))
    lines.append("   reply: " + head(f.get("reply") or "", 220))
    return lines


def flagged(cells):
    tasks = sorted({(k[0], k[1]) for k in cells}, key=lambda x: sort_key((x[0], x[1], NEW[0])))
    out = []
    for family, task in tasks:
        olds = [(m, stats(cells[(family, task, m)])) for m in OLD]
        top = max(cell_score(s) for _, s in olds)
        best = [m for m, s in olds if cell_score(s) == top]
        bs = stats(cells[(family, task, best[0])])
        bp = max(s["pictured"] for _, s in olds)
        bu = max(s["usable"] for _, s in olds)
        for m in NEW:
            s = stats(cells[(family, task, m)])
            d = [s["reached"] - bs["reached"], s["succ"] - bs["succ"], s["passed"] - bs["passed"], s["green"] - bs["green"]]
            pd = [s["pictured"] - bp, s["usable"] - bu] if s["picture_cell"] else []
            if any(abs(x) >= 2 for x in d + pd):
                out.append((family, task, m, best))
    return out


def main():
    cells, _ = load()
    pairs = flagged(cells)
    print(f"## A2 evidence: {len(pairs)} flagged (cell, new model) pairs; every record of the new model and of the "
          f"best v14 model(s) on the cell\n")
    seen = set()
    for family, task, m, best in pairs:
        print(f"### {task} / {SHORT[m]} (best v14: {', '.join(SHORT[b] for b in best)})\n")
        for model in [m] + [b for b in best if (family, task, b) not in seen]:
            if model in OLD:
                seen.add((family, task, model))
            print(f"**{SHORT[model]}**")
            for row in cells[(family, task, model)]:
                for line in evidence(row):
                    print(line)
            print()
    print("\n## every v15 red not in a flagged cell\n")
    keys = {(f, t, m) for f, t, m, _ in pairs}
    for key in sorted(cells, key=sort_key):
        if key[2] not in NEW or key in keys:
            continue
        for row in cells[key]:
            if row["verdict"].get("class") is not None:
                print(f"**{key[1]} {SHORT[key[2]]}**")
                for line in evidence(row):
                    print(line)
                print()
    print("\n## spine tool rounds per model, every family (the spine followed from r1, not read off the key)\n")
    for model in NEW + OLD:
        firsts, multi = Counter(), Counter()
        for key, rows in cells.items():
            if key[2] != model:
                continue
            for row in rows:
                t = load_trace(row)
                if t is None:
                    multi["no trace"] += 1
                    continue
                rounds, _ = spine_rounds(t)
                if rounds:
                    firsts[len(rounds[0][1])] += 1
                    multi["rounds"] += len(rounds)
                    multi["multi"] += sum(1 for _, v in rounds if len(v) > 1)
                    multi["calls"] += sum(len(v) for _, v in rounds)
                else:
                    multi["no spine call"] += 1
        print(f"- {SHORT[model]}: first spine tool round's call count {dict(sorted(firsts.items()))}; spine tool rounds "
              f"{multi['rounds']}, with >1 call {multi['multi']} ({multi['multi'] / max(multi['rounds'], 1):.3f}); "
              f"calls per spine tool round {multi['calls'] / max(multi['rounds'], 1):.2f}; records with no spine call "
              f"{multi['no spine call']}; no trace {multi['no trace']}")

    fan_habit(cells)


def fan_habit(cells):
    print("\n## the delegation fan per model: records whose spine made >= 2 `task` calls in all, and whether any one "
          "spine round carried >= 2 of them (task and workflow families)\n")
    print("| model | records with >= 2 spine task calls | of those, a round with >= 2 task calls | max task calls in one "
          "spine round (distribution) | records with a spawn call |")
    print("|---|---|---|---|---|")
    for model in NEW + OLD:
        n = fanned = spawned = 0
        maxes = Counter()
        for key, rows in cells.items():
            if key[2] != model or key[0] == "compose":
                continue
            for row in rows:
                t = load_trace(row)
                rounds, _ = spine_rounds(t)
                per = [sum(1 for r in rs if r.get("tool_name") == "task") for _, rs in rounds]
                spawned += any(r.get("tool_name") == "spawn" for _, rs in rounds for r in rs)
                if sum(per) >= 2:
                    n += 1
                    fanned += max(per) >= 2
                    maxes[max(per)] += 1
        print(f"| {SHORT[model]} | {n} | {fanned} | {dict(sorted(maxes.items()))} | {spawned} |")


if __name__ == "__main__":
    main()
```

### `A3_o7_merge.rb`

```ruby
# SECTION A copy of v14 C-scripts/c1_o7_merge.rb, run unchanged on the v15 labels via O7_LABELS (read-only, in memory).
# C(1): preview of one candidate correction to O7's picture — the merge admits a tool that computes
# over what it waits on (`"merge" => "model|tool|script"`, `computes: %w[na nb nc merge]`), as the
# normalisers already do — OFFLINE and IN MEMORY: `Objectives.find("O7")` is swapped for the
# re-read and restored; every workflow-barrier-free-pipeline and compose-three-stage-pairing record
# of v13 (last line per key) and v14 is re-read through today's harness twice (shipped O7, then
# the candidate) and every move in verdict, class, reason bucket or picture fact is printed.
# Nothing is appended. Run from e2e/: bundle exec ruby <this>
require "json"
require "timeout"
$stdout.sync = true
require_relative "/Users/jasl/Workspaces/cybros-ai.alt2/e2e/support/evals"
CB = E2E::ComposeBench
bench = E2E::Evals::Bench.read
corpus = E2E::Evals::Corpus.load_all(bench: bench)
o7 = CB::Objectives.find("O7")
shipped = o7.picture
candidate = CB::Picture.new(
  nodes: { "a" => "tool", "b" => "tool", "c" => "tool",
           "na" => "model|tool|script", "nb" => "model|tool|script", "nc" => "model|tool|script",
           "merge" => "model|tool|script" },
  edges: [%w[a na], %w[b nb], %w[c nc], %w[na merge], %w[nb merge], %w[nc merge]],
  reads: { "na" => %w[a], "nb" => %w[b], "nc" => %w[c], "merge" => %w[na nb nc] },
  computes: %w[na nb nc merge]
)
FIND = CB::Objectives.method(:find)
def bucket(record)
  text = "#{record["reason"]} #{record.dig("facts", "picture")}"
  text[/\(silent: ([^)]*)\)/, 1] || (record.dig("facts", "picture") == true || record["reason"].to_s.empty? ? "exact" : text[0, 50])
end
def reread(record, task)
  E2E::Evals::Rescore.rescored(record, task, E2E::Evals::Rescore.trace_of(record, record["artifact"]), Time.now.utc)
end
moves = 0
total = 0
LABELS = ENV.fetch("O7_LABELS", "2026-09-25-v13-workflow 2026-09-25-v13-compose 2026-09-26-v14-workflow 2026-09-26-v14-compose").split
LABELS.each do |label|
  E2E::Evals::Records.read(File.join(bench.runs_dir, label)).each do |record|
    next unless %w[workflow-barrier-free-pipeline compose-three-stage-pairing].include?(record["task"])
    next if record.dig("facts", "called", "compose").to_i.zero?
    total += 1
    task = corpus.find(record["task"])
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    puts "  start #{record["task"]} #{record["model"].split("/").last} ##{record["run"]} (#{label})"
    before = begin
      Timeout.timeout(60) { reread(record, task) }
    rescue Timeout::Error
      puts "  SHIPPED re-read did not finish in 60 s: skipped"
      next
    end
    puts "  #{record["task"]} #{record["model"].split("/").last} ##{record["run"]} (#{label}): shipped re-read #{(Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0).round(2)} s -> #{before["verdict"].slice("succeeded", "class")} #{bucket(before)}; candidate re-read starting"
    CB::Objectives.define_singleton_method(:find) { |id| id == "O7" ? o7.with(picture: candidate) : FIND.call(id) }
    after = begin
      Timeout.timeout(30) { reread(record, task) }
    rescue Timeout::Error
      { "verdict" => { "succeeded" => "TIMEOUT", "class" => "TIMEOUT" }, "reason" => "the candidate's re-read did not finish in 30 s", "facts" => {} }
    ensure
      CB::Objectives.define_singleton_method(:find) { |id| FIND.call(id) }
    end
    b = [before["verdict"].slice("succeeded", "class"), bucket(before)]
    a = [after["verdict"].slice("succeeded", "class"), bucket(after)]
    tag = b == a ? "" : " MOVES -> #{a.inspect}"
    moves += 1 unless b == a
    puts "#{label} #{record["task"]} #{record["model"].split("/").last} ##{record["run"]} tier=#{record.dig("facts", "tier")} pass=#{record.dig("verdict", "task_pass")} " \
         "shipped=#{b.inspect}#{tag}"
  end
end
puts "#{total} composed records re-read twice in memory; #{moves} move under the candidate"
```

### `A4_scripts.py`

```python
#!/usr/bin/env python3
"""SECTION A: the compose scripts (and failed rows) behind a few flagged v15 records, whole (read-only).

Prints each named record's compose calls' scripts from its trace, and any task row that ended
failed with its error key/detail, so the reading can quote what the model wrote.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
from A2_evidence import load_trace  # noqa: E402
from A1_cells import load  # noqa: E402

WANT = [
    ("task", "task-background-suite", "anthropic/claude-opus-5-5", 3),
    ("task", "task-mail", "anthropic/claude-opus-5-5", 1),
    ("compose", "compose-grep-then-edit", "openai_api/gpt-6-sol", 1),
    ("compose", "compose-grep-then-edit", "openai_api/gpt-6-sol", 3),
    ("workflow", "workflow-judge-panel", "openai_api/gpt-6-sol", 1),
    ("task", "task-fan-five", "openai_api/gpt-6-sol", 1),
]


def main():
    cells, _ = load()
    for family, task, model, run in WANT:
        row = next(r for r in cells[(family, task, model)] if r["run"] == run)
        t = load_trace(row)
        print(f"### {task} {model} #{run}: {row['verdict']} :: {' '.join((row.get('reason') or '').split())[:200]}\n")
        for r in t["tasks"]:
            if r.get("tool_name") == "compose":
                print(f"- {r['key']} compose status={r['status']} wait={r['tool_input'].get('wait')}:")
                print("```js\n" + r["tool_input"].get("script", "") + "\n```")
            if r.get("status") == "failed" or r.get("error_key"):
                print(f"- FAILED {r['key']} kind={r['kind']} tool={r.get('tool_name')} error={r.get('error_key')} "
                      f"detail={json.dumps(r.get('error_detail'))[:300]} input={json.dumps(r.get('tool_input'))[:300]}")
        print()


if __name__ == "__main__":
    main()
```

### `A5_doors.py`

```python
#!/usr/bin/env python3
"""SECTION A: the door each model took on the workflow family, per task (facts.door as recorded;
null = no door), and the compose-vs-task split per model (read-only)."""
import os
import sys
from collections import Counter

sys.path.insert(0, os.path.dirname(__file__))
from A1_cells import ORDER, SHORT, load  # noqa: E402


def main():
    cells, _ = load()
    tasks = sorted({k[1] for k in cells if k[0] == "workflow"})
    print("| task | " + " | ".join(SHORT[m] for m in ORDER) + " |")
    print("|---|" + "---|" * len(ORDER))
    tot = {m: Counter() for m in ORDER}
    for task in tasks:
        cols = []
        for m in ORDER:
            c = Counter(str(r["facts"].get("door")) for r in cells[("workflow", task, m)])
            tot[m] += c
            cols.append(", ".join(f"{k} {v}" for k, v in sorted(c.items())))
        print(f"| {task} | " + " | ".join(cols) + " |")
    print("| **all** | " + " | ".join(", ".join(f"{k} {v}" for k, v in sorted(tot[m].items())) for m in ORDER) + " |")


if __name__ == "__main__":
    main()
```

### `A6_wait_compose.py`

```python
#!/usr/bin/env python3
"""SECTION A: what a 'compose' door is made of on the task and workflow families, per model (read-only).

For every task/workflow record: spine `task` calls, the most in one spine round, compose calls, and
whether every compose script is only g.wait over already-dispatched tasks (a 'wait-compose': the fan
was dispatched one `task` per message and the compose only collects it) or builds steps
(g.tool / g.model / g.script / g.task ...)."""
import os
import re
import sys
from collections import Counter

sys.path.insert(0, os.path.dirname(__file__))
from A1_cells import NEW, OLD, SHORT, load  # noqa: E402
from A2_evidence import load_trace, spine_rounds  # noqa: E402

BUILD = re.compile(r"g\.(tool|model|script|task|stage|value)\s*\(")


def main():
    cells, _ = load()
    print("| model | family | records | with a compose call | every compose only g.wait | compose builds steps | "
          "spine task calls (sum) | records with >=2 task calls in one spine round |")
    print("|---|---|---|---|---|---|---|---|")
    detail = []
    for m in NEW + OLD:
        for fam in ("task", "workflow"):
            c = Counter()
            for key, rows in cells.items():
                if key[2] != m or key[0] != fam:
                    continue
                for row in rows:
                    t = load_trace(row)
                    rounds, _ = spine_rounds(t)
                    scripts = [r["tool_input"].get("script", "") for _, rs in rounds for r in rs if r.get("tool_name") == "compose"]
                    per = [sum(1 for r in rs if r.get("tool_name") == "task") for _, rs in rounds]
                    c["n"] += 1
                    c["tasks"] += sum(per)
                    c["fan"] += max(per or [0]) >= 2
                    if scripts:
                        c["compose"] += 1
                        if all(not BUILD.search(s) and "g.wait" in s for s in scripts):
                            c["wait_only"] += 1
                            detail.append(f"{SHORT[m]} {key[1]} #{row['run']}: wait-only compose; class "
                                          f"{row['verdict'].get('class') or 'green'}; spine task calls per round {[x for x in per if x]}")
                        else:
                            c["builds"] += 1
            print(f"| {SHORT[m]} | {fam} | {c['n']} | {c['compose']} | {c['wait_only']} | {c['builds']} | {c['tasks']} | {c['fan']} |")
    print("\nwait-only compose records:")
    for d in detail:
        print(f"- {d}")


if __name__ == "__main__":
    main()
```

### `A7_cache_ceiling.py`

```python
#!/usr/bin/env python3
"""SECTION A: every v15 record the cache bar reads under 0.80, with its per-round series and the
ceiling v14's §3.5 defines (sum of the previous rounds' input over the sum of input, measured rounds
only: the rate a provider serving every whole previous prompt would give) (read-only)."""
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
from A1_cells import NEW, SHORT, after_r1, load  # noqa: E402


def main():
    cells, _ = load()
    for key, rows in sorted(cells.items()):
        if key[2] not in NEW:
            continue
        for r in rows:
            series = r["efficiency"].get("cache_read_series") or {}
            vals = list(series.values())
            if len(vals) - 1 < 2:
                continue
            rate = after_r1(series)
            if rate is None or rate >= 0.80:
                continue
            prev = sum(int(vals[i - 1][0]) for i in range(1, len(vals)))
            inp = sum(int(v[0]) for v in vals[1:])
            served = [round(int(vals[i][1]) / int(vals[i - 1][0]), 4) for i in range(1, len(vals))]
            print(f"{key[1]} {SHORT[key[2]]} #{r['run']} class={r['verdict'].get('class')} after-r1 {rate} "
                  f"ceiling {prev / inp:.4f} series {series} read/previous-input per measured round {served}")


if __name__ == "__main__":
    main()
```

### `A8_checks.py`

```python
#!/usr/bin/env python3
"""SECTION A: per-run `task` dispatch on three cells the reading quotes (read-only): the spine's
`task` calls per round (rounds with none left out), each call's `wait`, and the g.wait count in
each compose script."""
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
from A1_cells import load  # noqa: E402
from A2_evidence import load_trace, spine_rounds  # noqa: E402

CELLS = [("workflow", "workflow-adversarial-verify", "openai_api/gpt-6-luna"),
         ("task", "task-fan-five", "openai_api/gpt-6-sol"),
         ("workflow", "workflow-fan-out-finders", "openai_api/gpt-6-sol")]


def main():
    cells, _ = load()
    for fam, task, m in CELLS:
        for r in cells[(fam, task, m)]:
            rounds, _ = spine_rounds(load_trace(r))
            per = [sum(1 for x in rs if x.get("tool_name") == "task") for _, rs in rounds]
            waits = [x["tool_input"].get("wait") for _, rs in rounds for x in rs if x.get("tool_name") == "task"]
            comp = [x["tool_input"]["script"].count("g.wait") for _, rs in rounds for x in rs if x.get("tool_name") == "compose"]
            print(task, m.split("/")[-1], r["run"], [p for p in per if p], "waits", waits, "g.wait per compose", comp)


if __name__ == "__main__":
    main()
```

### `A_assemble.py`

```python
#!/usr/bin/env python3
"""Assemble A-cells.md: the reading (A_head.md), then every output whole, then every script."""
import os

D = os.path.dirname(os.path.abspath(__file__))
OUT_MD = ["A1_cells.out", "A5_doors.out", "A6_wait_compose.out"]      # markdown already: headings demoted
OUT_TEXT = ["A2_evidence.out", "A3_o7_merge.out", "A4_scripts.out", "A7_cache_ceiling.out", "A8_checks.out"]
SCRIPTS = ["A1_cells.py", "A2_evidence.py", "A3_o7_merge.rb", "A4_scripts.py", "A5_doors.py", "A6_wait_compose.py",
           "A7_cache_ceiling.py", "A8_checks.py", "A_assemble.py"]


def read(name):
    with open(os.path.join(D, name), encoding="utf-8") as fh:
        return fh.read()


def demote(text, tag):
    out = []
    for line in text.splitlines():
        if line.startswith("## "):
            line = f"### [{tag}] " + line[3:]
        elif line.startswith("### "):
            line = "#### " + line[4:]
        elif line.startswith("#### "):
            line = "##### " + line[5:]
        out.append(line)
    return "\n".join(out)


def main():
    parts = [read("A_head.md").rstrip(), "\n\n---\n\n## Appendix 1 — outputs, whole\n"]
    for name in OUT_MD:
        parts.append(f"\n### `{name}`\n\n" + demote(read(name), name.split("_")[0]).rstrip() + "\n")
    for name in OUT_TEXT:
        body = read(name).rstrip().replace("```", "'''")
        parts.append(f"\n### `{name}`\n\n```text\n{body}\n```\n")
    parts.append("\n## Appendix 2 — scripts\n")
    for name in SCRIPTS:
        lang = "ruby" if name.endswith(".rb") else "python"
        parts.append(f"\n### `{name}`\n\n```{lang}\n{read(name).rstrip()}\n```\n")
    with open(os.path.join(D, "A-cells.md"), "w", encoding="utf-8") as fh:
        fh.write("".join(parts))


if __name__ == "__main__":
    main()
```
