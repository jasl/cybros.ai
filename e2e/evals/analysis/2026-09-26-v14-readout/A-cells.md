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

### task

| task | model | tier | r v14 | r v13 | s v14 | s v13 | p v14 | p v13 | classes v14 | classes v13 | bar v14 | bar v13 | mean s v14 | mean s v13 | cost v14 | cost v13 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| task-background-suite | glm-5.3 | strong | 3/3 | 3/3 | 2/3 | 3/3 | — | — | mc1 g2 | g3 | = s | = s | 220 | 143 | 0.6201 | 0.3797 |
| task-background-suite | kimi-k3 | strong | 3/3 | 2/3 | 3/3 | 2/3 | — | — | cuf2 g1 | mc1 cuf2 g0 | = s | = s | 96 | 129 | 0.6361 | 0.6436 |
| task-background-suite | deepseek-flash | floor | 0/3 | 1/3 | 0/3 | 1/3 | — | — | mc3 g0 | mc2 g1 | = s | = s | 73 | 60 | 0.0330 | 0.0269 |
| task-background-suite | glm-5.3-flash | floor | 0/3 | 2/3 | 0/3 | 2/3 | — | — | mc3 g0 | mc1 g2 | = s | = s | 314 | 138 | 0.0814 | 0.0622 |
| task-detached-receipt | glm-5.3 | strong | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | = s | = s | 82 | 73 | 0.0993 | 0.0842 |
| task-detached-receipt | kimi-k3 | strong | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | = s | = s | 75 | 100 | 0.0713 | 0.3058 |
| task-detached-receipt | deepseek-flash | floor | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | = s | = s | 68 | 72 | 0.0098 | 0.0082 |
| task-detached-receipt | glm-5.3-flash | floor | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | = s | = s | 77 | 84 | 0.0161 | 0.0160 |
| task-fan-five | glm-5.3 | strong | 3/3 | 3/3 | 3/3 | 3/3 | — | — | cuf2 g1 | g3 | = s | = s | 109 | 97 | 0.3597 | 0.1935 |
| task-fan-five | kimi-k3 | strong | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | = s | = s | 99 | 86 | 0.5116 | 0.7417 |
| task-fan-five | deepseek-flash | floor | 2/3 | 1/3 | 2/3 | 1/3 | — | — | mc1 g2 | mc2 g1 | = s | = s | 73 | 63 | 0.0397 | 0.0321 |
| task-fan-five | glm-5.3-flash | floor | 3/3 | 3/3 | 1/3 | 2/3 | — | — | mc2 g1 | mc1 g2 | = s | = s | 107 | 102 | 0.0456 | 0.0551 |
| task-grep-three-control | glm-5.3 | strong | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | = s | = s | 19 | 19 | 0.0408 | 0.0292 |
| task-grep-three-control | kimi-k3 | strong | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | = s | = s | 66 | 15 | 0.0620 | 0.0589 |
| task-grep-three-control | deepseek-flash | floor | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | = s | = s | 14 | 12 | 0.0023 | 0.0022 |
| task-grep-three-control | glm-5.3-flash | floor | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | = s | = s | 18 | 14 | 0.0040 | 0.0045 |
| task-mail | glm-5.3 | strong | 1/3 | 1/3 | 1/3 | 1/3 | — | — | mc2 g1 | mc2 g1 | = s | = s | 56 | 63 | 0.0776 | 0.0925 |
| task-mail | kimi-k3 | strong | 1/3 | 0/3 | 1/3 | 0/3 | — | — | mc2 g1 | mc3 g0 | = s | = s | 46 | 17 | 0.1712 | 0.1157 |
| task-mail | deepseek-flash | floor | 3/3 | 2/3 | 3/3 | 2/3 | — | — | g3 | mc1 g2 | = s | = s | 79 | 53 | 0.0107 | 0.0097 |
| task-mail | glm-5.3-flash | floor | 0/3 | 0/3 | 0/3 | 0/3 | — | — | mc3 g0 | mc3 g0 | = s | = s | 29 | 36 | 0.0075 | 0.0060 |
| task-two-calls | glm-5.3 | strong | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | = s | = s | 19 | 15 | 0.0307 | 0.0195 |
| task-two-calls | kimi-k3 | strong | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | = s | = s | 16 | 16 | 0.1526 | 0.0879 |
| task-two-calls | deepseek-flash | floor | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | = s | = s | 11 | 11 | 0.0018 | 0.0019 |
| task-two-calls | glm-5.3-flash | floor | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | = s | = s | 16 | 26 | 0.0040 | 0.0053 |

### compose

| task | model | tier | r v14 | r v13 | s v14 | s v13 | p v14 | p v13 | classes v14 | classes v13 | bar v14 | bar v13 | mean s v14 | mean s v13 | cost v14 | cost v13 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| compose-background-suite | glm-5.3 | strong | 3/3 | 2/3 | 1/3 | 1/3 | — | — | mc2 g1 | mc2 g1 | x 1/3 (u 3) | x 1/3 (u 2) | 368 | 313 | 0.6159 | 0.3435 (1 null) |
| compose-background-suite | kimi-k3 | strong | 3/3 | 3/3 | 1/3 | 1/3 | — | — | mc2 g1 | mc2 g1 | x 1/3 (u 3) | x 1/3 (u 3) | 119 | 112 | 0.7700 | 0.7017 |
| compose-background-suite | deepseek-flash | floor | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | u 3/3 (x 1) | u 3/3 (x 0) | 84 | 126 | 0.0529 | 0.0711 |
| compose-background-suite | glm-5.3-flash | floor | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | u 3/3 (x 1) | u 3/3 (x 1) | 241 | 330 | 0.0517 | 0.0744 |
| compose-grep-then-edit | glm-5.3 | strong | 3/3 | 3/3 | 2/3 | 2/3 | 3/3 | 3/3 | dis1 cuf1 g1 | dis1 cuf1 g1 | x 2/3 (u 3) | x 2/3 (u 3) | 423 | 387 | 1.0991 | 0.8292 |
| compose-grep-then-edit | kimi-k3 | strong | 3/3 | 3/3 | 2/3 | 1/3 | 3/3 | 3/3 | dis1 cuf1 g1 | dis2 g1 | x 2/3 (u 3) | x 1/3 (u 3) | 73 | 51 | 0.4602 | 0.3169 |
| compose-grep-then-edit | deepseek-flash | floor | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | cuf1 g2 | cuf1 g2 | u 3/3 (x 3) | u 3/3 (x 2) | 100 | 67 | 0.0828 | 0.0538 |
| compose-grep-then-edit | glm-5.3-flash | floor | 3/3 | 2/3 | 3/3 | 2/3 | 3/3 | 2/3 | mc1 g2 | mc1 g2 | u 3/3 (x 1) | u 2/3 (x 1) | 572 | 385 | 0.0765 | 0.0377 (1 null) |
| compose-race | glm-5.3 | strong | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | x 3/3 (u 3) | x 3/3 (u 3) | 91 | 137 | 0.2132 | 0.4539 |
| compose-race | kimi-k3 | strong | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | x 3/3 (u 3) | x 3/3 (u 3) | 53 | 28 | 0.2743 | 0.2192 |
| compose-race | deepseek-flash | floor | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | cuf1 g2 | u 3/3 (x 3) | u 3/3 (x 2) | 30 | 33 | 0.0121 | 0.0197 |
| compose-race | glm-5.3-flash | floor | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | u 3/3 (x 2) | u 3/3 (x 2) | 152 | 230 | 0.0368 | 0.0319 |
| compose-race-anon | glm-5.3 | strong | 3/3 | 3/3 | 3/3 | 3/3 | — | — | mc1 g2 | g3 | x 3/3 (u 3) | x 3/3 (u 3) | 61 | 134 | 0.2191 | 0.4655 |
| compose-race-anon | kimi-k3 | strong | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | x 3/3 (u 3) | x 3/3 (u 3) | 50 | 58 | 0.2616 | 0.2640 |
| compose-race-anon | deepseek-flash | floor | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | cuf1 g2 | u 3/3 (x 3) | u 3/3 (x 2) | 30 | 40 | 0.0145 | 0.0246 |
| compose-race-anon | glm-5.3-flash | floor | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | u 3/3 (x 3) | u 3/3 (x 3) | 118 | 97 | 0.0244 | 0.0179 |
| compose-rendezvous | glm-5.3 | strong | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | x 1/3 (u 3) | x 0/3 (u 3) | 305 | 160 | 1.0618 | 0.6720 |
| compose-rendezvous | kimi-k3 | strong | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | x 0/3 (u 3) | x 0/3 (u 3) | 249 | 167 | 0.9095 | 0.9157 |
| compose-rendezvous | deepseek-flash | floor | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | cuf1 g2 | u 3/3 (x 0) | u 3/3 (x 0) | 87 | 126 | 0.0679 | 0.1217 |
| compose-rendezvous | glm-5.3-flash | floor | 3/3 | 3/3 | 3/3 | 3/3 | — | — | mc1 g2 | g3 | u 3/3 (x 2) | u 3/3 (x 0) | 486 | 495 | 0.0898 | 0.1022 |
| compose-review-angles | glm-5.3 | strong | 3/3 | 3/3 | 3/3 | 2/3 | — | — | g3 | mc1 g2 | x 3/3 (u 3) | x 2/3 (u 3) | 154 | 244 | 0.4667 | 0.6169 |
| compose-review-angles | kimi-k3 | strong | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | x 3/3 (u 3) | x 3/3 (u 3) | 119 | 111 | 0.8657 | 0.7256 |
| compose-review-angles | deepseek-flash | floor | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | u 3/3 (x 3) | u 3/3 (x 3) | 136 | 167 | 0.0871 | 0.1256 |
| compose-review-angles | glm-5.3-flash | floor | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | u 3/3 (x 3) | u 3/3 (x 2) | 197 | 183 | 0.0578 | 0.0601 |
| compose-single-read | glm-5.3 | strong | 3/3 | 3/3 | 3/3 | 3/3 | — | — | cuf1 g2 | g3 | = s | = s | 14 | 15 | 0.1071 | 0.0263 |
| compose-single-read | kimi-k3 | strong | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | = s | = s | 17 | 13 | 0.0957 | 0.0859 |
| compose-single-read | deepseek-flash | floor | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | = s | = s | 15 | 13 | 0.0025 | 0.0021 |
| compose-single-read | glm-5.3-flash | floor | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | = s | = s | 15 | 59 | 0.0062 | 0.0088 |
| compose-three-stage-pairing | glm-5.3 | strong | 3/3 | 3/3 | 3/3 | 2/3 | — | — | g3 | mc1 g2 | x 3/3 (u 3) | x 2/3 (u 3) | 225 | 460 | 0.3677 | 0.7401 |
| compose-three-stage-pairing | kimi-k3 | strong | 3/3 | 3/3 | 3/3 | 2/3 | — | — | g3 | mc1 g2 | x 3/3 (u 3) | x 2/3 (u 3) | 70 | 99 | 0.4815 | 0.6390 |
| compose-three-stage-pairing | deepseek-flash | floor | 3/3 | 3/3 | 3/3 | 3/3 | — | — | cuf2 g1 | g3 | u 3/3 (x 1) | u 3/3 (x 3) | 54 | 49 | 0.0339 | 0.0256 |
| compose-three-stage-pairing | glm-5.3-flash | floor | 2/3 | 2/3 | 2/3 | 2/3 | — | — | mc1 g2 | mc1 g2 | u 2/3 (x 1) | u 2/3 (x 1) | 262 | 269 | 0.0578 | 0.0515 |
| compose-two-source-fan-in | glm-5.3 | strong | 3/3 | 3/3 | 1/3 | 0/3 | — | — | mc2 g1 | mc3 g0 | x 1/3 (u 3) | x 0/3 (u 3) | 186 | 59 | 0.4465 | 0.1150 |
| compose-two-source-fan-in | kimi-k3 | strong | 3/3 | 3/3 | 0/3 | 0/3 | — | — | mc3 g0 | mc3 g0 | x 0/3 (u 3) | x 0/3 (u 3) | 112 | 88 | 0.4626 | 0.5516 |
| compose-two-source-fan-in | deepseek-flash | floor | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | u 3/3 (x 0) | u 3/3 (x 1) | 69 | 60 | 0.0264 | 0.0223 |
| compose-two-source-fan-in | glm-5.3-flash | floor | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | u 3/3 (x 2) | u 3/3 (x 1) | 169 | 174 | 0.0349 | 0.0408 |

### workflow

| task | model | tier | r v14 | r v13 | s v14 | s v13 | p v14 | p v13 | classes v14 | classes v13 | bar v14 | bar v13 | mean s v14 | mean s v13 | cost v14 | cost v13 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| workflow-adversarial-verify | glm-5.3 | strong | 3/3 | 3/3 | 3/3 | 1/3 | 3/3 | 3/3 | cuf1 g2 | dis2 cuf1 g0 | = s | = s | 296 | 256 | 1.6683 | 1.2612 |
| workflow-adversarial-verify | kimi-k3 | strong | 3/3 | 3/3 | 2/3 | 1/3 | 3/3 | 1/3 | dis1 cuf2 g0 | mc2 cuf1 g0 | = s | = s | 224 | 218 | 2.0306 | 2.7377 |
| workflow-adversarial-verify | deepseek-flash | floor | 1/3 | 3/3 | 0/3 | 3/3 | 2/3 | 3/3 | mc2 dis1 g0 | g3 | = s | = s | 182 | 244 | 0.1813 | 0.2415 |
| workflow-adversarial-verify | glm-5.3-flash | floor | 3/3 | 3/3 | 1/3 | 2/3 | 3/3 | 3/3 | dis2 g1 | dis1 g2 | = s | = s | 330 | 264 | 0.2902 | 0.2086 |
| workflow-barrier-free-pipeline | glm-5.3 | strong | 3/3 | 2/3 | 0/3 | 1/3 | 3/3 | 3/3 | dis3 g0 | mc1 dis1 cuf1 g0 | x 0/3 (u 3) | x 1/3 (u 2) | 166 | 246 | 0.4837 | 0.6528 |
| workflow-barrier-free-pipeline | kimi-k3 | strong | 0/3 | 0/3 | 0/3 | 0/3 | 3/3 | 3/3 | mc3 g0 | mc3 g0 | x 0/3 (u 0) | x 0/3 (u 0) | 45 | 35 | 0.1651 | 0.1881 |
| workflow-barrier-free-pipeline | deepseek-flash | floor | 0/3 | 1/3 | 0/3 | 1/3 | 3/3 | 3/3 | mc3 g0 | mc2 g1 | u 0/3 (x 0) | u 1/3 (x 0) | 34 | 47 | 0.0074 | 0.0185 |
| workflow-barrier-free-pipeline | glm-5.3-flash | floor | 2/3 | 2/3 | 2/3 | 2/3 | 3/3 | 3/3 | mc1 g2 | mc1 g2 | u 2/3 (x 0) | u 2/3 (x 0) | 118 | 90 | 0.0247 | 0.0216 |
| workflow-fan-out-finders | glm-5.3 | strong | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | g3 | g3 | = s | = s | 67 | 65 | 0.1305 | 0.1401 |
| workflow-fan-out-finders | kimi-k3 | strong | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | g3 | cuf3 g0 | = s | = s | 99 | 92 | 0.7978 | 1.1415 |
| workflow-fan-out-finders | deepseek-flash | floor | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | g3 | g3 | = s | = s | 56 | 54 | 0.0196 | 0.0201 |
| workflow-fan-out-finders | glm-5.3-flash | floor | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | g3 | g3 | = s | = s | 83 | 134 | 0.0591 | 0.0531 |
| workflow-judge-panel | glm-5.3 | strong | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | cuf3 g0 | cuf3 g0 | = s | = s | 369 | 243 | 1.6750 | 1.2282 |
| workflow-judge-panel | kimi-k3 | strong | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | g3 | cuf2 g1 | = s | = s | 106 | 167 | 0.7648 | 1.2487 |
| workflow-judge-panel | deepseek-flash | floor | 2/3 | 3/3 | 2/3 | 3/3 | 3/3 | 3/3 | mc1 g2 | g3 | = s | = s | 80 | 100 | 0.0441 | 0.0989 |
| workflow-judge-panel | glm-5.3-flash | floor | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | g3 | g3 | = s | = s | 165 | 247 | 0.0809 | 0.0867 |
| workflow-loop-until-dry | glm-5.3 | strong | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | g3 | g3 | = s | = s | 123 | 101 | 0.1681 | 0.2982 |
| workflow-loop-until-dry | kimi-k3 | strong | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | g3 | cuf2 g1 | = s | = s | 236 | 121 | 0.6073 | 0.9472 |
| workflow-loop-until-dry | deepseek-flash | floor | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | g3 | g3 | = s | = s | 51 | 62 | 0.0140 | 0.0130 |
| workflow-loop-until-dry | glm-5.3-flash | floor | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | mc1 g2 | g3 | = s | = s | 114 | 89 | 0.0565 | 0.0427 |

## A.3 Totals, v14 against v13 (A1)

`bar` sums the tier's bar over picture cells. That is the picture on the strong tier and usable generation on the
floor, so a mixed-tier row adds two different bars.

### by family

| group | v14 | v13 |
|---|---|---|
| task | r 58/72 · s 55/72 · p — · mc17 cuf4 · green 51/72 · $3.0889 · 5348 s (mean 74 s) | r 57/72 · s 56/72 · p — · mc16 cuf2 · green 54/72 · $2.9823 · 4328 s (mean 60 s) |
| compose | r 107/108 · s 96/108 · p 12/12 · bar 79/96 · mc13 dis2 cuf6 · green 87/108 · $9.9939 · 16522 s (mean 153 s) | r 105/108 · s 90/108 · p 11/12 · bar 72/96 · mc15 dis3 cuf5 · green 85/108 · $9.5737 (2 null) · 16616 s (mean 154 s) |
| workflow | r 50/60 · s 43/60 · p 59/60 · bar 2/12 · mc11 dis7 cuf6 · green 36/60 · $9.2688 · 8831 s (mean 147 s) | r 53/60 · s 47/60 · p 58/60 · bar 4/12 · mc9 dis4 cuf13 · green 34/60 · $10.6485 · 8631 s (mean 144 s) |

### by model (all families)

| group | v14 | v13 |
|---|---|---|
| glm-5.3 | r 58/60 · s 49/60 · p 18/18 · bar 17/27 · mc8 dis4 cuf8 · green 40/60 · $9.9508 · 10060 s (mean 168 s) | r 56/60 · s 46/60 · p 18/18 · bar 14/27 · mc10 dis4 cuf6 · green 40/60 · $8.6416 (1 null) · 9692 s (mean 162 s) |
| kimi-k3 | r 55/60 · s 48/60 · p 18/18 · bar 15/27 · mc10 dis2 cuf5 · green 43/60 · $10.5516 · 5912 s (mean 99 s) | r 53/60 · s 43/60 · p 16/18 · bar 13/27 · mc15 dis2 cuf10 · green 33/60 · $12.6364 · 5172 s (mean 86 s) |
| deepseek-flash | r 50/60 · s 49/60 · p 17/18 · bar 24/27 · mc10 dis1 cuf3 · green 46/60 · $0.7437 · 3975 s (mean 66 s) | r 53/60 · s 53/60 · p 18/18 · bar 25/27 · mc7 cuf4 · green 49/60 · $0.9393 · 4379 s (mean 73 s) |
| glm-5.3-flash | r 52/60 · s 48/60 · p 18/18 · bar 25/27 · mc13 dis2 · green 45/60 · $1.1056 · 10754 s (mean 179 s) | r 53/60 · s 51/60 · p 17/18 · bar 24/27 · mc8 dis1 · green 51/60 · $0.9871 (1 null) · 10332 s (mean 172 s) |

### by family x model

| group | v14 | v13 |
|---|---|---|
| task / glm-5.3 | r 16/18 · s 15/18 · p — · mc3 cuf2 · green 13/18 · $1.2283 · 1516 s (mean 84 s) | r 16/18 · s 16/18 · p — · mc2 · green 16/18 · $0.7986 · 1231 s (mean 68 s) |
| task / kimi-k3 | r 16/18 · s 16/18 · p — · mc2 cuf2 · green 14/18 · $1.6049 · 1193 s (mean 66 s) | r 14/18 · s 14/18 · p — · mc4 cuf2 · green 12/18 · $1.9536 · 1087 s (mean 60 s) |
| task / deepseek-flash | r 14/18 · s 14/18 · p — · mc4 · green 14/18 · $0.0973 · 955 s (mean 53 s) | r 13/18 · s 13/18 · p — · mc5 · green 13/18 · $0.0809 · 812 s (mean 45 s) |
| task / glm-5.3-flash | r 12/18 · s 10/18 · p — · mc8 · green 10/18 · $0.1585 · 1684 s (mean 94 s) | r 14/18 · s 13/18 · p — · mc5 · green 13/18 · $0.1492 · 1198 s (mean 67 s) |
| compose / glm-5.3 | r 27/27 · s 22/27 · p 3/3 · bar 17/24 · mc5 dis1 cuf2 · green 19/27 · $4.5970 · 5482 s (mean 203 s) | r 26/27 · s 19/27 · p 3/3 · bar 13/24 · mc7 dis1 cuf1 · green 18/27 · $4.2624 (1 null) · 5729 s (mean 212 s) |
| compose / kimi-k3 | r 27/27 · s 21/27 · p 3/3 · bar 15/24 · mc5 dis1 cuf1 · green 20/27 · $4.5811 · 2588 s (mean 96 s) | r 27/27 · s 19/27 · p 3/3 · bar 13/24 · mc6 dis2 · green 19/27 · $4.4196 · 2183 s (mean 81 s) |
| compose / deepseek-flash | r 27/27 · s 27/27 · p 3/3 · bar 24/24 · cuf3 · green 24/27 · $0.3800 · 1812 s (mean 67 s) | r 27/27 · s 27/27 · p 3/3 · bar 24/24 · cuf4 · green 23/27 · $0.4665 · 2044 s (mean 76 s) |
| compose / glm-5.3-flash | r 26/27 · s 26/27 · p 3/3 · bar 23/24 · mc3 · green 24/27 · $0.4358 · 6640 s (mean 246 s) | r 25/27 · s 25/27 · p 2/3 · bar 22/24 · mc2 · green 25/27 · $0.4253 (1 null) · 6660 s (mean 247 s) |
| workflow / glm-5.3 | r 15/15 · s 12/15 · p 15/15 · bar 0/3 · dis3 cuf4 · green 8/15 · $4.1255 · 3062 s (mean 204 s) | r 14/15 · s 11/15 · p 15/15 · bar 1/3 · mc1 dis3 cuf5 · green 6/15 · $3.5806 · 2732 s (mean 182 s) |
| workflow / kimi-k3 | r 12/15 · s 11/15 · p 15/15 · bar 0/3 · mc3 dis1 cuf2 · green 9/15 · $4.3656 · 2131 s (mean 142 s) | r 12/15 · s 10/15 · p 13/15 · bar 0/3 · mc5 cuf8 · green 2/15 · $6.2633 · 1902 s (mean 127 s) |
| workflow / deepseek-flash | r 9/15 · s 8/15 · p 14/15 · bar 0/3 · mc6 dis1 · green 8/15 · $0.2663 · 1208 s (mean 81 s) | r 13/15 · s 13/15 · p 15/15 · bar 1/3 · mc2 · green 13/15 · $0.3919 · 1523 s (mean 102 s) |
| workflow / glm-5.3-flash | r 14/15 · s 12/15 · p 15/15 · bar 2/3 · mc2 dis2 · green 11/15 · $0.5113 · 2430 s (mean 162 s) | r 14/15 · s 13/15 · p 15/15 · bar 2/3 · mc1 dis1 · green 13/15 · $0.4127 · 2474 s (mean 165 s) |

### by family x tier

| group | v14 | v13 |
|---|---|---|
| task / strong | r 32/36 · s 31/36 · p — · mc5 cuf4 · green 27/36 · $2.8331 · 2709 s (mean 75 s) | r 30/36 · s 30/36 · p — · mc6 cuf2 · green 28/36 · $2.7522 · 2318 s (mean 64 s) |
| task / floor | r 26/36 · s 24/36 · p — · mc12 · green 24/36 · $0.2558 · 2639 s (mean 73 s) | r 27/36 · s 26/36 · p — · mc10 · green 26/36 · $0.2301 · 2010 s (mean 56 s) |
| compose / strong | r 54/54 · s 43/54 · p 6/6 · bar 32/48 · mc10 dis2 cuf3 · green 39/54 · $9.1781 · 8070 s (mean 149 s) | r 53/54 · s 38/54 · p 6/6 · bar 26/48 · mc13 dis3 cuf1 · green 37/54 · $8.6820 (1 null) · 7912 s (mean 147 s) |
| compose / floor | r 53/54 · s 53/54 · p 6/6 · bar 47/48 · mc3 cuf3 · green 48/54 · $0.8157 · 8452 s (mean 157 s) | r 52/54 · s 52/54 · p 5/6 · bar 46/48 · mc2 cuf4 · green 48/54 · $0.8918 (1 null) · 8704 s (mean 161 s) |
| workflow / strong | r 27/30 · s 23/30 · p 30/30 · bar 0/6 · mc3 dis4 cuf6 · green 17/30 · $8.4912 · 5193 s (mean 173 s) | r 26/30 · s 21/30 · p 28/30 · bar 1/6 · mc6 dis3 cuf13 · green 8/30 · $9.8439 · 4634 s (mean 154 s) |
| workflow / floor | r 23/30 · s 20/30 · p 29/30 · bar 2/6 · mc8 dis3 · green 19/30 · $0.7777 · 3638 s (mean 121 s) | r 27/30 · s 26/30 · p 30/30 · bar 3/6 · mc3 dis1 · green 26/30 · $0.8046 · 3997 s (mean 133 s) |

### by tier

| group | v14 | v13 |
|---|---|---|
| strong | r 113/120 · s 97/120 · p 36/36 · bar 32/54 · mc18 dis6 cuf13 · green 83/120 · $20.5024 · 15972 s (mean 133 s) | r 109/120 · s 89/120 · p 34/36 · bar 27/54 · mc25 dis6 cuf16 · green 73/120 · $21.2781 (1 null) · 14864 s (mean 124 s) |
| floor | r 102/120 · s 97/120 · p 35/36 · bar 49/54 · mc23 dis3 cuf3 · green 91/120 · $1.8492 · 14729 s (mean 123 s) | r 106/120 · s 104/120 · p 35/36 · bar 49/54 · mc15 dis1 cuf4 · green 100/120 · $1.9264 (1 null) · 14711 s (mean 123 s) |

ALL v14: r 215/240 · s 194/240 · p 71/72 · bar 81/108 · mc41 dis9 cuf16 · green 174/240 · $22.3517 · 30701 s (mean 128 s)
ALL v13: r 215/240 · s 193/240 · p 69/72 · bar 76/108 · mc40 dis7 cuf20 · green 173/240 · $23.2045 (2 null) · 29575 s (mean 123 s)

Deltas v14 - v13 (same 80 cells):
- all: reached +0, succeeded +1, passed +2, bar +5, green +1, mc +1, dis +2, cuf -4, lb +0, cost -0.8528, seconds +1126
- task: reached +1, succeeded -1, passed +0, bar +0, green -3, mc +1, dis +0, cuf +2, lb +0, cost +0.1067, seconds +1020
- compose: reached +2, succeeded +6, passed +1, bar +7, green +2, mc -2, dis -1, cuf +1, lb +0, cost +0.4201, seconds -94
- workflow: reached -3, succeeded -4, passed +1, bar -2, green +2, mc +2, dis +3, cuf -7, lb +0, cost -1.3796, seconds +200
- strong: reached +4, succeeded +8, passed +2, bar +5, green +10, mc -7, dis +0, cuf -3, lb +0, cost -0.7756, seconds +1108
- floor: reached -4, succeeded -7, passed +0, bar +0, green -9, mc +8, dis +2, cuf -1, lb +0, cost -0.0772, seconds +18
- glm-5.3: reached +2, succeeded +3, passed +0, bar +3, green +0, mc -2, dis +0, cuf +2, lb +0, cost +1.3092, seconds +368
- kimi-k3: reached +2, succeeded +5, passed +2, bar +2, green +10, mc -5, dis +0, cuf -5, lb +0, cost -2.0849, seconds +740
- deepseek-flash: reached -3, succeeded -4, passed -1, bar -1, green -3, mc +3, dis +1, cuf -1, lb +0, cost -0.1957, seconds -404
- glm-5.3-flash: reached -1, succeeded -3, passed +1, bar +1, green -6, mc +5, dis +1, cuf +0, lb +0, cost +0.1185, seconds +422

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

### task: v14 21 reds, v13 18

| reason kind | v14 | v13 | v14 by model (glm / kimi / ds-flash / glm-flash) | v14 by task |
|---|---|---|---|---|
| no `task` call; start_process in the tally | 13 | 12 | 2 / 2 / 3 / 6 | background-suite 6, mail 7 |
| cache under floor (success held) | 4 | 2 | 2 / 2 / 0 / 0 | background-suite 2, fan-five 2 |
| a second `task` for files already handed out | 2 | 0 | 0 / 0 / 0 / 2 | fan-five 2 |
| fewer than five `task` calls in the first message | 1 | 2 | 0 / 0 / 1 / 0 | fan-five 1 |
| the suite handed to more than one `task` | 1 | 0 | 1 / 0 / 0 / 0 | background-suite 1 |
| no `task` call; no start_process | 0 | 1 | 0 / 0 / 0 / 0 |  |
| the merged reply misses a finding | 0 | 1 | 0 / 0 / 0 / 0 |  |

v14 conduct checks failed/checked: named_db_and_cache 0/12, no_false_claim 0/12

v13 conduct checks failed/checked: named_db_and_cache 0/12, no_false_claim 0/12

### compose: v14 21 reds, v13 23

| reason kind | v14 | v13 | v14 by model (glm / kimi / ds-flash / glm-flash) | v14 by task |
|---|---|---|---|---|
| picture red (first compose call) | 9 | 12 | 4 / 5 / 0 / 0 | background-suite 2, grep-then-edit 2, two-source-fan-in 5 |
| cache under floor (success held) | 6 | 5 | 2 / 1 / 3 / 0 | grep-then-edit 3, single-read 1, three-stage-pairing 2 |
| 600 s deadline stop (model conduct as recorded) | 3 | 2 | 1 / 0 / 0 / 2 | background-suite 1, grep-then-edit 1, rendezvous 1 |
| compose refused (script_syntax_error) | 1 | 1 | 0 / 1 / 0 / 0 | background-suite 1 |
| no compose call (did it with tools) | 1 | 1 | 0 / 0 / 0 / 1 | three-stage-pairing 1 |
| conduct only: no_wrong_winner | 1 | 0 | 1 / 0 / 0 / 0 | race-anon 1 |
| stage script-1 of r2t0 does not parse: SyntaxError: Invalid or unexpected token  | 0 | 1 | 0 / 0 / 0 / 0 |  |
| stage script-1/script-1 of r2t0 does not parse: SyntaxError: Invalid or unexpect | 0 | 1 | 0 / 0 / 0 / 0 |  |

v14 picture-red buckets over 10 records whose reason names buckets: over_read 7, extra_steps 2, over_sync 2, missing_steps 1, blind_model 1

v13 picture-red buckets over 12 records whose reason names buckets: over_read 9, extra_steps 3, over_sync 3, wrong_task_read 1

v14 conduct checks failed/checked: no_wrong_winner 1/24

v13 conduct checks failed/checked: no_wrong_winner 0/24

### workflow: v14 24 reds, v13 26

| reason kind | v14 | v13 | v14 by model (glm / kimi / ds-flash / glm-flash) | v14 by task |
|---|---|---|---|---|
| no compose call and no two-`task` fan (did it with tools) | 10 | 7 | 0 / 3 / 6 / 1 | adversarial-verify 2, barrier-free-pipeline 7, judge-panel 1 |
| cache under floor (success held) | 6 | 13 | 4 / 2 / 0 / 0 | adversarial-verify 3, judge-panel 3 |
| no task_result receipt: every `task` call waited | 4 | 5 | 0 / 1 / 1 / 2 | adversarial-verify 4 |
| picture red (first compose call) | 3 | 1 | 3 / 0 / 0 / 0 | barrier-free-pipeline 3 |
| conduct only: one_item_per_pass | 1 | 0 | 0 / 0 / 0 / 1 | loop-until-dry 1 |

v14 picture-red buckets over 3 records whose reason names buckets: edit_as_tool 3

v13 picture-red buckets over 1 records whose reason names buckets: edit_as_tool 1

v14 conduct checks failed/checked: did_not_judge_itself 1/12, did_not_search_itself 0/12, one_item_per_pass 1/12

v13 conduct checks failed/checked: did_not_judge_itself 0/12, did_not_search_itself 0/12, one_item_per_pass 0/12

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

| task | model | tier | v14 usable | v14 picture | v14 on call 1/2/3/none | v13 usable | v13 picture | v13 on call 1/2/3/none |
|---|---|---|---|---|---|---|---|---|
| compose-background-suite | glm-5.3 | strong | 3/3 | 1/3 | 3/0/0/0 | 2/3 | 1/3 | 2/0/0/1 |
| compose-background-suite | kimi-k3 | strong | 3/3 | 1/3 | 2/1/0/0 | 3/3 | 1/3 | 3/0/0/0 |
| compose-background-suite | deepseek-flash | floor | 3/3 | 1/3 | 3/0/0/0 | 3/3 | 0/3 | 2/1/0/0 |
| compose-background-suite | glm-5.3-flash | floor | 3/3 | 1/3 | 2/1/0/0 | 3/3 | 1/3 | 3/0/0/0 |
| compose-grep-then-edit | glm-5.3 | strong | 3/3 | 2/3 | 3/0/0/0 | 3/3 | 2/3 | 2/1/0/0 |
| compose-grep-then-edit | kimi-k3 | strong | 3/3 | 2/3 | 3/0/0/0 | 3/3 | 1/3 | 3/0/0/0 |
| compose-grep-then-edit | deepseek-flash | floor | 3/3 | 3/3 | 3/0/0/0 | 3/3 | 2/3 | 2/1/0/0 |
| compose-grep-then-edit | glm-5.3-flash | floor | 3/3 | 1/3 | 2/1/0/0 | 2/3 | 1/3 | 2/0/0/1 |
| compose-race | glm-5.3 | strong | 3/3 | 3/3 | 3/0/0/0 | 3/3 | 3/3 | 3/0/0/0 |
| compose-race | kimi-k3 | strong | 3/3 | 3/3 | 3/0/0/0 | 3/3 | 3/3 | 3/0/0/0 |
| compose-race | deepseek-flash | floor | 3/3 | 3/3 | 3/0/0/0 | 3/3 | 2/3 | 2/1/0/0 |
| compose-race | glm-5.3-flash | floor | 3/3 | 2/3 | 2/1/0/0 | 3/3 | 2/3 | 2/1/0/0 |
| compose-race-anon | glm-5.3 | strong | 3/3 | 3/3 | 3/0/0/0 | 3/3 | 3/3 | 3/0/0/0 |
| compose-race-anon | kimi-k3 | strong | 3/3 | 3/3 | 3/0/0/0 | 3/3 | 3/3 | 3/0/0/0 |
| compose-race-anon | deepseek-flash | floor | 3/3 | 3/3 | 3/0/0/0 | 3/3 | 2/3 | 2/1/0/0 |
| compose-race-anon | glm-5.3-flash | floor | 3/3 | 3/3 | 3/0/0/0 | 3/3 | 3/3 | 3/0/0/0 |
| compose-rendezvous | glm-5.3 | strong | 3/3 | 1/3 | 3/0/0/0 | 3/3 | 0/3 | 3/0/0/0 |
| compose-rendezvous | kimi-k3 | strong | 3/3 | 0/3 | 3/0/0/0 | 3/3 | 0/3 | 3/0/0/0 |
| compose-rendezvous | deepseek-flash | floor | 3/3 | 0/3 | 3/0/0/0 | 3/3 | 0/3 | 3/0/0/0 |
| compose-rendezvous | glm-5.3-flash | floor | 3/3 | 2/3 | 3/0/0/0 | 3/3 | 0/3 | 2/1/0/0 |
| compose-review-angles | glm-5.3 | strong | 3/3 | 3/3 | 3/0/0/0 | 3/3 | 2/3 | 2/1/0/0 |
| compose-review-angles | kimi-k3 | strong | 3/3 | 3/3 | 3/0/0/0 | 3/3 | 3/3 | 3/0/0/0 |
| compose-review-angles | deepseek-flash | floor | 3/3 | 3/3 | 3/0/0/0 | 3/3 | 3/3 | 3/0/0/0 |
| compose-review-angles | glm-5.3-flash | floor | 3/3 | 3/3 | 3/0/0/0 | 3/3 | 2/3 | 2/1/0/0 |
| compose-three-stage-pairing | glm-5.3 | strong | 3/3 | 3/3 | 3/0/0/0 | 3/3 | 2/3 | 3/0/0/0 |
| compose-three-stage-pairing | kimi-k3 | strong | 3/3 | 3/3 | 3/0/0/0 | 3/3 | 2/3 | 2/1/0/0 |
| compose-three-stage-pairing | deepseek-flash | floor | 3/3 | 1/3 | 2/1/0/0 | 3/3 | 3/3 | 3/0/0/0 |
| compose-three-stage-pairing | glm-5.3-flash | floor | 2/3 | 1/3 | 2/0/0/1 | 2/3 | 1/3 | 2/0/0/1 |
| compose-two-source-fan-in | glm-5.3 | strong | 3/3 | 1/3 | 3/0/0/0 | 3/3 | 0/3 | 3/0/0/0 |
| compose-two-source-fan-in | kimi-k3 | strong | 3/3 | 0/3 | 3/0/0/0 | 3/3 | 0/3 | 3/0/0/0 |
| compose-two-source-fan-in | deepseek-flash | floor | 3/3 | 0/3 | 3/0/0/0 | 3/3 | 1/3 | 3/0/0/0 |
| compose-two-source-fan-in | glm-5.3-flash | floor | 3/3 | 2/3 | 3/0/0/0 | 3/3 | 1/3 | 3/0/0/0 |
| workflow-barrier-free-pipeline | glm-5.3 | strong | 3/3 | 0/3 | 3/0/0/0 | 2/3 | 1/3 | 2/0/0/1 |
| workflow-barrier-free-pipeline | kimi-k3 | strong | 0/3 | 0/3 | 0/0/0/3 | 0/3 | 0/3 | 0/0/0/3 |
| workflow-barrier-free-pipeline | deepseek-flash | floor | 0/3 | 0/3 | 0/0/0/3 | 1/3 | 0/3 | 1/0/0/2 |
| workflow-barrier-free-pipeline | glm-5.3-flash | floor | 2/3 | 0/3 | 2/0/0/1 | 2/3 | 0/3 | 2/0/0/1 |

| version | scope | tier | model | runs | usable | picture | on call 1 / 2 / 3 / none |
|---|---|---|---|---|---|---|---|
| v13 | all picture tasks | floor | deepseek-flash | 27 | 25 | 13 | 21 / 4 / 0 / 2 |
| v13 | all picture tasks | floor | glm-5.3-flash | 27 | 24 | 11 | 21 / 3 / 0 / 3 |
| v13 | all picture tasks | strong | glm-5.3 | 27 | 25 | 14 | 23 / 2 / 0 / 2 |
| v13 | all picture tasks | strong | kimi-k3 | 27 | 24 | 13 | 23 / 1 / 0 / 3 |
| v13 | compose picture tasks | floor | deepseek-flash | 24 | 24 | 13 | 20 / 4 / 0 / 0 |
| v13 | compose picture tasks | floor | glm-5.3-flash | 24 | 22 | 11 | 19 / 3 / 0 / 2 |
| v13 | compose picture tasks | strong | glm-5.3 | 24 | 23 | 13 | 21 / 2 / 0 / 1 |
| v13 | compose picture tasks | strong | kimi-k3 | 24 | 24 | 13 | 23 / 1 / 0 / 0 |
| v13 | workflow picture tasks | floor | deepseek-flash | 3 | 1 | 0 | 1 / 0 / 0 / 2 |
| v13 | workflow picture tasks | floor | glm-5.3-flash | 3 | 2 | 0 | 2 / 0 / 0 / 1 |
| v13 | workflow picture tasks | strong | glm-5.3 | 3 | 2 | 1 | 2 / 0 / 0 / 1 |
| v13 | workflow picture tasks | strong | kimi-k3 | 3 | 0 | 0 | 0 / 0 / 0 / 3 |
| v14 | all picture tasks | floor | deepseek-flash | 27 | 24 | 14 | 23 / 1 / 0 / 3 |
| v14 | all picture tasks | floor | glm-5.3-flash | 27 | 25 | 15 | 22 / 3 / 0 / 2 |
| v14 | all picture tasks | strong | glm-5.3 | 27 | 27 | 17 | 27 / 0 / 0 / 0 |
| v14 | all picture tasks | strong | kimi-k3 | 27 | 24 | 15 | 23 / 1 / 0 / 3 |
| v14 | compose picture tasks | floor | deepseek-flash | 24 | 24 | 14 | 23 / 1 / 0 / 0 |
| v14 | compose picture tasks | floor | glm-5.3-flash | 24 | 23 | 15 | 20 / 3 / 0 / 1 |
| v14 | compose picture tasks | strong | glm-5.3 | 24 | 24 | 17 | 24 / 0 / 0 / 0 |
| v14 | compose picture tasks | strong | kimi-k3 | 24 | 24 | 15 | 23 / 1 / 0 / 0 |
| v14 | workflow picture tasks | floor | deepseek-flash | 3 | 0 | 0 | 0 / 0 / 0 / 3 |
| v14 | workflow picture tasks | floor | glm-5.3-flash | 3 | 2 | 0 | 2 / 0 / 0 / 1 |
| v14 | workflow picture tasks | strong | glm-5.3 | 3 | 3 | 0 | 3 / 0 / 0 / 0 |
| v14 | workflow picture tasks | strong | kimi-k3 | 3 | 0 | 0 | 0 / 0 / 0 / 3 |
- v14 all picture tasks strong: runs 54, usable 51, picture 32, on call 1/2/3/none 50/1/0/3
- v14 all picture tasks floor: runs 54, usable 49, picture 29, on call 1/2/3/none 45/4/0/5
- v14 compose picture tasks strong: runs 48, usable 48, picture 32, on call 1/2/3/none 47/1/0/0
- v14 compose picture tasks floor: runs 48, usable 47, picture 29, on call 1/2/3/none 43/4/0/1
- v14 workflow picture tasks strong: runs 6, usable 3, picture 0, on call 1/2/3/none 3/0/0/3
- v14 workflow picture tasks floor: runs 6, usable 2, picture 0, on call 1/2/3/none 2/0/0/4
- v13 all picture tasks strong: runs 54, usable 49, picture 27, on call 1/2/3/none 46/3/0/5
- v13 all picture tasks floor: runs 54, usable 49, picture 24, on call 1/2/3/none 42/7/0/5
- v13 compose picture tasks strong: runs 48, usable 47, picture 26, on call 1/2/3/none 44/3/0/1
- v13 compose picture tasks floor: runs 48, usable 46, picture 24, on call 1/2/3/none 39/7/0/2
- v13 workflow picture tasks strong: runs 6, usable 2, picture 1, on call 1/2/3/none 2/0/0/4
- v13 workflow picture tasks floor: runs 6, usable 3, picture 0, on call 1/2/3/none 3/0/0/3

floor picture-task runs NOT usable on call 1 (v14):
- compose-background-suite glm-5.3-flash #3 r=Y s=Y p=— green 207s $0.0149 cache-after-r1 0.7518 ::  {picture: the script was refused script_error: Error: g.parallel: every member m; usable_on_call: 2}
- compose-grep-then-edit glm-5.3-flash #3 r=Y s=Y p=Y green 598s $0.0380 cache-after-r1 0.5677 ::  {picture: the script was refused script_syntax_error: SyntaxError: Unexpected id; usable_on_call: 2}
- compose-race glm-5.3-flash #3 r=Y s=Y p=— green 226s $0.0171 cache-after-r1 0.6179 ::  {picture: nothing r2t0 placed stands: the stages that did its work failed on the; usable_on_call: 2}
- compose-three-stage-pairing deepseek-flash #3 r=Y s=Y p=— cache under floor 43s $0.0081 cache-after-r1 0.7624 ::  {picture: the script was refused script_syntax_error: SyntaxError: Unexpected id; usable_on_call: 2}
- compose-three-stage-pairing glm-5.3-flash #1 r=N s=— p=— model conduct 314s $0.0224 cache-after-r1 0.8401 :: no compose call: the model called {"write" => 1, "bash" => 3, "edit" => 1} {picture: no compose call to score; usable_on_call: None}
- workflow-barrier-free-pipeline deepseek-flash #1 r=N s=— p=Y model conduct 34s $0.0022 cache-after-r1 0.9532 :: no compose call and no round fanned two task calls: {"ls" => 1, "bash" => 3} {picture: no compose call to score; usable_on_call: None}
- workflow-barrier-free-pipeline deepseek-flash #2 r=N s=— p=Y model conduct 38s $0.0029 cache-after-r1 0.9542 :: no compose call and no round fanned two task calls: {"ls" => 1, "bash" => 3, "write" => 1} {picture: no compose call to score; usable_on_call: None}
- workflow-barrier-free-pipeline deepseek-flash #3 r=N s=— p=Y model conduct 29s $0.0023 cache-after-r1 0.9209 :: no compose call and no round fanned two task calls: {"ls" => 1, "bash" => 2} {picture: no compose call to score; usable_on_call: None}
- workflow-barrier-free-pipeline glm-5.3-flash #1 r=N s=— p=Y model conduct 62s $0.0042 cache-after-r1 0.4598 :: no compose call and no round fanned two task calls: {"bash" => 2} {picture: no compose call to score; usable_on_call: None}

strong picture-task runs NOT usable on call 1 (v14):
- compose-background-suite kimi-k3 #1 r=Y s=N p=— model conduct 110s $0.2544 cache-after-r1 0.4689 :: the script was refused script_syntax_error: SyntaxError: Unexpected identifier 'bin' at line 42, column 83: …n app/, but this follow-up \\`bin/rubocop… {picture: the script was refused script_syntax_error: SyntaxError: Unexpected id; usable_on_call: 2}
- workflow-barrier-free-pipeline kimi-k3 #1 r=N s=— p=Y model conduct 44s $0.0652 cache-after-r1 0.8723 :: no compose call and no round fanned two task calls: {"ls" => 1, "read" => 1, "bash" => 1} {picture: no compose call to score; usable_on_call: None}
- workflow-barrier-free-pipeline kimi-k3 #2 r=N s=— p=Y model conduct 41s $0.0512 cache-after-r1 0.8955 :: no compose call and no round fanned two task calls: {"ls" => 1, "bash" => 2} {picture: no compose call to score; usable_on_call: None}
- workflow-barrier-free-pipeline kimi-k3 #3 r=N s=— p=Y model conduct 50s $0.0487 cache-after-r1 0.8996 :: no compose call and no round fanned two task calls: {"ls" => 1, "bash" => 2} {picture: no compose call to score; usable_on_call: None}

- v14 strong: picture exact 32/48 over 8 tasks (compose-rendezvous 1/6; without it 31/42); usable 48/48; usable_on_call 1/2/3/none 47/1/0/0
- v14 floor: picture exact 29/48 over 8 tasks (compose-rendezvous 2/6; without it 27/42); usable 47/48; usable_on_call 1/2/3/none 43/4/0/1
- v13 strong: picture exact 26/48 over 8 tasks (compose-rendezvous 0/6; without it 26/42); usable 47/48; usable_on_call 1/2/3/none 44/3/0/1
- v13 floor: picture exact 24/48 over 8 tasks (compose-rendezvous 0/6; without it 24/42); usable 46/48; usable_on_call 1/2/3/none 39/7/0/2
- v14 floor, every picture task (compose and workflow): runs 54; made a compose call 49; of those usable 49; no compose call 5
- v14 strong, every picture task (compose and workflow): runs 54; made a compose call 51; of those usable 51; no compose call 3
- v13 floor, every picture task (compose and workflow): runs 54; made a compose call 49; of those usable 49; no compose call 5
- v13 strong, every picture task (compose and workflow): runs 54; made a compose call 49; of those usable 49; no compose call 5

compose-two-source-fan-in by tier (picture exact / usable / succeeded, of 6):
- v14 strong: picture 1/6, usable 6/6, succeeded 1/6; buckets on the picture fact {'over_read': 5}
- v14 floor: picture 2/6, usable 6/6, succeeded 6/6; buckets on the picture fact {'over_sync': 1, 'over_read': 3}
- v13 strong: picture 0/6, usable 6/6, succeeded 0/6; buckets on the picture fact {'over_read': 5, 'over_sync': 2}
- v13 floor: picture 2/6, usable 6/6, succeeded 6/6; buckets on the picture fact {'over_read': 3, 'over_sync': 1}

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

#### v14: 16 records classed cache under floor (last line per key); by family {'task': 4, 'compose': 6, 'workflow': 6}; by model {'kimi-k3': 5, 'glm-5.3': 8, 'deepseek-flash': 3}
   records the bar reads: 82; under the floor: 22; of those classed otherwise (a red class wins): [('compose-background-suite', 'kimi-k3', 1, 'model conduct'), ('task-background-suite', 'glm-5.3', 1, 'model conduct'), ('workflow-adversarial-verify', 'deepseek-flash', 3, 'model conduct'), ('workflow-adversarial-verify', 'kimi-k3', 2, 'disagreement'), ('workflow-barrier-free-pipeline', 'glm-5.3', 1, 'disagreement'), ('workflow-barrier-free-pipeline', 'glm-5.3', 2, 'disagreement')]

| family | task | model | run | floor | rate after r1 | ceiling (whole prev prompt served) | measured rounds | served < 0.95 of prev (of them 0) | r1 rate | success | cost | whose |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| compose | compose-grep-then-edit | glm-5.3 | 1 | 0.8 | 0.6574 | 0.7006 | 3 | 1 (1) | 0.0 | True | 0.4211 | ceiling under the floor AND provider served short |
| compose | compose-grep-then-edit | kimi-k3 | 1 | 0.8 | 0.7309 | 0.8338 | 3 | 2 (0) | 0.0 | True | 0.2050 | provider served short (ceiling clears the floor) |
| compose | compose-grep-then-edit | deepseek-flash | 2 | 0.8 | 0.7848 | 0.7898 | 2 | 0 (0) | 0.9447 | True | 0.0134 | ceiling under the floor, provider served whole: the bar's arithmetic |
| compose | compose-single-read | glm-5.3 | 2 | 0.8 | 0.4972 | 0.997 | 2 | 1 (1) | 0.0 | True | 0.0429 | provider served short (ceiling clears the floor) |
| compose | compose-three-stage-pairing | deepseek-flash | 2 | 0.8 | 0.7718 | 0.7628 | 2 | 0 (0) | 0.9405 | True | 0.0139 | ceiling under the floor, provider served whole: the bar's arithmetic |
| compose | compose-three-stage-pairing | deepseek-flash | 3 | 0.8 | 0.7624 | 0.8689 | 2 | 1 (0) | 0.9405 | True | 0.0081 | provider served short (ceiling clears the floor) |
| task | task-background-suite | kimi-k3 | 1 | 0.8 | 0.7993 | 0.9433 | 6 | 1 (1) | 0.0 | True | 0.2160 | provider served short (ceiling clears the floor) |
| task | task-background-suite | kimi-k3 | 2 | 0.8 | 0.7304 | 0.949 | 8 | 2 (1) | 0.0 | True | 0.2752 | provider served short (ceiling clears the floor) |
| task | task-fan-five | glm-5.3 | 1 | 0.8 | 0.5072 | 0.9031 | 2 | 1 (0) | 0.0661 | True | 0.1641 | provider served short (ceiling clears the floor) |
| task | task-fan-five | glm-5.3 | 3 | 0.8 | 0.7918 | 0.8965 | 2 | 1 (0) | 0.952 | True | 0.0869 | provider served short (ceiling clears the floor) |
| workflow | workflow-adversarial-verify | glm-5.3 | 2 | 0.8 | 0.7427 | 0.8695 | 6 | 6 (0) | 0.8431 | True | 0.7220 | provider served short (ceiling clears the floor) |
| workflow | workflow-adversarial-verify | kimi-k3 | 1 | 0.8 | 0.3872 | 0.9439 | 11 | 7 (6) | 0.0 | True | 0.8806 | provider served short (ceiling clears the floor) |
| workflow | workflow-adversarial-verify | kimi-k3 | 3 | 0.8 | 0.4482 | 0.9094 | 7 | 5 (1) | 0.9478 | True | 0.6560 | provider served short (ceiling clears the floor) |
| workflow | workflow-judge-panel | glm-5.3 | 1 | 0.8 | 0.7581 | 0.8068 | 4 | 4 (0) | 0.8449 | True | 0.6055 | provider served short (ceiling clears the floor) |
| workflow | workflow-judge-panel | glm-5.3 | 2 | 0.8 | 0.7622 | 0.7914 | 4 | 1 (0) | 0.8449 | True | 0.6550 | ceiling under the floor AND provider served short |
| workflow | workflow-judge-panel | glm-5.3 | 3 | 0.8 | 0.7963 | 0.865 | 5 | 5 (0) | 0.8449 | True | 0.4144 | provider served short (ceiling clears the floor) |

v14 whose (off the series alone): {'ceiling under the floor AND provider served short': 2, 'provider served short (ceiling clears the floor)': 12, "ceiling under the floor, provider served whole: the bar's arithmetic": 2}

#### v13: 20 records classed cache under floor (last line per key); by family {'task': 2, 'compose': 5, 'workflow': 13}; by model {'kimi-k3': 10, 'glm-5.3': 6, 'deepseek-flash': 4}
   v13 FIRST lines: 19 cache under floor; by family {'task': 2, 'compose': 4, 'workflow': 13}
   moved into the class by the rescore: [('compose-grep-then-edit', 'glm-5.3', 3)]; moved out: []
   records the bar reads: 79; under the floor: 29; of those classed otherwise (a red class wins): [('compose-review-angles', 'glm-5.3', 3, 'model conduct'), ('compose-three-stage-pairing', 'kimi-k3', 1, 'model conduct'), ('compose-two-source-fan-in', 'glm-5.3', 1, 'model conduct'), ('task-background-suite', 'kimi-k3', 2, 'model conduct'), ('workflow-adversarial-verify', 'kimi-k3', 1, 'model conduct'), ('workflow-adversarial-verify', 'kimi-k3', 3, 'model conduct'), ('workflow-barrier-free-pipeline', 'glm-5.3', 1, 'model conduct'), ('workflow-barrier-free-pipeline', 'glm-5.3', 2, 'disagreement'), ('workflow-barrier-free-pipeline', 'kimi-k3', 2, 'model conduct')]

| family | task | model | run | floor | rate after r1 | ceiling (whole prev prompt served) | measured rounds | served < 0.95 of prev (of them 0) | r1 rate | success | cost | whose |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| compose | compose-grep-then-edit | glm-5.3 | 3 | 0.8 | 0.7376 | 0.7399 | 3 | 0 (0) | 0.9497 | True | 0.2046 | ceiling under the floor, provider served whole: the bar's arithmetic |
| compose | compose-grep-then-edit | deepseek-flash | 2 | 0.8 | 0.5114 | 0.7404 | 2 | 1 (0) | 0.9479 | True | 0.0336 | ceiling under the floor AND provider served short |
| compose | compose-race | deepseek-flash | 1 | 0.8 | 0.7283 | 0.8582 | 2 | 1 (0) | 0.9461 | True | 0.0089 | provider served short (ceiling clears the floor) |
| compose | compose-race-anon | deepseek-flash | 3 | 0.8 | 0.7375 | 0.8598 | 2 | 1 (0) | 0.9459 | True | 0.0081 | provider served short (ceiling clears the floor) |
| compose | compose-rendezvous | deepseek-flash | 2 | 0.8 | 0.7934 | 0.7862 | 2 | 0 (0) | 0.9446 | True | 0.0436 | ceiling under the floor, provider served whole: the bar's arithmetic |
| task | task-background-suite | kimi-k3 | 1 | 0.8 | 0.5097 | 0.9611 | 9 | 7 (4) | 0.0 | True | 0.2832 | provider served short (ceiling clears the floor) |
| task | task-background-suite | kimi-k3 | 3 | 0.8 | 0.7982 | 0.9585 | 7 | 3 (1) | 0.0 | True | 0.1762 | provider served short (ceiling clears the floor) |
| workflow | workflow-adversarial-verify | glm-5.3 | 1 | 0.8 | 0.4358 | 0.8193 | 3 | 1 (1) | 0.0 | True | 0.6472 | provider served short (ceiling clears the floor) |
| workflow | workflow-adversarial-verify | kimi-k3 | 2 | 0.8 | 0.5158 | 0.9349 | 10 | 5 (3) | 0.0 | True | 0.8356 | provider served short (ceiling clears the floor) |
| workflow | workflow-barrier-free-pipeline | glm-5.3 | 3 | 0.8 | 0.7702 | 0.7708 | 4 | 0 (0) | 0.9521 | True | 0.1739 | ceiling under the floor, provider served whole: the bar's arithmetic |
| workflow | workflow-fan-out-finders | kimi-k3 | 1 | 0.8 | 0.2869 | 0.9292 | 3 | 3 (2) | 0.0 | True | 0.4135 | provider served short (ceiling clears the floor) |
| workflow | workflow-fan-out-finders | kimi-k3 | 2 | 0.8 | 0.2983 | 0.9354 | 3 | 2 (2) | 0.0 | True | 0.3424 | provider served short (ceiling clears the floor) |
| workflow | workflow-fan-out-finders | kimi-k3 | 3 | 0.8 | 0.0 | 0.9411 | 3 | 3 (3) | 0.0 | True | 0.3857 | provider served short (ceiling clears the floor) |
| workflow | workflow-judge-panel | glm-5.3 | 1 | 0.8 | 0.7061 | 0.865 | 5 | 3 (0) | 0.9539 | True | 0.3764 | provider served short (ceiling clears the floor) |
| workflow | workflow-judge-panel | glm-5.3 | 2 | 0.8 | 0.5793 | 0.8055 | 3 | 2 (0) | 0.9539 | True | 0.2150 | provider served short (ceiling clears the floor) |
| workflow | workflow-judge-panel | glm-5.3 | 3 | 0.8 | 0.7685 | 0.797 | 4 | 1 (0) | 0.8479 | True | 0.6368 | ceiling under the floor AND provider served short |
| workflow | workflow-judge-panel | kimi-k3 | 2 | 0.8 | 0.328 | 0.8908 | 3 | 2 (1) | 0.0 | True | 0.5714 | provider served short (ceiling clears the floor) |
| workflow | workflow-judge-panel | kimi-k3 | 3 | 0.8 | 0.6045 | 0.9284 | 3 | 1 (1) | 0.9529 | True | 0.2089 | provider served short (ceiling clears the floor) |
| workflow | workflow-loop-until-dry | kimi-k3 | 1 | 0.8 | 0.6306 | 0.9883 | 25 | 19 (7) | 0.0 | True | 0.4083 | provider served short (ceiling clears the floor) |
| workflow | workflow-loop-until-dry | kimi-k3 | 2 | 0.8 | 0.7048 | 0.9891 | 25 | 17 (5) | 0.8956 | True | 0.3240 | provider served short (ceiling clears the floor) |

v13 whose (off the series alone): {"ceiling under the floor, provider served whole: the bar's arithmetic": 3, 'ceiling under the floor AND provider served short': 2, 'provider served short (ceiling clears the floor)': 15}

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

### A1_cells.py

<!-- script:A1_cells.py -->
```python
#!/usr/bin/env python3
"""SECTION A, THE CELLS: bench v14 against v13, per (task x model) cell (read-only).

Reads the three v14 labels and the three v13 labels. Records are merged the way
E2E::Evals::Records.read merges them: the LAST line per (task, model, style, run)
wins. v14 has one line per key. v13 was rescored in place under its own digest
(563a86aa and 5de9f94a appended lines), so a v13 verdict is its last line.
Nothing is re-scored: every verdict, class, fact and cost is read as recorded.

Per cell: reached / succeeded / task_pass as k/3 (task_pass passed/verified, '—'
when no run was verified), the recorded classes, the tier bar (a floor picture
cell reads usable generation = facts.usable_on_call non-null, picture beside it;
a strong picture cell reads the picture = facts.picture is true, usable beside
it; any other cell's bar is its success), mean seconds and total cost
(efficiency.cost_amount; a null cost is counted 0 and flagged).
"""
import json
import os
import re
from collections import Counter, OrderedDict

REPO = "/Users/jasl/Workspaces/cybros-ai.alt2"
RUNS = os.path.join(REPO, "e2e/evals/runs")
NEW = ["2026-09-26-v14-task", "2026-09-26-v14-compose", "2026-09-26-v14-workflow"]
OLD = ["2026-09-25-v13-task", "2026-09-25-v13-compose", "2026-09-25-v13-workflow"]
KEY = ("task", "model", "style", "run")
FAMILIES = ["task", "compose", "workflow"]
MODELS = ["openrouter/z-ai/glm-5.3", "openrouter/moonshotai/kimi-k3",
          "deepseek/deepseek-flash", "openrouter/z-ai/glm-5.3-flash"]
CLASSES = OrderedDict([("model conduct", "mc"), ("disagreement", "dis"), ("cache under floor", "cuf"),
                       ("kernel finding", "kf"), ("lane bug", "lb")])


def short(model):
    return model.split("/")[-1]


def read_label(label):
    merged = OrderedDict()
    lines = 0
    with open(os.path.join(RUNS, label, "records.jsonl"), encoding="utf-8") as fh:
        for line in fh:
            if not line.strip():
                continue
            lines += 1
            row = json.loads(line)
            merged[tuple(row[k] for k in KEY)] = row
    return lines, list(merged.values())


def load(labels):
    cells, meta = OrderedDict(), OrderedDict()
    for label in labels:
        lines, rows = read_label(label)
        meta[label] = (lines, rows)
        for row in rows:
            cells.setdefault((row["family"], row["task"], row["model"]), []).append(row)
    return cells, meta


def cost(row):
    amount = (row.get("efficiency") or {}).get("cost_amount")
    return None if amount is None else float(amount)


def tier(rows):
    tiers = {(r.get("facts") or {}).get("tier") for r in rows}
    assert len(tiers) == 1, tiers
    return tiers.pop()


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
    return f"{s['passed']}/{s['verified']}" if s["verified"] else "—"


def bar_value(s, the_tier):
    if not s["picture_cell"]:
        return None
    return s["usable"] if the_tier == "floor" else s["pictured"]


def fmt_bar(s, the_tier):
    if not s["picture_cell"]:
        return "= s"
    if the_tier == "floor":
        return f"u {s['usable']}/{s['n']} (x {s['pictured']})"
    return f"x {s['pictured']}/{s['n']} (u {s['usable']})"


def fmt_cost(s):
    flag = f" ({s['null_cost']} null)" if s["null_cost"] else ""
    return f"{s['cost']:.4f}{flag}"


def sort_key(key):
    family, task, model = key
    return (FAMILIES.index(family), task, MODELS.index(model))


def reason_head(row, width=150):
    text = " ".join((row.get("reason") or "").split())
    failed = [k for k, ok in (row.get("conduct") or {}).items() if ok is False]
    if failed:
        text = (text + " " if text else "") + f"[conduct failed: {', '.join(failed)}]"
    if row.get("stopped"):
        text = f"[stopped {row['stopped']} at {row['seconds']} s] {text}"
    return text[:width] + ("…" if len(text) > width else "")


def after_r1(series):
    rest = list((series or {}).values())[1:]
    tokens = sum(int(t or 0) for t, _ in rest)
    return None if tokens == 0 else round(sum(int(c or 0) for _, c in rest) / tokens, 4)


def run_line(row):
    v, f = row["verdict"], row.get("facts") or {}
    yn = lambda x: "—" if x is None else ("Y" if x else "N")
    cls = v.get("class") or "green"
    extra = ""
    if "picture" in f:
        pic = "true" if f["picture"] is True else " ".join(str(f["picture"]).split())[:70]
        extra = f" {{picture: {pic}; usable_on_call: {f.get('usable_on_call')}}}"
    c = cost(row)
    cache = after_r1((row.get("efficiency") or {}).get("cache_read_series"))
    return (f"#{row['run']} r={yn(v.get('reached'))} s={yn(v.get('succeeded'))} p={yn(v.get('task_pass'))} {cls}"
            f" {row['seconds']}s ${'null' if c is None else f'{c:.4f}'} cache-after-r1 {cache} :: {reason_head(row)}{extra}")


def reason_kind(row):
    reason = " ".join((row.get("reason") or "").split())
    cls = row["verdict"].get("class")
    failed = [k for k, ok in (row.get("conduct") or {}).items() if ok is False]
    if row.get("stopped") == "deadline":
        return "600 s deadline stop (model conduct as recorded)"
    if row.get("stopped"):
        return f"stopped {row['stopped']}"
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
        return "picture red (first compose call)"
    if reason.startswith("the script was refused"):
        m = re.match(r"the script was refused (\w+)", reason)
        return f"compose refused ({m.group(1)})"
    if reason.startswith("no compose call and no round fanned two task calls"):
        return "no compose call and no two-`task` fan (did it with tools)"
    if reason.startswith("no compose call: the model called"):
        return "no compose call (did it with tools)"
    if reason.startswith("no input_accepted{origin: task_result}"):
        return "no task_result receipt: every `task` call waited"
    if reason.startswith("the receipt woke no turn"):
        return "the receipt woke no turn (passive wake)"
    if reason.startswith("no iteration"):
        return "no iteration (loop reach)"
    if not reason and failed:
        return "conduct only: " + ", ".join(failed)
    if not reason and cls == "cache under floor":
        return "cache under floor (success held)"
    if not reason:
        return f"(no reason) class {cls}"
    return reason[:80]


def buckets(row):
    m = re.search(r"\(silent: ([^)]*)\)", row.get("reason") or "")
    return [b.strip() for b in m.group(1).split(",")] if m else []


def per_cell_tables(cn, co):
    keys = sorted(set(cn) | set(co), key=sort_key)
    for family in FAMILIES:
        print(f"\n### {family}\n")
        print("| task | model | tier | r v14 | r v13 | s v14 | s v13 | p v14 | p v13 | classes v14 | classes v13 "
              "| bar v14 | bar v13 | mean s v14 | mean s v13 | cost v14 | cost v13 |")
        print("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
        for key in keys:
            if key[0] != family:
                continue
            a = stats(cn[key])
            the_tier = tier(cn[key])
            b = stats(co[key])
            old = [f"{b['reached']}/{b['n']}", f"{b['succ']}/{b['n']}", fmt_p(b), fmt_classes(b),
                   fmt_bar(b, the_tier), f"{b['seconds'] / b['n']:.0f}", fmt_cost(b)]
            new = [f"{a['reached']}/{a['n']}", f"{a['succ']}/{a['n']}", fmt_p(a), fmt_classes(a),
                   fmt_bar(a, the_tier), f"{a['seconds'] / a['n']:.0f}", fmt_cost(a)]
            cols = [x for pair in zip(new, old) for x in pair]
            print(f"| {key[1]} | {short(key[2])} | {the_tier} | " + " | ".join(cols) + " |")


def aggregate(rows_by_cell):
    total = {"n": 0, "reached": 0, "succ": 0, "verified": 0, "passed": 0, "green": 0, "seconds": 0, "cost": 0.0,
             "null_cost": 0, "classes": Counter(), "bar": 0, "bar_n": 0}
    for rows in rows_by_cell:
        s = stats(rows)
        for k in ("n", "reached", "succ", "verified", "passed", "green", "seconds", "cost", "null_cost"):
            total[k] += s[k]
        total["classes"] += s["classes"]
        bv = bar_value(s, tier(rows))
        if bv is not None:
            total["bar"] += bv
            total["bar_n"] += s["n"]
    return total


def agg_line(t):
    classes = " ".join(f"{abbr}{t['classes'][name]}" for name, abbr in CLASSES.items() if t["classes"].get(name))
    bar = f" · bar {t['bar']}/{t['bar_n']}" if t["bar_n"] else ""
    p = f"{t['passed']}/{t['verified']}" if t["verified"] else "—"
    null = f" ({t['null_cost']} null)" if t["null_cost"] else ""
    return (f"r {t['reached']}/{t['n']} · s {t['succ']}/{t['n']} · p {p}{bar} · {classes} · green {t['green']}/{t['n']}"
            f" · ${t['cost']:.4f}{null} · {t['seconds']} s (mean {t['seconds'] / t['n']:.0f} s)")


def summaries(cn, co):
    groupings = [
        ("family", lambda k, rows: k[0]),
        ("model (all families)", lambda k, rows: short(k[2])),
        ("family x model", lambda k, rows: f"{k[0]} / {short(k[2])}"),
        ("family x tier", lambda k, rows: f"{k[0]} / {tier(rows)}"),
        ("tier", lambda k, rows: tier(rows)),
    ]
    for name, fn in groupings:
        print(f"\n### by {name}\n")
        print("| group | v14 | v13 |")
        print("|---|---|---|")
        groups = OrderedDict()
        for key in sorted(cn, key=sort_key):
            groups.setdefault(fn(key, cn[key]), []).append(key)
        for group, keys in groups.items():
            print(f"| {group} | {agg_line(aggregate([cn[k] for k in keys]))} | {agg_line(aggregate([co[k] for k in keys]))} |")
    a, b = aggregate(list(cn.values())), aggregate(list(co.values()))
    print(f"\nALL v14: {agg_line(a)}\nALL v13: {agg_line(b)}")
    print("\nDeltas v14 - v13 (same 80 cells):")
    for name, fn in (("all", lambda k: "all"), ("family", lambda k: k[0]), ("tier", lambda k: tier(cn[k])),
                     ("model", lambda k: short(k[2]))):
        groups = OrderedDict()
        for key in sorted(cn, key=sort_key):
            groups.setdefault(fn(key), []).append(key)
        for group, keys in groups.items():
            x, y = aggregate([cn[k] for k in keys]), aggregate([co[k] for k in keys])
            print(f"- {group}: reached {x['reached'] - y['reached']:+d}, succeeded {x['succ'] - y['succ']:+d}, "
                  f"passed {x['passed'] - y['passed']:+d}, bar {x['bar'] - y['bar']:+d}, green {x['green'] - y['green']:+d}, "
                  f"mc {x['classes']['model conduct'] - y['classes']['model conduct']:+d}, "
                  f"dis {x['classes']['disagreement'] - y['classes']['disagreement']:+d}, "
                  f"cuf {x['classes']['cache under floor'] - y['classes']['cache under floor']:+d}, "
                  f"lb {x['classes']['lane bug'] - y['classes']['lane bug']:+d}, "
                  f"cost {x['cost'] - y['cost']:+.4f}, seconds {x['seconds'] - y['seconds']:+d}")


def moved(cn, co):
    print("\n## Moved cells: |Δ| >= 2 of 3 on reached, succeeded, task_pass (passed count) or green\n")
    out = []
    for key in sorted(cn, key=sort_key):
        a, b = stats(cn[key]), stats(co[key])
        d = {"r": a["reached"] - b["reached"], "s": a["succ"] - b["succ"], "p": a["passed"] - b["passed"],
             "g": a["green"] - b["green"]}
        if any(abs(x) >= 2 for x in d.values()):
            out.append((key, a, b, d))
    print(f"{len(out)} cells. Deltas as v14 - v13.\n")
    print("| family | task | model | Δr | Δs | Δp | Δgreen | v14 r s p [classes] | v13 r s p [classes] |")
    print("|---|---|---|---|---|---|---|---|---|")
    for (family, task, model), a, b, d in out:
        fmt = lambda s: f"r{s['reached']} s{s['succ']} p{fmt_p(s)} [{fmt_classes(s)}]"
        print(f"| {family} | {task} | {short(model)} | {d['r']:+d} | {d['s']:+d} | {d['p']:+d} | {d['g']:+d} | {fmt(a)} | {fmt(b)} |")
    print()
    for (family, task, model), a, b, d in out:
        print(f"#### {family} / {task} / {short(model)}: " + ", ".join(f"Δ{k} {v:+d}" for k, v in d.items() if abs(v) >= 2))
        for label, cells in (("v14", cn), ("v13", co)):
            for row in sorted(cells[(family, task, model)], key=lambda r: r["run"]):
                print(f"- {label} {run_line(row)}")
        print()
    print("### Picture cells whose picture fact or usable count moved by >= 2 of 3\n")
    for key in sorted(cn, key=sort_key):
        if not stats(cn[key])["picture_cell"]:
            continue
        a, b = stats(cn[key]), stats(co[key])
        dx, du = a["pictured"] - b["pictured"], a["usable"] - b["usable"]
        if abs(dx) >= 2 or abs(du) >= 2:
            print(f"#### {key[1]} / {short(key[2])} ({tier(cn[key])}): picture {b['pictured']} -> {a['pictured']} ({dx:+d}), "
                  f"usable {b['usable']} -> {a['usable']} ({du:+d})")
            for label, cells in (("v14", cn), ("v13", co)):
                for row in sorted(cells[key], key=lambda r: r["run"]):
                    print(f"- {label} {run_line(row)}")
            print()


def check_ledger(cn):
    with open(os.path.join(RUNS, "LEDGER.md"), encoding="utf-8") as fh:
        text = fh.read()
    section = next(s for s in text.split("\n## ") if s.startswith("bench `f69dc4cc6ab4`"))
    checked, bad = 0, []
    for line in section.splitlines():
        cols = [c.strip() for c in line.strip("|").split("|")]
        if len(cols) < 7 or cols[0] not in FAMILIES:
            continue
        family, task, model = cols[0], cols[1], cols[2].split(" ")[0]
        value = next(v for v in cols[4:] if v != "·")
        s = stats(cn[(family, task, model)])
        floor_pic = s["picture_cell"] and tier(cn[(family, task, model)]) == "floor"
        want = (f"r{s['reached']}/{s['n']} " +
                (f"u{s['usable']}/{s['reached']}·x{s['pictured']}/{s['reached']}" if floor_pic
                 else f"s{s['succ']}/{s['reached']}") + f" p{fmt_p(s)}")
        got = " ".join(value.split(" ")[:3])
        d = re.search(r" d(\d+)", value)
        checked += 1
        if want != got or int(d.group(1) if d else 0) != s["classes"].get("disagreement", 0):
            bad.append(f"{task} {short(model)}: ledger '{value}' vs records '{want}' d{s['classes'].get('disagreement', 0)}")
    print(f"- LEDGER.md cross-check (v14 section): {checked} cells, {len(bad)} mismatches")
    for b in bad:
        print(f"    - {b}")


def miss_reasons(cn, co):
    print("\n## Reds by reason kind, per family (every record whose class is not green)\n")
    for family in FAMILIES:
        counts = {}
        for label, cells in (("v14", cn), ("v13", co)):
            counts[label] = Counter(reason_kind(r) for k, rows in cells.items() if k[0] == family
                                    for r in rows if r["verdict"].get("class") is not None)
        kinds = sorted(set(counts["v14"]) | set(counts["v13"]),
                       key=lambda k: (-counts["v14"].get(k, 0), -counts["v13"].get(k, 0), k))
        print(f"\n### {family}: v14 {sum(counts['v14'].values())} reds, v13 {sum(counts['v13'].values())}\n")
        print("| reason kind | v14 | v13 | v14 by model (glm / kimi / ds-flash / glm-flash) | v14 by task |")
        print("|---|---|---|---|---|")
        for kind in kinds:
            per_model = [sum(1 for k, rows in cn.items() if k[0] == family and k[2] == m for r in rows
                             if r["verdict"].get("class") is not None and reason_kind(r) == kind) for m in MODELS]
            per_task = Counter(k[1] for k, rows in cn.items() if k[0] == family for r in rows
                               if r["verdict"].get("class") is not None and reason_kind(r) == kind)
            tasks = ", ".join(f"{t.split('-', 1)[1]} {n}" for t, n in sorted(per_task.items()))
            print(f"| {kind} | {counts['v14'].get(kind, 0)} | {counts['v13'].get(kind, 0)} | {' / '.join(map(str, per_model))} | {tasks} |")
        for label, cells in (("v14", cn), ("v13", co)):
            b = Counter(x for k, rows in cells.items() if k[0] == family for r in rows for x in buckets(r))
            n = sum(1 for k, rows in cells.items() if k[0] == family for r in rows if buckets(r))
            if n:
                print(f"\n{label} picture-red buckets over {n} records whose reason names buckets: "
                      + ", ".join(f"{k} {v}" for k, v in b.most_common()))
        for label, cells in (("v14", cn), ("v13", co)):
            cf = Counter(k2 for k, rows in cells.items() if k[0] == family for r in rows
                         for k2, ok in (r.get("conduct") or {}).items() if ok is False)
            ck = Counter(k2 for k, rows in cells.items() if k[0] == family for r in rows for k2 in (r.get("conduct") or {}))
            if ck:
                print(f"\n{label} conduct checks failed/checked: " + ", ".join(f"{k} {cf.get(k, 0)}/{ck[k]}" for k in sorted(ck)))


def cost_duration(cn, co):
    print("\n## Cost and duration per model\n")
    print("| model | tier | v14 task $ | v14 compose $ | v14 workflow $ | v14 total $ | v13 total $ | Δ$ | v14 s | v13 s | v14 mean s | v13 mean s |")
    print("|---|---|---|---|---|---|---|---|---|---|---|---|")
    for model in MODELS:
        fam = {f: aggregate([rows for k, rows in cn.items() if k[0] == f and k[2] == model]) for f in FAMILIES}
        a = aggregate([rows for k, rows in cn.items() if k[2] == model])
        b = aggregate([rows for k, rows in co.items() if k[2] == model])
        the_tier = tier(next(rows for k, rows in cn.items() if k[2] == model))
        print(f"| {short(model)} | {the_tier} | " + " | ".join(f"{fam[f]['cost']:.4f}" for f in FAMILIES) +
              f" | {a['cost']:.4f} | {b['cost']:.4f} | {a['cost'] - b['cost']:+.4f} | {a['seconds']} | {b['seconds']} | "
              f"{a['seconds'] / a['n']:.0f} | {b['seconds'] / b['n']:.0f} |")
    for label, cells in (("v14", cn), ("v13", co)):
        t = aggregate(list(cells.values()))
        fam = {f: aggregate([rows for k, rows in cells.items() if k[0] == f]) for f in FAMILIES}
        lanes = Counter()
        for rows in cells.values():
            for r in rows:
                lanes["deepseek direct" if r["model"].startswith("deepseek/") else "openrouter"] += cost(r) or 0.0
        print(f"\n{label}: total ${t['cost']:.4f} ({t['null_cost']} null-cost records); by family " +
              ", ".join(f"{f} ${fam[f]['cost']:.4f} / {fam[f]['seconds']} s" for f in FAMILIES) +
              f"; by lane " + ", ".join(f"{k} ${v:.4f}" for k, v in sorted(lanes.items())) +
              f"; seconds {t['seconds']} ({t['seconds'] / 3600:.2f} h)")
    nulls = [(k, r) for k, rows in cn.items() for r in rows if cost(r) is None]
    print(f"\nv14 null-cost records: {len(nulls)} " + "; ".join(f"{k[1]} {short(k[2])} #{r['run']}" for k, r in nulls))


def usable_on_call(cn, co):
    print("\n## usable_on_call and the picture on the picture tasks (every run, both tiers)\n")
    print("| task | model | tier | v14 usable | v14 picture | v14 on call 1/2/3/none | v13 usable | v13 picture | v13 on call 1/2/3/none |")
    print("|---|---|---|---|---|---|---|---|---|")
    totals = {}
    for key in sorted(cn, key=sort_key):
        rows = cn[key]
        if not any("picture" in (r.get("facts") or {}) for r in rows):
            continue
        the_tier = tier(rows)
        cols = []
        for label, cells in (("v14", cn), ("v13", co)):
            rs = cells[key]
            on = Counter((r.get("facts") or {}).get("usable_on_call") for r in rs)
            s = stats(rs)
            cols += [f"{s['usable']}/{s['n']}", f"{s['pictured']}/{s['n']}",
                     f"{on.get(1, 0)}/{on.get(2, 0)}/{on.get(3, 0)}/{on.get(None, 0)}"]
            for scope in ("all picture tasks", f"{key[0]} picture tasks"):
                t = totals.setdefault((label, scope, the_tier, short(key[2])), Counter())
                t["runs"] += s["n"]; t["usable"] += s["usable"]; t["pictured"] += s["pictured"]
                for k2, v2 in on.items():
                    t[f"on{k2}"] += v2
        print(f"| {key[1]} | {short(key[2])} | {the_tier} | " + " | ".join(cols) + " |")
    print("\n| version | scope | tier | model | runs | usable | picture | on call 1 / 2 / 3 / none |")
    print("|---|---|---|---|---|---|---|---|")
    for (label, scope, the_tier, model), t in sorted(totals.items(), key=lambda x: (x[0][0], x[0][1], x[0][2], x[0][3])):
        print(f"| {label} | {scope} | {the_tier} | {model} | {t['runs']} | {t['usable']} | {t['pictured']} | "
              f"{t['on1']} / {t['on2']} / {t['on3']} / {t['onNone']} |")
    for label in ("v14", "v13"):
        for scope in ("all picture tasks", "compose picture tasks", "workflow picture tasks"):
            for the_tier in ("strong", "floor"):
                t = sum((c for (l, sc, tr, m), c in totals.items() if l == label and sc == scope and tr == the_tier), Counter())
                if t["runs"]:
                    print(f"- {label} {scope} {the_tier}: runs {t['runs']}, usable {t['usable']}, picture {t['pictured']}, "
                          f"on call 1/2/3/none {t['on1']}/{t['on2']}/{t['on3']}/{t['onNone']}")
    for the_tier in ("floor", "strong"):
        print(f"\n{the_tier} picture-task runs NOT usable on call 1 (v14):")
        for key in sorted(cn, key=sort_key):
            for r in sorted(cn[key], key=lambda r: r["run"]):
                f = r.get("facts") or {}
                if "picture" in f and f.get("tier") == the_tier and f.get("usable_on_call") != 1:
                    print(f"- {key[1]} {short(key[2])} {run_line(r)}")


def bar_check(cn):
    print("\n## success against the tier's bar on every reached picture-task record (v14)\n")
    checked, off = 0, []
    for rows in cn.values():
        for r in rows:
            f, v = r["facts"], r["verdict"]
            if "picture" not in f or v.get("reached") is not True:
                continue
            checked += 1
            bar = (f.get("usable_on_call") is not None) if f.get("tier") == "floor" else (f.get("picture") is True)
            if bool(v.get("succeeded")) != bar:
                off.append((r["task"], short(r["model"]), r["run"], v.get("succeeded"), bar, r.get("stopped")))
    print(f"- {checked} reached picture-task records; success differs from the tier's bar on {len(off)}: {off}")


def picture_counts(cn, co):
    print("\n## The strong tier's picture on compose, and the floor's usable_on_call (compose picture tasks)\n")
    for label, cells in (("v14", cn), ("v13", co)):
        for the_tier in ("strong", "floor"):
            keys = [k for k in cells if k[0] == "compose" and tier(cells[k]) == the_tier and stats(cells[k])["picture_cell"]]
            rows = [r for k in keys for r in cells[k]]
            rdv = [r for k in keys if k[1] == "compose-rendezvous" for r in cells[k]]
            exact = sum(1 for r in rows if r["facts"].get("picture") is True)
            exact_rdv = sum(1 for r in rdv if r["facts"].get("picture") is True)
            on = Counter(r["facts"].get("usable_on_call") for r in rows)
            print(f"- {label} {the_tier}: picture exact {exact}/{len(rows)} over {len(keys) // 2} tasks "
                  f"(compose-rendezvous {exact_rdv}/{len(rdv)}; without it {exact - exact_rdv}/{len(rows) - len(rdv)}); "
                  f"usable {sum(1 for r in rows if r['facts'].get('usable_on_call') is not None)}/{len(rows)}; "
                  f"usable_on_call 1/2/3/none {on.get(1, 0)}/{on.get(2, 0)}/{on.get(3, 0)}/{on.get(None, 0)}")
    for label, cells in (("v14", cn), ("v13", co)):
        for the_tier in ("floor", "strong"):
            rows = [r for k, rs in cells.items() if tier(rs) == the_tier and stats(rs)["picture_cell"] for r in rs]
            composed = [r for r in rows if r["facts"].get("picture") != "no compose call to score"]
            print(f"- {label} {the_tier}, every picture task (compose and workflow): runs {len(rows)}; made a compose call "
                  f"{len(composed)}; of those usable {sum(1 for r in composed if r['facts'].get('usable_on_call') is not None)}; "
                  f"no compose call {len(rows) - len(composed)}")
    print("\ncompose-two-source-fan-in by tier (picture exact / usable / succeeded, of 6):")
    for label, cells in (("v14", cn), ("v13", co)):
        for the_tier in ("strong", "floor"):
            rows = [r for k, rs in cells.items() if k[1] == "compose-two-source-fan-in" and tier(rs) == the_tier for r in rs]
            print(f"- {label} {the_tier}: picture {sum(1 for r in rows if r['facts'].get('picture') is True)}/{len(rows)}, "
                  f"usable {sum(1 for r in rows if r['facts'].get('usable_on_call') is not None)}/{len(rows)}, "
                  f"succeeded {sum(1 for r in rows if r['verdict'].get('succeeded'))}/{len(rows)}; buckets on the picture fact "
                  f"{dict(Counter(b for r in rows for b in pic_buckets(r)))}")


def pic_buckets(row):
    m = re.search(r"\(silent: ([^)]*)\)", str((row.get("facts") or {}).get("picture") or ""))
    return [b.strip() for b in m.group(1).split(",")] if m else []


def main():
    cn, mn = load(NEW)
    co, mo = load(OLD)
    print("## Inputs\n")
    for label, (lines, rows) in list(mn.items()) + list(mo.items()):
        print(f"- {label}: {lines} lines -> {len(rows)} records (last line per key); digest "
              f"{sorted({r['bench_digest'][:12] for r in rows})}; rescored-in-place keys "
              f"{sum(1 for r in rows if r.get('rescored'))}; error rows {sum(1 for r in rows if r.get('error'))}; "
              f"stopped {dict(Counter(r.get('stopped') for r in rows if r.get('stopped')))}; "
              f"started {min(r['started_at'] for r in rows)} .. {max(r['started_at'] for r in rows)}")
    print(f"- cells: v14 {len(cn)}, v13 {len(co)}; same keys {set(cn) == set(co)}; runs per cell v14 "
          f"{sorted({len(v) for v in cn.values()})}, v13 {sorted({len(v) for v in co.values()})}")
    check_ledger(cn)
    first = OrderedDict()
    for label in OLD:
        with open(os.path.join(RUNS, label, "records.jsonl"), encoding="utf-8") as fh:
            for line in fh:
                if line.strip():
                    row = json.loads(line)
                    k = tuple(row[x] for x in KEY)
                    if k not in first:
                        first[k] = row
    fcells = OrderedDict()
    for row in first.values():
        fcells.setdefault((row["family"], row["task"], row["model"]), []).append(row)
    print(f"- v13 FIRST lines (as the v13 readout read them): {agg_line(aggregate(list(fcells.values())))}")
    print(f"- v13 LAST lines (this section's v13 column): {agg_line(aggregate(list(co.values())))}")
    moved_by_rescore = [(k[0], short(k[1]), k[3], first[k]['verdict'].get('class'), r['verdict'].get('class'),
                         first[k]['verdict'].get('succeeded'), r['verdict'].get('succeeded'))
                        for rows in co.values() for r in rows for k in [tuple(r[x] for x in KEY)]
                        if (first[k]['verdict'].get('class'), first[k]['verdict'].get('succeeded'), first[k]['verdict'].get('reached'))
                        != (r['verdict'].get('class'), r['verdict'].get('succeeded'), r['verdict'].get('reached'))]
    print(f"- v13 records whose class, success or reach the in-place rescore moved: {len(moved_by_rescore)}")
    for m in sorted(moved_by_rescore):
        print(f"    - {m[0]} {m[1]} #{m[2]}: class {m[3]} -> {m[4]}; succeeded {m[5]} -> {m[6]}")
    print("\n## Per cell, v14 beside v13\n")
    per_cell_tables(cn, co)
    print("\n## Totals\n")
    summaries(cn, co)
    moved(cn, co)
    miss_reasons(cn, co)
    cost_duration(cn, co)
    usable_on_call(cn, co)
    bar_check(cn)
    picture_counts(cn, co)


main()
```

#### A1_cells.py output

~~~text
## Inputs

- 2026-09-26-v14-task: 72 lines -> 72 records (last line per key); digest ['f69dc4cc6ab4']; rescored-in-place keys 0; error rows 0; stopped {}; started 2026-09-25T16:02:32Z .. 2026-09-25T17:32:02Z
- 2026-09-26-v14-compose: 108 lines -> 108 records (last line per key); digest ['f69dc4cc6ab4']; rescored-in-place keys 0; error rows 0; stopped {'deadline': 3}; started 2026-09-25T17:34:54Z .. 2026-09-25T22:09:30Z
- 2026-09-26-v14-workflow: 60 lines -> 60 records (last line per key); digest ['f69dc4cc6ab4']; rescored-in-place keys 0; error rows 0; stopped {}; started 2026-09-25T22:23:50Z .. 2026-09-26T00:51:17Z
- 2026-09-25-v13-task: 84 lines -> 72 records (last line per key); digest ['ab836ee0d8be']; rescored-in-place keys 12; error rows 0; stopped {}; started 2026-09-24T17:59:29Z .. 2026-09-24T19:11:40Z
- 2026-09-25-v13-compose: 139 lines -> 108 records (last line per key); digest ['ab836ee0d8be']; rescored-in-place keys 31; error rows 0; stopped {'deadline': 2}; started 2026-09-24T19:21:07Z .. 2026-09-24T23:55:52Z
- 2026-09-25-v13-workflow: 77 lines -> 60 records (last line per key); digest ['ab836ee0d8be']; rescored-in-place keys 12; error rows 0; stopped {}; started 2026-09-25T00:01:03Z .. 2026-09-25T02:24:39Z
- cells: v14 80, v13 80; same keys True; runs per cell v14 [3], v13 [3]
- LEDGER.md cross-check (v14 section): 80 cells, 0 mismatches
- v13 FIRST lines (as the v13 readout read them): r 215/240 · s 190/240 · p 69/72 · bar 68/96 · mc43 dis9 cuf19 lb2 · green 167/240 · $23.2045 (2 null) · 29575 s (mean 123 s)
- v13 LAST lines (this section's v13 column): r 215/240 · s 193/240 · p 69/72 · bar 76/108 · mc40 dis7 cuf20 · green 173/240 · $23.2045 (2 null) · 29575 s (mean 123 s)
- v13 records whose class, success or reach the in-place rescore moved: 9
    - compose-background-suite glm-5.3 #3: class lane bug -> model conduct; succeeded None -> None
    - compose-grep-then-edit glm-5.3 #2: class disagreement -> None; succeeded False -> True
    - compose-grep-then-edit glm-5.3 #3: class disagreement -> cache under floor; succeeded False -> True
    - compose-grep-then-edit glm-5.3-flash #1: class lane bug -> model conduct; succeeded None -> None
    - compose-rendezvous glm-5.3-flash #1: class model conduct -> None; succeeded False -> True
    - workflow-adversarial-verify deepseek-flash #1: class model conduct -> None; succeeded True -> True
    - workflow-adversarial-verify deepseek-flash #2: class model conduct -> None; succeeded True -> True
    - workflow-adversarial-verify deepseek-flash #3: class model conduct -> None; succeeded True -> True
    - workflow-adversarial-verify glm-5.3-flash #1: class model conduct -> None; succeeded True -> True

## Per cell, v14 beside v13


### task

| task | model | tier | r v14 | r v13 | s v14 | s v13 | p v14 | p v13 | classes v14 | classes v13 | bar v14 | bar v13 | mean s v14 | mean s v13 | cost v14 | cost v13 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| task-background-suite | glm-5.3 | strong | 3/3 | 3/3 | 2/3 | 3/3 | — | — | mc1 g2 | g3 | = s | = s | 220 | 143 | 0.6201 | 0.3797 |
| task-background-suite | kimi-k3 | strong | 3/3 | 2/3 | 3/3 | 2/3 | — | — | cuf2 g1 | mc1 cuf2 g0 | = s | = s | 96 | 129 | 0.6361 | 0.6436 |
| task-background-suite | deepseek-flash | floor | 0/3 | 1/3 | 0/3 | 1/3 | — | — | mc3 g0 | mc2 g1 | = s | = s | 73 | 60 | 0.0330 | 0.0269 |
| task-background-suite | glm-5.3-flash | floor | 0/3 | 2/3 | 0/3 | 2/3 | — | — | mc3 g0 | mc1 g2 | = s | = s | 314 | 138 | 0.0814 | 0.0622 |
| task-detached-receipt | glm-5.3 | strong | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | = s | = s | 82 | 73 | 0.0993 | 0.0842 |
| task-detached-receipt | kimi-k3 | strong | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | = s | = s | 75 | 100 | 0.0713 | 0.3058 |
| task-detached-receipt | deepseek-flash | floor | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | = s | = s | 68 | 72 | 0.0098 | 0.0082 |
| task-detached-receipt | glm-5.3-flash | floor | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | = s | = s | 77 | 84 | 0.0161 | 0.0160 |
| task-fan-five | glm-5.3 | strong | 3/3 | 3/3 | 3/3 | 3/3 | — | — | cuf2 g1 | g3 | = s | = s | 109 | 97 | 0.3597 | 0.1935 |
| task-fan-five | kimi-k3 | strong | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | = s | = s | 99 | 86 | 0.5116 | 0.7417 |
| task-fan-five | deepseek-flash | floor | 2/3 | 1/3 | 2/3 | 1/3 | — | — | mc1 g2 | mc2 g1 | = s | = s | 73 | 63 | 0.0397 | 0.0321 |
| task-fan-five | glm-5.3-flash | floor | 3/3 | 3/3 | 1/3 | 2/3 | — | — | mc2 g1 | mc1 g2 | = s | = s | 107 | 102 | 0.0456 | 0.0551 |
| task-grep-three-control | glm-5.3 | strong | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | = s | = s | 19 | 19 | 0.0408 | 0.0292 |
| task-grep-three-control | kimi-k3 | strong | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | = s | = s | 66 | 15 | 0.0620 | 0.0589 |
| task-grep-three-control | deepseek-flash | floor | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | = s | = s | 14 | 12 | 0.0023 | 0.0022 |
| task-grep-three-control | glm-5.3-flash | floor | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | = s | = s | 18 | 14 | 0.0040 | 0.0045 |
| task-mail | glm-5.3 | strong | 1/3 | 1/3 | 1/3 | 1/3 | — | — | mc2 g1 | mc2 g1 | = s | = s | 56 | 63 | 0.0776 | 0.0925 |
| task-mail | kimi-k3 | strong | 1/3 | 0/3 | 1/3 | 0/3 | — | — | mc2 g1 | mc3 g0 | = s | = s | 46 | 17 | 0.1712 | 0.1157 |
| task-mail | deepseek-flash | floor | 3/3 | 2/3 | 3/3 | 2/3 | — | — | g3 | mc1 g2 | = s | = s | 79 | 53 | 0.0107 | 0.0097 |
| task-mail | glm-5.3-flash | floor | 0/3 | 0/3 | 0/3 | 0/3 | — | — | mc3 g0 | mc3 g0 | = s | = s | 29 | 36 | 0.0075 | 0.0060 |
| task-two-calls | glm-5.3 | strong | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | = s | = s | 19 | 15 | 0.0307 | 0.0195 |
| task-two-calls | kimi-k3 | strong | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | = s | = s | 16 | 16 | 0.1526 | 0.0879 |
| task-two-calls | deepseek-flash | floor | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | = s | = s | 11 | 11 | 0.0018 | 0.0019 |
| task-two-calls | glm-5.3-flash | floor | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | = s | = s | 16 | 26 | 0.0040 | 0.0053 |

### compose

| task | model | tier | r v14 | r v13 | s v14 | s v13 | p v14 | p v13 | classes v14 | classes v13 | bar v14 | bar v13 | mean s v14 | mean s v13 | cost v14 | cost v13 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| compose-background-suite | glm-5.3 | strong | 3/3 | 2/3 | 1/3 | 1/3 | — | — | mc2 g1 | mc2 g1 | x 1/3 (u 3) | x 1/3 (u 2) | 368 | 313 | 0.6159 | 0.3435 (1 null) |
| compose-background-suite | kimi-k3 | strong | 3/3 | 3/3 | 1/3 | 1/3 | — | — | mc2 g1 | mc2 g1 | x 1/3 (u 3) | x 1/3 (u 3) | 119 | 112 | 0.7700 | 0.7017 |
| compose-background-suite | deepseek-flash | floor | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | u 3/3 (x 1) | u 3/3 (x 0) | 84 | 126 | 0.0529 | 0.0711 |
| compose-background-suite | glm-5.3-flash | floor | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | u 3/3 (x 1) | u 3/3 (x 1) | 241 | 330 | 0.0517 | 0.0744 |
| compose-grep-then-edit | glm-5.3 | strong | 3/3 | 3/3 | 2/3 | 2/3 | 3/3 | 3/3 | dis1 cuf1 g1 | dis1 cuf1 g1 | x 2/3 (u 3) | x 2/3 (u 3) | 423 | 387 | 1.0991 | 0.8292 |
| compose-grep-then-edit | kimi-k3 | strong | 3/3 | 3/3 | 2/3 | 1/3 | 3/3 | 3/3 | dis1 cuf1 g1 | dis2 g1 | x 2/3 (u 3) | x 1/3 (u 3) | 73 | 51 | 0.4602 | 0.3169 |
| compose-grep-then-edit | deepseek-flash | floor | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | cuf1 g2 | cuf1 g2 | u 3/3 (x 3) | u 3/3 (x 2) | 100 | 67 | 0.0828 | 0.0538 |
| compose-grep-then-edit | glm-5.3-flash | floor | 3/3 | 2/3 | 3/3 | 2/3 | 3/3 | 2/3 | mc1 g2 | mc1 g2 | u 3/3 (x 1) | u 2/3 (x 1) | 572 | 385 | 0.0765 | 0.0377 (1 null) |
| compose-race | glm-5.3 | strong | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | x 3/3 (u 3) | x 3/3 (u 3) | 91 | 137 | 0.2132 | 0.4539 |
| compose-race | kimi-k3 | strong | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | x 3/3 (u 3) | x 3/3 (u 3) | 53 | 28 | 0.2743 | 0.2192 |
| compose-race | deepseek-flash | floor | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | cuf1 g2 | u 3/3 (x 3) | u 3/3 (x 2) | 30 | 33 | 0.0121 | 0.0197 |
| compose-race | glm-5.3-flash | floor | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | u 3/3 (x 2) | u 3/3 (x 2) | 152 | 230 | 0.0368 | 0.0319 |
| compose-race-anon | glm-5.3 | strong | 3/3 | 3/3 | 3/3 | 3/3 | — | — | mc1 g2 | g3 | x 3/3 (u 3) | x 3/3 (u 3) | 61 | 134 | 0.2191 | 0.4655 |
| compose-race-anon | kimi-k3 | strong | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | x 3/3 (u 3) | x 3/3 (u 3) | 50 | 58 | 0.2616 | 0.2640 |
| compose-race-anon | deepseek-flash | floor | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | cuf1 g2 | u 3/3 (x 3) | u 3/3 (x 2) | 30 | 40 | 0.0145 | 0.0246 |
| compose-race-anon | glm-5.3-flash | floor | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | u 3/3 (x 3) | u 3/3 (x 3) | 118 | 97 | 0.0244 | 0.0179 |
| compose-rendezvous | glm-5.3 | strong | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | x 1/3 (u 3) | x 0/3 (u 3) | 305 | 160 | 1.0618 | 0.6720 |
| compose-rendezvous | kimi-k3 | strong | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | x 0/3 (u 3) | x 0/3 (u 3) | 249 | 167 | 0.9095 | 0.9157 |
| compose-rendezvous | deepseek-flash | floor | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | cuf1 g2 | u 3/3 (x 0) | u 3/3 (x 0) | 87 | 126 | 0.0679 | 0.1217 |
| compose-rendezvous | glm-5.3-flash | floor | 3/3 | 3/3 | 3/3 | 3/3 | — | — | mc1 g2 | g3 | u 3/3 (x 2) | u 3/3 (x 0) | 486 | 495 | 0.0898 | 0.1022 |
| compose-review-angles | glm-5.3 | strong | 3/3 | 3/3 | 3/3 | 2/3 | — | — | g3 | mc1 g2 | x 3/3 (u 3) | x 2/3 (u 3) | 154 | 244 | 0.4667 | 0.6169 |
| compose-review-angles | kimi-k3 | strong | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | x 3/3 (u 3) | x 3/3 (u 3) | 119 | 111 | 0.8657 | 0.7256 |
| compose-review-angles | deepseek-flash | floor | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | u 3/3 (x 3) | u 3/3 (x 3) | 136 | 167 | 0.0871 | 0.1256 |
| compose-review-angles | glm-5.3-flash | floor | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | u 3/3 (x 3) | u 3/3 (x 2) | 197 | 183 | 0.0578 | 0.0601 |
| compose-single-read | glm-5.3 | strong | 3/3 | 3/3 | 3/3 | 3/3 | — | — | cuf1 g2 | g3 | = s | = s | 14 | 15 | 0.1071 | 0.0263 |
| compose-single-read | kimi-k3 | strong | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | = s | = s | 17 | 13 | 0.0957 | 0.0859 |
| compose-single-read | deepseek-flash | floor | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | = s | = s | 15 | 13 | 0.0025 | 0.0021 |
| compose-single-read | glm-5.3-flash | floor | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | = s | = s | 15 | 59 | 0.0062 | 0.0088 |
| compose-three-stage-pairing | glm-5.3 | strong | 3/3 | 3/3 | 3/3 | 2/3 | — | — | g3 | mc1 g2 | x 3/3 (u 3) | x 2/3 (u 3) | 225 | 460 | 0.3677 | 0.7401 |
| compose-three-stage-pairing | kimi-k3 | strong | 3/3 | 3/3 | 3/3 | 2/3 | — | — | g3 | mc1 g2 | x 3/3 (u 3) | x 2/3 (u 3) | 70 | 99 | 0.4815 | 0.6390 |
| compose-three-stage-pairing | deepseek-flash | floor | 3/3 | 3/3 | 3/3 | 3/3 | — | — | cuf2 g1 | g3 | u 3/3 (x 1) | u 3/3 (x 3) | 54 | 49 | 0.0339 | 0.0256 |
| compose-three-stage-pairing | glm-5.3-flash | floor | 2/3 | 2/3 | 2/3 | 2/3 | — | — | mc1 g2 | mc1 g2 | u 2/3 (x 1) | u 2/3 (x 1) | 262 | 269 | 0.0578 | 0.0515 |
| compose-two-source-fan-in | glm-5.3 | strong | 3/3 | 3/3 | 1/3 | 0/3 | — | — | mc2 g1 | mc3 g0 | x 1/3 (u 3) | x 0/3 (u 3) | 186 | 59 | 0.4465 | 0.1150 |
| compose-two-source-fan-in | kimi-k3 | strong | 3/3 | 3/3 | 0/3 | 0/3 | — | — | mc3 g0 | mc3 g0 | x 0/3 (u 3) | x 0/3 (u 3) | 112 | 88 | 0.4626 | 0.5516 |
| compose-two-source-fan-in | deepseek-flash | floor | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | u 3/3 (x 0) | u 3/3 (x 1) | 69 | 60 | 0.0264 | 0.0223 |
| compose-two-source-fan-in | glm-5.3-flash | floor | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | u 3/3 (x 2) | u 3/3 (x 1) | 169 | 174 | 0.0349 | 0.0408 |

### workflow

| task | model | tier | r v14 | r v13 | s v14 | s v13 | p v14 | p v13 | classes v14 | classes v13 | bar v14 | bar v13 | mean s v14 | mean s v13 | cost v14 | cost v13 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| workflow-adversarial-verify | glm-5.3 | strong | 3/3 | 3/3 | 3/3 | 1/3 | 3/3 | 3/3 | cuf1 g2 | dis2 cuf1 g0 | = s | = s | 296 | 256 | 1.6683 | 1.2612 |
| workflow-adversarial-verify | kimi-k3 | strong | 3/3 | 3/3 | 2/3 | 1/3 | 3/3 | 1/3 | dis1 cuf2 g0 | mc2 cuf1 g0 | = s | = s | 224 | 218 | 2.0306 | 2.7377 |
| workflow-adversarial-verify | deepseek-flash | floor | 1/3 | 3/3 | 0/3 | 3/3 | 2/3 | 3/3 | mc2 dis1 g0 | g3 | = s | = s | 182 | 244 | 0.1813 | 0.2415 |
| workflow-adversarial-verify | glm-5.3-flash | floor | 3/3 | 3/3 | 1/3 | 2/3 | 3/3 | 3/3 | dis2 g1 | dis1 g2 | = s | = s | 330 | 264 | 0.2902 | 0.2086 |
| workflow-barrier-free-pipeline | glm-5.3 | strong | 3/3 | 2/3 | 0/3 | 1/3 | 3/3 | 3/3 | dis3 g0 | mc1 dis1 cuf1 g0 | x 0/3 (u 3) | x 1/3 (u 2) | 166 | 246 | 0.4837 | 0.6528 |
| workflow-barrier-free-pipeline | kimi-k3 | strong | 0/3 | 0/3 | 0/3 | 0/3 | 3/3 | 3/3 | mc3 g0 | mc3 g0 | x 0/3 (u 0) | x 0/3 (u 0) | 45 | 35 | 0.1651 | 0.1881 |
| workflow-barrier-free-pipeline | deepseek-flash | floor | 0/3 | 1/3 | 0/3 | 1/3 | 3/3 | 3/3 | mc3 g0 | mc2 g1 | u 0/3 (x 0) | u 1/3 (x 0) | 34 | 47 | 0.0074 | 0.0185 |
| workflow-barrier-free-pipeline | glm-5.3-flash | floor | 2/3 | 2/3 | 2/3 | 2/3 | 3/3 | 3/3 | mc1 g2 | mc1 g2 | u 2/3 (x 0) | u 2/3 (x 0) | 118 | 90 | 0.0247 | 0.0216 |
| workflow-fan-out-finders | glm-5.3 | strong | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | g3 | g3 | = s | = s | 67 | 65 | 0.1305 | 0.1401 |
| workflow-fan-out-finders | kimi-k3 | strong | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | g3 | cuf3 g0 | = s | = s | 99 | 92 | 0.7978 | 1.1415 |
| workflow-fan-out-finders | deepseek-flash | floor | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | g3 | g3 | = s | = s | 56 | 54 | 0.0196 | 0.0201 |
| workflow-fan-out-finders | glm-5.3-flash | floor | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | g3 | g3 | = s | = s | 83 | 134 | 0.0591 | 0.0531 |
| workflow-judge-panel | glm-5.3 | strong | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | cuf3 g0 | cuf3 g0 | = s | = s | 369 | 243 | 1.6750 | 1.2282 |
| workflow-judge-panel | kimi-k3 | strong | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | g3 | cuf2 g1 | = s | = s | 106 | 167 | 0.7648 | 1.2487 |
| workflow-judge-panel | deepseek-flash | floor | 2/3 | 3/3 | 2/3 | 3/3 | 3/3 | 3/3 | mc1 g2 | g3 | = s | = s | 80 | 100 | 0.0441 | 0.0989 |
| workflow-judge-panel | glm-5.3-flash | floor | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | g3 | g3 | = s | = s | 165 | 247 | 0.0809 | 0.0867 |
| workflow-loop-until-dry | glm-5.3 | strong | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | g3 | g3 | = s | = s | 123 | 101 | 0.1681 | 0.2982 |
| workflow-loop-until-dry | kimi-k3 | strong | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | g3 | cuf2 g1 | = s | = s | 236 | 121 | 0.6073 | 0.9472 |
| workflow-loop-until-dry | deepseek-flash | floor | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | g3 | g3 | = s | = s | 51 | 62 | 0.0140 | 0.0130 |
| workflow-loop-until-dry | glm-5.3-flash | floor | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | mc1 g2 | g3 | = s | = s | 114 | 89 | 0.0565 | 0.0427 |

## Totals


### by family

| group | v14 | v13 |
|---|---|---|
| task | r 58/72 · s 55/72 · p — · mc17 cuf4 · green 51/72 · $3.0889 · 5348 s (mean 74 s) | r 57/72 · s 56/72 · p — · mc16 cuf2 · green 54/72 · $2.9823 · 4328 s (mean 60 s) |
| compose | r 107/108 · s 96/108 · p 12/12 · bar 79/96 · mc13 dis2 cuf6 · green 87/108 · $9.9939 · 16522 s (mean 153 s) | r 105/108 · s 90/108 · p 11/12 · bar 72/96 · mc15 dis3 cuf5 · green 85/108 · $9.5737 (2 null) · 16616 s (mean 154 s) |
| workflow | r 50/60 · s 43/60 · p 59/60 · bar 2/12 · mc11 dis7 cuf6 · green 36/60 · $9.2688 · 8831 s (mean 147 s) | r 53/60 · s 47/60 · p 58/60 · bar 4/12 · mc9 dis4 cuf13 · green 34/60 · $10.6485 · 8631 s (mean 144 s) |

### by model (all families)

| group | v14 | v13 |
|---|---|---|
| glm-5.3 | r 58/60 · s 49/60 · p 18/18 · bar 17/27 · mc8 dis4 cuf8 · green 40/60 · $9.9508 · 10060 s (mean 168 s) | r 56/60 · s 46/60 · p 18/18 · bar 14/27 · mc10 dis4 cuf6 · green 40/60 · $8.6416 (1 null) · 9692 s (mean 162 s) |
| kimi-k3 | r 55/60 · s 48/60 · p 18/18 · bar 15/27 · mc10 dis2 cuf5 · green 43/60 · $10.5516 · 5912 s (mean 99 s) | r 53/60 · s 43/60 · p 16/18 · bar 13/27 · mc15 dis2 cuf10 · green 33/60 · $12.6364 · 5172 s (mean 86 s) |
| deepseek-flash | r 50/60 · s 49/60 · p 17/18 · bar 24/27 · mc10 dis1 cuf3 · green 46/60 · $0.7437 · 3975 s (mean 66 s) | r 53/60 · s 53/60 · p 18/18 · bar 25/27 · mc7 cuf4 · green 49/60 · $0.9393 · 4379 s (mean 73 s) |
| glm-5.3-flash | r 52/60 · s 48/60 · p 18/18 · bar 25/27 · mc13 dis2 · green 45/60 · $1.1056 · 10754 s (mean 179 s) | r 53/60 · s 51/60 · p 17/18 · bar 24/27 · mc8 dis1 · green 51/60 · $0.9871 (1 null) · 10332 s (mean 172 s) |

### by family x model

| group | v14 | v13 |
|---|---|---|
| task / glm-5.3 | r 16/18 · s 15/18 · p — · mc3 cuf2 · green 13/18 · $1.2283 · 1516 s (mean 84 s) | r 16/18 · s 16/18 · p — · mc2 · green 16/18 · $0.7986 · 1231 s (mean 68 s) |
| task / kimi-k3 | r 16/18 · s 16/18 · p — · mc2 cuf2 · green 14/18 · $1.6049 · 1193 s (mean 66 s) | r 14/18 · s 14/18 · p — · mc4 cuf2 · green 12/18 · $1.9536 · 1087 s (mean 60 s) |
| task / deepseek-flash | r 14/18 · s 14/18 · p — · mc4 · green 14/18 · $0.0973 · 955 s (mean 53 s) | r 13/18 · s 13/18 · p — · mc5 · green 13/18 · $0.0809 · 812 s (mean 45 s) |
| task / glm-5.3-flash | r 12/18 · s 10/18 · p — · mc8 · green 10/18 · $0.1585 · 1684 s (mean 94 s) | r 14/18 · s 13/18 · p — · mc5 · green 13/18 · $0.1492 · 1198 s (mean 67 s) |
| compose / glm-5.3 | r 27/27 · s 22/27 · p 3/3 · bar 17/24 · mc5 dis1 cuf2 · green 19/27 · $4.5970 · 5482 s (mean 203 s) | r 26/27 · s 19/27 · p 3/3 · bar 13/24 · mc7 dis1 cuf1 · green 18/27 · $4.2624 (1 null) · 5729 s (mean 212 s) |
| compose / kimi-k3 | r 27/27 · s 21/27 · p 3/3 · bar 15/24 · mc5 dis1 cuf1 · green 20/27 · $4.5811 · 2588 s (mean 96 s) | r 27/27 · s 19/27 · p 3/3 · bar 13/24 · mc6 dis2 · green 19/27 · $4.4196 · 2183 s (mean 81 s) |
| compose / deepseek-flash | r 27/27 · s 27/27 · p 3/3 · bar 24/24 · cuf3 · green 24/27 · $0.3800 · 1812 s (mean 67 s) | r 27/27 · s 27/27 · p 3/3 · bar 24/24 · cuf4 · green 23/27 · $0.4665 · 2044 s (mean 76 s) |
| compose / glm-5.3-flash | r 26/27 · s 26/27 · p 3/3 · bar 23/24 · mc3 · green 24/27 · $0.4358 · 6640 s (mean 246 s) | r 25/27 · s 25/27 · p 2/3 · bar 22/24 · mc2 · green 25/27 · $0.4253 (1 null) · 6660 s (mean 247 s) |
| workflow / glm-5.3 | r 15/15 · s 12/15 · p 15/15 · bar 0/3 · dis3 cuf4 · green 8/15 · $4.1255 · 3062 s (mean 204 s) | r 14/15 · s 11/15 · p 15/15 · bar 1/3 · mc1 dis3 cuf5 · green 6/15 · $3.5806 · 2732 s (mean 182 s) |
| workflow / kimi-k3 | r 12/15 · s 11/15 · p 15/15 · bar 0/3 · mc3 dis1 cuf2 · green 9/15 · $4.3656 · 2131 s (mean 142 s) | r 12/15 · s 10/15 · p 13/15 · bar 0/3 · mc5 cuf8 · green 2/15 · $6.2633 · 1902 s (mean 127 s) |
| workflow / deepseek-flash | r 9/15 · s 8/15 · p 14/15 · bar 0/3 · mc6 dis1 · green 8/15 · $0.2663 · 1208 s (mean 81 s) | r 13/15 · s 13/15 · p 15/15 · bar 1/3 · mc2 · green 13/15 · $0.3919 · 1523 s (mean 102 s) |
| workflow / glm-5.3-flash | r 14/15 · s 12/15 · p 15/15 · bar 2/3 · mc2 dis2 · green 11/15 · $0.5113 · 2430 s (mean 162 s) | r 14/15 · s 13/15 · p 15/15 · bar 2/3 · mc1 dis1 · green 13/15 · $0.4127 · 2474 s (mean 165 s) |

### by family x tier

| group | v14 | v13 |
|---|---|---|
| task / strong | r 32/36 · s 31/36 · p — · mc5 cuf4 · green 27/36 · $2.8331 · 2709 s (mean 75 s) | r 30/36 · s 30/36 · p — · mc6 cuf2 · green 28/36 · $2.7522 · 2318 s (mean 64 s) |
| task / floor | r 26/36 · s 24/36 · p — · mc12 · green 24/36 · $0.2558 · 2639 s (mean 73 s) | r 27/36 · s 26/36 · p — · mc10 · green 26/36 · $0.2301 · 2010 s (mean 56 s) |
| compose / strong | r 54/54 · s 43/54 · p 6/6 · bar 32/48 · mc10 dis2 cuf3 · green 39/54 · $9.1781 · 8070 s (mean 149 s) | r 53/54 · s 38/54 · p 6/6 · bar 26/48 · mc13 dis3 cuf1 · green 37/54 · $8.6820 (1 null) · 7912 s (mean 147 s) |
| compose / floor | r 53/54 · s 53/54 · p 6/6 · bar 47/48 · mc3 cuf3 · green 48/54 · $0.8157 · 8452 s (mean 157 s) | r 52/54 · s 52/54 · p 5/6 · bar 46/48 · mc2 cuf4 · green 48/54 · $0.8918 (1 null) · 8704 s (mean 161 s) |
| workflow / strong | r 27/30 · s 23/30 · p 30/30 · bar 0/6 · mc3 dis4 cuf6 · green 17/30 · $8.4912 · 5193 s (mean 173 s) | r 26/30 · s 21/30 · p 28/30 · bar 1/6 · mc6 dis3 cuf13 · green 8/30 · $9.8439 · 4634 s (mean 154 s) |
| workflow / floor | r 23/30 · s 20/30 · p 29/30 · bar 2/6 · mc8 dis3 · green 19/30 · $0.7777 · 3638 s (mean 121 s) | r 27/30 · s 26/30 · p 30/30 · bar 3/6 · mc3 dis1 · green 26/30 · $0.8046 · 3997 s (mean 133 s) |

### by tier

| group | v14 | v13 |
|---|---|---|
| strong | r 113/120 · s 97/120 · p 36/36 · bar 32/54 · mc18 dis6 cuf13 · green 83/120 · $20.5024 · 15972 s (mean 133 s) | r 109/120 · s 89/120 · p 34/36 · bar 27/54 · mc25 dis6 cuf16 · green 73/120 · $21.2781 (1 null) · 14864 s (mean 124 s) |
| floor | r 102/120 · s 97/120 · p 35/36 · bar 49/54 · mc23 dis3 cuf3 · green 91/120 · $1.8492 · 14729 s (mean 123 s) | r 106/120 · s 104/120 · p 35/36 · bar 49/54 · mc15 dis1 cuf4 · green 100/120 · $1.9264 (1 null) · 14711 s (mean 123 s) |

ALL v14: r 215/240 · s 194/240 · p 71/72 · bar 81/108 · mc41 dis9 cuf16 · green 174/240 · $22.3517 · 30701 s (mean 128 s)
ALL v13: r 215/240 · s 193/240 · p 69/72 · bar 76/108 · mc40 dis7 cuf20 · green 173/240 · $23.2045 (2 null) · 29575 s (mean 123 s)

Deltas v14 - v13 (same 80 cells):
- all: reached +0, succeeded +1, passed +2, bar +5, green +1, mc +1, dis +2, cuf -4, lb +0, cost -0.8528, seconds +1126
- task: reached +1, succeeded -1, passed +0, bar +0, green -3, mc +1, dis +0, cuf +2, lb +0, cost +0.1067, seconds +1020
- compose: reached +2, succeeded +6, passed +1, bar +7, green +2, mc -2, dis -1, cuf +1, lb +0, cost +0.4201, seconds -94
- workflow: reached -3, succeeded -4, passed +1, bar -2, green +2, mc +2, dis +3, cuf -7, lb +0, cost -1.3796, seconds +200
- strong: reached +4, succeeded +8, passed +2, bar +5, green +10, mc -7, dis +0, cuf -3, lb +0, cost -0.7756, seconds +1108
- floor: reached -4, succeeded -7, passed +0, bar +0, green -9, mc +8, dis +2, cuf -1, lb +0, cost -0.0772, seconds +18
- glm-5.3: reached +2, succeeded +3, passed +0, bar +3, green +0, mc -2, dis +0, cuf +2, lb +0, cost +1.3092, seconds +368
- kimi-k3: reached +2, succeeded +5, passed +2, bar +2, green +10, mc -5, dis +0, cuf -5, lb +0, cost -2.0849, seconds +740
- deepseek-flash: reached -3, succeeded -4, passed -1, bar -1, green -3, mc +3, dis +1, cuf -1, lb +0, cost -0.1957, seconds -404
- glm-5.3-flash: reached -1, succeeded -3, passed +1, bar +1, green -6, mc +5, dis +1, cuf +0, lb +0, cost +0.1185, seconds +422

## Moved cells: |Δ| >= 2 of 3 on reached, succeeded, task_pass (passed count) or green

9 cells. Deltas as v14 - v13.

| family | task | model | Δr | Δs | Δp | Δgreen | v14 r s p [classes] | v13 r s p [classes] |
|---|---|---|---|---|---|---|---|---|
| task | task-background-suite | glm-5.3-flash | -2 | -2 | +0 | -2 | r0 s0 p— [mc3 g0] | r2 s2 p— [mc1 g2] |
| task | task-fan-five | glm-5.3 | +0 | +0 | +0 | -2 | r3 s3 p— [cuf2 g1] | r3 s3 p— [g3] |
| compose | compose-three-stage-pairing | deepseek-flash | +0 | +0 | +0 | -2 | r3 s3 p— [cuf2 g1] | r3 s3 p— [g3] |
| workflow | workflow-adversarial-verify | glm-5.3 | +0 | +2 | +0 | +2 | r3 s3 p3/3 [cuf1 g2] | r3 s1 p3/3 [dis2 cuf1 g0] |
| workflow | workflow-adversarial-verify | kimi-k3 | +0 | +1 | +2 | +0 | r3 s2 p3/3 [dis1 cuf2 g0] | r3 s1 p1/3 [mc2 cuf1 g0] |
| workflow | workflow-adversarial-verify | deepseek-flash | -2 | -3 | -1 | -3 | r1 s0 p2/3 [mc2 dis1 g0] | r3 s3 p3/3 [g3] |
| workflow | workflow-fan-out-finders | kimi-k3 | +0 | +0 | +0 | +3 | r3 s3 p3/3 [g3] | r3 s3 p3/3 [cuf3 g0] |
| workflow | workflow-judge-panel | kimi-k3 | +0 | +0 | +0 | +2 | r3 s3 p3/3 [g3] | r3 s3 p3/3 [cuf2 g1] |
| workflow | workflow-loop-until-dry | kimi-k3 | +0 | +0 | +0 | +2 | r3 s3 p3/3 [g3] | r3 s3 p3/3 [cuf2 g1] |

#### task / task-background-suite / glm-5.3-flash: Δr -2, Δs -2, Δg -2
- v14 #1 r=N s=— p=— model conduct 178s $0.0133 cache-after-r1 0.596 :: no `task` call: the model called {"start_process" => 1, "bash" => 10, "read" => 2, "edit" => 2}
- v14 #2 r=N s=— p=— model conduct 652s $0.0585 cache-after-r1 0.8576 :: no `task` call: the model called {"todo_write" => 4, "ls" => 1, "start_process" => 2, "bash" => 54, "read" => 3, "edit" => 1, "read_process" => 1, "me…
- v14 #3 r=N s=— p=— model conduct 113s $0.0096 cache-after-r1 0.914 :: no `task` call: the model called {"todo_write" => 2, "bash" => 8, "ls" => 1, "start_process" => 1, "read" => 1, "edit" => 1, "read_process" => 2}
- v13 #1 r=Y s=Y p=— green 124s $0.0231 cache-after-r1 0.6938 :: 
- v13 #2 r=N s=— p=— model conduct 128s $0.0180 cache-after-r1 0.7877 :: no `task` call: the model called {"todo_write" => 3, "ls" => 2, "list_processes" => 1, "bash" => 11, "read" => 1, "start_process" => 1, "edit" => 1, "…
- v13 #3 r=Y s=Y p=— green 161s $0.0211 cache-after-r1 0.6032 :: 

#### task / task-fan-five / glm-5.3: Δg -2
- v14 #1 r=Y s=Y p=— cache under floor 132s $0.1641 cache-after-r1 0.5072 :: 
- v14 #2 r=Y s=Y p=— green 114s $0.1088 cache-after-r1 0.8665 :: 
- v14 #3 r=Y s=Y p=— cache under floor 82s $0.0869 cache-after-r1 0.7918 :: 
- v13 #1 r=Y s=Y p=— green 101s $0.0858 cache-after-r1 0.6464 :: 
- v13 #2 r=Y s=Y p=— green 103s $0.0525 cache-after-r1 0.8068 :: 
- v13 #3 r=Y s=Y p=— green 87s $0.0552 cache-after-r1 0.0 :: 

#### compose / compose-three-stage-pairing / deepseek-flash: Δg -2
- v14 #1 r=Y s=Y p=— green 54s $0.0119 cache-after-r1 0.5901 ::  {picture: the picture is not the objective's (silent: over_read): {"nodes" => ["; usable_on_call: 1}
- v14 #2 r=Y s=Y p=— cache under floor 64s $0.0139 cache-after-r1 0.7718 ::  {picture: true; usable_on_call: 1}
- v14 #3 r=Y s=Y p=— cache under floor 43s $0.0081 cache-after-r1 0.7624 ::  {picture: the script was refused script_syntax_error: SyntaxError: Unexpected id; usable_on_call: 2}
- v13 #1 r=Y s=Y p=— green 38s $0.0062 cache-after-r1 0.7573 ::  {picture: true; usable_on_call: 1}
- v13 #2 r=Y s=Y p=— green 49s $0.0053 cache-after-r1 0.8266 ::  {picture: true; usable_on_call: 1}
- v13 #3 r=Y s=Y p=— green 59s $0.0141 cache-after-r1 0.5337 ::  {picture: true; usable_on_call: 1}

#### workflow / workflow-adversarial-verify / glm-5.3: Δs +2, Δg +2
- v14 #1 r=Y s=Y p=Y green 333s $0.6771 cache-after-r1 0.854 :: 
- v14 #2 r=Y s=Y p=Y cache under floor 403s $0.7220 cache-after-r1 0.7427 :: 
- v14 #3 r=Y s=Y p=Y green 151s $0.2692 cache-after-r1 0.8379 :: 
- v13 #1 r=Y s=Y p=Y cache under floor 264s $0.6472 cache-after-r1 0.4358 :: 
- v13 #2 r=Y s=N p=Y disagreement 239s $0.2210 cache-after-r1 0.8062 :: no input_accepted{origin: task_result}: every task call waited (wait: true on 12 of 12), so no receipt was owed and the receipt-wake loop never ran ({…
- v13 #3 r=Y s=N p=Y disagreement 265s $0.3931 cache-after-r1 0.8271 :: no input_accepted{origin: task_result}: every task call waited (wait: true on 12 of 12), so no receipt was owed and the receipt-wake loop never ran ({…

#### workflow / workflow-adversarial-verify / kimi-k3: Δp +2
- v14 #1 r=Y s=Y p=Y cache under floor 213s $0.8806 cache-after-r1 0.3872 :: 
- v14 #2 r=Y s=N p=Y disagreement 239s $0.4940 cache-after-r1 0.0267 :: no input_accepted{origin: task_result}: every task call waited (wait: true on 12 of 12), so no receipt was owed and the receipt-wake loop never ran ({…
- v14 #3 r=Y s=Y p=Y cache under floor 220s $0.6560 cache-after-r1 0.4482 :: 
- v13 #1 r=Y s=N p=N model conduct 201s $1.0803 cache-after-r1 0.1715 :: no input_accepted{origin: task_result}: every task call waited (wait: true on 12 of 12), so no receipt was owed and the receipt-wake loop never ran ({…
- v13 #2 r=Y s=Y p=Y cache under floor 182s $0.8356 cache-after-r1 0.5158 :: 
- v13 #3 r=Y s=N p=N model conduct 272s $0.8218 cache-after-r1 0.4457 :: no input_accepted{origin: task_result}: every task call waited (wait: true on 13 of 13), so no receipt was owed and the receipt-wake loop never ran ({…

#### workflow / workflow-adversarial-verify / deepseek-flash: Δr -2, Δs -3, Δg -3
- v14 #1 r=Y s=N p=Y disagreement 314s $0.1597 cache-after-r1 0.8521 :: no input_accepted{origin: task_result}: every task call waited (wait: true on 13 of 13), so no receipt was owed and the receipt-wake loop never ran ({…
- v14 #2 r=N s=— p=Y model conduct 189s $0.0089 cache-after-r1 0.8258 :: no compose call and no round fanned two task calls: {"read" => 1, "ls" => 1, "spawn" => 12, "write" => 1}
- v14 #3 r=N s=— p=N model conduct 42s $0.0126 cache-after-r1 0.7777 :: no compose call and no round fanned two task calls: {"read" => 4, "find" => 1, "spawn" => 12} [conduct failed: did_not_judge_itself]
- v13 #1 r=Y s=Y p=Y green 283s $0.0828 cache-after-r1 0.8863 :: 
- v13 #2 r=Y s=Y p=Y green 127s $0.0355 cache-after-r1 0.9154 :: 
- v13 #3 r=Y s=Y p=Y green 321s $0.1232 cache-after-r1 0.8541 :: 

#### workflow / workflow-fan-out-finders / kimi-k3: Δg +3
- v14 #1 r=Y s=Y p=Y green 96s $0.2628 cache-after-r1 0.8979 :: 
- v14 #2 r=Y s=Y p=Y green 80s $0.2115 cache-after-r1 0.8876 :: 
- v14 #3 r=Y s=Y p=Y green 122s $0.3236 cache-after-r1 0.9468 :: 
- v13 #1 r=Y s=Y p=Y cache under floor 85s $0.4135 cache-after-r1 0.2869 :: 
- v13 #2 r=Y s=Y p=Y cache under floor 83s $0.3424 cache-after-r1 0.2983 :: 
- v13 #3 r=Y s=Y p=Y cache under floor 108s $0.3857 cache-after-r1 0.0 :: 

#### workflow / workflow-judge-panel / kimi-k3: Δg +2
- v14 #1 r=Y s=Y p=Y green 111s $0.2698 cache-after-r1 0.8669 :: 
- v14 #2 r=Y s=Y p=Y green 101s $0.2508 cache-after-r1 0.9016 :: 
- v14 #3 r=Y s=Y p=Y green 107s $0.2442 cache-after-r1 0.8583 :: 
- v13 #1 r=Y s=Y p=Y green 132s $0.4684 cache-after-r1 0.8751 :: 
- v13 #2 r=Y s=Y p=Y cache under floor 187s $0.5714 cache-after-r1 0.328 :: 
- v13 #3 r=Y s=Y p=Y cache under floor 183s $0.2089 cache-after-r1 0.6045 :: 

#### workflow / workflow-loop-until-dry / kimi-k3: Δg +2
- v14 #1 r=Y s=Y p=Y green 160s $0.2022 cache-after-r1 0.9156 :: 
- v14 #2 r=Y s=Y p=Y green 421s $0.2542 cache-after-r1 0.835 :: 
- v14 #3 r=Y s=Y p=Y green 126s $0.1509 cache-after-r1 0.9477 :: 
- v13 #1 r=Y s=Y p=Y cache under floor 120s $0.4083 cache-after-r1 0.6306 :: 
- v13 #2 r=Y s=Y p=Y cache under floor 141s $0.3240 cache-after-r1 0.7048 :: 
- v13 #3 r=Y s=Y p=Y green 103s $0.2149 cache-after-r1 0.8044 :: 

### Picture cells whose picture fact or usable count moved by >= 2 of 3

#### compose-rendezvous / glm-5.3-flash (floor): picture 0 -> 2 (+2), usable 3 -> 3 (+0)
- v14 #1 r=Y s=Y p=— green 431s $0.0312 cache-after-r1 0.0 ::  {picture: true; usable_on_call: 1}
- v14 #2 r=Y s=Y p=— model conduct 651s $0.0331 cache-after-r1 None :: [stopped deadline at 651 s]  {picture: the picture is not the objective's (silent: over_read): {"nodes" => ["; usable_on_call: 1}
- v14 #3 r=Y s=Y p=— green 376s $0.0255 cache-after-r1 0.3285 ::  {picture: true; usable_on_call: 1}
- v13 #1 r=Y s=Y p=— green 475s $0.0315 cache-after-r1 0.605 ::  {picture: the script was refused script_error: Error: g.tool: after: goes beside; usable_on_call: 2}
- v13 #2 r=Y s=Y p=— green 399s $0.0271 cache-after-r1 0.8452 ::  {picture: the picture is not the objective's (silent: extra_steps, over_read): {; usable_on_call: 1}
- v13 #3 r=Y s=Y p=— green 611s $0.0436 cache-after-r1 0.1603 ::  {picture: the picture is not the objective's (silent: over_read): {"nodes" => ["; usable_on_call: 1}

#### compose-three-stage-pairing / deepseek-flash (floor): picture 3 -> 1 (-2), usable 3 -> 3 (+0)
- v14 #1 r=Y s=Y p=— green 54s $0.0119 cache-after-r1 0.5901 ::  {picture: the picture is not the objective's (silent: over_read): {"nodes" => ["; usable_on_call: 1}
- v14 #2 r=Y s=Y p=— cache under floor 64s $0.0139 cache-after-r1 0.7718 ::  {picture: true; usable_on_call: 1}
- v14 #3 r=Y s=Y p=— cache under floor 43s $0.0081 cache-after-r1 0.7624 ::  {picture: the script was refused script_syntax_error: SyntaxError: Unexpected id; usable_on_call: 2}
- v13 #1 r=Y s=Y p=— green 38s $0.0062 cache-after-r1 0.7573 ::  {picture: true; usable_on_call: 1}
- v13 #2 r=Y s=Y p=— green 49s $0.0053 cache-after-r1 0.8266 ::  {picture: true; usable_on_call: 1}
- v13 #3 r=Y s=Y p=— green 59s $0.0141 cache-after-r1 0.5337 ::  {picture: true; usable_on_call: 1}


## Reds by reason kind, per family (every record whose class is not green)


### task: v14 21 reds, v13 18

| reason kind | v14 | v13 | v14 by model (glm / kimi / ds-flash / glm-flash) | v14 by task |
|---|---|---|---|---|
| no `task` call; start_process in the tally | 13 | 12 | 2 / 2 / 3 / 6 | background-suite 6, mail 7 |
| cache under floor (success held) | 4 | 2 | 2 / 2 / 0 / 0 | background-suite 2, fan-five 2 |
| a second `task` for files already handed out | 2 | 0 | 0 / 0 / 0 / 2 | fan-five 2 |
| fewer than five `task` calls in the first message | 1 | 2 | 0 / 0 / 1 / 0 | fan-five 1 |
| the suite handed to more than one `task` | 1 | 0 | 1 / 0 / 0 / 0 | background-suite 1 |
| no `task` call; no start_process | 0 | 1 | 0 / 0 / 0 / 0 |  |
| the merged reply misses a finding | 0 | 1 | 0 / 0 / 0 / 0 |  |

v14 conduct checks failed/checked: named_db_and_cache 0/12, no_false_claim 0/12

v13 conduct checks failed/checked: named_db_and_cache 0/12, no_false_claim 0/12

### compose: v14 21 reds, v13 23

| reason kind | v14 | v13 | v14 by model (glm / kimi / ds-flash / glm-flash) | v14 by task |
|---|---|---|---|---|
| picture red (first compose call) | 9 | 12 | 4 / 5 / 0 / 0 | background-suite 2, grep-then-edit 2, two-source-fan-in 5 |
| cache under floor (success held) | 6 | 5 | 2 / 1 / 3 / 0 | grep-then-edit 3, single-read 1, three-stage-pairing 2 |
| 600 s deadline stop (model conduct as recorded) | 3 | 2 | 1 / 0 / 0 / 2 | background-suite 1, grep-then-edit 1, rendezvous 1 |
| compose refused (script_syntax_error) | 1 | 1 | 0 / 1 / 0 / 0 | background-suite 1 |
| no compose call (did it with tools) | 1 | 1 | 0 / 0 / 0 / 1 | three-stage-pairing 1 |
| conduct only: no_wrong_winner | 1 | 0 | 1 / 0 / 0 / 0 | race-anon 1 |
| stage script-1 of r2t0 does not parse: SyntaxError: Invalid or unexpected token  | 0 | 1 | 0 / 0 / 0 / 0 |  |
| stage script-1/script-1 of r2t0 does not parse: SyntaxError: Invalid or unexpect | 0 | 1 | 0 / 0 / 0 / 0 |  |

v14 picture-red buckets over 10 records whose reason names buckets: over_read 7, extra_steps 2, over_sync 2, missing_steps 1, blind_model 1

v13 picture-red buckets over 12 records whose reason names buckets: over_read 9, extra_steps 3, over_sync 3, wrong_task_read 1

v14 conduct checks failed/checked: no_wrong_winner 1/24

v13 conduct checks failed/checked: no_wrong_winner 0/24

### workflow: v14 24 reds, v13 26

| reason kind | v14 | v13 | v14 by model (glm / kimi / ds-flash / glm-flash) | v14 by task |
|---|---|---|---|---|
| no compose call and no two-`task` fan (did it with tools) | 10 | 7 | 0 / 3 / 6 / 1 | adversarial-verify 2, barrier-free-pipeline 7, judge-panel 1 |
| cache under floor (success held) | 6 | 13 | 4 / 2 / 0 / 0 | adversarial-verify 3, judge-panel 3 |
| no task_result receipt: every `task` call waited | 4 | 5 | 0 / 1 / 1 / 2 | adversarial-verify 4 |
| picture red (first compose call) | 3 | 1 | 3 / 0 / 0 / 0 | barrier-free-pipeline 3 |
| conduct only: one_item_per_pass | 1 | 0 | 0 / 0 / 0 / 1 | loop-until-dry 1 |

v14 picture-red buckets over 3 records whose reason names buckets: edit_as_tool 3

v13 picture-red buckets over 1 records whose reason names buckets: edit_as_tool 1

v14 conduct checks failed/checked: did_not_judge_itself 1/12, did_not_search_itself 0/12, one_item_per_pass 1/12

v13 conduct checks failed/checked: did_not_judge_itself 0/12, did_not_search_itself 0/12, one_item_per_pass 0/12

## Cost and duration per model

| model | tier | v14 task $ | v14 compose $ | v14 workflow $ | v14 total $ | v13 total $ | Δ$ | v14 s | v13 s | v14 mean s | v13 mean s |
|---|---|---|---|---|---|---|---|---|---|---|---|
| glm-5.3 | strong | 1.2283 | 4.5970 | 4.1255 | 9.9508 | 8.6416 | +1.3092 | 10060 | 9692 | 168 | 162 |
| kimi-k3 | strong | 1.6049 | 4.5811 | 4.3656 | 10.5516 | 12.6364 | -2.0849 | 5912 | 5172 | 99 | 86 |
| deepseek-flash | floor | 0.0973 | 0.3800 | 0.2663 | 0.7437 | 0.9393 | -0.1957 | 3975 | 4379 | 66 | 73 |
| glm-5.3-flash | floor | 0.1585 | 0.4358 | 0.5113 | 1.1056 | 0.9871 | +0.1185 | 10754 | 10332 | 179 | 172 |

v14: total $22.3517 (0 null-cost records); by family task $3.0889 / 5348 s, compose $9.9939 / 16522 s, workflow $9.2688 / 8831 s; by lane deepseek direct $0.7437, openrouter $21.6080; seconds 30701 (8.53 h)

v13: total $23.2045 (2 null-cost records); by family task $2.9823 / 4328 s, compose $9.5737 / 16616 s, workflow $10.6485 / 8631 s; by lane deepseek direct $0.9393, openrouter $22.2652; seconds 29575 (8.22 h)

v14 null-cost records: 0 

## usable_on_call and the picture on the picture tasks (every run, both tiers)

| task | model | tier | v14 usable | v14 picture | v14 on call 1/2/3/none | v13 usable | v13 picture | v13 on call 1/2/3/none |
|---|---|---|---|---|---|---|---|---|
| compose-background-suite | glm-5.3 | strong | 3/3 | 1/3 | 3/0/0/0 | 2/3 | 1/3 | 2/0/0/1 |
| compose-background-suite | kimi-k3 | strong | 3/3 | 1/3 | 2/1/0/0 | 3/3 | 1/3 | 3/0/0/0 |
| compose-background-suite | deepseek-flash | floor | 3/3 | 1/3 | 3/0/0/0 | 3/3 | 0/3 | 2/1/0/0 |
| compose-background-suite | glm-5.3-flash | floor | 3/3 | 1/3 | 2/1/0/0 | 3/3 | 1/3 | 3/0/0/0 |
| compose-grep-then-edit | glm-5.3 | strong | 3/3 | 2/3 | 3/0/0/0 | 3/3 | 2/3 | 2/1/0/0 |
| compose-grep-then-edit | kimi-k3 | strong | 3/3 | 2/3 | 3/0/0/0 | 3/3 | 1/3 | 3/0/0/0 |
| compose-grep-then-edit | deepseek-flash | floor | 3/3 | 3/3 | 3/0/0/0 | 3/3 | 2/3 | 2/1/0/0 |
| compose-grep-then-edit | glm-5.3-flash | floor | 3/3 | 1/3 | 2/1/0/0 | 2/3 | 1/3 | 2/0/0/1 |
| compose-race | glm-5.3 | strong | 3/3 | 3/3 | 3/0/0/0 | 3/3 | 3/3 | 3/0/0/0 |
| compose-race | kimi-k3 | strong | 3/3 | 3/3 | 3/0/0/0 | 3/3 | 3/3 | 3/0/0/0 |
| compose-race | deepseek-flash | floor | 3/3 | 3/3 | 3/0/0/0 | 3/3 | 2/3 | 2/1/0/0 |
| compose-race | glm-5.3-flash | floor | 3/3 | 2/3 | 2/1/0/0 | 3/3 | 2/3 | 2/1/0/0 |
| compose-race-anon | glm-5.3 | strong | 3/3 | 3/3 | 3/0/0/0 | 3/3 | 3/3 | 3/0/0/0 |
| compose-race-anon | kimi-k3 | strong | 3/3 | 3/3 | 3/0/0/0 | 3/3 | 3/3 | 3/0/0/0 |
| compose-race-anon | deepseek-flash | floor | 3/3 | 3/3 | 3/0/0/0 | 3/3 | 2/3 | 2/1/0/0 |
| compose-race-anon | glm-5.3-flash | floor | 3/3 | 3/3 | 3/0/0/0 | 3/3 | 3/3 | 3/0/0/0 |
| compose-rendezvous | glm-5.3 | strong | 3/3 | 1/3 | 3/0/0/0 | 3/3 | 0/3 | 3/0/0/0 |
| compose-rendezvous | kimi-k3 | strong | 3/3 | 0/3 | 3/0/0/0 | 3/3 | 0/3 | 3/0/0/0 |
| compose-rendezvous | deepseek-flash | floor | 3/3 | 0/3 | 3/0/0/0 | 3/3 | 0/3 | 3/0/0/0 |
| compose-rendezvous | glm-5.3-flash | floor | 3/3 | 2/3 | 3/0/0/0 | 3/3 | 0/3 | 2/1/0/0 |
| compose-review-angles | glm-5.3 | strong | 3/3 | 3/3 | 3/0/0/0 | 3/3 | 2/3 | 2/1/0/0 |
| compose-review-angles | kimi-k3 | strong | 3/3 | 3/3 | 3/0/0/0 | 3/3 | 3/3 | 3/0/0/0 |
| compose-review-angles | deepseek-flash | floor | 3/3 | 3/3 | 3/0/0/0 | 3/3 | 3/3 | 3/0/0/0 |
| compose-review-angles | glm-5.3-flash | floor | 3/3 | 3/3 | 3/0/0/0 | 3/3 | 2/3 | 2/1/0/0 |
| compose-three-stage-pairing | glm-5.3 | strong | 3/3 | 3/3 | 3/0/0/0 | 3/3 | 2/3 | 3/0/0/0 |
| compose-three-stage-pairing | kimi-k3 | strong | 3/3 | 3/3 | 3/0/0/0 | 3/3 | 2/3 | 2/1/0/0 |
| compose-three-stage-pairing | deepseek-flash | floor | 3/3 | 1/3 | 2/1/0/0 | 3/3 | 3/3 | 3/0/0/0 |
| compose-three-stage-pairing | glm-5.3-flash | floor | 2/3 | 1/3 | 2/0/0/1 | 2/3 | 1/3 | 2/0/0/1 |
| compose-two-source-fan-in | glm-5.3 | strong | 3/3 | 1/3 | 3/0/0/0 | 3/3 | 0/3 | 3/0/0/0 |
| compose-two-source-fan-in | kimi-k3 | strong | 3/3 | 0/3 | 3/0/0/0 | 3/3 | 0/3 | 3/0/0/0 |
| compose-two-source-fan-in | deepseek-flash | floor | 3/3 | 0/3 | 3/0/0/0 | 3/3 | 1/3 | 3/0/0/0 |
| compose-two-source-fan-in | glm-5.3-flash | floor | 3/3 | 2/3 | 3/0/0/0 | 3/3 | 1/3 | 3/0/0/0 |
| workflow-barrier-free-pipeline | glm-5.3 | strong | 3/3 | 0/3 | 3/0/0/0 | 2/3 | 1/3 | 2/0/0/1 |
| workflow-barrier-free-pipeline | kimi-k3 | strong | 0/3 | 0/3 | 0/0/0/3 | 0/3 | 0/3 | 0/0/0/3 |
| workflow-barrier-free-pipeline | deepseek-flash | floor | 0/3 | 0/3 | 0/0/0/3 | 1/3 | 0/3 | 1/0/0/2 |
| workflow-barrier-free-pipeline | glm-5.3-flash | floor | 2/3 | 0/3 | 2/0/0/1 | 2/3 | 0/3 | 2/0/0/1 |

| version | scope | tier | model | runs | usable | picture | on call 1 / 2 / 3 / none |
|---|---|---|---|---|---|---|---|
| v13 | all picture tasks | floor | deepseek-flash | 27 | 25 | 13 | 21 / 4 / 0 / 2 |
| v13 | all picture tasks | floor | glm-5.3-flash | 27 | 24 | 11 | 21 / 3 / 0 / 3 |
| v13 | all picture tasks | strong | glm-5.3 | 27 | 25 | 14 | 23 / 2 / 0 / 2 |
| v13 | all picture tasks | strong | kimi-k3 | 27 | 24 | 13 | 23 / 1 / 0 / 3 |
| v13 | compose picture tasks | floor | deepseek-flash | 24 | 24 | 13 | 20 / 4 / 0 / 0 |
| v13 | compose picture tasks | floor | glm-5.3-flash | 24 | 22 | 11 | 19 / 3 / 0 / 2 |
| v13 | compose picture tasks | strong | glm-5.3 | 24 | 23 | 13 | 21 / 2 / 0 / 1 |
| v13 | compose picture tasks | strong | kimi-k3 | 24 | 24 | 13 | 23 / 1 / 0 / 0 |
| v13 | workflow picture tasks | floor | deepseek-flash | 3 | 1 | 0 | 1 / 0 / 0 / 2 |
| v13 | workflow picture tasks | floor | glm-5.3-flash | 3 | 2 | 0 | 2 / 0 / 0 / 1 |
| v13 | workflow picture tasks | strong | glm-5.3 | 3 | 2 | 1 | 2 / 0 / 0 / 1 |
| v13 | workflow picture tasks | strong | kimi-k3 | 3 | 0 | 0 | 0 / 0 / 0 / 3 |
| v14 | all picture tasks | floor | deepseek-flash | 27 | 24 | 14 | 23 / 1 / 0 / 3 |
| v14 | all picture tasks | floor | glm-5.3-flash | 27 | 25 | 15 | 22 / 3 / 0 / 2 |
| v14 | all picture tasks | strong | glm-5.3 | 27 | 27 | 17 | 27 / 0 / 0 / 0 |
| v14 | all picture tasks | strong | kimi-k3 | 27 | 24 | 15 | 23 / 1 / 0 / 3 |
| v14 | compose picture tasks | floor | deepseek-flash | 24 | 24 | 14 | 23 / 1 / 0 / 0 |
| v14 | compose picture tasks | floor | glm-5.3-flash | 24 | 23 | 15 | 20 / 3 / 0 / 1 |
| v14 | compose picture tasks | strong | glm-5.3 | 24 | 24 | 17 | 24 / 0 / 0 / 0 |
| v14 | compose picture tasks | strong | kimi-k3 | 24 | 24 | 15 | 23 / 1 / 0 / 0 |
| v14 | workflow picture tasks | floor | deepseek-flash | 3 | 0 | 0 | 0 / 0 / 0 / 3 |
| v14 | workflow picture tasks | floor | glm-5.3-flash | 3 | 2 | 0 | 2 / 0 / 0 / 1 |
| v14 | workflow picture tasks | strong | glm-5.3 | 3 | 3 | 0 | 3 / 0 / 0 / 0 |
| v14 | workflow picture tasks | strong | kimi-k3 | 3 | 0 | 0 | 0 / 0 / 0 / 3 |
- v14 all picture tasks strong: runs 54, usable 51, picture 32, on call 1/2/3/none 50/1/0/3
- v14 all picture tasks floor: runs 54, usable 49, picture 29, on call 1/2/3/none 45/4/0/5
- v14 compose picture tasks strong: runs 48, usable 48, picture 32, on call 1/2/3/none 47/1/0/0
- v14 compose picture tasks floor: runs 48, usable 47, picture 29, on call 1/2/3/none 43/4/0/1
- v14 workflow picture tasks strong: runs 6, usable 3, picture 0, on call 1/2/3/none 3/0/0/3
- v14 workflow picture tasks floor: runs 6, usable 2, picture 0, on call 1/2/3/none 2/0/0/4
- v13 all picture tasks strong: runs 54, usable 49, picture 27, on call 1/2/3/none 46/3/0/5
- v13 all picture tasks floor: runs 54, usable 49, picture 24, on call 1/2/3/none 42/7/0/5
- v13 compose picture tasks strong: runs 48, usable 47, picture 26, on call 1/2/3/none 44/3/0/1
- v13 compose picture tasks floor: runs 48, usable 46, picture 24, on call 1/2/3/none 39/7/0/2
- v13 workflow picture tasks strong: runs 6, usable 2, picture 1, on call 1/2/3/none 2/0/0/4
- v13 workflow picture tasks floor: runs 6, usable 3, picture 0, on call 1/2/3/none 3/0/0/3

floor picture-task runs NOT usable on call 1 (v14):
- compose-background-suite glm-5.3-flash #3 r=Y s=Y p=— green 207s $0.0149 cache-after-r1 0.7518 ::  {picture: the script was refused script_error: Error: g.parallel: every member m; usable_on_call: 2}
- compose-grep-then-edit glm-5.3-flash #3 r=Y s=Y p=Y green 598s $0.0380 cache-after-r1 0.5677 ::  {picture: the script was refused script_syntax_error: SyntaxError: Unexpected id; usable_on_call: 2}
- compose-race glm-5.3-flash #3 r=Y s=Y p=— green 226s $0.0171 cache-after-r1 0.6179 ::  {picture: nothing r2t0 placed stands: the stages that did its work failed on the; usable_on_call: 2}
- compose-three-stage-pairing deepseek-flash #3 r=Y s=Y p=— cache under floor 43s $0.0081 cache-after-r1 0.7624 ::  {picture: the script was refused script_syntax_error: SyntaxError: Unexpected id; usable_on_call: 2}
- compose-three-stage-pairing glm-5.3-flash #1 r=N s=— p=— model conduct 314s $0.0224 cache-after-r1 0.8401 :: no compose call: the model called {"write" => 1, "bash" => 3, "edit" => 1} {picture: no compose call to score; usable_on_call: None}
- workflow-barrier-free-pipeline deepseek-flash #1 r=N s=— p=Y model conduct 34s $0.0022 cache-after-r1 0.9532 :: no compose call and no round fanned two task calls: {"ls" => 1, "bash" => 3} {picture: no compose call to score; usable_on_call: None}
- workflow-barrier-free-pipeline deepseek-flash #2 r=N s=— p=Y model conduct 38s $0.0029 cache-after-r1 0.9542 :: no compose call and no round fanned two task calls: {"ls" => 1, "bash" => 3, "write" => 1} {picture: no compose call to score; usable_on_call: None}
- workflow-barrier-free-pipeline deepseek-flash #3 r=N s=— p=Y model conduct 29s $0.0023 cache-after-r1 0.9209 :: no compose call and no round fanned two task calls: {"ls" => 1, "bash" => 2} {picture: no compose call to score; usable_on_call: None}
- workflow-barrier-free-pipeline glm-5.3-flash #1 r=N s=— p=Y model conduct 62s $0.0042 cache-after-r1 0.4598 :: no compose call and no round fanned two task calls: {"bash" => 2} {picture: no compose call to score; usable_on_call: None}

strong picture-task runs NOT usable on call 1 (v14):
- compose-background-suite kimi-k3 #1 r=Y s=N p=— model conduct 110s $0.2544 cache-after-r1 0.4689 :: the script was refused script_syntax_error: SyntaxError: Unexpected identifier 'bin' at line 42, column 83: …n app/, but this follow-up \\`bin/rubocop… {picture: the script was refused script_syntax_error: SyntaxError: Unexpected id; usable_on_call: 2}
- workflow-barrier-free-pipeline kimi-k3 #1 r=N s=— p=Y model conduct 44s $0.0652 cache-after-r1 0.8723 :: no compose call and no round fanned two task calls: {"ls" => 1, "read" => 1, "bash" => 1} {picture: no compose call to score; usable_on_call: None}
- workflow-barrier-free-pipeline kimi-k3 #2 r=N s=— p=Y model conduct 41s $0.0512 cache-after-r1 0.8955 :: no compose call and no round fanned two task calls: {"ls" => 1, "bash" => 2} {picture: no compose call to score; usable_on_call: None}
- workflow-barrier-free-pipeline kimi-k3 #3 r=N s=— p=Y model conduct 50s $0.0487 cache-after-r1 0.8996 :: no compose call and no round fanned two task calls: {"ls" => 1, "bash" => 2} {picture: no compose call to score; usable_on_call: None}

## success against the tier's bar on every reached picture-task record (v14)

- 100 reached picture-task records; success differs from the tier's bar on 5: [('compose-rendezvous', 'glm-5.3', 2, True, False, None), ('compose-rendezvous', 'glm-5.3', 3, True, False, None), ('compose-rendezvous', 'kimi-k3', 1, True, False, None), ('compose-rendezvous', 'kimi-k3', 2, True, False, None), ('compose-rendezvous', 'kimi-k3', 3, True, False, None)]

## The strong tier's picture on compose, and the floor's usable_on_call (compose picture tasks)

- v14 strong: picture exact 32/48 over 8 tasks (compose-rendezvous 1/6; without it 31/42); usable 48/48; usable_on_call 1/2/3/none 47/1/0/0
- v14 floor: picture exact 29/48 over 8 tasks (compose-rendezvous 2/6; without it 27/42); usable 47/48; usable_on_call 1/2/3/none 43/4/0/1
- v13 strong: picture exact 26/48 over 8 tasks (compose-rendezvous 0/6; without it 26/42); usable 47/48; usable_on_call 1/2/3/none 44/3/0/1
- v13 floor: picture exact 24/48 over 8 tasks (compose-rendezvous 0/6; without it 24/42); usable 46/48; usable_on_call 1/2/3/none 39/7/0/2
- v14 floor, every picture task (compose and workflow): runs 54; made a compose call 49; of those usable 49; no compose call 5
- v14 strong, every picture task (compose and workflow): runs 54; made a compose call 51; of those usable 51; no compose call 3
- v13 floor, every picture task (compose and workflow): runs 54; made a compose call 49; of those usable 49; no compose call 5
- v13 strong, every picture task (compose and workflow): runs 54; made a compose call 49; of those usable 49; no compose call 5

compose-two-source-fan-in by tier (picture exact / usable / succeeded, of 6):
- v14 strong: picture 1/6, usable 6/6, succeeded 1/6; buckets on the picture fact {'over_read': 5}
- v14 floor: picture 2/6, usable 6/6, succeeded 6/6; buckets on the picture fact {'over_sync': 1, 'over_read': 3}
- v13 strong: picture 0/6, usable 6/6, succeeded 0/6; buckets on the picture fact {'over_read': 5, 'over_sync': 2}
- v13 floor: picture 2/6, usable 6/6, succeeded 6/6; buckets on the picture fact {'over_read': 3, 'over_sync': 1}
~~~

### A2_evidence.py

<!-- script:A2_evidence.py -->
```python
#!/usr/bin/env python3
"""SECTION A, THE EVIDENCE BEHIND THE WATCHER'S THREE FLAGS AND THE MOVED CELLS (read-only).

Reads the v13 records (last line per key) and the v14 records, and each record's own artifact JSON
(record["artifact"]: tasks with tool_name / tool_input / after, sealed_request). Prints:
1. task-background-suite: the cell's history over v10, v11, v13, v14 (last line per key); per run on
   v13 and v14 the `task` rows (round, wait, the prompt's first words, whether it names the suite)
   and the `start_process` rows (round, command); what the first request carries on v13 against v14
   (system / developer / user entries after the per-run project path is normalised, and every tool
   definition), for the same model.
2. workflow-barrier-free-pipeline: per run on v13 and v14 the door, the call tally, the placed plan
   (each step's kind and command or stage) off facts.score, the silent buckets, task pass,
   usable_on_call; and O7's merge node types off objectives.rb.
3. the other moved cells: workflow-adversarial-verify (door, waited, receipts, spawn/task counts,
   the wait flag on every `task` / `spawn` row), task-fan-five (task rows per round and their
   files), the cache-moved cells' rate after round 1.
"""
import json
import os
import re
from collections import Counter, OrderedDict

REPO = "/Users/jasl/Workspaces/cybros-ai.alt2"
RUNS = os.path.join(REPO, "e2e/evals/runs")
KEY = ("task", "model", "style", "run")
MODELS = ["openrouter/z-ai/glm-5.3", "openrouter/moonshotai/kimi-k3",
          "deepseek/deepseek-flash", "openrouter/z-ai/glm-5.3-flash"]
VERSIONS = OrderedDict([("v10", "2026-09-23-v10"), ("v11", "2026-09-24-v11"), ("v13", "2026-09-25-v13"),
                        ("v14", "2026-09-26-v14")])


def short(model):
    return model.split("/")[-1]


def load(prefix, family):
    path = os.path.join(RUNS, f"{prefix}-{family}", "records.jsonl")
    out = OrderedDict()
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            if line.strip():
                row = json.loads(line)
                out[tuple(row[k] for k in KEY)] = row
    return list(out.values())


def artifact(r):
    with open(r["artifact"], encoding="utf-8") as fh:
        return json.load(fh)


def order(r):
    return (MODELS.index(r["model"]) if r["model"] in MODELS else 9, r["run"])


def verdict(r):
    v = r["verdict"]
    return f"r={v['reached']} s={v['succeeded']} p={v['task_pass']} class={v['class']}"


def head(text, n=90):
    t = " ".join(str(text or "").split())
    return t[:n] + ("…" if len(t) > n else "")


def rows_of(art, name):
    return [t for t in art["tasks"] if t.get("tool_name") == name]


def normalise(text):
    return re.sub(r"/var/folders/\S+?/projects/\S+", "<ROOT>", text)


# ---- 1. task-background-suite ------------------------------------------------------------------------
print("## 1. task-background-suite\n")
print("### the cell over versions (reached / succeeded / green of 3; last line per key)\n")
print("| model | " + " | ".join(VERSIONS) + " |")
print("|---|" + "---|" * len(VERSIONS))
hist = {}
for ver, prefix in VERSIONS.items():
    try:
        rows = [r for r in load(prefix, "task") if r["task"] == "task-background-suite" and r.get("style", "nexus") == "nexus"]
    except FileNotFoundError:
        rows = []
    for m in MODELS:
        rs = [r for r in rows if r["model"] == m]
        hist[(ver, m)] = (sum(1 for r in rs if r["verdict"]["reached"]), sum(1 for r in rs if r["verdict"]["succeeded"]),
                          sum(1 for r in rs if r["verdict"]["class"] is None), len(rs))
for m in MODELS:
    print(f"| {short(m)} | " + " | ".join(
        "r{} s{} g{} /{}".format(*hist[(v, m)]) if hist[(v, m)][3] else "—" for v in VERSIONS) + " |")
for ver in VERSIONS:
    tot = [sum(hist[(ver, m)][i] for m in MODELS) for i in range(4)]
    fl = [sum(hist[(ver, m)][i] for m in MODELS[2:]) for i in range(4)]
    print(f"- {ver}: all r{tot[0]} s{tot[1]} g{tot[2]} of {tot[3]}; floor r{fl[0]} s{fl[1]} g{fl[2]} of {fl[3]}")

print("\n### per run, v13 and v14\n")
for ver in ("v13", "v14"):
    for r in sorted((r for r in load(VERSIONS[ver], "task") if r["task"] == "task-background-suite"), key=order):
        art = artifact(r)
        tasks = rows_of(art, "task")
        sps = rows_of(art, "start_process")
        f = r["facts"]
        print(f"- {ver} {short(r['model'])} #{r['run']}: {verdict(r)}; reason {head(r.get('reason'), 60)!r}; "
              f"task_calls {f.get('task_calls')}, suite_in_background {f.get('suite_in_background')}, reran_the_suite "
              f"{f.get('reran_the_suite')}")
        for t in tasks:
            inp = t.get("tool_input") or {}
            print(f"    - task {t['key']} after {t.get('after')} wait={inp.get('wait')} names `rails test`="
                  f"{'rails test' in (inp.get('prompt') or '')} :: {head(inp.get('prompt'), 110)}")
        for t in sps:
            inp = t.get("tool_input") or {}
            print(f"    - start_process {t['key']} after {t.get('after')} :: {head(inp.get('command'), 80)}")

print("\n### what the first request carries, v13 against v14, same model and run number\n")
for m in MODELS:
    a13 = artifact(next(r for r in load(VERSIONS["v13"], "task") if r["task"] == "task-background-suite" and r["model"] == m and r["run"] == 1))
    a14 = artifact(next(r for r in load(VERSIONS["v14"], "task") if r["task"] == "task-background-suite" and r["model"] == m and r["run"] == 1))
    e13 = [(e.get("role"), normalise("".join(p.get("text", "") for p in e.get("parts", [])))) for e in a13["sealed_request"]["entries"][:3]]
    e14 = [(e.get("role"), normalise("".join(p.get("text", "") for p in e.get("parts", [])))) for e in a14["sealed_request"]["entries"][:3]]
    t13 = {t["function"]["name"]: json.dumps(t, sort_keys=True) for t in a13["sealed_request"]["request_options"]["tools"]}
    t14 = {t["function"]["name"]: json.dumps(t, sort_keys=True) for t in a14["sealed_request"]["request_options"]["tools"]}
    diff = sorted(n for n in set(t13) | set(t14) if t13.get(n) != t14.get(n))
    print(f"- {short(m)}: system/developer/user identical after path normalisation: {[x == y for x, y in zip(e13, e14)]}; "
          f"tools {len(t13)} -> {len(t14)}; definitions that differ: {diff} "
          f"({', '.join(f'{n} {len(t13.get(n, ""))} -> {len(t14.get(n, ""))} bytes' for n in diff)})")

# ---- 2. workflow-barrier-free-pipeline ---------------------------------------------------------------
print("\n## 2. workflow-barrier-free-pipeline\n")
obj = open(os.path.join(REPO, "e2e/support/compose_bench/objectives.rb"), encoding="utf-8").read()
o7 = obj[obj.index('id: "O7", slug: "three-stage-pairing"'):]
o7 = o7[:o7.index("note:")]
print("O7's picture (objectives.rb): " + " ".join(o7[o7.index("picture:"):].split()))


def plan_line(step, depth=0):
    """One line per placed step off facts.score.steps: kind, key, command / stage marker, after/results."""
    out = []
    if isinstance(step, list):
        for s in step:
            out += plan_line(s, depth)
        return out
    if "parallel" in step:
        out.append("  " * depth + f"parallel{' until ' + step['until'] if step.get('until') else ''}:")
        for arm in step["parallel"]:
            out += plan_line(arm, depth + 1)
        return out
    for kind in ("tool", "model", "script"):
        if kind in step:
            s = step[kind]
            what = (head((s.get("input") or {}).get("command") or (s.get("input") or {}).get("path") or s.get("name"), 70)
                    if kind == "tool" else head(s.get("prompt") or s.get("script"), 50))
            extra = "".join(f" {k}={s[k]}" for k in ("after", "results") if s.get(k))
            out.append("  " * depth + f"{kind} {s.get('key')}{extra} :: {what}")
    return out


for ver in ("v13", "v14"):
    for r in sorted((r for r in load(VERSIONS[ver], "workflow") if r["task"] == "workflow-barrier-free-pipeline"), key=order):
        f = r["facts"]
        score = f.get("score") if isinstance(f.get("score"), dict) else {"silent": head(f.get("score"), 40)}
        print(f"- {ver} {short(r['model'])} #{r['run']}: {verdict(r)}; door {f.get('door')}; called {f.get('called')}; "
              f"silent {score.get('silent')}; usable_on_call {f.get('usable_on_call')}; picture "
              f"{'true' if f.get('picture') is True else head(f.get('picture'), 50)!r}")
        if short(r["model"]) == "glm-5.3" and score.get("steps"):
            for line in plan_line(score["steps"]):
                print("      " + line)

# ---- 3. the other moved cells -------------------------------------------------------------------------
print("\n## 3. workflow-adversarial-verify: door, fan, waits\n")
for ver in ("v13", "v14"):
    for r in sorted((r for r in load(VERSIONS[ver], "workflow") if r["task"] == "workflow-adversarial-verify"), key=order):
        art = artifact(r)
        f = r["facts"]
        waits = {name: dict(Counter(str((t.get("tool_input") or {}).get("wait")) for t in rows_of(art, name)))
                 for name in ("task", "spawn") if rows_of(art, name)}
        print(f"- {ver} {short(r['model'])} #{r['run']}: {verdict(r)}; door {f.get('door')}; waited {f.get('waited')}; "
              f"receipts {f.get('receipts')}; wait flags {waits}; read_before_dispatch {f.get('read_before_dispatch')}; "
              f"conduct {r.get('conduct')}")

print("\n## 3b. task-fan-five on v14 (driver settle_receipts): task rows by round\n")
for r in sorted((r for r in load(VERSIONS["v14"], "task") if r["task"] == "task-fan-five"), key=order):
    art = artifact(r)
    f = r["facts"]
    by_round = Counter(tuple(t.get("after") or []) for t in rows_of(art, "task"))
    print(f"- {short(r['model'])} #{r['run']}: {verdict(r)}; reason {head(r.get('reason'), 60)!r}; task rows by round "
          f"{dict((','.join(k), v) for k, v in by_round.items())}; merge_turn {f.get('merge_turn')}; waited {f.get('waited')}; "
          f"orphans_named {f.get('orphans_named')}; woken_loops {f.get('woken_loops')}")
    if (r.get("reason") or "").startswith("a second task"):
        for t in rows_of(art, "task"):
            print(f"      task {t['key']} after {t.get('after')} :: {head((t.get('tool_input') or {}).get('prompt'), 90)}")

# ---- 1b. the floor's background-suite runs: what they did instead, and how rare 0 of 6 is -------------
print("\n## 1b. task-background-suite on the floor, v14: the runs that launched the suite with start_process\n")
for r in sorted((r for r in load(VERSIONS["v14"], "task") if r["task"] == "task-background-suite"
                 and r["model"] in MODELS[2:]), key=order):
    art = artifact(r)
    f = r["facts"]
    called = f.get("called") or {}
    print(f"- {short(r['model'])} #{r['run']}: rounds_settled {f.get('rounds_settled')}; start_process {called.get('start_process')}, "
          f"read_process {called.get('read_process', 0)}, edit {called.get('edit', 0)}, bash {called.get('bash', 0)}; "
          f"seconds {r['seconds']}; reply: {head(f.get('reply'), 150)!r}")
pooled = [hist[(v, m)] for v in ("v10", "v11", "v13") for m in MODELS[2:]]
reached, runs = sum(x[0] for x in pooled), sum(x[3] for x in pooled)
p = reached / runs
print(f"\n- the floor's reach on this cell over v10, v11, v13 pooled: {reached}/{runs} = {p:.3f}; P(0 of 6 | p) = "
      f"{(1 - p) ** 6:.4f}; P(0 of 6 | p = 0.5) = {0.5 ** 6:.4f}")

# ---- 3c. task-fan-five's 'a second task' reds: which file each task was given -------------------------
print("\n## 3c. task-fan-five glm-5.3-flash, v14: the file each task prompt assigns, and every file it names\n")
for r in sorted((r for r in load(VERSIONS["v14"], "task") if r["task"] == "task-fan-five"
                 and (r.get("reason") or "").startswith("a second task")), key=order):
    art = artifact(r)
    for t in rows_of(art, "task"):
        prompt = (t.get("tool_input") or {}).get("prompt") or ""
        assigned = re.findall(r"(?:ONLY|single file|Review) (?:the single file )?(lib/[a-e]\.rb)", prompt)
        named = [f for f in "abcde" if f"{f}.rb" in prompt]
        print(f"- #{r['run']} {t['key']}: assigned {assigned[:1]}; names {named}")
    print(f"  per_file fact {r['facts'].get('per_file')}; orphans_named {r['facts'].get('orphans_named')}; merge_turn "
          f"{r['facts'].get('merge_turn')}")

# ---- 3d. compose-race-anon glm-5.3 #1: the no_wrong_winner red, and the PROBED substitution --------
print("\n## 3d. compose-race-anon, v14: every no_wrong_winner red, the sentence before and after RaceWinner's PROBED gsub\n")
src = open(os.path.join(REPO, "e2e/support/evals/claims/race_winner.rb"), encoding="utf-8").read()
print("race_winner.rb PROBED: " + re.search(r"PROBED = (.*)", src).group(1).strip())
probed = re.compile(r"bin/probe\s+(?:alpha|bravo|charlie)\b", re.I)
for r in sorted((r for r in load(VERSIONS["v14"], "compose") if r["task"] in ("compose-race", "compose-race-anon")
                 and (r.get("conduct") or {}).get("no_wrong_winner") is False), key=order):
    reply = r["facts"].get("reply") or ""
    sent = next(s for s in re.split(r"(?<=[.!?])\s+", reply) if "first to respond" in s or "won" in s.lower())
    print(f"- {r['task']} {short(r['model'])} #{r['run']}: conduct_reasons {r.get('conduct_reasons')}")
    print(f"    reply sentence:       {head(sent, 220)!r}")
    print(f"    after the PROBED gsub: {head(probed.sub('bin/probe', sent), 220)!r}")
    print(f"    reply's first line naming a winner: {head(next(l for l in reply.splitlines() if 'won' in l.lower()), 80)!r}")

# ---- 3e. the three v14 deadline stops: where the 600 s went --------------------------------------------
print("\n## 3e. the v14 deadline stops: the model rounds' own times, and the stream at the stop\n")
from datetime import datetime


def ts(x):
    return datetime.strptime(x, "%Y-%m-%dT%H:%M:%SZ") if x else None


for r in sorted((r for r in load(VERSIONS["v14"], "compose") if r.get("stopped")), key=lambda r: (r["task"], order(r))):
    art = artifact(r)
    f = r["facts"]
    rounds = [t for t in art["tasks"] if t["kind"] == "model_task" and "-" not in t["key"]]
    end = max(ts(t["completed_at"]) for t in art["tasks"] if t.get("completed_at"))
    longest = sorted(((ts(t.get("completed_at")) or end) - ts(t["started_at"]), t["key"], t["status"])
                     for t in rounds if t.get("started_at"))[-2:]
    print(f"- {r['task']} {short(r['model'])} #{r['run']}: {verdict(r)}; seconds {r['seconds']}; usable_on_call "
          f"{f.get('usable_on_call')}; rounds_settled {f.get('rounds_settled')}; spine model rounds {len(rounds)}; the two "
          f"longest {[(k, int(d.total_seconds()), s) for d, k, s in longest]}; in_flight {{task_key: "
          f"{(f.get('in_flight') or {}).get('task_key')}, frames: {(f.get('in_flight') or {}).get('frames')}, last_frame_age_s: "
          f"{(f.get('in_flight') or {}).get('last_frame_age_s')}}}; cost {r['efficiency'].get('cost_amount')}")

# ---- 3f. `spawn` in place of `task`: every record that called spawn, v13 and v14 -----------------------
print("\n## 3f. every record that called `spawn`, v13 and v14 (last line per key)\n")
for ver in ("v13", "v14"):
    hits = [(r["family"], r["task"], short(r["model"]), r["run"], (r["facts"].get("called") or {}).get("spawn"),
             (r["facts"].get("called") or {}).get("task", 0), r["verdict"].get("reached"), r["verdict"].get("task_pass"),
             r["verdict"].get("class"))
            for fam in ("task", "compose", "workflow") for r in load(VERSIONS[ver], fam)
            if (r["facts"].get("called") or {}).get("spawn")]
    print(f"- {ver}: {len(hits)} records")
    for h in hits:
        print(f"    - {h[0]} {h[1]} {h[2]} #{h[3]}: spawn {h[4]}, task {h[5]}; reached {h[6]}; task_pass {h[7]}; class {h[8]}")
```

#### A2_evidence.py output

~~~text
## 1. task-background-suite

### the cell over versions (reached / succeeded / green of 3; last line per key)

| model | v10 | v11 | v13 | v14 |
|---|---|---|---|---|
| glm-5.3 | r2 s1 g1 /3 | r3 s1 g1 /3 | r3 s3 g3 /3 | r3 s2 g2 /3 |
| kimi-k3 | r3 s3 g3 /3 | r3 s2 g1 /3 | r2 s2 g0 /3 | r3 s3 g1 /3 |
| deepseek-flash | r0 s0 g0 /3 | r2 s2 g2 /3 | r1 s1 g1 /3 | r0 s0 g0 /3 |
| glm-5.3-flash | r2 s1 g1 /3 | r1 s1 g1 /3 | r2 s2 g2 /3 | r0 s0 g0 /3 |
- v10: all r7 s5 g5 of 12; floor r2 s1 g1 of 6
- v11: all r9 s6 g5 of 12; floor r3 s3 g3 of 6
- v13: all r8 s8 g6 of 12; floor r3 s3 g3 of 6
- v14: all r6 s5 g3 of 12; floor r0 s0 g0 of 6

### per run, v13 and v14

- v13 glm-5.3 #1: r=True s=True p=None class=None; reason ''; task_calls 1, suite_in_background True, reran_the_suite None
    - task r2t1 after ['r1'] wait=None names `rails test`=True :: Run the whole test suite of the Rails project in this directory (the runner root is the project root: /var/fol…
- v13 glm-5.3 #2: r=True s=True p=None class=None; reason ''; task_calls 1, suite_in_background True, reran_the_suite None
    - task r2t1 after ['r1'] wait=None names `rails test`=True :: In this repository, run the whole Rails test suite with the command `bin/rails test`. It may take a long time …
- v13 glm-5.3 #3: r=True s=True p=None class=None; reason ''; task_calls 1, suite_in_background True, reran_the_suite None
    - task r2t1 after ['r1'] wait=None names `rails test`=True :: In this repository, run the entire test suite with `bin/rails test` (from the repository root). It may take a …
- v13 kimi-k3 #1: r=True s=True p=None class=cache under floor; reason ''; task_calls 1, suite_in_background True, reran_the_suite None
    - task r2t0 after ['r1'] wait=None names `rails test`=True :: In the current project root, run the full Rails test suite with `bin/rails test`. It may take a long time — us…
- v13 kimi-k3 #2: r=False s=None p=None class=model conduct; reason 'no `task` call: the model called {"start_process" => 2, "bas…'; task_calls 0, suite_in_background False, reran_the_suite None
    - start_process r2t0 after ['r1'] :: bin/rails test
    - start_process r12t0 after ['r11'] :: bin/rails test
- v13 kimi-k3 #3: r=True s=True p=None class=cache under floor; reason ''; task_calls 1, suite_in_background True, reran_the_suite None
    - task r2t0 after ['r1'] wait=None names `rails test`=True :: Run the full Rails test suite by executing `bin/rails test` in the project directory (the current working dire…
- v13 deepseek-flash #1: r=False s=None p=None class=model conduct; reason 'no `task` call: the model called {"bash" => 8, "start_proces…'; task_calls 0, suite_in_background False, reran_the_suite None
    - start_process r3t1 after ['r2'] :: bin/rails test
- v13 deepseek-flash #2: r=False s=None p=None class=model conduct; reason 'no `task` call: the model called {"bash" => 7, "read" => 1, …'; task_calls 0, suite_in_background False, reran_the_suite None
    - start_process r4t1 after ['r3'] :: bin/rails test
- v13 deepseek-flash #3: r=True s=True p=None class=None; reason ''; task_calls 1, suite_in_background True, reran_the_suite None
    - task r2t0 after ['r1'] wait=None names `rails test`=True :: In the Rails project at /var/folders/_6/7vgpkxd14klg0lpvxyh5nk2h0000gn/T/rho-evals-e2e20260925-64655-ilogtr/pr…
- v13 glm-5.3-flash #1: r=True s=True p=None class=None; reason ''; task_calls 1, suite_in_background True, reran_the_suite None
    - task r2t0 after ['r1'] wait=None names `rails test`=True :: In this project directory, run `bin/rails test` (the whole test suite; it may take a long time). Do NOT try to…
- v13 glm-5.3-flash #2: r=False s=None p=None class=model conduct; reason 'no `task` call: the model called {"todo_write" => 3, "ls" =>…'; task_calls 0, suite_in_background False, reran_the_suite None
    - start_process r6t0 after ['r5'] :: bin/rails test
- v13 glm-5.3-flash #3: r=True s=True p=None class=None; reason ''; task_calls 1, suite_in_background True, reran_the_suite None
    - task r5t0 after ['r4'] wait=False names `rails test`=True :: In the repository at /var/folders/_6/7vgpkxd14klg0lpvxyh5nk2h0000gn/T/rho-evals-e2e20260925-64655-ilogtr/proje…
- v14 glm-5.3 #1: r=True s=False p=None class=model conduct; reason 'the suite was handed to 2 tasks'; task_calls 2, suite_in_background True, reran_the_suite None
    - task r2t0 after ['r1'] wait=None names `rails test`=True :: Run this Rails project's whole test suite with `bin/rails test` from the repository root. It takes a long time…
    - task r15t0 after ['r14'] wait=None names `rails test`=True :: Run this Rails project's whole test suite with `bin/rails test` from the repository root. It takes a long time…
- v14 glm-5.3 #2: r=True s=True p=None class=None; reason ''; task_calls 1, suite_in_background True, reran_the_suite None
    - task r2t0 after ['r1'] wait=False names `rails test`=True :: Run the whole Rails test suite with `bin/rails test` in the current repository working directory (run it from …
- v14 glm-5.3 #3: r=True s=True p=None class=None; reason ''; task_calls 1, suite_in_background True, reran_the_suite None
    - task r2t1 after ['r1'] wait=None names `rails test`=True :: The working directory is a Rails project. Run the ENTIRE test suite with `bin/rails test`. It takes a long tim…
- v14 kimi-k3 #1: r=True s=True p=None class=cache under floor; reason ''; task_calls 1, suite_in_background True, reran_the_suite None
    - task r2t0 after ['r1'] wait=None names `rails test`=True :: In the directory /var/folders/_6/7vgpkxd14klg0lpvxyh5nk2h0000gn/T/rho-evals-e2e20260926-99193-dhzeqq/projects/…
- v14 kimi-k3 #2: r=True s=True p=None class=cache under floor; reason ''; task_calls 1, suite_in_background True, reran_the_suite None
    - task r2t0 after ['r1'] wait=None names `rails test`=True :: In the project at /var/folders/_6/7vgpkxd14klg0lpvxyh5nk2h0000gn/T/rho-evals-e2e20260926-99193-dhzeqq/projects…
- v14 kimi-k3 #3: r=True s=True p=None class=None; reason ''; task_calls 1, suite_in_background True, reran_the_suite None
    - task r2t0 after ['r1'] wait=None names `rails test`=True :: In the Rails project at the current working directory, run the full test suite with `bin/rails test`. It takes…
- v14 deepseek-flash #1: r=False s=None p=None class=model conduct; reason 'no `task` call: the model called {"start_process" => 1, "bas…'; task_calls 0, suite_in_background False, reran_the_suite None
    - start_process r2t0 after ['r1'] :: bin/rails test
- v14 deepseek-flash #2: r=False s=None p=None class=model conduct; reason 'no `task` call: the model called {"start_process" => 1, "bas…'; task_calls 0, suite_in_background False, reran_the_suite None
    - start_process r2t0 after ['r1'] :: bin/rails test 2>&1
- v14 deepseek-flash #3: r=False s=None p=None class=model conduct; reason 'no `task` call: the model called {"ls" => 1, "bash" => 6, "r…'; task_calls 0, suite_in_background False, reran_the_suite None
    - start_process r4t1 after ['r3'] :: bin/rails test
- v14 glm-5.3-flash #1: r=False s=None p=None class=model conduct; reason 'no `task` call: the model called {"start_process" => 1, "bas…'; task_calls 0, suite_in_background False, reran_the_suite None
    - start_process r2t0 after ['r1'] :: bin/rails test
- v14 glm-5.3-flash #2: r=False s=None p=None class=model conduct; reason 'no `task` call: the model called {"todo_write" => 4, "ls" =>…'; task_calls 0, suite_in_background False, reran_the_suite None
    - start_process r2t2 after ['r1'] :: bin/rails test
    - start_process r58t1 after ['r57'] :: bin/rails test
- v14 glm-5.3-flash #3: r=False s=None p=None class=model conduct; reason 'no `task` call: the model called {"todo_write" => 2, "bash" …'; task_calls 0, suite_in_background False, reran_the_suite None
    - start_process r4t0 after ['r3'] :: bin/rails test

### what the first request carries, v13 against v14, same model and run number

- glm-5.3: system/developer/user identical after path normalisation: [True, True, True]; tools 25 -> 25; definitions that differ: ['compose'] (compose 9258 -> 9391 bytes)
- kimi-k3: system/developer/user identical after path normalisation: [True, True, True]; tools 25 -> 25; definitions that differ: ['compose'] (compose 9258 -> 9391 bytes)
- deepseek-flash: system/developer/user identical after path normalisation: [True, True, True]; tools 25 -> 25; definitions that differ: ['compose'] (compose 9258 -> 9391 bytes)
- glm-5.3-flash: system/developer/user identical after path normalisation: [True, True, True]; tools 25 -> 25; definitions that differ: ['compose'] (compose 9258 -> 9391 bytes)

## 2. workflow-barrier-free-pipeline

O7's picture (objectives.rb): picture: Picture.new( nodes: { "a" => "tool", "b" => "tool", "c" => "tool", "na" => "model|tool|script", "nb" => "model|tool|script", "nc" => "model|tool|script", "merge" => "model|script" }, edges: [%w[a na], %w[b nb], %w[c nc], %w[na merge], %w[nb merge], %w[nc merge]], reads: { "na" => %w[a], "nb" => %w[b], "nc" => %w[c], "merge" => %w[na nb nc] }, computes: %w[na nb nc] ),
- v13 glm-5.3 #1: r=False s=None p=True class=model conduct; door None; called {'ls': 1, 'read': 1, 'todo_write': 3, 'bash': 4}; silent no compose call to score; usable_on_call None; picture 'no compose call to score'
- v13 glm-5.3 #2: r=True s=False p=True class=disagreement; door compose; called {'ls': 1, 'bash': 8, 'compose': 1}; silent ['edit_as_tool']; usable_on_call 1; picture "the picture is not the objective's (silent: edit_a…"
      script script-1 :: const fa = g.tool({name: 'bash', input: {command: …
- v13 glm-5.3 #3: r=True s=True p=True class=cache under floor; door compose; called {'ls': 1, 'read': 2, 'find': 1, 'compose': 1, 'bash': 3, 'write': 1}; silent []; usable_on_call 1; picture 'true'
      parallel:
        tool tool-1 :: sh bin/fetch a
        script script-1 results=['tool-1'] :: const r = results[0]; if (!r || r.is_error || (r.s…
        tool tool-2 :: sh bin/fetch b
        script script-2 results=['tool-2'] :: const r = results[0]; if (!r || r.is_error || (r.s…
        tool tool-3 :: sh bin/fetch c
        script script-3 results=['tool-3'] :: const r = results[0]; if (!r || r.is_error || (r.s…
      script script-4 results=['script-1', 'script-2', 'script-3'] :: const names = ['a', 'b', 'c']; const records = [];…
- v13 kimi-k3 #1: r=False s=None p=True class=model conduct; door None; called {'ls': 1, 'read': 1, 'bash': 1}; silent no compose call to score; usable_on_call None; picture 'no compose call to score'
- v13 kimi-k3 #2: r=False s=None p=True class=model conduct; door None; called {'ls': 1, 'bash': 5}; silent no compose call to score; usable_on_call None; picture 'no compose call to score'
- v13 kimi-k3 #3: r=False s=None p=True class=model conduct; door None; called {'ls': 1, 'read': 1, 'bash': 1}; silent no compose call to score; usable_on_call None; picture 'no compose call to score'
- v13 deepseek-flash #1: r=False s=None p=True class=model conduct; door None; called {'bash': 2, 'ls': 1}; silent no compose call to score; usable_on_call None; picture 'no compose call to score'
- v13 deepseek-flash #2: r=False s=None p=True class=model conduct; door None; called {'bash': 4, 'write': 2}; silent no compose call to score; usable_on_call None; picture 'no compose call to score'
- v13 deepseek-flash #3: r=True s=True p=True class=None; door compose; called {'ls': 1, 'find': 1, 'read': 1, 'write': 1, 'todo_write': 2, 'bash': 9, 'compose': 1}; silent ['edit_as_tool']; usable_on_call 1; picture "the picture is not the objective's (silent: edit_a…"
- v13 glm-5.3-flash #1: r=True s=True p=True class=None; door compose; called {'ls': 1, 'read': 2, 'grep': 1, 'todo_write': 2, 'compose': 1, 'bash': 7}; silent ['edit_as_tool']; usable_on_call 1; picture "the picture is not the objective's (silent: edit_a…"
- v13 glm-5.3-flash #2: r=False s=None p=True class=model conduct; door None; called {'ls': 1, 'find': 1, 'read': 1, 'bash': 1}; silent no compose call to score; usable_on_call None; picture 'no compose call to score'
- v13 glm-5.3-flash #3: r=True s=True p=True class=None; door compose; called {'ls': 1, 'read': 1, 'write': 1, 'compose': 1, 'bash': 7}; silent ['edit_as_tool']; usable_on_call 1; picture "the picture is not the objective's (silent: edit_a…"
- v14 glm-5.3 #1: r=True s=False p=True class=disagreement; door compose; called {'ls': 1, 'find': 1, 'read': 1, 'compose': 1, 'bash': 7}; silent ['edit_as_tool']; usable_on_call 1; picture "the picture is not the objective's (silent: edit_a…"
      parallel:
        tool tool-1 :: sh bin/fetch a > raw_a.txt
        tool tool-2 after=['tool-1'] :: awk -F'|' '{print "source=" $1 " date=" $2 " value=" $3}' raw_a.txt > …
        tool tool-3 :: sh bin/fetch b > raw_b.txt
        tool tool-4 after=['tool-3'] :: awk -F'|' '{print "source=" $1 " date=" $2 " value=" $3}' raw_b.txt > …
        tool tool-5 :: sh bin/fetch c > raw_c.txt
        tool tool-6 after=['tool-5'] :: awk -F'|' '{print "source=" $1 " date=" $2 " value=" $3}' raw_c.txt > …
      tool tool-7 after=['tool-2', 'tool-4', 'tool-6'] :: cat rec_a.txt rec_b.txt rec_c.txt > merged.txt && cat merged.txt
- v14 glm-5.3 #2: r=True s=False p=True class=disagreement; door compose; called {'ls': 1, 'read': 3, 'compose': 1, 'bash': 5, 'write': 3}; silent ['edit_as_tool']; usable_on_call 1; picture "the picture is not the objective's (silent: edit_a…"
      parallel:
        tool tool-1 :: sh bin/fetch a
        script script-1 results=['tool-1'] :: const r = results[0]; if (r.status !== 'completed'…
        tool tool-2 :: sh bin/fetch b
        script script-2 results=['tool-2'] :: const r = results[0]; if (r.status !== 'completed'…
        tool tool-3 :: sh bin/fetch c
        script script-3 results=['tool-3'] :: const r = results[0]; if (r.status !== 'completed'…
      tool tool-4 :: echo "$(cat normalised/a.txt)" > merged.txt && echo "$(cat normalised/…
- v14 glm-5.3 #3: r=True s=False p=True class=disagreement; door compose; called {'ls': 1, 'read': 1, 'write': 1, 'bash': 10, 'compose': 1}; silent ['edit_as_tool']; usable_on_call 1; picture "the picture is not the objective's (silent: edit_a…"
      parallel until all:
        tool tool-1 :: sh bin/fetch a > raw/a.raw
        tool tool-4 :: sh bin/normalise raw/a.raw rec/a.rec
        tool tool-2 :: sh bin/fetch b > raw/b.raw
        tool tool-5 :: sh bin/normalise raw/b.raw rec/b.rec
        tool tool-3 :: sh bin/fetch c > raw/c.raw
        tool tool-6 :: sh bin/normalise raw/c.raw rec/c.rec
      tool tool-7 :: cat rec/a.rec rec/b.rec rec/c.rec > merged.txt && cat merged.txt
- v14 kimi-k3 #1: r=False s=None p=True class=model conduct; door None; called {'ls': 1, 'read': 1, 'bash': 1}; silent no compose call to score; usable_on_call None; picture 'no compose call to score'
- v14 kimi-k3 #2: r=False s=None p=True class=model conduct; door None; called {'ls': 1, 'bash': 2}; silent no compose call to score; usable_on_call None; picture 'no compose call to score'
- v14 kimi-k3 #3: r=False s=None p=True class=model conduct; door None; called {'ls': 1, 'bash': 2}; silent no compose call to score; usable_on_call None; picture 'no compose call to score'
- v14 deepseek-flash #1: r=False s=None p=True class=model conduct; door None; called {'ls': 1, 'bash': 3}; silent no compose call to score; usable_on_call None; picture 'no compose call to score'
- v14 deepseek-flash #2: r=False s=None p=True class=model conduct; door None; called {'ls': 1, 'bash': 3, 'write': 1}; silent no compose call to score; usable_on_call None; picture 'no compose call to score'
- v14 deepseek-flash #3: r=False s=None p=True class=model conduct; door None; called {'ls': 1, 'bash': 2}; silent no compose call to score; usable_on_call None; picture 'no compose call to score'
- v14 glm-5.3-flash #1: r=False s=None p=True class=model conduct; door None; called {'bash': 2}; silent no compose call to score; usable_on_call None; picture 'no compose call to score'
- v14 glm-5.3-flash #2: r=True s=True p=True class=None; door compose; called {'ls': 1, 'read': 1, 'compose': 1, 'bash': 7}; silent ['edit_as_tool']; usable_on_call 1; picture "the picture is not the objective's (silent: edit_a…"
- v14 glm-5.3-flash #3: r=True s=True p=True class=None; door compose; called {'ls': 1, 'read': 1, 'grep': 1, 'memory_ls': 1, 'todo_write': 2, 'compose': 1, 'bash': 7}; silent ['edit_as_tool']; usable_on_call 1; picture "the picture is not the objective's (silent: edit_a…"

## 3. workflow-adversarial-verify: door, fan, waits

- v13 glm-5.3 #1: r=True s=True p=True class=cache under floor; door task_fan; waited False; receipts 12; wait flags {'task': {'None': 12}}; read_before_dispatch 0; conduct {'did_not_judge_itself': True}
- v13 glm-5.3 #2: r=True s=False p=True class=disagreement; door task_fan; waited True; receipts 0; wait flags {'task': {'True': 12}}; read_before_dispatch 0; conduct {'did_not_judge_itself': True}
- v13 glm-5.3 #3: r=True s=False p=True class=disagreement; door task_fan; waited True; receipts 0; wait flags {'task': {'True': 12}}; read_before_dispatch 3; conduct {'did_not_judge_itself': True}
- v13 kimi-k3 #1: r=True s=False p=False class=model conduct; door task_fan; waited True; receipts 0; wait flags {'task': {'True': 12}}; read_before_dispatch 0; conduct {'did_not_judge_itself': True}
- v13 kimi-k3 #2: r=True s=True p=True class=cache under floor; door task_fan; waited False; receipts 12; wait flags {'task': {'None': 12}}; read_before_dispatch 0; conduct {'did_not_judge_itself': True}
- v13 kimi-k3 #3: r=True s=False p=False class=model conduct; door task_fan; waited True; receipts 0; wait flags {'task': {'True': 13}}; read_before_dispatch 0; conduct {'did_not_judge_itself': True}
- v13 deepseek-flash #1: r=True s=True p=True class=None; door task_fan; waited False; receipts 13; wait flags {'task': {'None': 13}}; read_before_dispatch 3; conduct {'did_not_judge_itself': True}
- v13 deepseek-flash #2: r=True s=True p=True class=None; door task_fan; waited False; receipts 12; wait flags {'task': {'None': 12}}; read_before_dispatch 3; conduct {'did_not_judge_itself': True}
- v13 deepseek-flash #3: r=True s=True p=True class=None; door task_fan; waited False; receipts 12; wait flags {'task': {'None': 12}}; read_before_dispatch 3; conduct {'did_not_judge_itself': True}
- v13 glm-5.3-flash #1: r=True s=True p=True class=None; door task_fan; waited False; receipts 12; wait flags {'task': {'None': 12}}; read_before_dispatch 3; conduct {'did_not_judge_itself': True}
- v13 glm-5.3-flash #2: r=True s=False p=True class=disagreement; door task_fan; waited True; receipts 0; wait flags {'task': {'True': 12}}; read_before_dispatch 3; conduct {'did_not_judge_itself': True}
- v13 glm-5.3-flash #3: r=True s=True p=True class=None; door task_fan; waited False; receipts 12; wait flags {'task': {'None': 12}}; read_before_dispatch 0; conduct {'did_not_judge_itself': True}
- v14 glm-5.3 #1: r=True s=True p=True class=None; door task_fan; waited False; receipts 12; wait flags {'task': {'None': 12}}; read_before_dispatch 0; conduct {'did_not_judge_itself': True}
- v14 glm-5.3 #2: r=True s=True p=True class=cache under floor; door task_fan; waited False; receipts 12; wait flags {'task': {'None': 12}}; read_before_dispatch 3; conduct {'did_not_judge_itself': True}
- v14 glm-5.3 #3: r=True s=True p=True class=None; door task_fan; waited False; receipts 12; wait flags {'task': {'None': 12}}; read_before_dispatch 0; conduct {'did_not_judge_itself': True}
- v14 kimi-k3 #1: r=True s=True p=True class=cache under floor; door task_fan; waited False; receipts 12; wait flags {'task': {'None': 12}}; read_before_dispatch 0; conduct {'did_not_judge_itself': True}
- v14 kimi-k3 #2: r=True s=False p=True class=disagreement; door task_fan; waited True; receipts 0; wait flags {'task': {'True': 12}}; read_before_dispatch 0; conduct {'did_not_judge_itself': True}
- v14 kimi-k3 #3: r=True s=True p=True class=cache under floor; door task_fan; waited False; receipts 12; wait flags {'task': {'None': 12}}; read_before_dispatch 0; conduct {'did_not_judge_itself': True}
- v14 deepseek-flash #1: r=True s=False p=True class=disagreement; door task_fan; waited True; receipts 0; wait flags {'task': {'True': 13}}; read_before_dispatch 3; conduct {'did_not_judge_itself': True}
- v14 deepseek-flash #2: r=False s=None p=True class=model conduct; door None; waited False; receipts 0; wait flags {'spawn': {'True': 12}}; read_before_dispatch 0; conduct {'did_not_judge_itself': True}
- v14 deepseek-flash #3: r=False s=None p=False class=model conduct; door None; waited False; receipts 4; wait flags {'spawn': {'None': 12}}; read_before_dispatch 0; conduct {'did_not_judge_itself': False}
- v14 glm-5.3-flash #1: r=True s=True p=True class=None; door task_fan; waited False; receipts 12; wait flags {'task': {'None': 12}}; read_before_dispatch 0; conduct {'did_not_judge_itself': True}
- v14 glm-5.3-flash #2: r=True s=False p=True class=disagreement; door task_fan; waited True; receipts 0; wait flags {'task': {'True': 12}}; read_before_dispatch 0; conduct {'did_not_judge_itself': True}
- v14 glm-5.3-flash #3: r=True s=False p=True class=disagreement; door task_fan; waited True; receipts 0; wait flags {'task': {'True': 12}}; read_before_dispatch 3; conduct {'did_not_judge_itself': True}

## 3b. task-fan-five on v14 (driver settle_receipts): task rows by round

- glm-5.3 #1: r=True s=True p=None class=cache under floor; reason ''; task rows by round {'r1': 5}; merge_turn primary; waited True; orphans_named 5; woken_loops []
- glm-5.3 #2: r=True s=True p=None class=None; reason ''; task rows by round {'r1': 5}; merge_turn primary; waited True; orphans_named 5; woken_loops []
- glm-5.3 #3: r=True s=True p=None class=cache under floor; reason ''; task rows by round {'r1': 5}; merge_turn primary; waited True; orphans_named 5; woken_loops []
- kimi-k3 #1: r=True s=True p=None class=None; reason ''; task rows by round {'r1': 5}; merge_turn primary; waited True; orphans_named 5; woken_loops []
- kimi-k3 #2: r=True s=True p=None class=None; reason ''; task rows by round {'r1': 5}; merge_turn primary; waited True; orphans_named 5; woken_loops []
- kimi-k3 #3: r=True s=True p=None class=None; reason ''; task rows by round {'r1': 5}; merge_turn primary; waited True; orphans_named 5; woken_loops []
- deepseek-flash #1: r=False s=None p=None class=model conduct; reason '0 task call(s) in the first message, not five: {"read" => 5}'; task rows by round {'r2': 5}; merge_turn primary; waited True; orphans_named 5; woken_loops []
- deepseek-flash #2: r=True s=True p=None class=None; reason ''; task rows by round {'r1': 5}; merge_turn woken-1; waited False; orphans_named 5; woken_loops ['01a0d986-d0b5-7064-8a66-09db98a74da7', '01a0d987-0f95-7066-a8eb-99141ec91e7d', '01a0d987-19fa-7ad1-ba44-e3bd6897cb0f', '01a0d987-214b-7234-aa8b-e5773554b20e', '01a0d987-32ef-73bd-ab53-fc5c0dbf8e5d']
- deepseek-flash #3: r=True s=True p=None class=None; reason ''; task rows by round {'r1': 5}; merge_turn primary; waited False; orphans_named 5; woken_loops []
- glm-5.3-flash #1: r=True s=False p=None class=model conduct; reason 'a second task for a.rb, b.rb, c.rb, d.rb, e.rb'; task rows by round {'r1': 5}; merge_turn primary; waited False; orphans_named 5; woken_loops []
      task r2t0 after ['r1'] :: In this repo there is a directory lib/ containing several Ruby files (lib/a.rb, lib/b.rb, …
      task r2t1 after ['r1'] :: In this repo there is a directory lib/ containing several Ruby files (lib/a.rb, lib/b.rb, …
      task r2t2 after ['r1'] :: In this repo there is a directory lib/ containing several Ruby files (lib/a.rb, lib/b.rb, …
      task r2t3 after ['r1'] :: In this repo there is a directory lib/ containing several Ruby files (lib/a.rb, lib/b.rb, …
      task r2t4 after ['r1'] :: In this repo there is a directory lib/ containing several Ruby files (lib/a.rb, lib/b.rb, …
- glm-5.3-flash #2: r=True s=True p=None class=None; reason ''; task rows by round {'r1': 5}; merge_turn primary; waited True; orphans_named 5; woken_loops []
- glm-5.3-flash #3: r=True s=False p=None class=model conduct; reason 'a second task for a.rb, b.rb, c.rb, d.rb, e.rb'; task rows by round {'r1': 5}; merge_turn primary; waited True; orphans_named 5; woken_loops []
      task r2t1 after ['r1'] :: Review the single file lib/a.rb. Exactly one method defined in it is never called anywhere…
      task r2t2 after ['r1'] :: Review the single file lib/b.rb. Exactly one method defined in it is never called anywhere…
      task r2t3 after ['r1'] :: Review the single file lib/c.rb. Exactly one method defined in it is never called anywhere…
      task r2t4 after ['r1'] :: Review the single file lib/d.rb. Exactly one method defined in it is never called anywhere…
      task r2t5 after ['r1'] :: Review the single file lib/e.rb. Exactly one method defined in it is never called anywhere…

## 1b. task-background-suite on the floor, v14: the runs that launched the suite with start_process

- deepseek-flash #1: rounds_settled 13; start_process 1, read_process 2, edit 1, bash 10; seconds 75; reply: 'status: completed Done — both parts of your request are handled. **Test suite (background, not waited on)** Launched `bin/rails test` as a background …'
- deepseek-flash #2: rounds_settled 8; start_process 1, read_process 1, edit 0, bash 8; seconds 57; reply: 'status: completed Done with my part. **Test suite** — started in the background as `p2` (`bin/rails test`), still running, so nothing was blocked wait…'
- deepseek-flash #3: rounds_settled 10; start_process 1, read_process 2, edit 1, bash 6; seconds 87; reply: 'status: completed Both done. **Test suite** — launched in the background (process `p3`) so nothing was blocked on it. It finished on its own, exit sta…'
- glm-5.3-flash #1: rounds_settled 12; start_process 1, read_process 0, edit 2, bash 10; seconds 178; reply: "status: completed Both offences are fixed and verified. Here's the full picture: **1. Test suite (`bin/rails test`) — done, all green.** It was launch…"
- glm-5.3-flash #2: rounds_settled 61; start_process 2, read_process 1, edit 1, bash 54; seconds 652; reply: 'status: completed All done — and the background suite finished on its own, so nothing was left waiting. ## Test suite (`bin/rails test`) Ran it in the…'
- glm-5.3-flash #3: rounds_settled 14; start_process 1, read_process 2, edit 1, bash 8; seconds 113; reply: 'status: completed Both jobs are done. **Test suite** (`bin/rails test`, ran in the background the whole time — you never had to wait on it): ``` Run o…'

- the floor's reach on this cell over v10, v11, v13 pooled: 8/18 = 0.444; P(0 of 6 | p) = 0.0294; P(0 of 6 | p = 0.5) = 0.0156

## 3c. task-fan-five glm-5.3-flash, v14: the file each task prompt assigns, and every file it names

- #1 r2t0: assigned ['lib/a.rb']; names ['a', 'b', 'c', 'd', 'e']
- #1 r2t1: assigned ['lib/b.rb']; names ['a', 'b', 'c', 'd', 'e']
- #1 r2t2: assigned ['lib/c.rb']; names ['a', 'b', 'c', 'd', 'e']
- #1 r2t3: assigned ['lib/d.rb']; names ['a', 'b', 'c', 'd', 'e']
- #1 r2t4: assigned ['lib/e.rb']; names ['a', 'b', 'c', 'd', 'e']
  per_file fact {'a.rb': 5, 'b.rb': 5, 'c.rb': 5, 'd.rb': 5, 'e.rb': 5}; orphans_named 5; merge_turn primary
- #3 r2t1: assigned ['lib/a.rb']; names ['a', 'b', 'e']
- #3 r2t2: assigned ['lib/b.rb']; names ['a', 'b', 'c', 'e']
- #3 r2t3: assigned ['lib/c.rb']; names ['a', 'b', 'c', 'd', 'e']
- #3 r2t4: assigned ['lib/d.rb']; names ['a', 'b', 'c', 'd', 'e']
- #3 r2t5: assigned ['lib/e.rb']; names ['a', 'd', 'e']
  per_file fact {'a.rb': 5, 'b.rb': 4, 'c.rb': 3, 'd.rb': 3, 'e.rb': 5}; orphans_named 5; merge_turn primary

## 3d. compose-race-anon, v14: every no_wrong_winner red, the sentence before and after RaceWinner's PROBED gsub

race_winner.rb PROBED: %r{bin/probe\s+(?:alpha|bravo|charlie)\b}i
- compose-race-anon glm-5.3 #1: conduct_reasons {'no_wrong_winner': 'the reply ties alpha to `won`: "`bin/probe` was the first to respond (returned \\"200 OK\\" in 2 seconds), so the fan settled on it and stopped waiting on alpha and charlie."'}
    reply sentence:       'status: completed **bravo won.** The three probes ran at once as a race; `bin/probe bravo` was the first to respond (returned "200 OK" in 2 seconds), so the fan settled on it and stopped waiting on alpha and charlie.'
    after the PROBED gsub: 'status: completed **bravo won.** The three probes ran at once as a race; `bin/probe` was the first to respond (returned "200 OK" in 2 seconds), so the fan settled on it and stopped waiting on alpha and charlie.'
    reply's first line naming a winner: '**bravo won.**'

## 3e. the v14 deadline stops: the model rounds' own times, and the stream at the stop

- compose-background-suite glm-5.3 #1: r=True s=False p=None class=model conduct; seconds 610; usable_on_call 1; rounds_settled 3; spine model rounds 2; the two longest [('r2', 1, 'running'), ('r1', 601, 'completed')]; in_flight {task_key: r2, frames: 0, last_frame_age_s: None}; cost 0.14257425
- compose-grep-then-edit glm-5.3-flash #1: r=True s=True p=True class=model conduct; seconds 613; usable_on_call 1; rounds_settled 1; spine model rounds 2; the two longest [('r2', 0, 'running'), ('r1', 599, 'completed')]; in_flight {task_key: r2, frames: 405, last_frame_age_s: 4.8}; cost 0.0211537375
- compose-rendezvous glm-5.3-flash #2: r=True s=True p=None class=model conduct; seconds 651; usable_on_call 1; rounds_settled 29; spine model rounds 27; the two longest [('r5', 33, 'completed'), ('r1', 134, 'completed')]; in_flight {task_key: r27, frames: 1474, last_frame_age_s: 3.5}; cost 0.03307421

## 3f. every record that called `spawn`, v13 and v14 (last line per key)

- v13: 0 records
- v14: 3 records
    - workflow workflow-adversarial-verify deepseek-flash #2: spawn 12, task 0; reached False; task_pass True; class model conduct
    - workflow workflow-adversarial-verify deepseek-flash #3: spawn 12, task 0; reached False; task_pass False; class model conduct
    - workflow workflow-judge-panel deepseek-flash #3: spawn 4, task 0; reached False; task_pass True; class model conduct
~~~

### A3_cache.py

<!-- script:A3_cache.py -->
```python
#!/usr/bin/env python3
"""SECTION A, THE 'CACHE UNDER FLOOR' RECORDS: v14 against v13, and whose miss it is (read-only).

1. Every record classed `cache under floor` on v14 and on v13 (last line per key; v13's FIRST
   line beside it, since v13 was rescored in place), with the family's floor from bench.yml
   (limits.cache_floor_by_family), the rate after round 1 (Trace.after_first_round_rate: the
   spine's rounds 2..n of cache_read_series pooled), the measured rounds and the r1 rate.
2. For each v14 record, each measured spine round: its input, its cache read, the previous
   round's input, and which earlier round's full prompt (if any) the read equals within the
   wire's quantum (the read is a hit on that round's request when it does).
3. OUR PREFIX, read off the world log: each spine round's sealed request is rebuilt from the
   jobs log (the ScheduleJob that made the round's ModelInvocation writes a `request`
   ContentBody, its ordered content_body_entries -> content_fragment ids, and its byte_size),
   matched to the round by `request_bytes_series`. For each measured round: whether the
   previous round's entry list is a prefix of this round's (the tail-only growth a prefix cache
   needs), the common-prefix length in entries, and whether the ModelInvocation's
   request_options (the tool list the wire sends first) is byte-identical to the previous
   round's. A round is OUR prefix's miss when the previous request is not a prefix of it (or
   request_options changed); it is the PROVIDER's when our request extends the previous one and
   the provider still served less than the previous prompt.
"""
import hashlib
import json
import os
import re
from collections import Counter, OrderedDict, defaultdict

REPO = "/Users/jasl/Workspaces/cybros-ai.alt2"
RUNS = os.path.join(REPO, "e2e/evals/runs")
ART = os.path.join(REPO, "e2e/artifacts/evals")
LABELS = {"v14": [f"2026-09-26-v14-{f}" for f in ("task", "compose", "workflow")],
          "v13": [f"2026-09-25-v13-{f}" for f in ("task", "compose", "workflow")]}
KEY = ("task", "model", "style", "run")
MODELS = ["openrouter/z-ai/glm-5.3", "openrouter/moonshotai/kimi-k3",
          "deepseek/deepseek-flash", "openrouter/z-ai/glm-5.3-flash"]
ANSI = re.compile(r"\x1b\[[0-9;]*m")
JOB = re.compile(r"^\[ActiveJob\] \[([^\]]+)\] \[([0-9a-f-]{36})\]")


def short(model):
    return model.split("/")[-1]


def bench_floors():
    """limits.cache_floor_by_family and cache_floor_min_rounds, read off bench.yml as text."""
    text = open(os.path.join(REPO, "e2e/evals/bench.yml"), encoding="utf-8").read()
    block = text.split("cache_floor_by_family:", 1)[1].split("\n  #", 1)[0]
    floors = {m.group(1): float(m.group(2)) for m in re.finditer(r"^\s+(\w+): ([0-9.]+)$", block, re.M)}
    min_rounds = int(re.search(r"^\s+cache_floor_min_rounds: (\d+)$", text, re.M).group(1))
    exempt = re.search(r"cache_floor_exempt_models:\n((?:\s+- .*\n)+)", text).group(1)
    return floors, min_rounds, [x.strip()[2:] for x in exempt.strip().splitlines()]


def records(version, first=False):
    out = OrderedDict()
    for label in LABELS[version]:
        with open(os.path.join(RUNS, label, "records.jsonl"), encoding="utf-8") as fh:
            for line in fh:
                if line.strip():
                    row = json.loads(line)
                    k = tuple(row[x] for x in KEY)
                    if first and k in out:
                        continue
                    out[k] = row
    return list(out.values())


def after_r1(series):
    rest = list((series or {}).values())[1:]
    tokens = sum(int(t or 0) for t, _ in rest)
    return None if tokens == 0 else round(sum(int(c or 0) for _, c in rest) / tokens, 4)


def r1_rate(series):
    vals = list((series or {}).values())
    return None if not vals or not vals[0][0] else round(vals[0][1] / vals[0][0], 4)


def ideal(series):
    """The rate a provider that served every measured round its whole previous prompt would give:
    sum(prev input) / sum(input) over rounds 2..n -- the ceiling our own prefix growth sets."""
    vals = list((series or {}).values())
    if len(vals) < 2:
        return None
    return round(sum(vals[i - 1][0] for i in range(1, len(vals))) / sum(v[0] for v in vals[1:]), 4)


def short_served(series):
    """Measured rounds the provider served under 0.95 of the previous prompt, and of those the zeros."""
    vals = list((series or {}).values())
    low = [i for i in range(1, len(vals)) if vals[i - 1][0] and vals[i][1] < 0.95 * vals[i - 1][0]]
    return len(low), sum(1 for i in low if vals[i][1] == 0), len(vals) - 1


def order(r):
    return (r["family"], r["task"], MODELS.index(r["model"]), r["run"])


# ---- the world log: each request body's fragment list ---------------------------------------------

def sql_literal_after(text, start):
    """The single-quoted SQL literal starting at text[start] == "'"; returns its raw inner text."""
    assert text[start] == "'"
    i, out = start + 1, []
    while i < len(text):
        c = text[i]
        if c == "'":
            if i + 1 < len(text) and text[i + 1] == "'":
                out.append("'")
                i += 2
                continue
            return "".join(out)
        out.append(c)
        i += 1
    return "".join(out)


def request_bodies(log_path):
    """{body_id: {"mi": model_invocation_id, "entries": [fragment ids by position], "bytes": n, "opts": digest}}."""
    per_job = defaultdict(list)
    with open(log_path, encoding="utf-8", errors="replace") as fh:
        for raw in fh:
            if "INSERT INTO" not in raw and "UPDATE \"content_bodies\"" not in raw:
                continue
            line = ANSI.sub("", raw)
            m = JOB.match(line)
            if not m:
                continue
            per_job[m.group(2)].append(line)
    bodies = {}
    for job, lines in per_job.items():
        opts_digest, pending, last_opts = {}, None, None
        for line in lines:
            if 'INSERT INTO "model_invocations"' in line:
                pub = re.search(r"VALUES \(\d+, \d+, \d+, (?:NULL|\d+), '([0-9a-f-]{36})'", line)
                at = line.find("'{\"tools\":")
                digest = hashlib.sha256(sql_literal_after(line, at).encode()).hexdigest()[:12] if at >= 0 else None
                opts_digest[pub.group(1) if pub else None] = digest
                last_opts = digest
            elif 'INSERT INTO "content_bodies"' in line and "(1, 'request'," in line:
                mi = re.search(r"\(1, 'request', NULL, NULL, '[^']*', '[^']*', NULL, (\d+),", line)
                pending = {"mi": int(mi.group(1)) if mi else None, "entries": {}, "bytes": None,
                           "opts": last_opts}
            elif 'INSERT INTO "content_body_entries"' in line and pending is not None:
                rows = re.findall(r"\(1, (\d+), (\d+), (?:CURRENT_TIMESTAMP|'[^']*'), (\d+),", line)
                for body, frag, pos in rows:
                    b = bodies.setdefault(int(body), dict(pending, entries={}))
                    b["entries"][int(pos)] = int(frag)
            elif 'UPDATE "content_bodies"' in line:
                m2 = re.search(r'"byte_size" = (\d+) WHERE "content_bodies"."id" = (\d+)', line)
                if m2 and int(m2.group(2)) in bodies:
                    bodies[int(m2.group(2))]["bytes"] = int(m2.group(1))
    for b in bodies.values():
        b["entries"] = [b["entries"][p] for p in sorted(b["entries"])]
    return bodies


def common_prefix(a, b):
    n = 0
    for x, y in zip(a, b):
        if x != y:
            break
        n += 1
    return n


def prefix_read(record):
    """Per spine round: the body its request_bytes matched, and the prefix relation to the previous round."""
    stem = os.path.basename(record["artifact"])[:-5]
    log = os.path.join(os.path.dirname(record["artifact"]), "logs", stem, "nexus.jobs.rails.log")
    if not os.path.exists(log):
        return None, f"no jobs log at {log}"
    bodies = request_bodies(log)
    by_bytes = defaultdict(list)
    for bid, b in bodies.items():
        by_bytes[b["bytes"]].append(bid)
    series = record["efficiency"].get("request_bytes_series") or {}
    rows, prev = [], None
    for key, nbytes in series.items():
        ids = by_bytes.get(nbytes, [])
        if len(ids) != 1:
            rows.append((key, nbytes, None, f"{len(ids)} bodies of {nbytes} bytes"))
            prev = None
            continue
        b = bodies[ids[0]]
        if prev is None:
            rows.append((key, nbytes, b, "first matched round"))
        else:
            cp = common_prefix(prev["entries"], b["entries"])
            extends = cp == len(prev["entries"])
            same_opts = prev["opts"] == b["opts"]
            rows.append((key, nbytes, b, f"prev entries {len(prev['entries'])}, this {len(b['entries'])}, common prefix "
                                         f"{cp} -> {'EXTENDS' if extends else 'DIVERGES at entry ' + str(cp)}; tools "
                                         f"{'same' if same_opts else 'CHANGED'}"))
        prev = b
    return rows, f"{len(bodies)} request bodies in the jobs log window"


def main():
    floors, min_rounds, exempt = bench_floors()
    print(f"## bench.yml: cache_floor_by_family task {floors['task']}, compose {floors['compose']}, workflow "
          f"{floors['workflow']}; cache_floor_min_rounds {min_rounds}; exempt {exempt}\n")
    for version in ("v14", "v13"):
        last = records(version)
        cuf = [r for r in last if r["verdict"].get("class") == "cache under floor"]
        print(f"## {version}: {len(cuf)} records classed cache under floor (last line per key); by family "
              f"{dict(Counter(r['family'] for r in cuf))}; by model {dict(Counter(short(r['model']) for r in cuf))}")
        if version == "v13":
            firsts = records(version, first=True)
            f_cuf = [r for r in firsts if r["verdict"].get("class") == "cache under floor"]
            print(f"   v13 FIRST lines: {len(f_cuf)} cache under floor; by family {dict(Counter(r['family'] for r in f_cuf))}")
            fk = {tuple(r[x] for x in KEY) for r in f_cuf}
            lk = {tuple(r[x] for x in KEY) for r in cuf}
            print(f"   moved into the class by the rescore: {sorted((k[0], short(k[1]), k[3]) for k in lk - fk)}; "
                  f"moved out: {sorted((k[0], short(k[1]), k[3]) for k in fk - lk)}")
        # every record the bar READS (not exempt, enough measured rounds), and how many sit under it
        read = [r for r in last if r["model"] not in exempt and after_r1(r["efficiency"].get("cache_read_series")) is not None
                and len(r["efficiency"].get("cache_read_series") or {}) - 1 >= min_rounds]
        under = [r for r in read if after_r1(r["efficiency"]["cache_read_series"]) < floors[r["family"]]]
        print(f"   records the bar reads: {len(read)}; under the floor: {len(under)}; of those classed otherwise (a red "
              f"class wins): {sorted((r['task'], short(r['model']), r['run'], r['verdict'].get('class')) for r in under if r['verdict'].get('class') != 'cache under floor')}")
        print("\n| family | task | model | run | floor | rate after r1 | ceiling (whole prev prompt served) | measured rounds | "
              "served < 0.95 of prev (of them 0) | r1 rate | success | cost | whose |")
        print("|---|---|---|---|---|---|---|---|---|---|---|---|---|")
        whose = Counter()
        for r in sorted(cuf, key=order):
            s = r["efficiency"]["cache_read_series"]
            low, zeros, measured = short_served(s)
            under_ceiling = ideal(s) < floors[r["family"]]
            w = ("ceiling under the floor, provider served whole: the bar's arithmetic" if under_ceiling and low == 0 else
                 "ceiling under the floor AND provider served short" if under_ceiling else
                 "provider served short (ceiling clears the floor)" if low else "?")
            whose[w] += 1
            print(f"| {r['family']} | {r['task']} | {short(r['model'])} | {r['run']} | {floors[r['family']]} | {after_r1(s)} | "
                  f"{ideal(s)} | {measured} | {low} ({zeros}) | {r1_rate(s)} | {r['verdict'].get('succeeded')} | "
                  f"{float(r['efficiency'].get('cost_amount') or 0):.4f} | {w} |")
        print(f"\n{version} whose (off the series alone): {dict(whose)}\n")
    print("\n## v14 cache-under-floor records, round by round\n")
    for r in sorted((r for r in records("v14") if r["verdict"].get("class") == "cache under floor"), key=order):
        s = r["efficiency"]["cache_read_series"]
        print(f"### {r['task']} {short(r['model'])} #{r['run']}: rate after r1 {after_r1(s)} (floor {floors[r['family']]})")
        keys = list(s)
        rows, note = prefix_read(r)
        pref = {k: text for k, _, _, text in (rows or [])}
        for i, k in enumerate(keys):
            inp, read = s[k]
            if i == 0:
                print(f"- {k}: input {inp}, read {read} (round 1, not measured) | {pref.get(k, '')}")
                continue
            prev_inp = s[keys[i - 1]][0]
            earlier = [keys[j] for j in range(i) if s[keys[j]][0] and abs(s[keys[j]][0] - read) <= max(0.02 * s[keys[j]][0], 256)]
            ratio = read / prev_inp if prev_inp else 0
            kind = ("0 (nothing served)" if read == 0 else
                    f"= prev prompt ({ratio:.3f})" if ratio >= 0.95 else
                    f"= {earlier[-1]}'s prompt" if earlier else f"partial ({ratio:.3f} of prev)")
            print(f"- {k}: input {inp}, read {read}, prev input {prev_inp} -> {kind} | {pref.get(k, '')}")
        print(f"  ({note})\n")


def population():
    """Our prefix on EVERY v14 record with a request_bytes_series: each measured spine round's request against
    the previous one's, off the jobs log (the same reader as above)."""
    tally, diverged, unmatched = Counter(), [], Counter()
    for r in sorted(records("v14"), key=order):
        rows, note = prefix_read(r)
        if rows is None:
            tally["no log"] += 1
            continue
        if rows and rows[0][2] is None:
            tally["round 1 not matched to one body"] += 1
            diverged.append((r["task"], short(r["model"]), r["run"], rows[0][0], "round 1: " + rows[0][3]))
        for key, nbytes, b, text in rows[1:]:
            if b is None:
                unmatched[text.split(" of ")[0]] += 1
                tally["round not matched to one body"] += 1
            elif "first matched round" in text:
                tally["re-anchored after an unmatched round"] += 1
            elif "EXTENDS" in text and "tools same" in text:
                tally["extends, tools same"] += 1
            else:
                tally["DIVERGES or tools changed"] += 1
                diverged.append((r["task"], short(r["model"]), r["run"], key, text))
    print("\n## Our prefix over every v14 record (measured spine rounds)\n")
    print(f"- {dict(tally)}; unmatched by cause {dict(unmatched)}")
    for d in diverged:
        print(f"- not 'extends': {d}")


def quanta():
    """The granularity of each model's cache reads over EVERY v14 record's spine rounds (non-zero reads):
    the largest of 1024 / 512 / 256 / 128 / 64 dividing every read, and the share divisible by each."""
    print("\n## Cache-read granularity per model, every v14 spine round with a non-zero read\n")
    reads = {}
    for r in records("v14"):
        for inp, read in (r["efficiency"].get("cache_read_series") or {}).values():
            if read:
                reads.setdefault(short(r["model"]), []).append(read)
    for m, xs in sorted(reads.items()):
        shares = {q: sum(1 for x in xs if x % q == 0) for q in (1024, 512, 256, 128, 64)}
        print(f"- {m}: {len(xs)} non-zero reads; divisible by " + ", ".join(f"{q}: {n}" for q, n in shares.items()))


main()
population()
quanta()
```

#### A3_cache.py output

~~~text
## bench.yml: cache_floor_by_family task 0.8, compose 0.8, workflow 0.8; cache_floor_min_rounds 2; exempt ['openrouter/z-ai/glm-5.3-flash']

## v14: 16 records classed cache under floor (last line per key); by family {'task': 4, 'compose': 6, 'workflow': 6}; by model {'kimi-k3': 5, 'glm-5.3': 8, 'deepseek-flash': 3}
   records the bar reads: 82; under the floor: 22; of those classed otherwise (a red class wins): [('compose-background-suite', 'kimi-k3', 1, 'model conduct'), ('task-background-suite', 'glm-5.3', 1, 'model conduct'), ('workflow-adversarial-verify', 'deepseek-flash', 3, 'model conduct'), ('workflow-adversarial-verify', 'kimi-k3', 2, 'disagreement'), ('workflow-barrier-free-pipeline', 'glm-5.3', 1, 'disagreement'), ('workflow-barrier-free-pipeline', 'glm-5.3', 2, 'disagreement')]

| family | task | model | run | floor | rate after r1 | ceiling (whole prev prompt served) | measured rounds | served < 0.95 of prev (of them 0) | r1 rate | success | cost | whose |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| compose | compose-grep-then-edit | glm-5.3 | 1 | 0.8 | 0.6574 | 0.7006 | 3 | 1 (1) | 0.0 | True | 0.4211 | ceiling under the floor AND provider served short |
| compose | compose-grep-then-edit | kimi-k3 | 1 | 0.8 | 0.7309 | 0.8338 | 3 | 2 (0) | 0.0 | True | 0.2050 | provider served short (ceiling clears the floor) |
| compose | compose-grep-then-edit | deepseek-flash | 2 | 0.8 | 0.7848 | 0.7898 | 2 | 0 (0) | 0.9447 | True | 0.0134 | ceiling under the floor, provider served whole: the bar's arithmetic |
| compose | compose-single-read | glm-5.3 | 2 | 0.8 | 0.4972 | 0.997 | 2 | 1 (1) | 0.0 | True | 0.0429 | provider served short (ceiling clears the floor) |
| compose | compose-three-stage-pairing | deepseek-flash | 2 | 0.8 | 0.7718 | 0.7628 | 2 | 0 (0) | 0.9405 | True | 0.0139 | ceiling under the floor, provider served whole: the bar's arithmetic |
| compose | compose-three-stage-pairing | deepseek-flash | 3 | 0.8 | 0.7624 | 0.8689 | 2 | 1 (0) | 0.9405 | True | 0.0081 | provider served short (ceiling clears the floor) |
| task | task-background-suite | kimi-k3 | 1 | 0.8 | 0.7993 | 0.9433 | 6 | 1 (1) | 0.0 | True | 0.2160 | provider served short (ceiling clears the floor) |
| task | task-background-suite | kimi-k3 | 2 | 0.8 | 0.7304 | 0.949 | 8 | 2 (1) | 0.0 | True | 0.2752 | provider served short (ceiling clears the floor) |
| task | task-fan-five | glm-5.3 | 1 | 0.8 | 0.5072 | 0.9031 | 2 | 1 (0) | 0.0661 | True | 0.1641 | provider served short (ceiling clears the floor) |
| task | task-fan-five | glm-5.3 | 3 | 0.8 | 0.7918 | 0.8965 | 2 | 1 (0) | 0.952 | True | 0.0869 | provider served short (ceiling clears the floor) |
| workflow | workflow-adversarial-verify | glm-5.3 | 2 | 0.8 | 0.7427 | 0.8695 | 6 | 6 (0) | 0.8431 | True | 0.7220 | provider served short (ceiling clears the floor) |
| workflow | workflow-adversarial-verify | kimi-k3 | 1 | 0.8 | 0.3872 | 0.9439 | 11 | 7 (6) | 0.0 | True | 0.8806 | provider served short (ceiling clears the floor) |
| workflow | workflow-adversarial-verify | kimi-k3 | 3 | 0.8 | 0.4482 | 0.9094 | 7 | 5 (1) | 0.9478 | True | 0.6560 | provider served short (ceiling clears the floor) |
| workflow | workflow-judge-panel | glm-5.3 | 1 | 0.8 | 0.7581 | 0.8068 | 4 | 4 (0) | 0.8449 | True | 0.6055 | provider served short (ceiling clears the floor) |
| workflow | workflow-judge-panel | glm-5.3 | 2 | 0.8 | 0.7622 | 0.7914 | 4 | 1 (0) | 0.8449 | True | 0.6550 | ceiling under the floor AND provider served short |
| workflow | workflow-judge-panel | glm-5.3 | 3 | 0.8 | 0.7963 | 0.865 | 5 | 5 (0) | 0.8449 | True | 0.4144 | provider served short (ceiling clears the floor) |

v14 whose (off the series alone): {'ceiling under the floor AND provider served short': 2, 'provider served short (ceiling clears the floor)': 12, "ceiling under the floor, provider served whole: the bar's arithmetic": 2}

## v13: 20 records classed cache under floor (last line per key); by family {'task': 2, 'compose': 5, 'workflow': 13}; by model {'kimi-k3': 10, 'glm-5.3': 6, 'deepseek-flash': 4}
   v13 FIRST lines: 19 cache under floor; by family {'task': 2, 'compose': 4, 'workflow': 13}
   moved into the class by the rescore: [('compose-grep-then-edit', 'glm-5.3', 3)]; moved out: []
   records the bar reads: 79; under the floor: 29; of those classed otherwise (a red class wins): [('compose-review-angles', 'glm-5.3', 3, 'model conduct'), ('compose-three-stage-pairing', 'kimi-k3', 1, 'model conduct'), ('compose-two-source-fan-in', 'glm-5.3', 1, 'model conduct'), ('task-background-suite', 'kimi-k3', 2, 'model conduct'), ('workflow-adversarial-verify', 'kimi-k3', 1, 'model conduct'), ('workflow-adversarial-verify', 'kimi-k3', 3, 'model conduct'), ('workflow-barrier-free-pipeline', 'glm-5.3', 1, 'model conduct'), ('workflow-barrier-free-pipeline', 'glm-5.3', 2, 'disagreement'), ('workflow-barrier-free-pipeline', 'kimi-k3', 2, 'model conduct')]

| family | task | model | run | floor | rate after r1 | ceiling (whole prev prompt served) | measured rounds | served < 0.95 of prev (of them 0) | r1 rate | success | cost | whose |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| compose | compose-grep-then-edit | glm-5.3 | 3 | 0.8 | 0.7376 | 0.7399 | 3 | 0 (0) | 0.9497 | True | 0.2046 | ceiling under the floor, provider served whole: the bar's arithmetic |
| compose | compose-grep-then-edit | deepseek-flash | 2 | 0.8 | 0.5114 | 0.7404 | 2 | 1 (0) | 0.9479 | True | 0.0336 | ceiling under the floor AND provider served short |
| compose | compose-race | deepseek-flash | 1 | 0.8 | 0.7283 | 0.8582 | 2 | 1 (0) | 0.9461 | True | 0.0089 | provider served short (ceiling clears the floor) |
| compose | compose-race-anon | deepseek-flash | 3 | 0.8 | 0.7375 | 0.8598 | 2 | 1 (0) | 0.9459 | True | 0.0081 | provider served short (ceiling clears the floor) |
| compose | compose-rendezvous | deepseek-flash | 2 | 0.8 | 0.7934 | 0.7862 | 2 | 0 (0) | 0.9446 | True | 0.0436 | ceiling under the floor, provider served whole: the bar's arithmetic |
| task | task-background-suite | kimi-k3 | 1 | 0.8 | 0.5097 | 0.9611 | 9 | 7 (4) | 0.0 | True | 0.2832 | provider served short (ceiling clears the floor) |
| task | task-background-suite | kimi-k3 | 3 | 0.8 | 0.7982 | 0.9585 | 7 | 3 (1) | 0.0 | True | 0.1762 | provider served short (ceiling clears the floor) |
| workflow | workflow-adversarial-verify | glm-5.3 | 1 | 0.8 | 0.4358 | 0.8193 | 3 | 1 (1) | 0.0 | True | 0.6472 | provider served short (ceiling clears the floor) |
| workflow | workflow-adversarial-verify | kimi-k3 | 2 | 0.8 | 0.5158 | 0.9349 | 10 | 5 (3) | 0.0 | True | 0.8356 | provider served short (ceiling clears the floor) |
| workflow | workflow-barrier-free-pipeline | glm-5.3 | 3 | 0.8 | 0.7702 | 0.7708 | 4 | 0 (0) | 0.9521 | True | 0.1739 | ceiling under the floor, provider served whole: the bar's arithmetic |
| workflow | workflow-fan-out-finders | kimi-k3 | 1 | 0.8 | 0.2869 | 0.9292 | 3 | 3 (2) | 0.0 | True | 0.4135 | provider served short (ceiling clears the floor) |
| workflow | workflow-fan-out-finders | kimi-k3 | 2 | 0.8 | 0.2983 | 0.9354 | 3 | 2 (2) | 0.0 | True | 0.3424 | provider served short (ceiling clears the floor) |
| workflow | workflow-fan-out-finders | kimi-k3 | 3 | 0.8 | 0.0 | 0.9411 | 3 | 3 (3) | 0.0 | True | 0.3857 | provider served short (ceiling clears the floor) |
| workflow | workflow-judge-panel | glm-5.3 | 1 | 0.8 | 0.7061 | 0.865 | 5 | 3 (0) | 0.9539 | True | 0.3764 | provider served short (ceiling clears the floor) |
| workflow | workflow-judge-panel | glm-5.3 | 2 | 0.8 | 0.5793 | 0.8055 | 3 | 2 (0) | 0.9539 | True | 0.2150 | provider served short (ceiling clears the floor) |
| workflow | workflow-judge-panel | glm-5.3 | 3 | 0.8 | 0.7685 | 0.797 | 4 | 1 (0) | 0.8479 | True | 0.6368 | ceiling under the floor AND provider served short |
| workflow | workflow-judge-panel | kimi-k3 | 2 | 0.8 | 0.328 | 0.8908 | 3 | 2 (1) | 0.0 | True | 0.5714 | provider served short (ceiling clears the floor) |
| workflow | workflow-judge-panel | kimi-k3 | 3 | 0.8 | 0.6045 | 0.9284 | 3 | 1 (1) | 0.9529 | True | 0.2089 | provider served short (ceiling clears the floor) |
| workflow | workflow-loop-until-dry | kimi-k3 | 1 | 0.8 | 0.6306 | 0.9883 | 25 | 19 (7) | 0.0 | True | 0.4083 | provider served short (ceiling clears the floor) |
| workflow | workflow-loop-until-dry | kimi-k3 | 2 | 0.8 | 0.7048 | 0.9891 | 25 | 17 (5) | 0.8956 | True | 0.3240 | provider served short (ceiling clears the floor) |

v13 whose (off the series alone): {"ceiling under the floor, provider served whole: the bar's arithmetic": 3, 'ceiling under the floor AND provider served short': 2, 'provider served short (ceiling clears the floor)': 15}


## v14 cache-under-floor records, round by round

### compose-grep-then-edit glm-5.3 #1: rate after r1 0.6574 (floor 0.8)
- r1: input 9615, read 0 (round 1, not measured) | first matched round
- r2: input 70353, read 0, prev input 9615 -> 0 (nothing served) | prev entries 3, this 10, common prefix 3 -> EXTENDS; tools same
- r3: input 76299, read 70336, prev input 70353 -> = prev prompt (1.000) | prev entries 10, this 13, common prefix 10 -> EXTENDS; tools same
- r4: input 76393, read 76288, prev input 76299 -> = prev prompt (1.000) | prev entries 13, this 16, common prefix 13 -> EXTENDS; tools same
  (4 request bodies in the jobs log window)

### compose-grep-then-edit kimi-k3 #1: rate after r1 0.7309 (floor 0.8)
- r1: input 9148, read 0 (round 1, not measured) | first matched round
- r2: input 16896, read 8448, prev input 9148 -> partial (0.923 of prev) | prev entries 3, this 10, common prefix 3 -> EXTENDS; tools same
- r3: input 17760, read 12288, prev input 16896 -> partial (0.727 of prev) | prev entries 10, this 13, common prefix 10 -> EXTENDS; tools same
- r4: input 17881, read 17664, prev input 17760 -> = prev prompt (0.995) | prev entries 13, this 15, common prefix 13 -> EXTENDS; tools same
  (4 request bodies in the jobs log window)

### compose-grep-then-edit deepseek-flash #2: rate after r1 0.7848 (floor 0.8)
- r1: input 10026, read 9472 (round 1, not measured) | first matched round
- r2: input 16640, read 9984, prev input 10026 -> = prev prompt (0.996) | prev entries 3, this 7, common prefix 3 -> EXTENDS; tools same
- r7: input 17121, read 16512, prev input 16640 -> = prev prompt (0.992) | prev entries 7, this 12, common prefix 7 -> EXTENDS; tools same
  (9 request bodies in the jobs log window)

### compose-single-read glm-5.3 #2: rate after r1 0.4972 (floor 0.8)
- r1: input 9615, read 0 (round 1, not measured) | first matched round
- r2: input 9638, read 0, prev input 9615 -> 0 (nothing served) | prev entries 3, this 5, common prefix 3 -> EXTENDS; tools same
- r3: input 9672, read 9600, prev input 9638 -> = prev prompt (0.996) | prev entries 5, this 7, common prefix 5 -> EXTENDS; tools same
  (3 request bodies in the jobs log window)

### compose-three-stage-pairing deepseek-flash #2: rate after r1 0.7718 (floor 0.8)
- r1: input 10071, read 9472 (round 1, not measured) | first matched round
- r2: input 17509, read 9984, prev input 10071 -> = prev prompt (0.991) | prev entries 3, this 7, common prefix 3 -> EXTENDS; tools same
- r3: input 18645, read 17920, prev input 17509 -> = prev prompt (1.023) | prev entries 7, this 10, common prefix 7 -> EXTENDS; tools same
  (7 request bodies in the jobs log window)

### compose-three-stage-pairing deepseek-flash #3: rate after r1 0.7624 (floor 0.8)
- r1: input 10071, read 9472 (round 1, not measured) | first matched round
- r2: input 14874, read 11904, prev input 10071 -> = prev prompt (1.182) | prev entries 3, this 6, common prefix 3 -> EXTENDS; tools same
- r3: input 13836, read 9984, prev input 14874 -> = r1's prompt | prev entries 6, this 10, common prefix 6 -> EXTENDS; tools same
  (7 request bodies in the jobs log window)

### task-background-suite kimi-k3 #1: rate after r1 0.7993 (floor 0.8)
- r1: input 9118, read 0 (round 1, not measured) | first matched round
- r2: input 9951, read 9120, prev input 9118 -> = prev prompt (1.000) | prev entries 3, this 8, common prefix 3 -> EXTENDS; tools same
- r4: input 10434, read 0, prev input 9951 -> 0 (nothing served) | prev entries 8, this 13, common prefix 8 -> EXTENDS; tools same
- r5: input 11123, read 10432, prev input 10434 -> = prev prompt (1.000) | prev entries 13, this 18, common prefix 13 -> EXTENDS; tools same
- r6: input 12003, read 11104, prev input 11123 -> = prev prompt (0.998) | prev entries 18, this 21, common prefix 18 -> EXTENDS; tools same
- r7: input 12856, read 12000, prev input 12003 -> = prev prompt (1.000) | prev entries 21, this 24, common prefix 21 -> EXTENDS; tools same
- r8: input 13052, read 12832, prev input 12856 -> = prev prompt (0.998) | prev entries 24, this 26, common prefix 24 -> EXTENDS; tools same
  (10 request bodies in the jobs log window)

### task-background-suite kimi-k3 #2: rate after r1 0.7304 (floor 0.8)
- r1: input 9118, read 0 (round 1, not measured) | first matched round
- r2: input 10340, read 0, prev input 9118 -> 0 (nothing served) | prev entries 3, this 8, common prefix 3 -> EXTENDS; tools same
- r3: input 10656, read 191, prev input 10340 -> partial (0.018 of prev) | prev entries 8, this 13, common prefix 8 -> EXTENDS; tools same
- r5: input 11179, read 10343, prev input 10656 -> = prev prompt (0.971) | prev entries 13, this 18, common prefix 13 -> EXTENDS; tools same
- r8: input 11825, read 10809, prev input 11179 -> = prev prompt (0.967) | prev entries 18, this 21, common prefix 18 -> EXTENDS; tools same
- r9: input 12278, read 11533, prev input 11825 -> = prev prompt (0.975) | prev entries 21, this 24, common prefix 21 -> EXTENDS; tools same
- r11: input 12622, read 12064, prev input 12278 -> = prev prompt (0.983) | prev entries 24, this 26, common prefix 24 -> EXTENDS; tools same
- r12: input 13827, read 12010, prev input 12622 -> = prev prompt (0.952) | prev entries 26, this 29, common prefix 26 -> EXTENDS; tools same
- r13: input 14056, read 13744, prev input 13827 -> = prev prompt (0.994) | prev entries 29, this 31, common prefix 29 -> EXTENDS; tools same
  (15 request bodies in the jobs log window)

### task-fan-five glm-5.3 #1: rate after r1 0.5072 (floor 0.8)
- r1: input 9681, read 640 (round 1, not measured) | first matched round
- r2: input 11745, read 512, prev input 9681 -> partial (0.053 of prev) | prev entries 3, this 14, common prefix 3 -> EXTENDS; tools same
- r19: input 11979, read 11520, prev input 11745 -> = prev prompt (0.981) | prev entries 14, this 17, common prefix 14 -> EXTENDS; tools same
  (24 request bodies in the jobs log window)

### task-fan-five glm-5.3 #3: rate after r1 0.7918 (floor 0.8)
- r1: input 9681, read 9216 (round 1, not measured) | first matched round
- r2: input 11550, read 9472, prev input 9681 -> = prev prompt (0.978) | prev entries 3, this 14, common prefix 3 -> EXTENDS; tools same
- r15: input 12133, read 9280, prev input 11550 -> partial (0.803 of prev) | prev entries 14, this 17, common prefix 14 -> EXTENDS; tools same
  (20 request bodies in the jobs log window)

### workflow-adversarial-verify glm-5.3 #2: rate after r1 0.7427 (floor 0.8)
- r1: input 9717, read 8192 (round 1, not measured) | first matched round
- r2: input 9844, read 8192, prev input 9717 -> partial (0.843 of prev) | prev entries 3, this 6, common prefix 3 -> EXTENDS; tools same
- r3: input 9904, read 8192, prev input 9844 -> partial (0.832 of prev) | prev entries 6, this 9, common prefix 6 -> EXTENDS; tools same
- r4: input 10235, read 8192, prev input 9904 -> partial (0.827 of prev) | prev entries 9, this 15, common prefix 9 -> EXTENDS; tools same
- r5: input 14305, read 8192, prev input 10235 -> partial (0.800 of prev) | prev entries 15, this 18, common prefix 15 -> EXTENDS; tools same
- r6: input 20317, read 12288, prev input 14305 -> partial (0.859 of prev) | prev entries 18, this 45, common prefix 18 -> EXTENDS; tools same
- r23: input 20875, read 18432, prev input 20317 -> partial (0.907 of prev) | prev entries 45, this 48, common prefix 45 -> EXTENDS; tools same
  (100 request bodies in the jobs log window)

### workflow-adversarial-verify kimi-k3 #1: rate after r1 0.3872 (floor 0.8)
- r1: input 9183, read 0 (round 1, not measured) | first matched round
- r2: input 9429, read 0, prev input 9183 -> 0 (nothing served) | prev entries 3, this 8, common prefix 3 -> EXTENDS; tools same
- r3: input 9662, read 9216, prev input 9429 -> = prev prompt (0.977) | prev entries 8, this 11, common prefix 8 -> EXTENDS; tools same
- r4: input 13890, read 9216, prev input 9662 -> = prev prompt (0.954) | prev entries 11, this 36, common prefix 11 -> EXTENDS; tools same
- r19: input 14546, read 0, prev input 13890 -> 0 (nothing served) | prev entries 36, this 39, common prefix 36 -> EXTENDS; tools same
- w1: input 14853, read 0, prev input 14546 -> 0 (nothing served) | prev entries 39, this 42, common prefix 39 -> EXTENDS; tools same
- r25: input 15075, read 14848, prev input 14853 -> = prev prompt (1.000) | prev entries 42, this 44, common prefix 42 -> EXTENDS; tools same
- w2: input 16321, read 13824, prev input 15075 -> = r4's prompt | prev entries 44, this 53, common prefix 44 -> EXTENDS; tools same
- r29: input 17147, read 0, prev input 16321 -> 0 (nothing served) | prev entries 53, this 56, common prefix 53 -> EXTENDS; tools same
- w3: input 17688, read 0, prev input 17147 -> 0 (nothing served) | prev entries 56, this 59, common prefix 56 -> EXTENDS; tools same
- r30: input 18209, read 16896, prev input 17688 -> = prev prompt (0.955) | prev entries 59, this 64, common prefix 59 -> EXTENDS; tools same
- r31: input 18449, read 0, prev input 18209 -> 0 (nothing served) | prev entries 64, this 66, common prefix 64 -> EXTENDS; tools same
  (46 request bodies in the jobs log window)

### workflow-adversarial-verify kimi-k3 #3: rate after r1 0.4482 (floor 0.8)
- r1: input 9183, read 8704 (round 1, not measured) | first matched round
- r2: input 9446, read 512, prev input 9183 -> partial (0.056 of prev) | prev entries 3, this 6, common prefix 3 -> EXTENDS; tools same
- r3: input 9767, read 512, prev input 9446 -> partial (0.054 of prev) | prev entries 6, this 11, common prefix 6 -> EXTENDS; tools same
- r4: input 14376, read 0, prev input 9767 -> 0 (nothing served) | prev entries 11, this 36, common prefix 11 -> EXTENDS; tools same
- r19: input 14873, read 8704, prev input 14376 -> partial (0.605 of prev) | prev entries 36, this 39, common prefix 36 -> EXTENDS; tools same
- r23: input 14972, read 2901, prev input 14873 -> partial (0.195 of prev) | prev entries 39, this 41, common prefix 39 -> EXTENDS; tools same
- w1: input 17428, read 14336, prev input 14972 -> = prev prompt (0.958) | prev entries 41, this 54, common prefix 41 -> EXTENDS; tools same
- r28: input 18150, read 17408, prev input 17428 -> = prev prompt (0.999) | prev entries 54, this 59, common prefix 54 -> EXTENDS; tools same
  (41 request bodies in the jobs log window)

### workflow-judge-panel glm-5.3 #1: rate after r1 0.7581 (floor 0.8)
- r1: input 9696, read 8192 (round 1, not measured) | first matched round
- r2: input 33457, read 8192, prev input 9696 -> partial (0.845 of prev) | prev entries 3, this 14, common prefix 3 -> EXTENDS; tools same
- r30: input 36761, read 31744, prev input 33457 -> partial (0.949 of prev) | prev entries 14, this 21, common prefix 14 -> EXTENDS; tools same
- r31: input 37788, read 34816, prev input 36761 -> partial (0.947 of prev) | prev entries 21, this 26, common prefix 21 -> EXTENDS; tools same
- r32: input 37883, read 35840, prev input 37788 -> partial (0.948 of prev) | prev entries 26, this 28, common prefix 26 -> EXTENDS; tools same
  (36 request bodies in the jobs log window)

### workflow-judge-panel glm-5.3 #2: rate after r1 0.7622 (floor 0.8)
- r1: input 9696, read 8192 (round 1, not measured) | first matched round
- r2: input 50600, read 8192, prev input 9696 -> partial (0.845 of prev) | prev entries 3, this 6, common prefix 3 -> EXTENDS; tools same
- r3: input 53717, read 49152, prev input 50600 -> = prev prompt (0.971) | prev entries 6, this 10, common prefix 6 -> EXTENDS; tools same
- r42: input 53965, read 52224, prev input 53717 -> = prev prompt (0.972) | prev entries 10, this 13, common prefix 10 -> EXTENDS; tools same
- r43: input 53985, read 52224, prev input 53965 -> = prev prompt (0.968) | prev entries 13, this 15, common prefix 13 -> EXTENDS; tools same
  (47 request bodies in the jobs log window)

### workflow-judge-panel glm-5.3 #3: rate after r1 0.7963 (floor 0.8)
- r1: input 9696, read 8192 (round 1, not measured) | first matched round
- r2: input 18065, read 8192, prev input 9696 -> partial (0.845 of prev) | prev entries 3, this 12, common prefix 3 -> EXTENDS; tools same
- r3: input 22151, read 16384, prev input 18065 -> partial (0.907 of prev) | prev entries 12, this 21, common prefix 12 -> EXTENDS; tools same
- r27: input 25007, read 20480, prev input 22151 -> partial (0.925 of prev) | prev entries 21, this 26, common prefix 21 -> EXTENDS; tools same
- r28: input 25201, read 23552, prev input 25007 -> partial (0.942 of prev) | prev entries 26, this 29, common prefix 26 -> EXTENDS; tools same
- r29: input 25318, read 23552, prev input 25201 -> partial (0.935 of prev) | prev entries 29, this 31, common prefix 29 -> EXTENDS; tools same
  (33 request bodies in the jobs log window)


## Our prefix over every v14 record (measured spine rounds)

- {'extends, tools same': 805, 'round 1 not matched to one body': 1, 're-anchored after an unmatched round': 1}; unmatched by cause {}
- not 'extends': ('workflow-adversarial-verify', 'glm-5.3', 3, 'r1', 'round 1: 2 bodies of 3018 bytes')

## Cache-read granularity per model, every v14 spine round with a non-zero read

- deepseek-flash: 231 non-zero reads; divisible by 1024: 21, 512: 36, 256: 156, 128: 231, 64: 231
- glm-5.3: 244 non-zero reads; divisible by 1024: 67, 512: 75, 256: 97, 128: 139, 64: 244
- glm-5.3-flash: 211 non-zero reads; divisible by 1024: 12, 512: 21, 256: 45, 128: 156, 64: 211
- kimi-k3: 194 non-zero reads; divisible by 1024: 27, 512: 65, 256: 121, 128: 122, 64: 124
~~~

### A4_spend.py

<!-- script:A4_spend.py -->
```python
#!/usr/bin/env python3
"""SECTION A, SPEND: v14's recorded cost by lane against the balance move the orchestrator quoted (read-only).

The balances are the orchestrator's (the task statement: OpenRouter $199.30 -> $173.33, DeepSeek
CNY 98.26 -> 94.05); no file under the repo holds a v14 balance snapshot. The records carry each
run's cost_amount (USD at the catalog price on the DeepSeek lane). The race-text A/B's reruns are
dated by their launch outputs' mtimes, read in UTC.
"""
import json
import os
import time
from collections import Counter

REPO = "/Users/jasl/Workspaces/cybros-ai.alt2"
RUNS = os.path.join(REPO, "e2e/evals/runs")
BALANCES = {"openrouter": (199.30, 173.33), "deepseek (CNY)": (98.26, 94.05)}

by_lane, by_family_lane, starts = Counter(), Counter(), []
for fam in ("task", "compose", "workflow"):
    with open(os.path.join(RUNS, f"2026-09-26-v14-{fam}", "records.jsonl"), encoding="utf-8") as fh:
        for line in fh:
            if line.strip():
                r = json.loads(line)
                lane = "deepseek" if r["model"].startswith("deepseek/") else "openrouter"
                c = float(r["efficiency"].get("cost_amount") or 0)
                by_lane[lane] += c
                by_family_lane[(fam, lane)] += c
                starts.append((r["started_at"], r["seconds"]))
for lane, (a, b) in BALANCES.items():
    print(f"- balance {lane}: {a} -> {b}, moved {a - b:.2f}")
print(f"- records: openrouter ${by_lane['openrouter']:.4f}, deepseek ${by_lane['deepseek']:.4f} (USD at the catalog price)")
print(f"- openrouter balance move minus records: ${BALANCES['openrouter'][0] - BALANCES['openrouter'][1] - by_lane['openrouter']:.4f}")
print("- records by family and lane: " + ", ".join(f"{f}/{l} ${v:.4f}" for (f, l), v in sorted(by_family_lane.items())))
print(f"- the bench's records start {min(s for s, _ in starts)} and the last starts {max(s for s, _ in starts)}")
rt = os.path.join(REPO, "e2e/artifacts/bench/2026-09-26-racetext")
for name in ("logs/launch.txt", "rerun-flash-A", "rerun-flash-A.launch.out", "rerun-glm53-O3", "rerun-glm53-O3.launch.out",
             "rerun-flash-B", "rerun-flash-B.launch.out"):
    path = os.path.join(rt, name)
    print(f"- race-text {name}: mtime {time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(os.stat(path).st_mtime))}")
```

#### A4_spend.py output

~~~text
- balance openrouter: 199.3 -> 173.33, moved 25.97
- balance deepseek (CNY): 98.26 -> 94.05, moved 4.21
- records: openrouter $21.6080, deepseek $0.7437 (USD at the catalog price)
- openrouter balance move minus records: $4.3620
- records by family and lane: compose/deepseek $0.3800, compose/openrouter $9.6139, task/deepseek $0.0973, task/openrouter $2.9916, workflow/deepseek $0.2663, workflow/openrouter $9.0025
- the bench's records start 2026-09-25T16:02:32Z and the last starts 2026-09-26T00:51:17Z
- race-text logs/launch.txt: mtime 2026-09-25T15:16:27Z
- race-text rerun-flash-A: mtime 2026-09-25T15:51:22Z
- race-text rerun-flash-A.launch.out: mtime 2026-09-25T17:26:11Z
- race-text rerun-glm53-O3: mtime 2026-09-25T17:26:27Z
- race-text rerun-glm53-O3.launch.out: mtime 2026-09-25T17:47:34Z
- race-text rerun-flash-B: mtime 2026-09-25T17:47:34Z
- race-text rerun-flash-B.launch.out: mtime 2026-09-25T19:36:40Z
~~~
