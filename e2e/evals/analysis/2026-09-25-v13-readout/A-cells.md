# Section A: the cells, bench v13 against v11

Read-only. Nothing was re-scored and nothing was rewritten in place. The v13 input is the three labels
`2026-09-25-v13-{task,compose,workflow}`: 240 records, digest `ab836ee0d8be`, 0 error rows, no duplicate key. The v11
baseline is `2026-09-24-v11-{task,compose,workflow}`: 228 records, digest `c0b22996599e`. v11's pack and candidate
labels (`kimi-pack-compose`, `kimi-k6-compose`, `glm-pack-workflow`, `glm-wfword-workflow`, `kimi-pack-workflow`) use
other styles or candidates, so they are not the baseline. v11 has no compose-race-anon cell, and those four cells are
marked `new`. Every number below was printed by one of the three scripts in the appendix. Each script is embedded
verbatim and its output sits beside it. To re-run a script, extract it from this file:

~~~sh
R='import re,sys;t=open(sys.argv[1],encoding="utf-8").read();m=re.search(r"<!-- script:"+re.escape(sys.argv[2])+r" -->\n```(?:python|ruby)\n(.*?)\n```",t,re.S);exec(compile(m.group(1),sys.argv[2],"exec"),{"__name__":"__main__"})'
cd /private/tmp/claude-501/-Users-jasl-Workspaces-cybros-ai-alt2/fe6d4094-2f85-4b52-abfc-78043a70e275/scratchpad/v13/readout
python3 -c "$R" A-cells.md A1_cells.py   # the cells, totals, moves, reasons, cost, usable_on_call, floor bars
python3 -c "$R" A-cells.md A2_evidence.py  # the evidence behind the moves (records + artifacts)
python3 -c "$R" A-cells.md A3_logs.py      # the world-log reads (refusal texts, S1, the lane bugs)
~~~

**Cross-checks.** All 80 v13 cells match LEDGER.md's v13 strings (`r`, `s`/`u·x`, `p`, `d`), with 0 mismatches (A1).
The v11 per-model costs this script computes match the v11 readout's §7.6 figures: $9.5537 / $11.6580 / $1.0523 /
$1.4691.

## A.1 Headline

- **v13, all 240 runs:** reached 215/240, succeeded 190/240, task pass 69/72, green 167/240. Classes: model conduct
  43, disagreement 9, cache under floor 19, lane bug 2. Recorded cost is $23.2045, with 2 records that carry no cost.
  Record time totals 29575 s (8.22 h).
- **v11, all 228 runs:** reached 202/228, succeeded 161/228, task pass 70/72, green 133/228. Classes: model conduct
  65, disagreement 17, cache under floor 13. Cost $23.7331; record time 27474 s.
- **Change on v11's 76 cells** (compose-race-anon left out): succeeded +17, green +23, reached +1, passed −1. Model
  conduct −22, disagreement −8, cache under floor +5. Cost −$1.3006.
  - task: succeeded +8, green +8.
  - compose is flat: succeeded −1, green −1, bar −3, reached −2.
  - workflow: succeeded +10, green +16.
  - strong tier: succeeded +9, green +11.
  - floor tier: succeeded +8, green +12.
- **The new cell, compose-race-anon**, reads r 3/3 and s 3/3 in all four cells. The strong picture is 3/3 on both
  glm-5.3 and kimi-k3. The floor is usable 3/3 on both floor models, and its picture is 2/3 on deepseek-flash and 3/3
  on glm-5.3-flash. Cost is $0.4655 for glm-5.3, $0.2640 for kimi-k3, $0.0246 for deepseek-flash and $0.0179 for
  glm-5.3-flash.
- **Most of the gain has three sources:**
  - v12's readers, which now read the kernel's spine mark and what a loop pass took from `queue/`;
  - v12's revised task-detached-receipt instruction;
  - a handful of model choices at n = 3.

  The strong tier's picture on v11's seven picture tasks is unchanged at 19/42, and so is each model's: glm-5.3 9/21
  and kimi-k3 10/21.

## A.2 The cells, v13 beside v11 (A1)

Notation:
- r and s are k of 3 runs. p is passed/verified, and `—` means no run was verified.
- Classes: mc model conduct, dis disagreement, cuf cache under floor, lb lane bug, g green.
- bar is the tier's bar on a picture task:
  - a floor cell reads `u usable/3 (x picture)`, where usable means `usable_on_call` is set, meaning some call in the
    run met the bar;
  - a strong cell reads `x picture/3 (u usable)`, where the picture is read on the first compose call;
  - `= s` marks a cell whose bar is its success.
- On every reached picture-task record, success equals the tier's bar (A2 §7).
- Mean s is the mean of the records' `seconds`. Cost is the sum of `cost_amount` in USD; `(1 null)` flags a record
  that carries no cost.

### task

| task | model | tier | r v13 | r v11 | s v13 | s v11 | p v13 | p v11 | classes v13 | classes v11 | bar v13 | bar v11 | mean s v13 | mean s v11 | cost v13 | cost v11 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| task-background-suite | glm-5.3 | strong | 3/3 | 3/3 | 3/3 | 1/3 | — | — | g3 | mc2 g1 | = s | = s | 143 | 172 | 0.3797 | 0.5207 |
| task-background-suite | kimi-k3 | strong | 2/3 | 3/3 | 2/3 | 2/3 | — | — | mc1 cuf2 g0 | mc1 cuf1 g1 | = s | = s | 129 | 126 | 0.6436 | 0.5167 |
| task-background-suite | deepseek-flash | floor | 1/3 | 2/3 | 1/3 | 2/3 | — | — | mc2 g1 | mc1 g2 | = s | = s | 60 | 80 | 0.0269 | 0.0409 |
| task-background-suite | glm-5.3-flash | floor | 2/3 | 1/3 | 2/3 | 1/3 | — | — | mc1 g2 | mc2 g1 | = s | = s | 138 | 104 | 0.0622 | 0.0290 |
| task-detached-receipt | glm-5.3 | strong | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | = s | = s | 73 | 108 | 0.0842 | 0.2339 |
| task-detached-receipt | kimi-k3 | strong | 3/3 | 3/3 | 3/3 | 1/3 | — | — | g3 | mc2 g1 | = s | = s | 100 | 79 | 0.3058 | 0.1412 |
| task-detached-receipt | deepseek-flash | floor | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | = s | = s | 72 | 67 | 0.0082 | 0.0080 |
| task-detached-receipt | glm-5.3-flash | floor | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | = s | = s | 84 | 80 | 0.0160 | 0.0155 |
| task-fan-five | glm-5.3 | strong | 3/3 | 3/3 | 3/3 | 2/3 | — | — | g3 | mc1 g2 | = s | = s | 97 | 76 | 0.1935 | 0.2243 |
| task-fan-five | kimi-k3 | strong | 3/3 | 3/3 | 3/3 | 2/3 | — | — | g3 | mc1 g2 | = s | = s | 86 | 62 | 0.7417 | 0.3436 |
| task-fan-five | deepseek-flash | floor | 1/3 | 1/3 | 1/3 | 1/3 | — | — | mc2 g1 | mc2 cuf1 g0 | = s | = s | 63 | 61 | 0.0321 | 0.0390 |
| task-fan-five | glm-5.3-flash | floor | 3/3 | 2/3 | 2/3 | 2/3 | — | — | mc1 g2 | mc1 g2 | = s | = s | 102 | 70 | 0.0551 | 0.0441 |
| task-grep-three-control | glm-5.3 | strong | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | = s | = s | 19 | 11 | 0.0292 | 0.0262 |
| task-grep-three-control | kimi-k3 | strong | 3/3 | 2/3 | 3/3 | 2/3 | — | — | g3 | mc1 g2 | = s | = s | 15 | 17 | 0.0589 | 0.1264 |
| task-grep-three-control | deepseek-flash | floor | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | = s | = s | 12 | 13 | 0.0022 | 0.0021 |
| task-grep-three-control | glm-5.3-flash | floor | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | = s | = s | 14 | 12 | 0.0045 | 0.0045 |
| task-mail | glm-5.3 | strong | 1/3 | 0/3 | 1/3 | 0/3 | — | — | mc2 g1 | mc3 g0 | = s | = s | 63 | 19 | 0.0925 | 0.0230 |
| task-mail | kimi-k3 | strong | 0/3 | 1/3 | 0/3 | 1/3 | — | — | mc3 g0 | mc2 g1 | = s | = s | 17 | 60 | 0.1157 | 0.1816 |
| task-mail | deepseek-flash | floor | 2/3 | 2/3 | 2/3 | 1/3 | — | — | mc1 g2 | mc2 g1 | = s | = s | 53 | 60 | 0.0097 | 0.0096 |
| task-mail | glm-5.3-flash | floor | 0/3 | 0/3 | 0/3 | 0/3 | — | — | mc3 g0 | mc3 g0 | = s | = s | 36 | 28 | 0.0060 | 0.0052 |
| task-two-calls | glm-5.3 | strong | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | = s | = s | 15 | 14 | 0.0195 | 0.0382 |
| task-two-calls | kimi-k3 | strong | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | = s | = s | 16 | 14 | 0.0879 | 0.1032 |
| task-two-calls | deepseek-flash | floor | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | = s | = s | 11 | 19 | 0.0019 | 0.0018 |
| task-two-calls | glm-5.3-flash | floor | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | = s | = s | 26 | 14 | 0.0053 | 0.0044 |

### compose

| task | model | tier | r v13 | r v11 | s v13 | s v11 | p v13 | p v11 | classes v13 | classes v11 | bar v13 | bar v11 | mean s v13 | mean s v11 | cost v13 | cost v11 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| compose-background-suite | glm-5.3 | strong | 2/3 | 3/3 | 1/3 | 1/3 | — | — | mc1 lb1 g1 | mc2 g1 | x 1/3 (u 2) | x 1/3 (u 3) | 313 | 259 | 0.3435 (1 null) | 0.7204 |
| compose-background-suite | kimi-k3 | strong | 3/3 | 3/3 | 1/3 | 0/3 | — | — | mc2 g1 | mc3 g0 | x 1/3 (u 3) | x 0/3 (u 3) | 112 | 159 | 0.7017 | 0.5654 |
| compose-background-suite | deepseek-flash | floor | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | u 3/3 (x 0) | u 3/3 (x 2) | 126 | 83 | 0.0711 | 0.0514 |
| compose-background-suite | glm-5.3-flash | floor | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | u 3/3 (x 1) | u 3/3 (x 0) | 330 | 187 | 0.0744 | 0.0587 |
| compose-grep-then-edit | glm-5.3 | strong | 3/3 | 3/3 | 0/3 | 0/3 | 3/3 | 3/3 | dis3 g0 | dis3 g0 | x 0/3 (u 3) | x 0/3 (u 3) | 387 | 324 | 0.8292 | 1.3125 |
| compose-grep-then-edit | kimi-k3 | strong | 3/3 | 3/3 | 1/3 | 2/3 | 3/3 | 3/3 | dis2 g1 | dis1 g2 | x 1/3 (u 3) | x 2/3 (u 3) | 51 | 82 | 0.3169 | 0.3100 |
| compose-grep-then-edit | deepseek-flash | floor | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | cuf1 g2 | cuf1 g2 | u 3/3 (x 2) | u 3/3 (x 2) | 67 | 74 | 0.0538 | 0.0601 |
| compose-grep-then-edit | glm-5.3-flash | floor | 2/3 | 3/3 | 2/3 | 3/3 | 2/3 | 3/3 | lb1 g2 | g3 | u 2/3 (x 0) | u 3/3 (x 0) | 385 | 305 | 0.0377 (1 null) | 0.0737 |
| compose-race | glm-5.3 | strong | 3/3 | 3/3 | 3/3 | 2/3 | — | — | g3 | mc1 g2 | x 3/3 (u 3) | x 2/3 (u 3) | 137 | 189 | 0.4539 | 0.4638 |
| compose-race | kimi-k3 | strong | 3/3 | 3/3 | 3/3 | 2/3 | — | — | g3 | mc1 g2 | x 3/3 (u 3) | x 2/3 (u 3) | 28 | 189 | 0.2192 | 0.4091 |
| compose-race | deepseek-flash | floor | 3/3 | 3/3 | 3/3 | 3/3 | — | — | cuf1 g2 | g3 | u 3/3 (x 2) | u 3/3 (x 2) | 33 | 32 | 0.0197 | 0.0169 |
| compose-race | glm-5.3-flash | floor | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | u 3/3 (x 2) | u 3/3 (x 1) | 230 | 190 | 0.0319 | 0.0459 |
| compose-race-anon | glm-5.3 | strong | 3/3 | new | 3/3 | new | — | new | g3 | new | x 3/3 (u 3) | new | 134 | new | 0.4655 | new |
| compose-race-anon | kimi-k3 | strong | 3/3 | new | 3/3 | new | — | new | g3 | new | x 3/3 (u 3) | new | 58 | new | 0.2640 | new |
| compose-race-anon | deepseek-flash | floor | 3/3 | new | 3/3 | new | — | new | cuf1 g2 | new | u 3/3 (x 2) | new | 40 | new | 0.0246 | new |
| compose-race-anon | glm-5.3-flash | floor | 3/3 | new | 3/3 | new | — | new | g3 | new | u 3/3 (x 3) | new | 97 | new | 0.0179 | new |
| compose-rendezvous | glm-5.3 | strong | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | = s | = s | 160 | 360 | 0.6720 | 1.0875 |
| compose-rendezvous | kimi-k3 | strong | 3/3 | 3/3 | 3/3 | 2/3 | — | — | g3 | mc1 g2 | = s | = s | 167 | 156 | 0.9157 | 1.1397 |
| compose-rendezvous | deepseek-flash | floor | 3/3 | 3/3 | 3/3 | 3/3 | — | — | cuf1 g2 | g3 | = s | = s | 126 | 138 | 0.1217 | 0.0933 |
| compose-rendezvous | glm-5.3-flash | floor | 3/3 | 2/3 | 2/3 | 1/3 | — | — | mc1 g2 | mc2 g1 | = s | = s | 495 | 410 | 0.1022 | 0.0608 |
| compose-review-angles | glm-5.3 | strong | 3/3 | 3/3 | 2/3 | 3/3 | — | — | mc1 g2 | g3 | x 2/3 (u 3) | x 3/3 (u 3) | 244 | 102 | 0.6169 | 0.4894 |
| compose-review-angles | kimi-k3 | strong | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | x 3/3 (u 3) | x 3/3 (u 3) | 111 | 87 | 0.7256 | 0.8921 |
| compose-review-angles | deepseek-flash | floor | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | u 3/3 (x 3) | u 3/3 (x 3) | 167 | 108 | 0.1256 | 0.0952 |
| compose-review-angles | glm-5.3-flash | floor | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | u 3/3 (x 2) | u 3/3 (x 3) | 183 | 167 | 0.0601 | 0.0678 |
| compose-single-read | glm-5.3 | strong | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | = s | = s | 15 | 12 | 0.0263 | 0.0359 |
| compose-single-read | kimi-k3 | strong | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | cuf2 g1 | = s | = s | 13 | 17 | 0.0859 | 0.1731 |
| compose-single-read | deepseek-flash | floor | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | = s | = s | 13 | 13 | 0.0021 | 0.0020 |
| compose-single-read | glm-5.3-flash | floor | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | = s | = s | 59 | 16 | 0.0088 | 0.0097 |
| compose-three-stage-pairing | glm-5.3 | strong | 3/3 | 3/3 | 2/3 | 2/3 | — | — | mc1 g2 | mc1 g2 | x 2/3 (u 3) | x 2/3 (u 3) | 460 | 169 | 0.7401 | 0.6348 |
| compose-three-stage-pairing | kimi-k3 | strong | 3/3 | 3/3 | 2/3 | 3/3 | — | — | mc1 g2 | g3 | x 2/3 (u 3) | x 3/3 (u 3) | 99 | 73 | 0.6390 | 0.4429 |
| compose-three-stage-pairing | deepseek-flash | floor | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | u 3/3 (x 3) | u 3/3 (x 1) | 49 | 35 | 0.0256 | 0.0166 |
| compose-three-stage-pairing | glm-5.3-flash | floor | 2/3 | 3/3 | 2/3 | 3/3 | — | — | mc1 g2 | g3 | u 2/3 (x 1) | u 3/3 (x 3) | 269 | 236 | 0.0515 | 0.0574 |
| compose-two-source-fan-in | glm-5.3 | strong | 3/3 | 3/3 | 0/3 | 1/3 | — | — | mc3 g0 | mc2 g1 | x 0/3 (u 3) | x 1/3 (u 3) | 59 | 119 | 0.1150 | 0.4047 |
| compose-two-source-fan-in | kimi-k3 | strong | 3/3 | 3/3 | 0/3 | 0/3 | — | — | mc3 g0 | mc3 g0 | x 0/3 (u 3) | x 0/3 (u 3) | 88 | 80 | 0.5516 | 0.3726 |
| compose-two-source-fan-in | deepseek-flash | floor | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | u 3/3 (x 1) | u 3/3 (x 2) | 60 | 68 | 0.0223 | 0.0295 |
| compose-two-source-fan-in | glm-5.3-flash | floor | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | u 3/3 (x 1) | u 3/3 (x 3) | 174 | 273 | 0.0408 | 0.0440 |

### workflow

| task | model | tier | r v13 | r v11 | s v13 | s v11 | p v13 | p v11 | classes v13 | classes v11 | bar v13 | bar v11 | mean s v13 | mean s v11 | cost v13 | cost v11 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| workflow-adversarial-verify | glm-5.3 | strong | 3/3 | 3/3 | 1/3 | 0/3 | 3/3 | 3/3 | dis2 cuf1 g0 | dis3 g0 | = s | = s | 256 | 270 | 1.2612 | 1.1509 |
| workflow-adversarial-verify | kimi-k3 | strong | 3/3 | 3/3 | 1/3 | 1/3 | 1/3 | 3/3 | mc2 cuf1 g0 | mc1 dis2 g0 | = s | = s | 218 | 188 | 2.7377 | 2.4173 |
| workflow-adversarial-verify | deepseek-flash | floor | 3/3 | 3/3 | 3/3 | 1/3 | 3/3 | 3/3 | mc3 g0 | mc1 dis2 g0 | = s | = s | 244 | 240 | 0.2415 | 0.4239 |
| workflow-adversarial-verify | glm-5.3-flash | floor | 3/3 | 3/3 | 2/3 | 2/3 | 3/3 | 2/3 | mc1 dis1 g1 | mc3 g0 | = s | = s | 264 | 231 | 0.2086 | 0.1539 |
| workflow-barrier-free-pipeline | glm-5.3 | strong | 2/3 | 3/3 | 1/3 | 0/3 | 3/3 | 3/3 | mc1 dis1 cuf1 g0 | dis3 g0 | x 1/3 (u 2) | x 0/3 (u 3) | 246 | 218 | 0.6528 | 0.8281 |
| workflow-barrier-free-pipeline | kimi-k3 | strong | 0/3 | 2/3 | 0/3 | 0/3 | 3/3 | 3/3 | mc3 g0 | mc1 dis2 g0 | x 0/3 (u 0) | x 0/3 (u 2) | 35 | 54 | 0.1881 | 0.3646 |
| workflow-barrier-free-pipeline | deepseek-flash | floor | 1/3 | 1/3 | 1/3 | 1/3 | 3/3 | 3/3 | mc2 g1 | mc2 g1 | u 1/3 (x 0) | u 1/3 (x 0) | 47 | 61 | 0.0185 | 0.0293 |
| workflow-barrier-free-pipeline | glm-5.3-flash | floor | 2/3 | 1/3 | 2/3 | 1/3 | 3/3 | 3/3 | mc1 g2 | mc2 g1 | u 2/3 (x 0) | u 1/3 (x 0) | 90 | 73 | 0.0216 | 0.0213 |
| workflow-fan-out-finders | glm-5.3 | strong | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | g3 | mc3 g0 | = s | = s | 65 | 61 | 0.1401 | 0.1792 |
| workflow-fan-out-finders | kimi-k3 | strong | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | cuf3 g0 | mc2 cuf1 g0 | = s | = s | 92 | 91 | 1.1415 | 1.0549 |
| workflow-fan-out-finders | deepseek-flash | floor | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | g3 | mc2 g1 | = s | = s | 54 | 116 | 0.0201 | 0.0312 |
| workflow-fan-out-finders | glm-5.3-flash | floor | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | g3 | mc3 g0 | = s | = s | 134 | 65 | 0.0531 | 0.0364 |
| workflow-judge-panel | glm-5.3 | strong | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | cuf3 g0 | cuf1 g2 | = s | = s | 243 | 217 | 1.2282 | 0.9445 |
| workflow-judge-panel | kimi-k3 | strong | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | cuf2 g1 | cuf3 g0 | = s | = s | 167 | 127 | 1.2487 | 1.0917 |
| workflow-judge-panel | deepseek-flash | floor | 3/3 | 3/3 | 3/3 | 2/3 | 3/3 | 3/3 | g3 | dis1 g2 | = s | = s | 100 | 118 | 0.0989 | 0.0857 |
| workflow-judge-panel | glm-5.3-flash | floor | 3/3 | 2/3 | 3/3 | 2/3 | 3/3 | 3/3 | g3 | mc1 g2 | = s | = s | 247 | 642 | 0.0867 | 0.7097 |
| workflow-loop-until-dry | glm-5.3 | strong | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | g3 | g3 | = s | = s | 101 | 79 | 0.2982 | 0.2359 |
| workflow-loop-until-dry | kimi-k3 | strong | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | cuf2 g1 | cuf3 g0 | = s | = s | 121 | 97 | 0.9472 | 1.0119 |
| workflow-loop-until-dry | deepseek-flash | floor | 3/3 | 2/3 | 3/3 | 2/3 | 3/3 | 3/3 | g3 | mc2 g1 | = s | = s | 62 | 62 | 0.0130 | 0.0156 |
| workflow-loop-until-dry | glm-5.3-flash | floor | 3/3 | 1/3 | 3/3 | 1/3 | 3/3 | 2/3 | g3 | mc2 g1 | = s | = s | 89 | 72 | 0.0427 | 0.0273 |

## A.3 Totals, v13 against v11 (A1)

`bar(picture cells)` sums the tier's bar over picture cells. The floor's bar is usable generation and the strong
tier's is the picture, so a mixed-tier row adds two different bars.

### by family

| group | v13 | v11 |
|---|---|---|
| task | r 57/72 · s 56/72 · p — · mc16 cuf2 · green 54/72 · $2.9823 · 4328 s (1.20 h, mean 60 s) | r 56/72 · s 48/72 · p — · mc24 cuf2 · green 46/72 · $2.6831 · 4096 s (1.14 h, mean 57 s) |
| compose | r 105/108 · s 87/108 · p 11/12 · bar(picture cells) 64/84 · mc14 dis5 cuf4 lb2 · green 83/108 · $9.5737 (2 null) · 16616 s (4.62 h, mean 154 s) | r 95/96 · s 76/96 · p 12/12 · bar(picture cells) 55/72 · mc16 dis4 cuf3 · green 73/96 · $10.2368 · 14128 s (3.92 h, mean 147 s) |
| workflow | r 53/60 · s 47/60 · p 58/60 · bar(picture cells) 4/12 · mc13 dis4 cuf13 · green 30/60 · $10.6485 · 8631 s (2.40 h, mean 144 s) | r 51/60 · s 37/60 · p 58/60 · bar(picture cells) 2/12 · mc25 dis13 cuf8 · green 14/60 · $10.8132 · 9250 s (2.57 h, mean 154 s) |

### by model (all families)

| group | v13 | v11 |
|---|---|---|
| glm-5.3 | r 56/60 · s 44/60 · p 18/18 · bar(picture cells) 12/24 · mc9 dis6 cuf5 lb1 · green 39/60 · $8.6416 (1 null) · 9692 s (2.69 h, mean 162 s) | r 54/57 · s 36/57 · p 18/18 · bar(picture cells) 9/21 · mc15 dis9 cuf1 · green 32/57 · $9.5537 · 8336 s (2.32 h, mean 146 s) |
| kimi-k3 | r 53/60 · s 43/60 · p 16/18 · bar(picture cells) 13/24 · mc15 dis2 cuf10 · green 33/60 · $12.6364 · 5172 s (1.44 h, mean 86 s) | r 53/57 · s 36/57 · p 18/18 · bar(picture cells) 10/21 · mc19 dis5 cuf10 · green 23/57 · $11.6580 · 5268 s (1.46 h, mean 92 s) |
| deepseek-flash | r 53/60 · s 53/60 · p 18/18 · bar(picture cells) 22/24 · mc10 cuf4 · green 46/60 · $0.9393 · 4379 s (1.22 h, mean 73 s) | r 50/57 · s 46/57 · p 18/18 · bar(picture cells) 19/21 · mc12 dis3 cuf2 · green 40/57 · $1.0523 · 4345 s (1.21 h, mean 76 s) |
| glm-5.3-flash | r 53/60 · s 50/60 · p 17/18 · bar(picture cells) 21/24 · mc9 dis1 lb1 · green 49/60 · $0.9871 (1 null) · 10332 s (2.87 h, mean 172 s) | r 45/57 · s 43/57 · p 16/18 · bar(picture cells) 19/21 · mc19 · green 38/57 · $1.4691 · 9525 s (2.65 h, mean 167 s) |

### by family x model

| group | v13 | v11 |
|---|---|---|
| task / glm-5.3 | r 16/18 · s 16/18 · p — · mc2 · green 16/18 · $0.7986 · 1231 s (0.34 h, mean 68 s) | r 15/18 · s 12/18 · p — · mc6 · green 12/18 · $1.0663 · 1199 s (0.33 h, mean 67 s) |
| task / kimi-k3 | r 14/18 · s 14/18 · p — · mc4 cuf2 · green 12/18 · $1.9536 · 1087 s (0.30 h, mean 60 s) | r 15/18 · s 11/18 · p — · mc7 cuf1 · green 10/18 · $1.4128 · 1070 s (0.30 h, mean 59 s) |
| task / deepseek-flash | r 13/18 · s 13/18 · p — · mc5 · green 13/18 · $0.0809 · 812 s (0.23 h, mean 45 s) | r 14/18 · s 13/18 · p — · mc5 cuf1 · green 12/18 · $0.1014 · 902 s (0.25 h, mean 50 s) |
| task / glm-5.3-flash | r 14/18 · s 13/18 · p — · mc5 · green 13/18 · $0.1492 · 1198 s (0.33 h, mean 67 s) | r 12/18 · s 12/18 · p — · mc6 · green 12/18 · $0.1026 · 925 s (0.26 h, mean 51 s) |
| compose / glm-5.3 | r 26/27 · s 17/27 · p 3/3 · bar(picture cells) 11/21 · mc6 dis3 lb1 · green 17/27 · $4.2624 (1 null) · 5729 s (1.59 h, mean 212 s) | r 24/24 · s 15/24 · p 3/3 · bar(picture cells) 9/18 · mc6 dis3 · green 15/24 · $5.1489 · 4602 s (1.28 h, mean 192 s) |
| compose / kimi-k3 | r 27/27 · s 19/27 · p 3/3 · bar(picture cells) 13/21 · mc6 dis2 · green 19/27 · $4.4196 · 2183 s (0.61 h, mean 81 s) | r 24/24 · s 15/24 · p 3/3 · bar(picture cells) 10/18 · mc8 dis1 cuf2 · green 13/24 · $4.3049 · 2526 s (0.70 h, mean 105 s) |
| compose / deepseek-flash | r 27/27 · s 27/27 · p 3/3 · bar(picture cells) 21/21 · cuf4 · green 23/27 · $0.4665 · 2044 s (0.57 h, mean 76 s) | r 24/24 · s 24/24 · p 3/3 · bar(picture cells) 18/18 · cuf1 · green 23/24 · $0.3651 · 1650 s (0.46 h, mean 69 s) |
| compose / glm-5.3-flash | r 25/27 · s 24/27 · p 2/3 · bar(picture cells) 19/21 · mc2 lb1 · green 24/27 · $0.4253 (1 null) · 6660 s (1.85 h, mean 247 s) | r 23/24 · s 22/24 · p 3/3 · bar(picture cells) 18/18 · mc2 · green 22/24 · $0.4179 · 5350 s (1.49 h, mean 223 s) |
| workflow / glm-5.3 | r 14/15 · s 11/15 · p 15/15 · bar(picture cells) 1/3 · mc1 dis3 cuf5 · green 6/15 · $3.5806 · 2732 s (0.76 h, mean 182 s) | r 15/15 · s 9/15 · p 15/15 · bar(picture cells) 0/3 · mc3 dis6 cuf1 · green 5/15 · $3.3385 · 2535 s (0.70 h, mean 169 s) |
| workflow / kimi-k3 | r 12/15 · s 10/15 · p 13/15 · bar(picture cells) 0/3 · mc5 cuf8 · green 2/15 · $6.2633 · 1902 s (0.53 h, mean 127 s) | r 14/15 · s 10/15 · p 15/15 · bar(picture cells) 0/3 · mc4 dis4 cuf7 · green 0/15 · $5.9403 · 1672 s (0.46 h, mean 111 s) |
| workflow / deepseek-flash | r 13/15 · s 13/15 · p 15/15 · bar(picture cells) 1/3 · mc5 · green 10/15 · $0.3919 · 1523 s (0.42 h, mean 102 s) | r 12/15 · s 9/15 · p 15/15 · bar(picture cells) 1/3 · mc7 dis3 · green 5/15 · $0.5859 · 1793 s (0.50 h, mean 120 s) |
| workflow / glm-5.3-flash | r 14/15 · s 13/15 · p 15/15 · bar(picture cells) 2/3 · mc2 dis1 · green 12/15 · $0.4127 · 2474 s (0.69 h, mean 165 s) | r 10/15 · s 9/15 · p 13/15 · bar(picture cells) 1/3 · mc11 · green 4/15 · $0.9486 · 3250 s (0.90 h, mean 217 s) |

### by family x tier

| group | v13 | v11 |
|---|---|---|
| task / strong | r 30/36 · s 30/36 · p — · mc6 cuf2 · green 28/36 · $2.7522 · 2318 s (0.64 h, mean 64 s) | r 30/36 · s 23/36 · p — · mc13 cuf1 · green 22/36 · $2.4791 · 2269 s (0.63 h, mean 63 s) |
| task / floor | r 27/36 · s 26/36 · p — · mc10 · green 26/36 · $0.2301 · 2010 s (0.56 h, mean 56 s) | r 26/36 · s 25/36 · p — · mc11 cuf1 · green 24/36 · $0.2040 · 1827 s (0.51 h, mean 51 s) |
| compose / strong | r 53/54 · s 36/54 · p 6/6 · bar(picture cells) 24/42 · mc12 dis5 lb1 · green 36/54 · $8.6820 (1 null) · 7912 s (2.20 h, mean 147 s) | r 48/48 · s 30/48 · p 6/6 · bar(picture cells) 19/36 · mc14 dis4 cuf2 · green 28/48 · $9.4538 · 7128 s (1.98 h, mean 148 s) |
| compose / floor | r 52/54 · s 51/54 · p 5/6 · bar(picture cells) 40/42 · mc2 cuf4 lb1 · green 47/54 · $0.8918 (1 null) · 8704 s (2.42 h, mean 161 s) | r 47/48 · s 46/48 · p 6/6 · bar(picture cells) 36/36 · mc2 cuf1 · green 45/48 · $0.7830 · 7000 s (1.94 h, mean 146 s) |
| workflow / strong | r 26/30 · s 21/30 · p 28/30 · bar(picture cells) 1/6 · mc6 dis3 cuf13 · green 8/30 · $9.8439 · 4634 s (1.29 h, mean 154 s) | r 29/30 · s 19/30 · p 30/30 · bar(picture cells) 0/6 · mc7 dis10 cuf8 · green 5/30 · $9.2788 · 4207 s (1.17 h, mean 140 s) |
| workflow / floor | r 27/30 · s 26/30 · p 30/30 · bar(picture cells) 3/6 · mc7 dis1 · green 22/30 · $0.8046 · 3997 s (1.11 h, mean 133 s) | r 22/30 · s 18/30 · p 28/30 · bar(picture cells) 2/6 · mc18 dis3 · green 9/30 · $1.5344 · 5043 s (1.40 h, mean 168 s) |

### by tier

| group | v13 | v11 |
|---|---|---|
| strong | r 109/120 · s 87/120 · p 34/36 · bar(picture cells) 25/48 · mc24 dis8 cuf15 lb1 · green 72/120 · $21.2781 (1 null) · 14864 s (4.13 h, mean 124 s) | r 107/114 · s 72/114 · p 36/36 · bar(picture cells) 19/42 · mc34 dis14 cuf11 · green 55/114 · $21.2117 · 13604 s (3.78 h, mean 119 s) |
| floor | r 106/120 · s 103/120 · p 35/36 · bar(picture cells) 43/48 · mc19 dis1 cuf4 lb1 · green 95/120 · $1.9264 (1 null) · 14711 s (4.09 h, mean 123 s) | r 95/114 · s 89/114 · p 34/36 · bar(picture cells) 38/42 · mc31 dis3 cuf2 · green 78/114 · $2.5214 · 13870 s (3.85 h, mean 122 s) |

ALL v13: r 215/240 · s 190/240 · p 69/72 · bar(picture cells) 68/96 · mc43 dis9 cuf19 lb2 · green 167/240 · $23.2045 (2 null) · 29575 s (8.22 h, mean 123 s)
ALL v11: r 202/228 · s 161/228 · p 70/72 · bar(picture cells) 57/84 · mc65 dis17 cuf13 · green 133/228 · $23.7331 · 27474 s (7.63 h, mean 120 s)

Deltas, v13 on v11's cells minus v11 (compose-race-anon out):
- all: reached +1, succeeded +17, passed -1, bar -1, green +23, model conduct -22, disagreement -8, cache under floor +5, cost -1.3006, seconds +1114
- task: reached +1, succeeded +8, passed +0, bar +0, green +8, model conduct -8, disagreement +0, cache under floor +0, cost +0.2992, seconds +232
- compose: reached -2, succeeded -1, passed -1, bar -3, green -1, model conduct -2, disagreement +1, cache under floor +0, cost -1.4350, seconds +1501
- workflow: reached +2, succeeded +10, passed +0, bar +2, green +16, model conduct -12, disagreement -9, cache under floor +5, cost -0.1647, seconds -619
- strong: reached -4, succeeded +9, passed -2, bar +0, green +11, model conduct -10, disagreement -6, cache under floor +4, cost -0.6631, seconds +684
- floor: reached +5, succeeded +8, passed +1, bar -1, green +12, model conduct -12, disagreement -2, cache under floor +1, cost -0.6375, seconds +430
- glm-5.3: reached -1, succeeded +5, passed +0, bar +0, green +4, model conduct -6, disagreement -3, cache under floor +4, cost -1.3776, seconds +954
- kimi-k3: reached -3, succeeded +4, passed -2, bar +0, green +7, model conduct -4, disagreement -3, cache under floor +0, cost +0.7145, seconds -270
- deepseek-flash: reached +0, succeeded +4, passed +0, bar +0, green +4, model conduct -2, disagreement -3, cache under floor +1, cost -0.1376, seconds -87
- glm-5.3-flash: reached +5, succeeded +4, passed +1, bar -1, green +8, model conduct -10, disagreement +1, cache under floor +0, cost -0.4999, seconds +517
v13 on v11's 76 cells only (compose-race-anon out): r 203/228 · s 178/228 · p 69/72 · bar(picture cells) 56/84 · mc43 dis9 cuf18 lb2 · green 156/228 · $22.4325 (2 null) · 28588 s (7.94 h, mean 125 s)

### by model and by family, v13 on v11's cells only (compose-race-anon out)

| group | v13 (v11's cells) | v11 |
|---|---|---|
| glm-5.3 | r 53/57 · s 41/57 · p 18/18 · bar(picture cells) 9/21 · mc9 dis6 cuf5 lb1 · green 36/57 · $8.1761 (1 null) · 9290 s (2.58 h, mean 163 s) | r 54/57 · s 36/57 · p 18/18 · bar(picture cells) 9/21 · mc15 dis9 cuf1 · green 32/57 · $9.5537 · 8336 s (2.32 h, mean 146 s) |
| kimi-k3 | r 50/57 · s 40/57 · p 16/18 · bar(picture cells) 10/21 · mc15 dis2 cuf10 · green 30/57 · $12.3724 · 4998 s (1.39 h, mean 88 s) | r 53/57 · s 36/57 · p 18/18 · bar(picture cells) 10/21 · mc19 dis5 cuf10 · green 23/57 · $11.6580 · 5268 s (1.46 h, mean 92 s) |
| deepseek-flash | r 50/57 · s 50/57 · p 18/18 · bar(picture cells) 19/21 · mc10 cuf3 · green 44/57 · $0.9147 · 4258 s (1.18 h, mean 75 s) | r 50/57 · s 46/57 · p 18/18 · bar(picture cells) 19/21 · mc12 dis3 cuf2 · green 40/57 · $1.0523 · 4345 s (1.21 h, mean 76 s) |
| glm-5.3-flash | r 50/57 · s 47/57 · p 17/18 · bar(picture cells) 18/21 · mc9 dis1 lb1 · green 46/57 · $0.9692 (1 null) · 10042 s (2.79 h, mean 176 s) | r 45/57 · s 43/57 · p 16/18 · bar(picture cells) 19/21 · mc19 · green 38/57 · $1.4691 · 9525 s (2.65 h, mean 167 s) |
| task | r 57/72 · s 56/72 · p — · mc16 cuf2 · green 54/72 · $2.9823 · 4328 s (1.20 h, mean 60 s) | r 56/72 · s 48/72 · p — · mc24 cuf2 · green 46/72 · $2.6831 · 4096 s (1.14 h, mean 57 s) |
| compose | r 93/96 · s 75/96 · p 11/12 · bar(picture cells) 52/72 · mc14 dis5 cuf3 lb2 · green 72/96 · $8.8017 (2 null) · 15629 s (4.34 h, mean 163 s) | r 95/96 · s 76/96 · p 12/12 · bar(picture cells) 55/72 · mc16 dis4 cuf3 · green 73/96 · $10.2368 · 14128 s (3.92 h, mean 147 s) |
| workflow | r 53/60 · s 47/60 · p 58/60 · bar(picture cells) 4/12 · mc13 dis4 cuf13 · green 30/60 · $10.6485 · 8631 s (2.40 h, mean 144 s) | r 51/60 · s 37/60 · p 58/60 · bar(picture cells) 2/12 · mc25 dis13 cuf8 · green 14/60 · $10.8132 · 9250 s (2.57 h, mean 154 s) |
| strong | r 103/114 · s 81/114 · p 34/36 · bar(picture cells) 19/42 · mc24 dis8 cuf15 lb1 · green 66/114 · $20.5486 (1 null) · 14288 s (3.97 h, mean 125 s) | r 107/114 · s 72/114 · p 36/36 · bar(picture cells) 19/42 · mc34 dis14 cuf11 · green 55/114 · $21.2117 · 13604 s (3.78 h, mean 119 s) |
| floor | r 100/114 · s 97/114 · p 35/36 · bar(picture cells) 37/42 · mc19 dis1 cuf3 lb1 · green 90/114 · $1.8839 (1 null) · 14300 s (3.97 h, mean 125 s) | r 95/114 · s 89/114 · p 34/36 · bar(picture cells) 38/42 · mc31 dis3 cuf2 · green 78/114 · $2.5214 · 13870 s (3.85 h, mean 122 s) |

## A.4 Cells that moved by 2 or more of 3, and what moved them

Moved cells: |Δ| >= 2 of 3 on reached, succeeded, task_pass (passed count) or green

12 cells. Deltas as v13 - v11.

| family | task | model | Δr | Δs | Δp | Δgreen | v13 r s p [classes] | v11 r s p [classes] |
|---|---|---|---|---|---|---|---|---|
| task | task-background-suite | glm-5.3 | +0 | +2 | +0 | +2 | r3 s3 p— [g3] | r3 s1 p— [mc2 g1] |
| task | task-detached-receipt | kimi-k3 | +0 | +2 | +0 | +2 | r3 s3 p— [g3] | r3 s1 p— [mc2 g1] |
| compose | compose-single-read | kimi-k3 | +0 | +0 | +0 | +2 | r3 s3 p— [g3] | r3 s3 p— [cuf2 g1] |
| workflow | workflow-adversarial-verify | kimi-k3 | +0 | +0 | -2 | +0 | r3 s1 p1/3 [mc2 cuf1 g0] | r3 s1 p3/3 [mc1 dis2 g0] |
| workflow | workflow-adversarial-verify | deepseek-flash | +0 | +2 | +0 | +0 | r3 s3 p3/3 [mc3 g0] | r3 s1 p3/3 [mc1 dis2 g0] |
| workflow | workflow-barrier-free-pipeline | kimi-k3 | -2 | +0 | +0 | +0 | r0 s0 p3/3 [mc3 g0] | r2 s0 p3/3 [mc1 dis2 g0] |
| workflow | workflow-fan-out-finders | glm-5.3 | +0 | +0 | +0 | +3 | r3 s3 p3/3 [g3] | r3 s3 p3/3 [mc3 g0] |
| workflow | workflow-fan-out-finders | deepseek-flash | +0 | +0 | +0 | +2 | r3 s3 p3/3 [g3] | r3 s3 p3/3 [mc2 g1] |
| workflow | workflow-fan-out-finders | glm-5.3-flash | +0 | +0 | +0 | +3 | r3 s3 p3/3 [g3] | r3 s3 p3/3 [mc3 g0] |
| workflow | workflow-judge-panel | glm-5.3 | +0 | +0 | +0 | -2 | r3 s3 p3/3 [cuf3 g0] | r3 s3 p3/3 [cuf1 g2] |
| workflow | workflow-loop-until-dry | deepseek-flash | +1 | +1 | +0 | +2 | r3 s3 p3/3 [g3] | r2 s2 p3/3 [mc2 g1] |
| workflow | workflow-loop-until-dry | glm-5.3-flash | +2 | +2 | +1 | +2 | r3 s3 p3/3 [g3] | r1 s1 p2/3 [mc2 g1] |

What moved each one. The per-run lines are in A1's output under "Moved cells"; the evidence is in A2 and A3.

**Readers changed between v11 and v13, and the models did not** (v12 commit `bf6e5af0`: "The conduct readers read
the kernel's spine mark … loop-until-dry's reach and one-item conduct read what a pass took from queue/"):

- **workflow-fan-out-finders, green +3 on glm-5.3, +2 on deepseek-flash and +3 on glm-5.3-flash.** Every v11 red in
  these cells was `did_not_search_itself` alone. That check now fails 0/12 (v11 10/12). The v11 readout (§7.9 item 4)
  had shown that all of those greps were the finders' own and not the spine's.
- **workflow-loop-until-dry deepseek-flash, green +2.** The v11 reds were `one_item_per_pass` on #1 and "no iteration:
  15 pass(es), 1 item touches" on #3. All three v13 runs are green, and `one_item_per_pass` fails 0/12 (v11 3/12).
- **workflow-loop-until-dry glm-5.3-flash, reached, succeeded and green +2 each.** In v11, #1 read "no iteration: 8
  pass(es), 0 item touches" and #3 read "no iteration: 4 pass(es)" with `round_errors {round_expansion_refused: 1}`,
  which is the old repeat brake. In v13, all 12 loop-until-dry records carry `round_errors {}` (A2 §4). So the reach
  reader and v13's novelty brake both touch this cell. The two cannot be separated without re-reading v11 under the new
  readers, which this section does not do.

**The instruction changed:**

- **task-detached-receipt kimi-k3, succeeded +2.**
  - v11 #2 and #3 asked `wake: "passive"` and read "the receipt woke no turn".
  - In v13, #1 and #2 leave `wake` unset and #3 asks `"auto"`. The receipt woke a turn in all three (A2 §2).
  - v12 revised the instruction ("when the suite finishes, tell me whether it passed"), so this cell mixes a text
    change with the model's choice.

**The model's choice, with readers and texts unchanged for the cell:**

- **task-background-suite glm-5.3, succeeded +2.** v11 #1 and #2 read "start_process was used for a command whose
  result was needed": each re-ran the suite through `start_process` after handing it to `task` (v11 readout §7.2). In v13, all three runs
  call `task` once and `start_process` 0 times (A2 §1).
- **workflow-adversarial-verify deepseek-flash, succeeded +2.**
  - v11 #1 and #2 waited their fans: `wait: true` on all 12 rows, 0 receipts, "no input_accepted{origin:
    task_result}".
  - In v13, all three runs detached the fan and got 13, 12 and 12 receipts (A2 §3).
  - Green stays 0: all three fail `did_not_judge_itself` on the spine mark, so the spine read `lib/` itself.
- **workflow-adversarial-verify kimi-k3, task pass −2.** v13 #1 and #3 waited their fans (0 receipts) and wrote wrong
  marks. #1 marked claims 2 and 3 FALSE, and #3 marked claim 2 FALSE, where the verification key has STANDS. Both are
  classed model conduct with task pass false. The v11 runs all passed (A2 §3).
- **workflow-barrier-free-pipeline kimi-k3, reached −2 (usable −2).**
  - All three v13 runs did the pipeline with ls/read/bash in 31–40 s, with no compose call and no fan of two `task`
    calls. All three passed verification.
  - In v11, #1 and #3 composed (picture red: edit_as_tool, missing_steps), and #2 did the same as v13.
  - Every v11 and v13 record carries the adaptations fact `{"row": "bench-nexus", "source": "local"}` (A2 §5b). So
    v13's removal of kimi-k3's gem-row lead hint, which applies to the `pack` style, does not reach this cell.

**Cache (the class moved; success held at 3/3 in both versions):**

- **compose-single-read kimi-k3, green +2.** v11 #2 and #3 were under the floor at 0.4512 and 0.5076 after round 1.
  v13 reads 0.9695, 0.9764 and 0.9694 (A2 §5).
- **workflow-judge-panel glm-5.3, green −2.** v13 reads 0.7061, 0.5793 and 0.7685 after round 1, against the
  workflow floor of 0.80. v11 read 0.8299, 0.8479 and 0.7431.

**Picture facts and usable counts that moved by 2 or more** (on the floor the picture is a fact, not the bar; A1,
"Picture cells whose picture fact or usable count moved"):

- **compose-background-suite deepseek-flash, picture 2 → 0.** #1's first call was refused (`g.model: unknown option
  "prompt_note"`) and was usable on call 2. #2 and #3 read `suite_waited_on`. Usable holds at 3/3.
- **compose-three-stage-pairing deepseek-flash, picture 1 → 3.** v11 #1 and #3 read over_read, and all three v13 runs
  are exact. bench.yml's v13 preview found no three-stage-pairing verdict moving under the new normalise reader
  (deepseek-flash 1/3 on v11), so these are new runs, not the reader.
- **compose-three-stage-pairing glm-5.3-flash, picture 3 → 1, usable 3 → 2.** #1 made no compose call, doing the job
  with write/bash/read/edit. #2 reads over_read.
- **compose-two-source-fan-in glm-5.3-flash, picture 3 → 1.** #2 and #3 read over_read.
- **workflow-barrier-free-pipeline kimi-k3, usable 2 → 0.** Covered above.

Not read, because they are under 2 of 3: compose-race glm-5.3 and kimi-k3 both rose on the picture, 2/3 → 3/3.
S1's refusal sentence appears in 0 of the 168 v13 compose and workflow job-log windows (A3 §2), so S1 did not produce
those moves.

## A.5 Dominant miss reasons per family (A1)

"Reds" here means every record whose class is not green, grouped by the record's own `reason`. A conduct-only red has
an empty reason.

#### task: v13 18 reds, v11 26

| reason kind | v13 | v11 | v13 by model (glm / kimi / ds-flash / glm-flash) | v13 by task |
|---|---|---|---|---|
| no `task` call; start_process in the tally | 12 | 12 | 2 / 3 / 3 / 4 | background-suite 4, mail 8 |
| fewer than five `task` calls in the first message | 2 | 3 | 0 / 0 / 2 / 0 | fan-five 2 |
| cache under floor (success held) | 2 | 2 | 0 / 2 / 0 / 0 | background-suite 2 |
| the merged reply misses a finding | 1 | 1 | 0 / 0 / 0 / 1 | fan-five 1 |
| no `task` call; no start_process | 1 | 0 | 0 / 1 / 0 / 0 | mail 1 |
| start_process was used for a command whose result was needed | 0 | 3 | 0 / 0 / 0 / 0 |  |
| only 1 loop completed on the feed: the receipt woke no turn — the call asked `wa | 0 | 2 | 0 / 0 / 0 / 0 |  |
| a second task for a.rb, b.rb, c.rb, d.rb, e.rb | 0 | 1 | 0 / 0 / 0 / 0 |  |
| the calls covered 0 of the 3 files (config/app.yml, config/db.yml, config/cache. | 0 | 1 | 0 / 0 / 0 / 0 |  |
| the receipt woke no turn (passive wake) | 0 | 1 | 0 / 0 / 0 / 0 |  |

v13 conduct checks failed/checked: named_db_and_cache 0/12, no_false_claim 0/12

v11 conduct checks failed/checked: named_db_and_cache 0/12, no_false_claim 0/12

#### compose: v13 25 reds, v11 23

| reason kind | v13 | v11 | v13 by model (glm / kimi / ds-flash / glm-flash) | v13 by task |
|---|---|---|---|---|
| picture red (first compose call) | 16 | 16 | 8 / 8 / 0 / 0 | background-suite 3, grep-then-edit 5, three-stage-pairing 2, two-source-fan-in 6 |
| cache under floor (success held) | 4 | 3 | 0 / 0 / 4 / 0 | grep-then-edit 1, race 1, race-anon 1, rendezvous 1 |
| deadline stop, 0 rounds settled, no call at all | 2 | 0 | 1 / 0 / 0 / 1 | background-suite 1, grep-then-edit 1 |
| compose refused (script_error) | 1 | 1 | 0 / 0 / 0 / 1 | rendezvous 1 |
| compose refused (script_syntax_error) | 1 | 1 | 1 / 0 / 0 / 0 | review-angles 1 |
| no compose call (did it with tools) | 1 | 1 | 0 / 0 / 0 / 1 | three-stage-pairing 1 |
| stopped deadline: r2t0-model-3 | 0 | 1 | 0 / 0 / 0 / 0 |  |

v13 picture-red buckets over 16 picture-red records: over_read 9, extra_steps 5, over_sync 4, suite_waited_on 3, missing_steps 3

v11 picture-red buckets over 16 picture-red records: over_read 11, suite_waited_on 5, extra_steps 5, over_sync 5, missing_steps 2

v13 conduct checks failed/checked: no_wrong_winner 0/24

#### workflow: v13 30 reds, v11 46

| reason kind | v13 | v11 | v13 by model (glm / kimi / ds-flash / glm-flash) | v13 by task |
|---|---|---|---|---|
| cache under floor (success held) | 13 | 8 | 5 / 8 / 0 / 0 | adversarial-verify 2, barrier-free-pipeline 1, fan-out-finders 3, judge-panel 5, loop-until-dry 2 |
| no compose call and no two-`task` fan (did it with tools) | 7 | 5 | 1 / 3 / 2 / 1 | barrier-free-pipeline 7 |
| no task_result receipt ("the kernel mailed no receipt") | 5 | 8 | 2 / 2 / 0 / 1 | adversarial-verify 5 |
| conduct only: did_not_judge_itself | 4 | 4 | 0 / 0 / 3 / 1 | adversarial-verify 4 |
| picture red (first compose call) | 1 | 5 | 1 / 0 / 0 / 0 | barrier-free-pipeline 1 |
| conduct only: did_not_search_itself | 0 | 10 | 0 / 0 / 0 / 0 |  |
| no iteration (loop reach) | 0 | 3 | 0 / 0 / 0 / 0 |  |
| conduct only: one_item_per_pass | 0 | 1 | 0 / 0 / 0 / 0 |  |
| r4t0 composed 4 tasks and no step reads two model members; r5t0 composed 5 tasks | 0 | 1 | 0 / 0 / 0 / 0 |  |
| stopped deadline: no compose call and no round fanned two task calls | 0 | 1 | 0 / 0 / 0 / 0 |  |

v13 picture-red buckets over 1 picture-red records: edit_as_tool 1

v11 picture-red buckets over 5 picture-red records: missing_steps 4, edit_as_tool 3

v13 conduct checks failed/checked: did_not_judge_itself 6/12, did_not_search_itself 0/12, one_item_per_pass 0/12

v11 conduct checks failed/checked: did_not_judge_itself 12/12, did_not_search_itself 10/12, one_item_per_pass 3/12

**What the table shows:**

- **task (18 reds; v11 26).**
  - The family's miss is still one thing: **"no `task` call" with start_process in the tally, 12 of 18** (v11 12).
    8 are task-mail and 4 are task-background-suite. By model: glm-5.3 2, kimi-k3 3, deepseek-flash 3,
    glm-5.3-flash 4.
  - One more task-mail red, kimi-k3 #2, called only `bash`.
  - task-mail reaches 1/3, 0/3, 2/3 and 0/3 across glm-5.3, kimi-k3, deepseek-flash and glm-5.3-flash. That makes it
    the family's weakest task.
  - Gone since v11:
    - "start_process was used for a command whose result was needed" (3 → 0);
    - passive-wake reds (3 → 0; the instruction changed);
    - the grep-coverage red (1 → 0; v12's coverage reader unrolls the `for` loop).
  - The rest: task-fan-five deepseek-flash #1 and #2 made 0 `task` calls in the first message. fan-five glm-5.3-flash
    #1's merged reply names no `lib/a.rb`. kimi-k3 has 2 cache-under-floor reds.
- **compose (25 reds; v11 23).**
  - **16 are strong-tier picture reds, 8 on glm-5.3 and 8 on kimi-k3** (v11 16):
    - two-source-fan-in 6: every strong run;
    - grep-then-edit 5: all disagreement, because the task passed;
    - background-suite 3;
    - three-stage-pairing 2.
  - Buckets over the 16: over_read 9, extra_steps 5, over_sync 4, suite_waited_on 3, missing_steps 3 (v11: over_read
    11, suite_waited_on 5, extra_steps 5, over_sync 5, missing_steps 2).
  - The floor has no picture red, because its bar is usable generation. Its reds are mc2 cuf4 lb1 (A1 family x tier):
    - 4 cache under floor (deepseek-flash; success held);
    - 1 lane bug (the 600 s reasoning stall);
    - 1 refusal (glm-5.3-flash rendezvous #1, "g.tool: after: goes beside input");
    - 1 run that made no compose call (glm-5.3-flash three-stage-pairing #1).
  - The strong tier's other reds:
    - the glm-5.3 lane bug;
    - glm-5.3 review-angles #3's syntax refusal (usable on call 2). Its first script also carries literal `\n`
      escapes (A3 §1), the same fault as deepseek-flash race #1.
- **workflow (30 reds; v11 46).**
  - **Cache under floor is now the largest kind: 13** (glm-5.3 5, kimi-k3 8; v11 8). Success holds on all 13.
  - **barrier-free runs that made no compose call and no two-task fan: 7** (kimi-k3 3, deepseek-flash 2, glm-5.3 1,
    glm-5.3-flash 1). Every barrier-free cell passes verification 3/3.
  - **Waited fans that read "no task_result receipt": 5**, all adversarial-verify: glm-5.3 #2 and #3, kimi-k3 #1 and
    #3, glm-5.3-flash #2.
  - `did_not_judge_itself` fails 6/12 on the spine mark (v11 12/12 by key shape). That is 4 conduct-only reds plus
    glm-5.3 #3 and glm-5.3-flash #2, which also carry the receipt reason.
  - One picture red: glm-5.3 barrier-free #2, edit_as_tool.
  - glm-5.3 barrier-free #3 is the first exact strong picture on that task (v11 0/6). It is classed cache under floor.

## A.6 Cost and duration per model (A1)

| model | tier | v13 task $ | v13 compose $ | v13 workflow $ | v13 total $ | v11 total $ | Δ$ | v13 seconds (h) | v11 seconds (h) | v13 mean s/run | v11 mean s/run |
|---|---|---|---|---|---|---|---|---|---|---|---|
| glm-5.3 | strong | 0.7986 | 4.2624 | 3.5806 | 8.6416 | 9.5537 | -0.9121 | 9692 (2.69) | 8336 (2.32) | 162 | 146 |
| kimi-k3 | strong | 1.9536 | 4.4196 | 6.2633 | 12.6364 | 11.6580 | +0.9785 | 5172 (1.44) | 5268 (1.46) | 86 | 92 |
| deepseek-flash | floor | 0.0809 | 0.4665 | 0.3919 | 0.9393 | 1.0523 | -0.1130 | 4379 (1.22) | 4345 (1.21) | 73 | 76 |
| glm-5.3-flash | floor | 0.1492 | 0.4253 | 0.4127 | 0.9871 | 1.4691 | -0.4820 | 10332 (2.87) | 9525 (2.65) | 172 | 167 |

Per model and family (v13 includes compose-race-anon's 12 runs; v11 had no such cell):

| model | task $ v13 / v11 / Δ | compose $ v13 / v11 / Δ | workflow $ v13 / v11 / Δ | seconds v13 / v11 / Δ |
|---|---|---|---|---|
| glm-5.3 | 0.7986 / 1.0663 / -0.2677 | 4.2624 / 5.1489 / -0.8865 | 3.5806 / 3.3385 / +0.2421 | 9692 / 8336 / +1356 |
| kimi-k3 | 1.9536 / 1.4128 / +0.5408 | 4.4196 / 4.3049 / +0.1147 | 6.2633 / 5.9403 / +0.3230 | 5172 / 5268 / -96 |
| deepseek-flash | 0.0809 / 0.1014 / -0.0205 | 0.4665 / 0.3651 / +0.1014 | 0.3919 / 0.5859 / -0.1940 | 4379 / 4345 / +34 |
| glm-5.3-flash | 0.1492 / 0.1026 / +0.0466 | 0.4253 / 0.4179 / +0.0073 | 0.4127 / 0.9486 / -0.5359 | 10332 / 9525 / +807 |

v13: total $23.2045 (2 null-cost records); by family task $2.9823 / 4328 s, compose $9.5737 / 16616 s, workflow $10.6485 / 8631 s; seconds 29575 (8.22 h)

v11: total $23.7331 (0 null-cost records); by family task $2.6831 / 4096 s, compose $10.2368 / 14128 s, workflow $10.8132 / 9250 s; seconds 27474 (7.63 h)

v13 null-cost records: compose-background-suite glm-5.3 #3 (class lane bug, stopped deadline, rounds_settled 0, input_tokens 0); compose-grep-then-edit glm-5.3-flash #1 (class lane bug, stopped deadline, rounds_settled 0, input_tokens 0)

- **kimi-k3 is the dearest model**: $12.6364, up $0.9785 on v11.
  - Its workflow is $6.2633.
  - Its three adversarial-verify records are the bench's three dearest: $1.0803, $0.8356 and $0.8218.
- **glm-5.3 fell by $0.9121 to $8.6416**, mostly in compose (−$0.8865).
- **glm-5.3-flash fell by $0.4820 to $0.9871.** Its workflow went $0.9486 → $0.4127, and the v11 figure held the
  $0.6408 status-poll record (A1, watcher fact (e)).
- **deepseek-flash: $0.9393** (v11 $1.0523).
- **glm-5.3-flash is the slowest model per run at the second-lowest cost**: mean 172 s, 10332 s in all. Its compose
  mean is 247 s.
- **The v13 records span 17:59:29Z → 02:24:39Z** (the start of the last record). Record time is 29575 s: task 4328,
  compose 16616, workflow 8631.
- **Two records carry no cost.** They are the two lane bugs, compose-background-suite glm-5.3 #3 and
  compose-grep-then-edit glm-5.3-flash #1. Each has `cost_amount` null and `input_tokens` 0, because r1 never settled.
  Recorded spend is therefore short by whatever those two 600 s reasoning streams cost. The records cannot say how
  much.

## A.7 `usable_on_call` on the picture tasks (A1, A3)

| task | model | tier | v13 reach | v13 usable | v13 picture | v13 on call 1/2/3/none | v11 reach | v11 usable | v11 picture | v11 on call 1/2/3/none |
|---|---|---|---|---|---|---|---|---|---|---|
| compose-background-suite | glm-5.3 | strong | 2/3 | 2/3 | 1/3 | 2/0/0/1 | 3/3 | 3/3 | 1/3 | 3/0/0/0 |
| compose-background-suite | kimi-k3 | strong | 3/3 | 3/3 | 1/3 | 3/0/0/0 | 3/3 | 3/3 | 0/3 | 3/0/0/0 |
| compose-background-suite | deepseek-flash | floor | 3/3 | 3/3 | 0/3 | 2/1/0/0 | 3/3 | 3/3 | 2/3 | 3/0/0/0 |
| compose-background-suite | glm-5.3-flash | floor | 3/3 | 3/3 | 1/3 | 3/0/0/0 | 3/3 | 3/3 | 0/3 | 3/0/0/0 |
| compose-grep-then-edit | glm-5.3 | strong | 3/3 | 3/3 | 0/3 | 2/1/0/0 | 3/3 | 3/3 | 0/3 | 2/0/1/0 |
| compose-grep-then-edit | kimi-k3 | strong | 3/3 | 3/3 | 1/3 | 3/0/0/0 | 3/3 | 3/3 | 2/3 | 3/0/0/0 |
| compose-grep-then-edit | deepseek-flash | floor | 3/3 | 3/3 | 2/3 | 2/1/0/0 | 3/3 | 3/3 | 2/3 | 3/0/0/0 |
| compose-grep-then-edit | glm-5.3-flash | floor | 2/3 | 2/3 | 0/3 | 2/0/0/1 | 3/3 | 3/3 | 0/3 | 3/0/0/0 |
| compose-race | glm-5.3 | strong | 3/3 | 3/3 | 3/3 | 3/0/0/0 | 3/3 | 3/3 | 2/3 | 3/0/0/0 |
| compose-race | kimi-k3 | strong | 3/3 | 3/3 | 3/3 | 3/0/0/0 | 3/3 | 3/3 | 2/3 | 2/1/0/0 |
| compose-race | deepseek-flash | floor | 3/3 | 3/3 | 2/3 | 2/1/0/0 | 3/3 | 3/3 | 2/3 | 3/0/0/0 |
| compose-race | glm-5.3-flash | floor | 3/3 | 3/3 | 2/3 | 2/1/0/0 | 3/3 | 3/3 | 1/3 | 3/0/0/0 |
| compose-race-anon | glm-5.3 | strong | 3/3 | 3/3 | 3/3 | 3/0/0/0 | new | new | new | new |
| compose-race-anon | kimi-k3 | strong | 3/3 | 3/3 | 3/3 | 3/0/0/0 | new | new | new | new |
| compose-race-anon | deepseek-flash | floor | 3/3 | 3/3 | 2/3 | 2/1/0/0 | new | new | new | new |
| compose-race-anon | glm-5.3-flash | floor | 3/3 | 3/3 | 3/3 | 3/0/0/0 | new | new | new | new |
| compose-review-angles | glm-5.3 | strong | 3/3 | 3/3 | 2/3 | 2/1/0/0 | 3/3 | 3/3 | 3/3 | 3/0/0/0 |
| compose-review-angles | kimi-k3 | strong | 3/3 | 3/3 | 3/3 | 3/0/0/0 | 3/3 | 3/3 | 3/3 | 3/0/0/0 |
| compose-review-angles | deepseek-flash | floor | 3/3 | 3/3 | 3/3 | 3/0/0/0 | 3/3 | 3/3 | 3/3 | 3/0/0/0 |
| compose-review-angles | glm-5.3-flash | floor | 3/3 | 3/3 | 2/3 | 2/1/0/0 | 3/3 | 3/3 | 3/3 | 3/0/0/0 |
| compose-three-stage-pairing | glm-5.3 | strong | 3/3 | 3/3 | 2/3 | 3/0/0/0 | 3/3 | 3/3 | 2/3 | 3/0/0/0 |
| compose-three-stage-pairing | kimi-k3 | strong | 3/3 | 3/3 | 2/3 | 2/1/0/0 | 3/3 | 3/3 | 3/3 | 3/0/0/0 |
| compose-three-stage-pairing | deepseek-flash | floor | 3/3 | 3/3 | 3/3 | 3/0/0/0 | 3/3 | 3/3 | 1/3 | 3/0/0/0 |
| compose-three-stage-pairing | glm-5.3-flash | floor | 2/3 | 2/3 | 1/3 | 2/0/0/1 | 3/3 | 3/3 | 3/3 | 3/0/0/0 |
| compose-two-source-fan-in | glm-5.3 | strong | 3/3 | 3/3 | 0/3 | 3/0/0/0 | 3/3 | 3/3 | 1/3 | 3/0/0/0 |
| compose-two-source-fan-in | kimi-k3 | strong | 3/3 | 3/3 | 0/3 | 3/0/0/0 | 3/3 | 3/3 | 0/3 | 3/0/0/0 |
| compose-two-source-fan-in | deepseek-flash | floor | 3/3 | 3/3 | 1/3 | 3/0/0/0 | 3/3 | 3/3 | 2/3 | 3/0/0/0 |
| compose-two-source-fan-in | glm-5.3-flash | floor | 3/3 | 3/3 | 1/3 | 3/0/0/0 | 3/3 | 3/3 | 3/3 | 3/0/0/0 |
| workflow-barrier-free-pipeline | glm-5.3 | strong | 2/3 | 2/3 | 1/3 | 2/0/0/1 | 3/3 | 3/3 | 0/3 | 3/0/0/0 |
| workflow-barrier-free-pipeline | kimi-k3 | strong | 0/3 | 0/3 | 0/3 | 0/0/0/3 | 2/3 | 2/3 | 0/3 | 2/0/0/1 |
| workflow-barrier-free-pipeline | deepseek-flash | floor | 1/3 | 1/3 | 0/3 | 1/0/0/2 | 1/3 | 1/3 | 0/3 | 0/1/0/2 |
| workflow-barrier-free-pipeline | glm-5.3-flash | floor | 2/3 | 2/3 | 0/3 | 2/0/0/1 | 1/3 | 1/3 | 0/3 | 1/0/0/2 |

| scope | model | tier | runs | usable | picture | on call 1 / 2 / 3 / none | first-call usable / runs | first-call usable / usable |
|---|---|---|---|---|---|---|---|---|
| v11 | glm-5.3 | strong | 21 | 21 | 9 | 20 / 0 / 1 / 0 | 20/21 (95 %) | 20/21 (95 %) |
| v11 | kimi-k3 | strong | 21 | 20 | 10 | 19 / 1 / 0 / 1 | 19/21 (90 %) | 19/20 (95 %) |
| v11 | deepseek-flash | floor | 21 | 19 | 12 | 18 / 1 / 0 / 2 | 18/21 (86 %) | 18/19 (95 %) |
| v11 | glm-5.3-flash | floor | 21 | 19 | 10 | 19 / 0 / 0 / 2 | 19/21 (90 %) | 19/19 (100 %) |
| v11 compose-only | glm-5.3 | strong | 18 | 18 | 9 | 17 / 0 / 1 / 0 | 17/18 (94 %) | 17/18 (94 %) |
| v11 compose-only | kimi-k3 | strong | 18 | 18 | 10 | 17 / 1 / 0 / 0 | 17/18 (94 %) | 17/18 (94 %) |
| v11 compose-only | deepseek-flash | floor | 18 | 18 | 12 | 18 / 0 / 0 / 0 | 18/18 (100 %) | 18/18 (100 %) |
| v11 compose-only | glm-5.3-flash | floor | 18 | 18 | 10 | 18 / 0 / 0 / 0 | 18/18 (100 %) | 18/18 (100 %) |
| v13 | glm-5.3 | strong | 24 | 22 | 12 | 20 / 2 / 0 / 2 | 20/24 (83 %) | 20/22 (91 %) |
| v13 | kimi-k3 | strong | 24 | 21 | 13 | 20 / 1 / 0 / 3 | 20/24 (83 %) | 20/21 (95 %) |
| v13 | deepseek-flash | floor | 24 | 22 | 13 | 18 / 4 / 0 / 2 | 18/24 (75 %) | 18/22 (82 %) |
| v13 | glm-5.3-flash | floor | 24 | 21 | 10 | 19 / 2 / 0 / 3 | 19/24 (79 %) | 19/21 (90 %) |
| v13 compose-only | glm-5.3 | strong | 21 | 20 | 11 | 18 / 2 / 0 / 1 | 18/21 (86 %) | 18/20 (90 %) |
| v13 compose-only | kimi-k3 | strong | 21 | 21 | 13 | 20 / 1 / 0 / 0 | 20/21 (95 %) | 20/21 (95 %) |
| v13 compose-only | deepseek-flash | floor | 21 | 21 | 13 | 17 / 4 / 0 / 0 | 17/21 (81 %) | 17/21 (81 %) |
| v13 compose-only | glm-5.3-flash | floor | 21 | 19 | 10 | 17 / 2 / 0 / 2 | 17/21 (81 %) | 17/19 (89 %) |
- v13 floor: runs 48, usable 43, picture 23, on call 1/2/3/none 37/6/0/5
- v13 strong: runs 48, usable 43, picture 25, on call 1/2/3/none 40/3/0/5
- v11 floor: runs 42, usable 38, picture 22, on call 1/2/3/none 37/1/0/4
- v11 strong: runs 42, usable 41, picture 19, on call 1/2/3/none 39/1/1/1
- v13 compose-only floor: runs 42, usable 40, picture 23, on call 1/2/3/none 34/6/0/2
- v13 compose-only strong: runs 42, usable 41, picture 24, on call 1/2/3/none 38/3/0/1
- v11 compose-only floor: runs 36, usable 36, picture 22, on call 1/2/3/none 36/0/0/0
- v11 compose-only strong: runs 36, usable 36, picture 19, on call 1/2/3/none 34/1/1/0

**The floor's distribution:**

- **All eight picture tasks** (48 runs): 37 usable on call 1, 6 on call 2, 0 on call 3, 5 never. v11 had 37 / 1 / 0 / 4
  over 42 runs on seven tasks.
- **The seven compose picture tasks** (42 runs): 34 / 6 / 0 / 2. v11 had 36 / 0 / 0 / 0 over 36.
- **By model:** deepseek-flash 18 / 4 / 0 / 2 and glm-5.3-flash 19 / 2 / 0 / 3.
- **The strong tier** reads 40 / 3 / 0 / 5 on the same 48.

**The six call-2 floor runs** are all compose, and all six were repaired on their second call. The kernel's answer to
each first call, and how that first script starts (A3 §1):

- compose-background-suite deepseek-flash #1: `script_error: g.model: unknown option "prompt_note"`.
- compose-grep-then-edit deepseek-flash #2: `script_syntax_error: Unexpected identifier 'Finish' at line 54, column
  12`.
- compose-race deepseek-flash #1: `script_syntax_error … at line 1, column 45`. The script starts
  `const hosts = [...];\nconst probes`, with literal `\n` escapes.
- compose-race glm-5.3-flash #1: "The script built no tasks." The script starts with a backtick, so it evaluated to a
  template literal. A1 reads the first call's picture as `missing_join, …`.
- compose-race-anon deepseek-flash #3: `g.parallel: every member must be a step built for this group` (the
  member_not_a_step text).
- compose-review-angles glm-5.3-flash #1: `g.model: results names an "all" group, which is not one step` (v12's
  `group_reference` text).

Only the last is a text new since v11. At n = 3 per cell, 0 → 6 call-2 runs on the floor's compose tasks is a fact to
record, not a trend to call.

**The five floor runs that were never usable** made no compose call:

- compose-grep-then-edit glm-5.3-flash #1: the lane bug, 600 s of r1 reasoning and no call at all;
- compose-three-stage-pairing glm-5.3-flash #1: did the job with tools;
- workflow-barrier-free-pipeline deepseek-flash #1 and #2, and glm-5.3-flash #2: did the job with bash. All three
  passed verification.

## A.8 Which bars the floor holds (A1)

- v13 floor: usable generation on the picture tasks 43/48 (compose tasks only 40/42); usable on call 1 37/48; runs that made a compose call 43/48; picture (the strong bar, a fact on the floor) 23/48 (compose only 23/42); non-picture cells: reach 63/72, success 60/72; task pass 35/36; green 95/120
- v11 floor: usable generation on the picture tasks 38/42 (compose tasks only 36/36); usable on call 1 37/42; runs that made a compose call 38/42; picture (the strong bar, a fact on the floor) 22/42 (compose only 22/36); non-picture cells: reach 57/72, success 51/72; task pass 34/36; green 78/114

- **Usable generation (the owner's floor bar) holds.** It reads 43/48 on the eight picture tasks, and every floor run
  that made a compose call was usable (43 composed, 43 usable). On the seven compose picture tasks it reads 40/42 (v11
  36/36). Both misses made no compose call: one is the 600 s reasoning stall classed lane bug, the other did the work
  with tools. On v11's seven tasks the floor reads 37/42 against v11's 38/42.
- **Usable on the first call slipped on compose.** It reads 34/42 against v11's 36/36; over all picture tasks it is
  37/48 against 37/42. No run was lost to a second call, since every call-2 run became usable.
- **The picture (the strong tier's bar; on the floor a fact) is not held.** The floor reads 23/48 (v11 22/42) and
  23/42 on compose (v11 22/36). For comparison, the strong tier reads 25/48, and 19/42 on v11's cells, the same as
  v11.
- **Other floor numbers:**
  - non-picture floor cells: reach 63/72 (v11 57/72), success 60/72 (51/72);
  - hidden verification: 35/36 (34/36), whose one fail is the lane-bug run;
  - green: 95/120 (78/114).

## A.9 The watcher's facts, checked

- **(a) Holds, except one count.** Both lane bugs are `stopped: deadline` at 607 s, with `rounds_settled` 0,
  `called {}`, a loop left `canceling` and the note "r1(model_task/running)" (A1). Both carry a null cost.
  - compose-background-suite glm-5.3 #3: there are **1679** `reasoning_delta` broadcasts on its loop, all on `r1`,
    from line 15161 to line **31715 of 32194** of `nexus.model_runner.log`, and 0 stream_reset (A3 §3). **The
    watcher's 582 does not reproduce**; the last-delta line does. The same 1679 appear in nexus.server.log,
    nexus.rails.log and nexus.model_runner.rails.log (A3 §3).
  - compose-grep-then-edit glm-5.3-flash #1: 4060 deltas, all on `r1`, the last at line 243589 of 243608, and 1
    `stream_reset` on r1 (reason `"retry"`, line 236061). That matches "more than 4000 and one stream_reset".
  - Both records show a model deliberating until the deadline with no call, which the record classes as a lane bug.
- **(b) Holds.** S1's refusal sentence is in 0 of 168 v13 windows (A3 §2).
  - deepseek-flash race #1's first call was a syntax error from literal `\n` escapes.
  - glm-5.3-flash race #1's first script opens with a backtick, and the kernel answered "The script built no tasks."
  - deepseek-flash race-anon #3's first call got the member_not_a_step text.
- **(c) Holds.** v13 has 5 records with the reason "no input_accepted{origin: task_result}: the kernel mailed no
  receipt", and all 5 have `wait: true` on every `task` row and 0 receipts. v11 has the same 8 of 8 (A2 §3). A waited
  fan owes no receipt, so the wording blames the kernel for the model's own choice.
- **(d) Holds.** task-mail glm-5.3 reached 0/3 in v11, and reaches 1/3 in v13 (#3 called `task`; #1 and #2 called
  `start_process`).
- **(e) Holds.**
  - v11 workflow-judge-panel glm-5.3-flash #2 was the 1420 s status poll: `status` 399 times, 398 rounds, $0.6408.
  - v13 #2 is green in 281 s over 22 rounds, with one `compose` call, `round_errors {}` and $0.0358.

## A.10 What the v13 records confirm about the lane

- **Each run has its own project directory:** 240 distinct directories for 240 records. In v11 it was 57 for 228, with
  up to 4 records on one directory (A2 §6).
- **No v13 sealed request carries the live-process sentence** ("Processes started earlier"): 0/240. v11 had it on task
  10/72 and compose 2/96.
- **So the v11 side still carries both confounds and the v13 side carries neither.** A v11→v13 move on a workflow
  verification or a task-family prompt mixes the fix with the run.

## Appendix: scripts and their outputs

### A1_cells.py

<!-- script:A1_cells.py -->
```python
#!/usr/bin/env python3
"""SECTION A, THE CELLS: v13 against v11, per (task x model) cell (read-only).

Reads the merged records (newest line per (task, model, style, run) wins, as
E2E::Evals::Records.read merges them) of the three v13 labels and the three
v11 nexus labels. v11's pack/candidate labels (kimi-pack-compose, k6, the glm
pack/wfword workflow pairs, kimi-pack-workflow) are other styles or
candidates and are NOT the baseline. Nothing is re-scored: every verdict,
class, fact and cost is read as recorded.

Per cell: reached / succeeded / task_pass as k/3 (task_pass as passed/verified,
'—' when no run was verified), the recorded classes, the tier bar (a floor
picture cell reads usable generation = facts.usable_on_call non-null, the
picture beside it; a strong picture cell reads the picture = facts.picture is
true, usable beside it; any other cell's bar is its success), mean seconds and
total cost (efficiency.cost_amount; a null cost is counted as 0 and flagged).

Run from anywhere: paths are absolute.
"""
import json
import os
import re
from collections import Counter, OrderedDict

REPO = "/Users/jasl/Workspaces/cybros-ai.alt2"
RUNS = os.path.join(REPO, "e2e/evals/runs")
V13 = ["2026-09-25-v13-task", "2026-09-25-v13-compose", "2026-09-25-v13-workflow"]
V11 = ["2026-09-24-v11-task", "2026-09-24-v11-compose", "2026-09-24-v11-workflow"]
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
    picture_cell = any("picture" in f for f in facts)
    return {
        "n": len(rows),
        "reached": sum(1 for x in v if x.get("reached") is True),
        "succ": sum(1 for x in v if x.get("succeeded") is True),
        "verified": len(verified),
        "passed": sum(1 for x in verified if x.get("task_pass") is True),
        "classes": Counter(x.get("class") for x in v),
        "green": sum(1 for x in v if x.get("class") is None),
        "picture_cell": picture_cell,
        "usable": sum(1 for f in facts if "picture" in f and f.get("usable_on_call") is not None),
        "pictured": sum(1 for f in facts if f.get("picture") is True),
        "seconds": sum(r["seconds"] for r in rows),
        "cost": sum(cost(r) or 0.0 for r in rows),
        "null_cost": sum(1 for r in rows if cost(r) is None),
        "stopped": Counter(r.get("stopped") for r in rows if r.get("stopped")),
    }


def fmt_classes(s):
    parts = [f"{abbr}{s['classes'][name]}" for name, abbr in CLASSES.items() if s["classes"].get(name)]
    parts.append(f"g{s['green']}")
    return " ".join(parts)


def fmt_p(s):
    return f"{s['passed']}/{s['verified']}" if s["verified"] else "—"


def bar_value(s, the_tier):
    """The tier's bar count on a picture cell; None elsewhere (the bar there is the success)."""
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


def reason_head(row, width=140):
    text = " ".join((row.get("reason") or "").split())
    failed = [k for k, ok in (row.get("conduct") or {}).items() if ok is False]
    if failed:
        text = (text + " " if text else "") + f"[conduct failed: {', '.join(failed)}]"
    if row.get("stopped"):
        text = f"[stopped {row['stopped']} at {row['seconds']} s] {text}"
    return text[:width] + ("…" if len(text) > width else "")


def run_line(row):
    v, f = row["verdict"], row.get("facts") or {}
    yn = lambda x: "—" if x is None else ("Y" if x else "N")
    cls = v.get("class") or "green"
    extra = ""
    if "picture" in f:
        pic = "true" if f["picture"] is True else " ".join(str(f["picture"]).split())[:60]
        extra = f" {{picture: {pic}; usable_on_call: {f.get('usable_on_call')}}}"
    c = cost(row)
    return (f"#{row['run']} r={yn(v.get('reached'))} s={yn(v.get('succeeded'))} p={yn(v.get('task_pass'))} {cls}"
            f" {row['seconds']}s ${'null' if c is None else f'{c:.4f}'} :: {reason_head(row)}{extra}")


# ---- reason kinds --------------------------------------------------------------------------------

def reason_kind(row):
    reason = " ".join((row.get("reason") or "").split())
    cls = row["verdict"].get("class")
    failed = [k for k, ok in (row.get("conduct") or {}).items() if ok is False]
    if row.get("stopped") == "deadline" and reason.endswith("the model called {}"):
        return "deadline stop, 0 rounds settled, no call at all"
    if row.get("stopped"):
        return f"stopped {row['stopped']}: " + re.split(r"[:({]", reason, maxsplit=1)[0].strip()
    if reason.startswith("no `task` call"):
        return "no `task` call; start_process in the tally" if "start_process" in reason else "no `task` call; no start_process"
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
        return "no task_result receipt (\"the kernel mailed no receipt\")"
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


# ---- output ---------------------------------------------------------------------------------------

def per_cell_tables(c13, c11):
    keys = sorted(set(c13) | set(c11), key=sort_key)
    for family in FAMILIES:
        print(f"\n### {family}\n")
        print("| task | model | tier | r v13 | r v11 | s v13 | s v11 | p v13 | p v11 | classes v13 | classes v11 "
              "| bar v13 | bar v11 | mean s v13 | mean s v11 | cost v13 | cost v11 |")
        print("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
        for key in keys:
            if key[0] != family:
                continue
            a = stats(c13[key])
            the_tier = tier(c13[key])
            if key in c11:
                b = stats(c11[key])
                old = [f"{b['reached']}/{b['n']}", f"{b['succ']}/{b['n']}", fmt_p(b), fmt_classes(b),
                       fmt_bar(b, the_tier), f"{b['seconds'] / b['n']:.0f}", fmt_cost(b)]
            else:
                old = ["new"] * 7
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
    bar = f" · bar(picture cells) {t['bar']}/{t['bar_n']}" if t["bar_n"] else ""
    p = f"{t['passed']}/{t['verified']}" if t["verified"] else "—"
    null = f" ({t['null_cost']} null)" if t["null_cost"] else ""
    return (f"r {t['reached']}/{t['n']} · s {t['succ']}/{t['n']} · p {p}{bar} · {classes} · green {t['green']}/{t['n']}"
            f" · ${t['cost']:.4f}{null} · {t['seconds']} s ({t['seconds'] / 3600:.2f} h, mean {t['seconds'] / t['n']:.0f} s)")


def summaries(c13, c11):
    groupings = [
        ("family", lambda k, rows: k[0]),
        ("model (all families)", lambda k, rows: short(k[2])),
        ("family x model", lambda k, rows: f"{k[0]} / {short(k[2])}"),
        ("family x tier", lambda k, rows: f"{k[0]} / {tier(rows)}"),
        ("tier", lambda k, rows: tier(rows)),
    ]
    for name, fn in groupings:
        print(f"\n### by {name}\n")
        print("| group | v13 | v11 |")
        print("|---|---|---|")
        groups = OrderedDict()
        for key in sorted(c13, key=sort_key):
            groups.setdefault(fn(key, c13[key]), []).append(key)
        for group, keys in groups.items():
            a = aggregate([c13[k] for k in keys])
            b = aggregate([c11[k] for k in keys if k in c11])
            print(f"| {group} | {agg_line(a)} | {agg_line(b)} |")
    a = aggregate(list(c13.values()))
    b = aggregate(list(c11.values()))
    print(f"\nALL v13: {agg_line(a)}\nALL v11: {agg_line(b)}")
    print("\nDeltas, v13 on v11's cells minus v11 (compose-race-anon out):")
    for name, fn in (("all", lambda k: "all"), ("family", lambda k: k[0]), ("tier", lambda k: tier(c13[k])),
                     ("model", lambda k: short(k[2]))):
        groups = OrderedDict()
        for key in sorted((k for k in c13 if k in c11), key=sort_key):
            groups.setdefault(fn(key), []).append(key)
        for group, keys in groups.items():
            x, y = aggregate([c13[k] for k in keys]), aggregate([c11[k] for k in keys])
            print(f"- {group}: reached {x['reached'] - y['reached']:+d}, succeeded {x['succ'] - y['succ']:+d}, "
                  f"passed {x['passed'] - y['passed']:+d}, bar {x['bar'] - y['bar']:+d}, green {x['green'] - y['green']:+d}, "
                  f"model conduct {x['classes']['model conduct'] - y['classes']['model conduct']:+d}, "
                  f"disagreement {x['classes']['disagreement'] - y['classes']['disagreement']:+d}, "
                  f"cache under floor {x['classes']['cache under floor'] - y['classes']['cache under floor']:+d}, "
                  f"cost {x['cost'] - y['cost']:+.4f}, seconds {x['seconds'] - y['seconds']:+d}")
    same = [k for k in c13 if k in c11]
    a = aggregate([c13[k] for k in same])
    print(f"v13 on v11's 76 cells only (compose-race-anon out): {agg_line(a)}")
    print("\n### by model and by family, v13 on v11's cells only (compose-race-anon out)\n")
    print("| group | v13 (v11's cells) | v11 |")
    print("|---|---|---|")
    for name, fn in (("model", lambda k: short(k[2])), ("family", lambda k: k[0]), ("tier", lambda k: tier(c13[k]))):
        groups = OrderedDict()
        for key in sorted(same, key=sort_key):
            groups.setdefault(fn(key), []).append(key)
        for group, keys in groups.items():
            print(f"| {group} | {agg_line(aggregate([c13[k] for k in keys]))} | {agg_line(aggregate([c11[k] for k in keys]))} |")


def moved(c13, c11):
    print("\n## Moved cells: |Δ| >= 2 of 3 on reached, succeeded, task_pass (passed count) or green\n")
    out = []
    for key in sorted(c13, key=sort_key):
        if key not in c11:
            continue
        a, b = stats(c13[key]), stats(c11[key])
        d = {"r": a["reached"] - b["reached"], "s": a["succ"] - b["succ"], "p": a["passed"] - b["passed"],
             "g": a["green"] - b["green"]}
        if any(abs(x) >= 2 for x in d.values()):
            out.append((key, a, b, d))
    print(f"{len(out)} cells. Deltas as v13 - v11.\n")
    print("| family | task | model | Δr | Δs | Δp | Δgreen | v13 r s p [classes] | v11 r s p [classes] |")
    print("|---|---|---|---|---|---|---|---|---|")
    for (family, task, model), a, b, d in out:
        fmt = lambda s: f"r{s['reached']} s{s['succ']} p{fmt_p(s)} [{fmt_classes(s)}]"
        print(f"| {family} | {task} | {short(model)} | {d['r']:+d} | {d['s']:+d} | {d['p']:+d} | {d['g']:+d} | {fmt(a)} | {fmt(b)} |")
    print()
    for (family, task, model), a, b, d in out:
        print(f"#### {family} / {task} / {short(model)}: " + ", ".join(f"Δ{k} {v:+d}" for k, v in d.items() if abs(v) >= 2))
        for label, cells in (("v13", c13), ("v11", c11)):
            for row in sorted(cells[(family, task, model)], key=lambda r: r["run"]):
                print(f"- {label} {run_line(row)}")
        print()
    print("### Picture cells whose picture fact or usable count moved by >= 2 of 3 (the floor's picture is a fact, not its bar)\n")
    for key in sorted(c13, key=sort_key):
        if key not in c11 or not stats(c13[key])["picture_cell"]:
            continue
        a, b = stats(c13[key]), stats(c11[key])
        dx, du = a["pictured"] - b["pictured"], a["usable"] - b["usable"]
        if abs(dx) >= 2 or abs(du) >= 2:
            print(f"#### {key[1]} / {short(key[2])} ({tier(c13[key])}): picture {b['pictured']} -> {a['pictured']} ({dx:+d}), "
                  f"usable {b['usable']} -> {a['usable']} ({du:+d})")
            for label, cells in (("v13", c13), ("v11", c11)):
                for row in sorted(cells[key], key=lambda r: r["run"]):
                    print(f"- {label} {run_line(row)}")
            print()


LEDGER_CELL = re.compile(r"^r(\d+)/(\d+) (?:s(\d+)/(\d+)|u(\d+)/(\d+)·x(\d+)/(\d+)) p(\S+)")


def check_ledger(c13):
    """Every v13 cell against its LEDGER.md string (r reached/read, s succeeded/reached or u·x, p, d)."""
    with open(os.path.join(RUNS, "LEDGER.md"), encoding="utf-8") as fh:
        text = fh.read()
    section = next(s for s in text.split("\n## ") if s.startswith("bench `ab836ee0d8be`"))
    checked, bad = 0, []
    for line in section.splitlines():
        cols = [c.strip() for c in line.strip("|").split("|")]
        if len(cols) < 7 or cols[0] not in FAMILIES:
            continue
        family, task, model = cols[0], cols[1], cols[2].split(" ")[0]
        value = next(v for v in cols[4:] if v != "·")
        s = stats(c13[(family, task, model)])
        want = (f"r{s['reached']}/{s['n']} " +
                (f"u{s['usable']}/{s['reached']}·x{s['pictured']}/{s['reached']}" if s["picture_cell"] and tier(c13[(family, task, model)]) == "floor"
                 else f"s{s['succ']}/{s['reached']}") + f" p{fmt_p(s)}")
        got = " ".join(value.split(" ")[:3])
        d = re.search(r" d(\d+)", value)
        checked += 1
        if want != got or int(d.group(1) if d else 0) != s["classes"].get("disagreement", 0):
            bad.append(f"{task} {short(model)}: ledger '{value}' vs records '{want}' d{s['classes'].get('disagreement', 0)}")
    print(f"- LEDGER.md cross-check (v13 section): {checked} cells, {len(bad)} mismatches {bad}")


def miss_reasons(c13, c11):
    print("\n## Reds by reason kind, per family (every record whose class is not green)\n")
    for family in FAMILIES:
        counts = {}
        for label, cells in (("v13", c13), ("v11", c11)):
            counts[label] = Counter(reason_kind(r) for k, rows in cells.items() if k[0] == family
                                    for r in rows if r["verdict"].get("class") is not None)
        kinds = sorted(set(counts["v13"]) | set(counts["v11"]), key=lambda k: (-counts["v13"].get(k, 0), -counts["v11"].get(k, 0), k))
        print(f"\n### {family}: v13 {sum(counts['v13'].values())} reds, v11 {sum(counts['v11'].values())}\n")
        print("| reason kind | v13 | v11 | v13 by model (glm / kimi / ds-flash / glm-flash) | v13 by task |")
        print("|---|---|---|---|---|")
        for kind in kinds:
            per_model = [sum(1 for k, rows in c13.items() if k[0] == family and k[2] == m for r in rows
                             if r["verdict"].get("class") is not None and reason_kind(r) == kind) for m in MODELS]
            per_task = Counter(k[1] for k, rows in c13.items() if k[0] == family for r in rows
                               if r["verdict"].get("class") is not None and reason_kind(r) == kind)
            tasks = ", ".join(f"{t.split('-', 1)[1]} {n}" for t, n in sorted(per_task.items()))
            print(f"| {kind} | {counts['v13'].get(kind, 0)} | {counts['v11'].get(kind, 0)} | {' / '.join(map(str, per_model))} | {tasks} |")
        for label, cells in (("v13", c13), ("v11", c11)):
            b = Counter(x for k, rows in cells.items() if k[0] == family for r in rows for x in buckets(r))
            n = sum(1 for k, rows in cells.items() if k[0] == family for r in rows if buckets(r))
            if n:
                print(f"\n{label} picture-red buckets over {n} picture-red records: " + ", ".join(f"{k} {v}" for k, v in b.most_common()))
        for label, cells in (("v13", c13), ("v11", c11)):
            cf = Counter(k2 for k, rows in cells.items() if k[0] == family for r in rows
                         for k2, ok in (r.get("conduct") or {}).items() if ok is False)
            ck = Counter(k2 for k, rows in cells.items() if k[0] == family for r in rows for k2 in (r.get("conduct") or {}))
            if ck:
                print(f"\n{label} conduct checks failed/checked: " + ", ".join(f"{k} {cf.get(k, 0)}/{ck[k]}" for k in sorted(ck)))


def cost_duration(c13, c11):
    print("\n## Cost and duration per model\n")
    print("| model | tier | v13 task $ | v13 compose $ | v13 workflow $ | v13 total $ | v11 total $ | Δ$ | v13 seconds (h) | v11 seconds (h) | v13 mean s/run | v11 mean s/run |")
    print("|---|---|---|---|---|---|---|---|---|---|---|---|")
    for model in MODELS:
        fam13 = {f: aggregate([rows for k, rows in c13.items() if k[0] == f and k[2] == model]) for f in FAMILIES}
        a = aggregate([rows for k, rows in c13.items() if k[2] == model])
        b = aggregate([rows for k, rows in c11.items() if k[2] == model])
        the_tier = tier(next(rows for k, rows in c13.items() if k[2] == model))
        print(f"| {short(model)} | {the_tier} | " + " | ".join(f"{fam13[f]['cost']:.4f}" for f in FAMILIES) +
              f" | {a['cost']:.4f} | {b['cost']:.4f} | {a['cost'] - b['cost']:+.4f} | {a['seconds']} ({a['seconds'] / 3600:.2f}) | "
              f"{b['seconds']} ({b['seconds'] / 3600:.2f}) | {a['seconds'] / a['n']:.0f} | {b['seconds'] / b['n']:.0f} |")
    print("\nPer model and family (v13 includes compose-race-anon's 12 runs; v11 had no such cell):\n")
    print("| model | task $ v13 / v11 / Δ | compose $ v13 / v11 / Δ | workflow $ v13 / v11 / Δ | seconds v13 / v11 / Δ |")
    print("|---|---|---|---|---|")
    for model in MODELS:
        cols = []
        for f in FAMILIES:
            a = aggregate([rows for k, rows in c13.items() if k[0] == f and k[2] == model])
            b = aggregate([rows for k, rows in c11.items() if k[0] == f and k[2] == model])
            cols.append(f"{a['cost']:.4f} / {b['cost']:.4f} / {a['cost'] - b['cost']:+.4f}")
        a = aggregate([rows for k, rows in c13.items() if k[2] == model])
        b = aggregate([rows for k, rows in c11.items() if k[2] == model])
        cols.append(f"{a['seconds']} / {b['seconds']} / {a['seconds'] - b['seconds']:+d}")
        print(f"| {short(model)} | " + " | ".join(cols) + " |")
    for label, cells in (("v13", c13), ("v11", c11)):
        t = aggregate(list(cells.values()))
        fam = {f: aggregate([rows for k, rows in cells.items() if k[0] == f]) for f in FAMILIES}
        print(f"\n{label}: total ${t['cost']:.4f} ({t['null_cost']} null-cost records); by family " +
              ", ".join(f"{f} ${fam[f]['cost']:.4f} / {fam[f]['seconds']} s" for f in FAMILIES) +
              f"; seconds {t['seconds']} ({t['seconds'] / 3600:.2f} h)")
    nulls = [(k, r) for k, rows in c13.items() for r in rows if cost(r) is None]
    print("\nv13 null-cost records: " + "; ".join(f"{k[1]} {short(k[2])} #{r['run']} (class {r['verdict'].get('class')}, "
                                                  f"stopped {r.get('stopped')}, rounds_settled {r['facts'].get('rounds_settled')}, "
                                                  f"input_tokens {r['efficiency'].get('input_tokens')})" for k, r in nulls))
    print("\nTop 8 v13 records by cost:")
    top = sorted(((cost(r) or 0.0, k, r) for k, rows in c13.items() for r in rows), key=lambda x: -x[0])[:8]
    for c, k, r in top:
        print(f"- ${c:.4f} {k[1]} {short(k[2])} #{r['run']} ({r['seconds']} s, class {r['verdict'].get('class')})")
    print("\nTop 8 v13 records by seconds:")
    top = sorted(((r["seconds"], k, r) for k, rows in c13.items() for r in rows), key=lambda x: -x[0])[:8]
    for s, k, r in top:
        print(f"- {s} s {k[1]} {short(k[2])} #{r['run']} (${cost(r) or 0:.4f}, class {r['verdict'].get('class')}, stopped {r.get('stopped')})")


def usable_on_call(c13, c11):
    print("\n## usable_on_call on the picture tasks (every run, both tiers)\n")
    print("| task | model | tier | v13 reach | v13 usable | v13 picture | v13 on call 1/2/3/none | v11 reach | v11 usable | v11 picture | v11 on call 1/2/3/none |")
    print("|---|---|---|---|---|---|---|---|---|---|---|")
    totals = {}
    for key in sorted(c13, key=sort_key):
        rows = c13[key]
        if not any("picture" in (r.get("facts") or {}) for r in rows):
            continue
        the_tier = tier(rows)
        cols = []
        for label, cells in (("v13", c13), ("v11", c11)):
            if key not in cells:
                cols += ["new"] * 4
                continue
            rs = cells[key]
            on = Counter((r.get("facts") or {}).get("usable_on_call") for r in rs)
            s = stats(rs)
            cols += [f"{s['reached']}/{s['n']}", f"{s['usable']}/{s['n']}", f"{s['pictured']}/{s['n']}",
                     f"{on.get(1, 0)}/{on.get(2, 0)}/{on.get(3, 0)}/{on.get(None, 0)}"]
            t = totals.setdefault((label, short(key[2]), the_tier), Counter())
            t["runs"] += s["n"]; t["reached"] += s["reached"]; t["usable"] += s["usable"]; t["pictured"] += s["pictured"]
            for k2, v2 in on.items():
                t[f"on{k2}"] += v2
            if key[0] == "compose":
                tc = totals.setdefault((label + " compose-only", short(key[2]), the_tier), Counter())
                tc["runs"] += s["n"]; tc["usable"] += s["usable"]; tc["pictured"] += s["pictured"]
                for k2, v2 in on.items():
                    tc[f"on{k2}"] += v2
        print(f"| {key[1]} | {short(key[2])} | {the_tier} | " + " | ".join(cols) + " |")
    print("\n| scope | model | tier | runs | usable | picture | on call 1 / 2 / 3 / none | first-call usable / runs | first-call usable / usable |")
    print("|---|---|---|---|---|---|---|---|---|")
    for (label, model, the_tier), t in sorted(totals.items(), key=lambda x: (x[0][0], MODELS.index(next(m for m in MODELS if short(m) == x[0][1])))):
        first = t["on1"]
        print(f"| {label} | {model} | {the_tier} | {t['runs']} | {t['usable']} | {t['pictured']} | "
              f"{t['on1']} / {t['on2']} / {t['on3']} / {t['onNone']} | {first}/{t['runs']} ({100 * first / t['runs']:.0f} %) | "
              f"{first}/{t['usable']} ({(100 * first / t['usable']) if t['usable'] else 0:.0f} %) |")
    for label in ("v13", "v11", "v13 compose-only", "v11 compose-only"):
        for the_tier in ("floor", "strong"):
            t = sum((c for (l, m, tr), c in totals.items() if l == label and tr == the_tier), Counter())
            if t["runs"]:
                print(f"- {label} {the_tier}: runs {t['runs']}, usable {t['usable']}, picture {t['pictured']}, "
                      f"on call 1/2/3/none {t['on1']}/{t['on2']}/{t['on3']}/{t['onNone']}")
    print("\nFloor picture-task runs NOT usable on call 1 (v13):")
    for key in sorted(c13, key=sort_key):
        for r in sorted(c13[key], key=lambda r: r["run"]):
            f = r.get("facts") or {}
            if "picture" in f and f.get("tier") == "floor" and f.get("usable_on_call") != 1:
                print(f"- {key[1]} {short(key[2])} {run_line(r)}")
    print("\nStrong picture-task runs NOT usable on call 1 (v13):")
    for key in sorted(c13, key=sort_key):
        for r in sorted(c13[key], key=lambda r: r["run"]):
            f = r.get("facts") or {}
            if "picture" in f and f.get("tier") == "strong" and f.get("usable_on_call") != 1:
                print(f"- {key[1]} {short(key[2])} {run_line(r)}")


def floor_bars(c13, c11):
    print("\n## The floor's bars, v13 (v11)\n")
    for label, cells in (("v13", c13), ("v11", c11)):
        fl = {k: rows for k, rows in cells.items() if tier(rows) == "floor"}
        pic = {k: rows for k, rows in fl.items() if any("picture" in (r.get("facts") or {}) for r in rows)}
        pic_c = {k: rows for k, rows in pic.items() if k[0] == "compose"}
        non = {k: rows for k, rows in fl.items() if k not in pic}
        def cnt(d, f):
            return sum(1 for rows in d.values() for r in rows if f(r)), sum(len(rows) for rows in d.values())
        u = cnt(pic, lambda r: r["facts"].get("usable_on_call") is not None)
        uc = cnt(pic_c, lambda r: r["facts"].get("usable_on_call") is not None)
        u1 = cnt(pic, lambda r: r["facts"].get("usable_on_call") == 1)
        x = cnt(pic, lambda r: r["facts"].get("picture") is True)
        xc = cnt(pic_c, lambda r: r["facts"].get("picture") is True)
        composed = cnt(pic, lambda r: r["facts"].get("picture") != "no compose call to score")
        s_non = cnt(non, lambda r: r["verdict"].get("succeeded") is True)
        r_non = cnt(non, lambda r: r["verdict"].get("reached") is True)
        g_all = cnt(fl, lambda r: r["verdict"].get("class") is None)
        p_ver = sum(1 for rows in fl.values() for r in rows if r["verdict"].get("task_pass") is not None)
        p_ok = sum(1 for rows in fl.values() for r in rows if r["verdict"].get("task_pass") is True)
        print(f"- {label} floor: usable generation on the picture tasks {u[0]}/{u[1]} (compose tasks only {uc[0]}/{uc[1]}); "
              f"usable on call 1 {u1[0]}/{u1[1]}; runs that made a compose call {composed[0]}/{composed[1]}; "
              f"picture (the strong bar, a fact on the floor) {x[0]}/{x[1]} (compose only {xc[0]}/{xc[1]}); "
              f"non-picture cells: reach {r_non[0]}/{r_non[1]}, success {s_non[0]}/{s_non[1]}; "
              f"task pass {p_ok}/{p_ver}; green {g_all[0]}/{g_all[1]}")
    print("\nFloor picture-task runs with no usable call (v13):")
    for key in sorted(c13, key=sort_key):
        for r in sorted(c13[key], key=lambda r: r["run"]):
            f = r.get("facts") or {}
            if "picture" in f and f.get("tier") == "floor" and f.get("usable_on_call") is None:
                print(f"- {key[1]} {short(key[2])} {run_line(r)}")


def watcher_facts(c13, c11):
    print("\n## Watcher facts (d), (e), (a) from the records\n")
    key = ("task", "task-mail", "openrouter/z-ai/glm-5.3")
    for label, cells in (("v11", c11), ("v13", c13)):
        s = stats(cells[key])
        print(f"- (d) task-mail glm-5.3 {label}: reached {s['reached']}/{s['n']}, succeeded {s['succ']}/{s['n']}")
    key = ("workflow", "workflow-judge-panel", "openrouter/z-ai/glm-5.3-flash")
    for label, cells in (("v11", c11), ("v13", c13)):
        for r in sorted(cells[key], key=lambda r: r["run"]):
            if r["run"] == 2:
                f = r.get("facts") or {}
                print(f"- (e) judge-panel glm-5.3-flash #2 {label}: {run_line(r)}; rounds_settled {f.get('rounds_settled')}, "
                      f"called {f.get('called')}, round_errors {f.get('round_errors')}")
    for key, rows in c13.items():
        for r in rows:
            if r["verdict"].get("class") == "lane bug":
                f = r.get("facts") or {}
                print(f"- (a) lane bug: {key[1]} {short(key[2])} #{r['run']}: stopped {r.get('stopped')}, seconds {r['seconds']}, "
                      f"rounds_settled {f.get('rounds_settled')}, called {f.get('called')}, loops {r.get('loops')}, note {r.get('note')!r}")


def main():
    c13, m13 = load(V13)
    c11, m11 = load(V11)
    print("## Inputs\n")
    for label, (lines, rows) in list(m13.items()) + list(m11.items()):
        print(f"- {label}: {lines} lines -> {len(rows)} records; digest {sorted({r['bench_digest'][:12] for r in rows})}; "
              f"styles {sorted({r['style'] for r in rows})}; error rows {sum(1 for r in rows if r.get('error'))}; "
              f"started {min(r['started_at'] for r in rows)} .. {max(r['started_at'] for r in rows)}")
    print(f"- cells: v13 {len(c13)}, v11 {len(c11)}; v13 cells with no v11 cell: "
          f"{sorted({(k[1]) for k in c13 if k not in c11})}; runs per cell v13 {sorted({len(v) for v in c13.values()})}")
    check_ledger(c13)
    print("\n## Per cell, v13 beside v11\n")
    print("Notation: r/s k of 3 runs; p passed/verified ('—' none verified); classes mc model conduct, dis disagreement, "
          "cuf cache under floor, lb lane bug, g green; bar: floor picture cell 'u usable/3 (x picture)', strong picture "
          "cell 'x picture/3 (u usable)', '= s' where the bar is the success; mean s = mean record seconds; cost = sum of "
          "cost_amount (USD).")
    per_cell_tables(c13, c11)
    print("\n## Totals\n")
    summaries(c13, c11)
    moved(c13, c11)
    miss_reasons(c13, c11)
    cost_duration(c13, c11)
    usable_on_call(c13, c11)
    floor_bars(c13, c11)
    watcher_facts(c13, c11)


main()
```

#### A1_cells.py output

~~~text
## Inputs

- 2026-09-25-v13-task: 72 lines -> 72 records; digest ['ab836ee0d8be']; styles ['nexus']; error rows 0; started 2026-09-24T17:59:29Z .. 2026-09-24T19:11:40Z
- 2026-09-25-v13-compose: 108 lines -> 108 records; digest ['ab836ee0d8be']; styles ['nexus']; error rows 0; started 2026-09-24T19:21:07Z .. 2026-09-24T23:55:52Z
- 2026-09-25-v13-workflow: 60 lines -> 60 records; digest ['ab836ee0d8be']; styles ['nexus']; error rows 0; started 2026-09-25T00:01:03Z .. 2026-09-25T02:24:39Z
- 2026-09-24-v11-task: 72 lines -> 72 records; digest ['c0b22996599e']; styles ['nexus']; error rows 0; started 2026-09-23T21:42:55Z .. 2026-09-23T22:51:23Z
- 2026-09-24-v11-compose: 96 lines -> 96 records; digest ['c0b22996599e']; styles ['nexus']; error rows 0; started 2026-09-23T23:19:23Z .. 2026-09-24T03:12:19Z
- 2026-09-24-v11-workflow: 60 lines -> 60 records; digest ['c0b22996599e']; styles ['nexus']; error rows 0; started 2026-09-24T03:16:46Z .. 2026-09-24T05:51:28Z
- cells: v13 80, v11 76; v13 cells with no v11 cell: ['compose-race-anon']; runs per cell v13 [3]
- LEDGER.md cross-check (v13 section): 80 cells, 0 mismatches []

## Per cell, v13 beside v11

Notation: r/s k of 3 runs; p passed/verified ('—' none verified); classes mc model conduct, dis disagreement, cuf cache under floor, lb lane bug, g green; bar: floor picture cell 'u usable/3 (x picture)', strong picture cell 'x picture/3 (u usable)', '= s' where the bar is the success; mean s = mean record seconds; cost = sum of cost_amount (USD).

### task

| task | model | tier | r v13 | r v11 | s v13 | s v11 | p v13 | p v11 | classes v13 | classes v11 | bar v13 | bar v11 | mean s v13 | mean s v11 | cost v13 | cost v11 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| task-background-suite | glm-5.3 | strong | 3/3 | 3/3 | 3/3 | 1/3 | — | — | g3 | mc2 g1 | = s | = s | 143 | 172 | 0.3797 | 0.5207 |
| task-background-suite | kimi-k3 | strong | 2/3 | 3/3 | 2/3 | 2/3 | — | — | mc1 cuf2 g0 | mc1 cuf1 g1 | = s | = s | 129 | 126 | 0.6436 | 0.5167 |
| task-background-suite | deepseek-flash | floor | 1/3 | 2/3 | 1/3 | 2/3 | — | — | mc2 g1 | mc1 g2 | = s | = s | 60 | 80 | 0.0269 | 0.0409 |
| task-background-suite | glm-5.3-flash | floor | 2/3 | 1/3 | 2/3 | 1/3 | — | — | mc1 g2 | mc2 g1 | = s | = s | 138 | 104 | 0.0622 | 0.0290 |
| task-detached-receipt | glm-5.3 | strong | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | = s | = s | 73 | 108 | 0.0842 | 0.2339 |
| task-detached-receipt | kimi-k3 | strong | 3/3 | 3/3 | 3/3 | 1/3 | — | — | g3 | mc2 g1 | = s | = s | 100 | 79 | 0.3058 | 0.1412 |
| task-detached-receipt | deepseek-flash | floor | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | = s | = s | 72 | 67 | 0.0082 | 0.0080 |
| task-detached-receipt | glm-5.3-flash | floor | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | = s | = s | 84 | 80 | 0.0160 | 0.0155 |
| task-fan-five | glm-5.3 | strong | 3/3 | 3/3 | 3/3 | 2/3 | — | — | g3 | mc1 g2 | = s | = s | 97 | 76 | 0.1935 | 0.2243 |
| task-fan-five | kimi-k3 | strong | 3/3 | 3/3 | 3/3 | 2/3 | — | — | g3 | mc1 g2 | = s | = s | 86 | 62 | 0.7417 | 0.3436 |
| task-fan-five | deepseek-flash | floor | 1/3 | 1/3 | 1/3 | 1/3 | — | — | mc2 g1 | mc2 cuf1 g0 | = s | = s | 63 | 61 | 0.0321 | 0.0390 |
| task-fan-five | glm-5.3-flash | floor | 3/3 | 2/3 | 2/3 | 2/3 | — | — | mc1 g2 | mc1 g2 | = s | = s | 102 | 70 | 0.0551 | 0.0441 |
| task-grep-three-control | glm-5.3 | strong | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | = s | = s | 19 | 11 | 0.0292 | 0.0262 |
| task-grep-three-control | kimi-k3 | strong | 3/3 | 2/3 | 3/3 | 2/3 | — | — | g3 | mc1 g2 | = s | = s | 15 | 17 | 0.0589 | 0.1264 |
| task-grep-three-control | deepseek-flash | floor | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | = s | = s | 12 | 13 | 0.0022 | 0.0021 |
| task-grep-three-control | glm-5.3-flash | floor | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | = s | = s | 14 | 12 | 0.0045 | 0.0045 |
| task-mail | glm-5.3 | strong | 1/3 | 0/3 | 1/3 | 0/3 | — | — | mc2 g1 | mc3 g0 | = s | = s | 63 | 19 | 0.0925 | 0.0230 |
| task-mail | kimi-k3 | strong | 0/3 | 1/3 | 0/3 | 1/3 | — | — | mc3 g0 | mc2 g1 | = s | = s | 17 | 60 | 0.1157 | 0.1816 |
| task-mail | deepseek-flash | floor | 2/3 | 2/3 | 2/3 | 1/3 | — | — | mc1 g2 | mc2 g1 | = s | = s | 53 | 60 | 0.0097 | 0.0096 |
| task-mail | glm-5.3-flash | floor | 0/3 | 0/3 | 0/3 | 0/3 | — | — | mc3 g0 | mc3 g0 | = s | = s | 36 | 28 | 0.0060 | 0.0052 |
| task-two-calls | glm-5.3 | strong | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | = s | = s | 15 | 14 | 0.0195 | 0.0382 |
| task-two-calls | kimi-k3 | strong | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | = s | = s | 16 | 14 | 0.0879 | 0.1032 |
| task-two-calls | deepseek-flash | floor | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | = s | = s | 11 | 19 | 0.0019 | 0.0018 |
| task-two-calls | glm-5.3-flash | floor | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | = s | = s | 26 | 14 | 0.0053 | 0.0044 |

### compose

| task | model | tier | r v13 | r v11 | s v13 | s v11 | p v13 | p v11 | classes v13 | classes v11 | bar v13 | bar v11 | mean s v13 | mean s v11 | cost v13 | cost v11 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| compose-background-suite | glm-5.3 | strong | 2/3 | 3/3 | 1/3 | 1/3 | — | — | mc1 lb1 g1 | mc2 g1 | x 1/3 (u 2) | x 1/3 (u 3) | 313 | 259 | 0.3435 (1 null) | 0.7204 |
| compose-background-suite | kimi-k3 | strong | 3/3 | 3/3 | 1/3 | 0/3 | — | — | mc2 g1 | mc3 g0 | x 1/3 (u 3) | x 0/3 (u 3) | 112 | 159 | 0.7017 | 0.5654 |
| compose-background-suite | deepseek-flash | floor | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | u 3/3 (x 0) | u 3/3 (x 2) | 126 | 83 | 0.0711 | 0.0514 |
| compose-background-suite | glm-5.3-flash | floor | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | u 3/3 (x 1) | u 3/3 (x 0) | 330 | 187 | 0.0744 | 0.0587 |
| compose-grep-then-edit | glm-5.3 | strong | 3/3 | 3/3 | 0/3 | 0/3 | 3/3 | 3/3 | dis3 g0 | dis3 g0 | x 0/3 (u 3) | x 0/3 (u 3) | 387 | 324 | 0.8292 | 1.3125 |
| compose-grep-then-edit | kimi-k3 | strong | 3/3 | 3/3 | 1/3 | 2/3 | 3/3 | 3/3 | dis2 g1 | dis1 g2 | x 1/3 (u 3) | x 2/3 (u 3) | 51 | 82 | 0.3169 | 0.3100 |
| compose-grep-then-edit | deepseek-flash | floor | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | cuf1 g2 | cuf1 g2 | u 3/3 (x 2) | u 3/3 (x 2) | 67 | 74 | 0.0538 | 0.0601 |
| compose-grep-then-edit | glm-5.3-flash | floor | 2/3 | 3/3 | 2/3 | 3/3 | 2/3 | 3/3 | lb1 g2 | g3 | u 2/3 (x 0) | u 3/3 (x 0) | 385 | 305 | 0.0377 (1 null) | 0.0737 |
| compose-race | glm-5.3 | strong | 3/3 | 3/3 | 3/3 | 2/3 | — | — | g3 | mc1 g2 | x 3/3 (u 3) | x 2/3 (u 3) | 137 | 189 | 0.4539 | 0.4638 |
| compose-race | kimi-k3 | strong | 3/3 | 3/3 | 3/3 | 2/3 | — | — | g3 | mc1 g2 | x 3/3 (u 3) | x 2/3 (u 3) | 28 | 189 | 0.2192 | 0.4091 |
| compose-race | deepseek-flash | floor | 3/3 | 3/3 | 3/3 | 3/3 | — | — | cuf1 g2 | g3 | u 3/3 (x 2) | u 3/3 (x 2) | 33 | 32 | 0.0197 | 0.0169 |
| compose-race | glm-5.3-flash | floor | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | u 3/3 (x 2) | u 3/3 (x 1) | 230 | 190 | 0.0319 | 0.0459 |
| compose-race-anon | glm-5.3 | strong | 3/3 | new | 3/3 | new | — | new | g3 | new | x 3/3 (u 3) | new | 134 | new | 0.4655 | new |
| compose-race-anon | kimi-k3 | strong | 3/3 | new | 3/3 | new | — | new | g3 | new | x 3/3 (u 3) | new | 58 | new | 0.2640 | new |
| compose-race-anon | deepseek-flash | floor | 3/3 | new | 3/3 | new | — | new | cuf1 g2 | new | u 3/3 (x 2) | new | 40 | new | 0.0246 | new |
| compose-race-anon | glm-5.3-flash | floor | 3/3 | new | 3/3 | new | — | new | g3 | new | u 3/3 (x 3) | new | 97 | new | 0.0179 | new |
| compose-rendezvous | glm-5.3 | strong | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | = s | = s | 160 | 360 | 0.6720 | 1.0875 |
| compose-rendezvous | kimi-k3 | strong | 3/3 | 3/3 | 3/3 | 2/3 | — | — | g3 | mc1 g2 | = s | = s | 167 | 156 | 0.9157 | 1.1397 |
| compose-rendezvous | deepseek-flash | floor | 3/3 | 3/3 | 3/3 | 3/3 | — | — | cuf1 g2 | g3 | = s | = s | 126 | 138 | 0.1217 | 0.0933 |
| compose-rendezvous | glm-5.3-flash | floor | 3/3 | 2/3 | 2/3 | 1/3 | — | — | mc1 g2 | mc2 g1 | = s | = s | 495 | 410 | 0.1022 | 0.0608 |
| compose-review-angles | glm-5.3 | strong | 3/3 | 3/3 | 2/3 | 3/3 | — | — | mc1 g2 | g3 | x 2/3 (u 3) | x 3/3 (u 3) | 244 | 102 | 0.6169 | 0.4894 |
| compose-review-angles | kimi-k3 | strong | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | x 3/3 (u 3) | x 3/3 (u 3) | 111 | 87 | 0.7256 | 0.8921 |
| compose-review-angles | deepseek-flash | floor | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | u 3/3 (x 3) | u 3/3 (x 3) | 167 | 108 | 0.1256 | 0.0952 |
| compose-review-angles | glm-5.3-flash | floor | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | u 3/3 (x 2) | u 3/3 (x 3) | 183 | 167 | 0.0601 | 0.0678 |
| compose-single-read | glm-5.3 | strong | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | = s | = s | 15 | 12 | 0.0263 | 0.0359 |
| compose-single-read | kimi-k3 | strong | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | cuf2 g1 | = s | = s | 13 | 17 | 0.0859 | 0.1731 |
| compose-single-read | deepseek-flash | floor | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | = s | = s | 13 | 13 | 0.0021 | 0.0020 |
| compose-single-read | glm-5.3-flash | floor | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | = s | = s | 59 | 16 | 0.0088 | 0.0097 |
| compose-three-stage-pairing | glm-5.3 | strong | 3/3 | 3/3 | 2/3 | 2/3 | — | — | mc1 g2 | mc1 g2 | x 2/3 (u 3) | x 2/3 (u 3) | 460 | 169 | 0.7401 | 0.6348 |
| compose-three-stage-pairing | kimi-k3 | strong | 3/3 | 3/3 | 2/3 | 3/3 | — | — | mc1 g2 | g3 | x 2/3 (u 3) | x 3/3 (u 3) | 99 | 73 | 0.6390 | 0.4429 |
| compose-three-stage-pairing | deepseek-flash | floor | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | u 3/3 (x 3) | u 3/3 (x 1) | 49 | 35 | 0.0256 | 0.0166 |
| compose-three-stage-pairing | glm-5.3-flash | floor | 2/3 | 3/3 | 2/3 | 3/3 | — | — | mc1 g2 | g3 | u 2/3 (x 1) | u 3/3 (x 3) | 269 | 236 | 0.0515 | 0.0574 |
| compose-two-source-fan-in | glm-5.3 | strong | 3/3 | 3/3 | 0/3 | 1/3 | — | — | mc3 g0 | mc2 g1 | x 0/3 (u 3) | x 1/3 (u 3) | 59 | 119 | 0.1150 | 0.4047 |
| compose-two-source-fan-in | kimi-k3 | strong | 3/3 | 3/3 | 0/3 | 0/3 | — | — | mc3 g0 | mc3 g0 | x 0/3 (u 3) | x 0/3 (u 3) | 88 | 80 | 0.5516 | 0.3726 |
| compose-two-source-fan-in | deepseek-flash | floor | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | u 3/3 (x 1) | u 3/3 (x 2) | 60 | 68 | 0.0223 | 0.0295 |
| compose-two-source-fan-in | glm-5.3-flash | floor | 3/3 | 3/3 | 3/3 | 3/3 | — | — | g3 | g3 | u 3/3 (x 1) | u 3/3 (x 3) | 174 | 273 | 0.0408 | 0.0440 |

### workflow

| task | model | tier | r v13 | r v11 | s v13 | s v11 | p v13 | p v11 | classes v13 | classes v11 | bar v13 | bar v11 | mean s v13 | mean s v11 | cost v13 | cost v11 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| workflow-adversarial-verify | glm-5.3 | strong | 3/3 | 3/3 | 1/3 | 0/3 | 3/3 | 3/3 | dis2 cuf1 g0 | dis3 g0 | = s | = s | 256 | 270 | 1.2612 | 1.1509 |
| workflow-adversarial-verify | kimi-k3 | strong | 3/3 | 3/3 | 1/3 | 1/3 | 1/3 | 3/3 | mc2 cuf1 g0 | mc1 dis2 g0 | = s | = s | 218 | 188 | 2.7377 | 2.4173 |
| workflow-adversarial-verify | deepseek-flash | floor | 3/3 | 3/3 | 3/3 | 1/3 | 3/3 | 3/3 | mc3 g0 | mc1 dis2 g0 | = s | = s | 244 | 240 | 0.2415 | 0.4239 |
| workflow-adversarial-verify | glm-5.3-flash | floor | 3/3 | 3/3 | 2/3 | 2/3 | 3/3 | 2/3 | mc1 dis1 g1 | mc3 g0 | = s | = s | 264 | 231 | 0.2086 | 0.1539 |
| workflow-barrier-free-pipeline | glm-5.3 | strong | 2/3 | 3/3 | 1/3 | 0/3 | 3/3 | 3/3 | mc1 dis1 cuf1 g0 | dis3 g0 | x 1/3 (u 2) | x 0/3 (u 3) | 246 | 218 | 0.6528 | 0.8281 |
| workflow-barrier-free-pipeline | kimi-k3 | strong | 0/3 | 2/3 | 0/3 | 0/3 | 3/3 | 3/3 | mc3 g0 | mc1 dis2 g0 | x 0/3 (u 0) | x 0/3 (u 2) | 35 | 54 | 0.1881 | 0.3646 |
| workflow-barrier-free-pipeline | deepseek-flash | floor | 1/3 | 1/3 | 1/3 | 1/3 | 3/3 | 3/3 | mc2 g1 | mc2 g1 | u 1/3 (x 0) | u 1/3 (x 0) | 47 | 61 | 0.0185 | 0.0293 |
| workflow-barrier-free-pipeline | glm-5.3-flash | floor | 2/3 | 1/3 | 2/3 | 1/3 | 3/3 | 3/3 | mc1 g2 | mc2 g1 | u 2/3 (x 0) | u 1/3 (x 0) | 90 | 73 | 0.0216 | 0.0213 |
| workflow-fan-out-finders | glm-5.3 | strong | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | g3 | mc3 g0 | = s | = s | 65 | 61 | 0.1401 | 0.1792 |
| workflow-fan-out-finders | kimi-k3 | strong | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | cuf3 g0 | mc2 cuf1 g0 | = s | = s | 92 | 91 | 1.1415 | 1.0549 |
| workflow-fan-out-finders | deepseek-flash | floor | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | g3 | mc2 g1 | = s | = s | 54 | 116 | 0.0201 | 0.0312 |
| workflow-fan-out-finders | glm-5.3-flash | floor | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | g3 | mc3 g0 | = s | = s | 134 | 65 | 0.0531 | 0.0364 |
| workflow-judge-panel | glm-5.3 | strong | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | cuf3 g0 | cuf1 g2 | = s | = s | 243 | 217 | 1.2282 | 0.9445 |
| workflow-judge-panel | kimi-k3 | strong | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | cuf2 g1 | cuf3 g0 | = s | = s | 167 | 127 | 1.2487 | 1.0917 |
| workflow-judge-panel | deepseek-flash | floor | 3/3 | 3/3 | 3/3 | 2/3 | 3/3 | 3/3 | g3 | dis1 g2 | = s | = s | 100 | 118 | 0.0989 | 0.0857 |
| workflow-judge-panel | glm-5.3-flash | floor | 3/3 | 2/3 | 3/3 | 2/3 | 3/3 | 3/3 | g3 | mc1 g2 | = s | = s | 247 | 642 | 0.0867 | 0.7097 |
| workflow-loop-until-dry | glm-5.3 | strong | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | g3 | g3 | = s | = s | 101 | 79 | 0.2982 | 0.2359 |
| workflow-loop-until-dry | kimi-k3 | strong | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | cuf2 g1 | cuf3 g0 | = s | = s | 121 | 97 | 0.9472 | 1.0119 |
| workflow-loop-until-dry | deepseek-flash | floor | 3/3 | 2/3 | 3/3 | 2/3 | 3/3 | 3/3 | g3 | mc2 g1 | = s | = s | 62 | 62 | 0.0130 | 0.0156 |
| workflow-loop-until-dry | glm-5.3-flash | floor | 3/3 | 1/3 | 3/3 | 1/3 | 3/3 | 2/3 | g3 | mc2 g1 | = s | = s | 89 | 72 | 0.0427 | 0.0273 |

## Totals


### by family

| group | v13 | v11 |
|---|---|---|
| task | r 57/72 · s 56/72 · p — · mc16 cuf2 · green 54/72 · $2.9823 · 4328 s (1.20 h, mean 60 s) | r 56/72 · s 48/72 · p — · mc24 cuf2 · green 46/72 · $2.6831 · 4096 s (1.14 h, mean 57 s) |
| compose | r 105/108 · s 87/108 · p 11/12 · bar(picture cells) 64/84 · mc14 dis5 cuf4 lb2 · green 83/108 · $9.5737 (2 null) · 16616 s (4.62 h, mean 154 s) | r 95/96 · s 76/96 · p 12/12 · bar(picture cells) 55/72 · mc16 dis4 cuf3 · green 73/96 · $10.2368 · 14128 s (3.92 h, mean 147 s) |
| workflow | r 53/60 · s 47/60 · p 58/60 · bar(picture cells) 4/12 · mc13 dis4 cuf13 · green 30/60 · $10.6485 · 8631 s (2.40 h, mean 144 s) | r 51/60 · s 37/60 · p 58/60 · bar(picture cells) 2/12 · mc25 dis13 cuf8 · green 14/60 · $10.8132 · 9250 s (2.57 h, mean 154 s) |

### by model (all families)

| group | v13 | v11 |
|---|---|---|
| glm-5.3 | r 56/60 · s 44/60 · p 18/18 · bar(picture cells) 12/24 · mc9 dis6 cuf5 lb1 · green 39/60 · $8.6416 (1 null) · 9692 s (2.69 h, mean 162 s) | r 54/57 · s 36/57 · p 18/18 · bar(picture cells) 9/21 · mc15 dis9 cuf1 · green 32/57 · $9.5537 · 8336 s (2.32 h, mean 146 s) |
| kimi-k3 | r 53/60 · s 43/60 · p 16/18 · bar(picture cells) 13/24 · mc15 dis2 cuf10 · green 33/60 · $12.6364 · 5172 s (1.44 h, mean 86 s) | r 53/57 · s 36/57 · p 18/18 · bar(picture cells) 10/21 · mc19 dis5 cuf10 · green 23/57 · $11.6580 · 5268 s (1.46 h, mean 92 s) |
| deepseek-flash | r 53/60 · s 53/60 · p 18/18 · bar(picture cells) 22/24 · mc10 cuf4 · green 46/60 · $0.9393 · 4379 s (1.22 h, mean 73 s) | r 50/57 · s 46/57 · p 18/18 · bar(picture cells) 19/21 · mc12 dis3 cuf2 · green 40/57 · $1.0523 · 4345 s (1.21 h, mean 76 s) |
| glm-5.3-flash | r 53/60 · s 50/60 · p 17/18 · bar(picture cells) 21/24 · mc9 dis1 lb1 · green 49/60 · $0.9871 (1 null) · 10332 s (2.87 h, mean 172 s) | r 45/57 · s 43/57 · p 16/18 · bar(picture cells) 19/21 · mc19 · green 38/57 · $1.4691 · 9525 s (2.65 h, mean 167 s) |

### by family x model

| group | v13 | v11 |
|---|---|---|
| task / glm-5.3 | r 16/18 · s 16/18 · p — · mc2 · green 16/18 · $0.7986 · 1231 s (0.34 h, mean 68 s) | r 15/18 · s 12/18 · p — · mc6 · green 12/18 · $1.0663 · 1199 s (0.33 h, mean 67 s) |
| task / kimi-k3 | r 14/18 · s 14/18 · p — · mc4 cuf2 · green 12/18 · $1.9536 · 1087 s (0.30 h, mean 60 s) | r 15/18 · s 11/18 · p — · mc7 cuf1 · green 10/18 · $1.4128 · 1070 s (0.30 h, mean 59 s) |
| task / deepseek-flash | r 13/18 · s 13/18 · p — · mc5 · green 13/18 · $0.0809 · 812 s (0.23 h, mean 45 s) | r 14/18 · s 13/18 · p — · mc5 cuf1 · green 12/18 · $0.1014 · 902 s (0.25 h, mean 50 s) |
| task / glm-5.3-flash | r 14/18 · s 13/18 · p — · mc5 · green 13/18 · $0.1492 · 1198 s (0.33 h, mean 67 s) | r 12/18 · s 12/18 · p — · mc6 · green 12/18 · $0.1026 · 925 s (0.26 h, mean 51 s) |
| compose / glm-5.3 | r 26/27 · s 17/27 · p 3/3 · bar(picture cells) 11/21 · mc6 dis3 lb1 · green 17/27 · $4.2624 (1 null) · 5729 s (1.59 h, mean 212 s) | r 24/24 · s 15/24 · p 3/3 · bar(picture cells) 9/18 · mc6 dis3 · green 15/24 · $5.1489 · 4602 s (1.28 h, mean 192 s) |
| compose / kimi-k3 | r 27/27 · s 19/27 · p 3/3 · bar(picture cells) 13/21 · mc6 dis2 · green 19/27 · $4.4196 · 2183 s (0.61 h, mean 81 s) | r 24/24 · s 15/24 · p 3/3 · bar(picture cells) 10/18 · mc8 dis1 cuf2 · green 13/24 · $4.3049 · 2526 s (0.70 h, mean 105 s) |
| compose / deepseek-flash | r 27/27 · s 27/27 · p 3/3 · bar(picture cells) 21/21 · cuf4 · green 23/27 · $0.4665 · 2044 s (0.57 h, mean 76 s) | r 24/24 · s 24/24 · p 3/3 · bar(picture cells) 18/18 · cuf1 · green 23/24 · $0.3651 · 1650 s (0.46 h, mean 69 s) |
| compose / glm-5.3-flash | r 25/27 · s 24/27 · p 2/3 · bar(picture cells) 19/21 · mc2 lb1 · green 24/27 · $0.4253 (1 null) · 6660 s (1.85 h, mean 247 s) | r 23/24 · s 22/24 · p 3/3 · bar(picture cells) 18/18 · mc2 · green 22/24 · $0.4179 · 5350 s (1.49 h, mean 223 s) |
| workflow / glm-5.3 | r 14/15 · s 11/15 · p 15/15 · bar(picture cells) 1/3 · mc1 dis3 cuf5 · green 6/15 · $3.5806 · 2732 s (0.76 h, mean 182 s) | r 15/15 · s 9/15 · p 15/15 · bar(picture cells) 0/3 · mc3 dis6 cuf1 · green 5/15 · $3.3385 · 2535 s (0.70 h, mean 169 s) |
| workflow / kimi-k3 | r 12/15 · s 10/15 · p 13/15 · bar(picture cells) 0/3 · mc5 cuf8 · green 2/15 · $6.2633 · 1902 s (0.53 h, mean 127 s) | r 14/15 · s 10/15 · p 15/15 · bar(picture cells) 0/3 · mc4 dis4 cuf7 · green 0/15 · $5.9403 · 1672 s (0.46 h, mean 111 s) |
| workflow / deepseek-flash | r 13/15 · s 13/15 · p 15/15 · bar(picture cells) 1/3 · mc5 · green 10/15 · $0.3919 · 1523 s (0.42 h, mean 102 s) | r 12/15 · s 9/15 · p 15/15 · bar(picture cells) 1/3 · mc7 dis3 · green 5/15 · $0.5859 · 1793 s (0.50 h, mean 120 s) |
| workflow / glm-5.3-flash | r 14/15 · s 13/15 · p 15/15 · bar(picture cells) 2/3 · mc2 dis1 · green 12/15 · $0.4127 · 2474 s (0.69 h, mean 165 s) | r 10/15 · s 9/15 · p 13/15 · bar(picture cells) 1/3 · mc11 · green 4/15 · $0.9486 · 3250 s (0.90 h, mean 217 s) |

### by family x tier

| group | v13 | v11 |
|---|---|---|
| task / strong | r 30/36 · s 30/36 · p — · mc6 cuf2 · green 28/36 · $2.7522 · 2318 s (0.64 h, mean 64 s) | r 30/36 · s 23/36 · p — · mc13 cuf1 · green 22/36 · $2.4791 · 2269 s (0.63 h, mean 63 s) |
| task / floor | r 27/36 · s 26/36 · p — · mc10 · green 26/36 · $0.2301 · 2010 s (0.56 h, mean 56 s) | r 26/36 · s 25/36 · p — · mc11 cuf1 · green 24/36 · $0.2040 · 1827 s (0.51 h, mean 51 s) |
| compose / strong | r 53/54 · s 36/54 · p 6/6 · bar(picture cells) 24/42 · mc12 dis5 lb1 · green 36/54 · $8.6820 (1 null) · 7912 s (2.20 h, mean 147 s) | r 48/48 · s 30/48 · p 6/6 · bar(picture cells) 19/36 · mc14 dis4 cuf2 · green 28/48 · $9.4538 · 7128 s (1.98 h, mean 148 s) |
| compose / floor | r 52/54 · s 51/54 · p 5/6 · bar(picture cells) 40/42 · mc2 cuf4 lb1 · green 47/54 · $0.8918 (1 null) · 8704 s (2.42 h, mean 161 s) | r 47/48 · s 46/48 · p 6/6 · bar(picture cells) 36/36 · mc2 cuf1 · green 45/48 · $0.7830 · 7000 s (1.94 h, mean 146 s) |
| workflow / strong | r 26/30 · s 21/30 · p 28/30 · bar(picture cells) 1/6 · mc6 dis3 cuf13 · green 8/30 · $9.8439 · 4634 s (1.29 h, mean 154 s) | r 29/30 · s 19/30 · p 30/30 · bar(picture cells) 0/6 · mc7 dis10 cuf8 · green 5/30 · $9.2788 · 4207 s (1.17 h, mean 140 s) |
| workflow / floor | r 27/30 · s 26/30 · p 30/30 · bar(picture cells) 3/6 · mc7 dis1 · green 22/30 · $0.8046 · 3997 s (1.11 h, mean 133 s) | r 22/30 · s 18/30 · p 28/30 · bar(picture cells) 2/6 · mc18 dis3 · green 9/30 · $1.5344 · 5043 s (1.40 h, mean 168 s) |

### by tier

| group | v13 | v11 |
|---|---|---|
| strong | r 109/120 · s 87/120 · p 34/36 · bar(picture cells) 25/48 · mc24 dis8 cuf15 lb1 · green 72/120 · $21.2781 (1 null) · 14864 s (4.13 h, mean 124 s) | r 107/114 · s 72/114 · p 36/36 · bar(picture cells) 19/42 · mc34 dis14 cuf11 · green 55/114 · $21.2117 · 13604 s (3.78 h, mean 119 s) |
| floor | r 106/120 · s 103/120 · p 35/36 · bar(picture cells) 43/48 · mc19 dis1 cuf4 lb1 · green 95/120 · $1.9264 (1 null) · 14711 s (4.09 h, mean 123 s) | r 95/114 · s 89/114 · p 34/36 · bar(picture cells) 38/42 · mc31 dis3 cuf2 · green 78/114 · $2.5214 · 13870 s (3.85 h, mean 122 s) |

ALL v13: r 215/240 · s 190/240 · p 69/72 · bar(picture cells) 68/96 · mc43 dis9 cuf19 lb2 · green 167/240 · $23.2045 (2 null) · 29575 s (8.22 h, mean 123 s)
ALL v11: r 202/228 · s 161/228 · p 70/72 · bar(picture cells) 57/84 · mc65 dis17 cuf13 · green 133/228 · $23.7331 · 27474 s (7.63 h, mean 120 s)

Deltas, v13 on v11's cells minus v11 (compose-race-anon out):
- all: reached +1, succeeded +17, passed -1, bar -1, green +23, model conduct -22, disagreement -8, cache under floor +5, cost -1.3006, seconds +1114
- task: reached +1, succeeded +8, passed +0, bar +0, green +8, model conduct -8, disagreement +0, cache under floor +0, cost +0.2992, seconds +232
- compose: reached -2, succeeded -1, passed -1, bar -3, green -1, model conduct -2, disagreement +1, cache under floor +0, cost -1.4350, seconds +1501
- workflow: reached +2, succeeded +10, passed +0, bar +2, green +16, model conduct -12, disagreement -9, cache under floor +5, cost -0.1647, seconds -619
- strong: reached -4, succeeded +9, passed -2, bar +0, green +11, model conduct -10, disagreement -6, cache under floor +4, cost -0.6631, seconds +684
- floor: reached +5, succeeded +8, passed +1, bar -1, green +12, model conduct -12, disagreement -2, cache under floor +1, cost -0.6375, seconds +430
- glm-5.3: reached -1, succeeded +5, passed +0, bar +0, green +4, model conduct -6, disagreement -3, cache under floor +4, cost -1.3776, seconds +954
- kimi-k3: reached -3, succeeded +4, passed -2, bar +0, green +7, model conduct -4, disagreement -3, cache under floor +0, cost +0.7145, seconds -270
- deepseek-flash: reached +0, succeeded +4, passed +0, bar +0, green +4, model conduct -2, disagreement -3, cache under floor +1, cost -0.1376, seconds -87
- glm-5.3-flash: reached +5, succeeded +4, passed +1, bar -1, green +8, model conduct -10, disagreement +1, cache under floor +0, cost -0.4999, seconds +517
v13 on v11's 76 cells only (compose-race-anon out): r 203/228 · s 178/228 · p 69/72 · bar(picture cells) 56/84 · mc43 dis9 cuf18 lb2 · green 156/228 · $22.4325 (2 null) · 28588 s (7.94 h, mean 125 s)

### by model and by family, v13 on v11's cells only (compose-race-anon out)

| group | v13 (v11's cells) | v11 |
|---|---|---|
| glm-5.3 | r 53/57 · s 41/57 · p 18/18 · bar(picture cells) 9/21 · mc9 dis6 cuf5 lb1 · green 36/57 · $8.1761 (1 null) · 9290 s (2.58 h, mean 163 s) | r 54/57 · s 36/57 · p 18/18 · bar(picture cells) 9/21 · mc15 dis9 cuf1 · green 32/57 · $9.5537 · 8336 s (2.32 h, mean 146 s) |
| kimi-k3 | r 50/57 · s 40/57 · p 16/18 · bar(picture cells) 10/21 · mc15 dis2 cuf10 · green 30/57 · $12.3724 · 4998 s (1.39 h, mean 88 s) | r 53/57 · s 36/57 · p 18/18 · bar(picture cells) 10/21 · mc19 dis5 cuf10 · green 23/57 · $11.6580 · 5268 s (1.46 h, mean 92 s) |
| deepseek-flash | r 50/57 · s 50/57 · p 18/18 · bar(picture cells) 19/21 · mc10 cuf3 · green 44/57 · $0.9147 · 4258 s (1.18 h, mean 75 s) | r 50/57 · s 46/57 · p 18/18 · bar(picture cells) 19/21 · mc12 dis3 cuf2 · green 40/57 · $1.0523 · 4345 s (1.21 h, mean 76 s) |
| glm-5.3-flash | r 50/57 · s 47/57 · p 17/18 · bar(picture cells) 18/21 · mc9 dis1 lb1 · green 46/57 · $0.9692 (1 null) · 10042 s (2.79 h, mean 176 s) | r 45/57 · s 43/57 · p 16/18 · bar(picture cells) 19/21 · mc19 · green 38/57 · $1.4691 · 9525 s (2.65 h, mean 167 s) |
| task | r 57/72 · s 56/72 · p — · mc16 cuf2 · green 54/72 · $2.9823 · 4328 s (1.20 h, mean 60 s) | r 56/72 · s 48/72 · p — · mc24 cuf2 · green 46/72 · $2.6831 · 4096 s (1.14 h, mean 57 s) |
| compose | r 93/96 · s 75/96 · p 11/12 · bar(picture cells) 52/72 · mc14 dis5 cuf3 lb2 · green 72/96 · $8.8017 (2 null) · 15629 s (4.34 h, mean 163 s) | r 95/96 · s 76/96 · p 12/12 · bar(picture cells) 55/72 · mc16 dis4 cuf3 · green 73/96 · $10.2368 · 14128 s (3.92 h, mean 147 s) |
| workflow | r 53/60 · s 47/60 · p 58/60 · bar(picture cells) 4/12 · mc13 dis4 cuf13 · green 30/60 · $10.6485 · 8631 s (2.40 h, mean 144 s) | r 51/60 · s 37/60 · p 58/60 · bar(picture cells) 2/12 · mc25 dis13 cuf8 · green 14/60 · $10.8132 · 9250 s (2.57 h, mean 154 s) |
| strong | r 103/114 · s 81/114 · p 34/36 · bar(picture cells) 19/42 · mc24 dis8 cuf15 lb1 · green 66/114 · $20.5486 (1 null) · 14288 s (3.97 h, mean 125 s) | r 107/114 · s 72/114 · p 36/36 · bar(picture cells) 19/42 · mc34 dis14 cuf11 · green 55/114 · $21.2117 · 13604 s (3.78 h, mean 119 s) |
| floor | r 100/114 · s 97/114 · p 35/36 · bar(picture cells) 37/42 · mc19 dis1 cuf3 lb1 · green 90/114 · $1.8839 (1 null) · 14300 s (3.97 h, mean 125 s) | r 95/114 · s 89/114 · p 34/36 · bar(picture cells) 38/42 · mc31 dis3 cuf2 · green 78/114 · $2.5214 · 13870 s (3.85 h, mean 122 s) |

## Moved cells: |Δ| >= 2 of 3 on reached, succeeded, task_pass (passed count) or green

12 cells. Deltas as v13 - v11.

| family | task | model | Δr | Δs | Δp | Δgreen | v13 r s p [classes] | v11 r s p [classes] |
|---|---|---|---|---|---|---|---|---|
| task | task-background-suite | glm-5.3 | +0 | +2 | +0 | +2 | r3 s3 p— [g3] | r3 s1 p— [mc2 g1] |
| task | task-detached-receipt | kimi-k3 | +0 | +2 | +0 | +2 | r3 s3 p— [g3] | r3 s1 p— [mc2 g1] |
| compose | compose-single-read | kimi-k3 | +0 | +0 | +0 | +2 | r3 s3 p— [g3] | r3 s3 p— [cuf2 g1] |
| workflow | workflow-adversarial-verify | kimi-k3 | +0 | +0 | -2 | +0 | r3 s1 p1/3 [mc2 cuf1 g0] | r3 s1 p3/3 [mc1 dis2 g0] |
| workflow | workflow-adversarial-verify | deepseek-flash | +0 | +2 | +0 | +0 | r3 s3 p3/3 [mc3 g0] | r3 s1 p3/3 [mc1 dis2 g0] |
| workflow | workflow-barrier-free-pipeline | kimi-k3 | -2 | +0 | +0 | +0 | r0 s0 p3/3 [mc3 g0] | r2 s0 p3/3 [mc1 dis2 g0] |
| workflow | workflow-fan-out-finders | glm-5.3 | +0 | +0 | +0 | +3 | r3 s3 p3/3 [g3] | r3 s3 p3/3 [mc3 g0] |
| workflow | workflow-fan-out-finders | deepseek-flash | +0 | +0 | +0 | +2 | r3 s3 p3/3 [g3] | r3 s3 p3/3 [mc2 g1] |
| workflow | workflow-fan-out-finders | glm-5.3-flash | +0 | +0 | +0 | +3 | r3 s3 p3/3 [g3] | r3 s3 p3/3 [mc3 g0] |
| workflow | workflow-judge-panel | glm-5.3 | +0 | +0 | +0 | -2 | r3 s3 p3/3 [cuf3 g0] | r3 s3 p3/3 [cuf1 g2] |
| workflow | workflow-loop-until-dry | deepseek-flash | +1 | +1 | +0 | +2 | r3 s3 p3/3 [g3] | r2 s2 p3/3 [mc2 g1] |
| workflow | workflow-loop-until-dry | glm-5.3-flash | +2 | +2 | +1 | +2 | r3 s3 p3/3 [g3] | r1 s1 p2/3 [mc2 g1] |

#### task / task-background-suite / glm-5.3: Δs +2, Δg +2
- v13 #1 r=Y s=Y p=— green 172s $0.1614 :: 
- v13 #2 r=Y s=Y p=— green 94s $0.0877 :: 
- v13 #3 r=Y s=Y p=— green 164s $0.1305 :: 
- v11 #1 r=Y s=N p=— model conduct 192s $0.1500 :: start_process was used for a command whose result was needed
- v11 #2 r=Y s=N p=— model conduct 164s $0.1630 :: start_process was used for a command whose result was needed
- v11 #3 r=Y s=Y p=— green 159s $0.2077 :: 

#### task / task-detached-receipt / kimi-k3: Δs +2, Δg +2
- v13 #1 r=Y s=Y p=— green 96s $0.1057 :: 
- v13 #2 r=Y s=Y p=— green 100s $0.1247 :: 
- v13 #3 r=Y s=Y p=— green 103s $0.0754 :: 
- v11 #1 r=Y s=Y p=— green 94s $0.0769 :: 
- v11 #2 r=Y s=N p=— model conduct 74s $0.0322 :: only 1 loop completed on the feed: the receipt woke no turn — the call asked `wake: "passive"`
- v11 #3 r=Y s=N p=— model conduct 68s $0.0321 :: only 1 loop completed on the feed: the receipt woke no turn — the call asked `wake: "passive"`

#### compose / compose-single-read / kimi-k3: Δg +2
- v13 #1 r=Y s=Y p=— green 12s $0.0324 :: 
- v13 #2 r=Y s=Y p=— green 14s $0.0286 :: 
- v13 #3 r=Y s=Y p=— green 12s $0.0250 :: 
- v11 #1 r=Y s=Y p=— green 24s $0.0543 :: 
- v11 #2 r=Y s=Y p=— cache under floor 14s $0.0614 :: 
- v11 #3 r=Y s=Y p=— cache under floor 13s $0.0574 :: 

#### workflow / workflow-adversarial-verify / kimi-k3: Δp -2
- v13 #1 r=Y s=N p=N model conduct 201s $1.0803 :: no input_accepted{origin: task_result}: the kernel mailed no receipt ({"read" => 13, "ls" => 2, "task" => 12, "bash" => 14, "write" => 2})
- v13 #2 r=Y s=Y p=Y cache under floor 182s $0.8356 :: 
- v13 #3 r=Y s=N p=N model conduct 272s $0.8218 :: no input_accepted{origin: task_result}: the kernel mailed no receipt ({"read" => 42, "ls" => 12, "task" => 13, "find" => 1, "bash" => 17, "g…
- v11 #1 r=Y s=N p=Y disagreement 190s $0.9014 :: no input_accepted{origin: task_result}: the kernel mailed no receipt ({"read" => 35, "ls" => 7, "task" => 12, "bash" => 18, "grep" => 2, "wr…
- v11 #2 r=Y s=Y p=Y model conduct 193s $1.0374 :: [conduct failed: did_not_judge_itself]
- v11 #3 r=Y s=N p=Y disagreement 181s $0.4785 :: no input_accepted{origin: task_result}: the kernel mailed no receipt ({"read" => 35, "ls" => 3, "task" => 12, "bash" => 20, "write" => 2}) […

#### workflow / workflow-adversarial-verify / deepseek-flash: Δs +2
- v13 #1 r=Y s=Y p=Y model conduct 283s $0.0828 :: [conduct failed: did_not_judge_itself]
- v13 #2 r=Y s=Y p=Y model conduct 127s $0.0355 :: [conduct failed: did_not_judge_itself]
- v13 #3 r=Y s=Y p=Y model conduct 321s $0.1232 :: [conduct failed: did_not_judge_itself]
- v11 #1 r=Y s=N p=Y disagreement 191s $0.0494 :: no input_accepted{origin: task_result}: the kernel mailed no receipt ({"read" => 37, "ls" => 3, "task" => 12, "bash" => 31, "write" => 1}) […
- v11 #2 r=Y s=N p=Y disagreement 130s $0.0371 :: no input_accepted{origin: task_result}: the kernel mailed no receipt ({"read" => 5, "bash" => 14, "memory_write" => 2, "todo_write" => 2, "t…
- v11 #3 r=Y s=Y p=Y model conduct 400s $0.3375 :: [conduct failed: did_not_judge_itself]

#### workflow / workflow-barrier-free-pipeline / kimi-k3: Δr -2
- v13 #1 r=N s=— p=Y model conduct 31s $0.0459 :: no compose call and no round fanned two task calls: {"ls" => 1, "read" => 1, "bash" => 1} {picture: no compose call to score; usable_on_call: None}
- v13 #2 r=N s=— p=Y model conduct 40s $0.0897 :: no compose call and no round fanned two task calls: {"ls" => 1, "bash" => 5} {picture: no compose call to score; usable_on_call: None}
- v13 #3 r=N s=— p=Y model conduct 34s $0.0525 :: no compose call and no round fanned two task calls: {"ls" => 1, "read" => 1, "bash" => 1} {picture: no compose call to score; usable_on_call: None}
- v11 #1 r=Y s=N p=Y disagreement 57s $0.0828 :: the picture is not the objective's (silent: edit_as_tool, missing_steps): {"nodes" => ["tool-1:tool", "tool-2:tool", "tool-3:tool", "tool-4:… {picture: the picture is not the objective's (silent: edit_as_tool, mi; usable_on_call: 1}
- v11 #2 r=N s=— p=Y model conduct 46s $0.1293 :: no compose call and no round fanned two task calls: {"ls" => 1, "bash" => 5, "read" => 2} {picture: no compose call to score; usable_on_call: None}
- v11 #3 r=Y s=N p=Y disagreement 60s $0.1524 :: the picture is not the objective's (silent: edit_as_tool, missing_steps): {"nodes" => ["tool-1:tool", "tool-2:tool", "tool-3:tool", "tool-4:… {picture: the picture is not the objective's (silent: edit_as_tool, mi; usable_on_call: 1}

#### workflow / workflow-fan-out-finders / glm-5.3: Δg +3
- v13 #1 r=Y s=Y p=Y green 77s $0.0615 :: 
- v13 #2 r=Y s=Y p=Y green 62s $0.0401 :: 
- v13 #3 r=Y s=Y p=Y green 57s $0.0384 :: 
- v11 #1 r=Y s=Y p=Y model conduct 57s $0.0552 :: [conduct failed: did_not_search_itself]
- v11 #2 r=Y s=Y p=Y model conduct 65s $0.0796 :: [conduct failed: did_not_search_itself]
- v11 #3 r=Y s=Y p=Y model conduct 60s $0.0443 :: [conduct failed: did_not_search_itself]

#### workflow / workflow-fan-out-finders / deepseek-flash: Δg +2
- v13 #1 r=Y s=Y p=Y green 56s $0.0075 :: 
- v13 #2 r=Y s=Y p=Y green 56s $0.0067 :: 
- v13 #3 r=Y s=Y p=Y green 51s $0.0059 :: 
- v11 #1 r=Y s=Y p=Y green 196s $0.0109 :: 
- v11 #2 r=Y s=Y p=Y model conduct 66s $0.0078 :: [conduct failed: did_not_search_itself]
- v11 #3 r=Y s=Y p=Y model conduct 86s $0.0126 :: [conduct failed: did_not_search_itself]

#### workflow / workflow-fan-out-finders / glm-5.3-flash: Δg +3
- v13 #1 r=Y s=Y p=Y green 107s $0.0208 :: 
- v13 #2 r=Y s=Y p=Y green 92s $0.0177 :: 
- v13 #3 r=Y s=Y p=Y green 202s $0.0145 :: 
- v11 #1 r=Y s=Y p=Y model conduct 60s $0.0171 :: [conduct failed: did_not_search_itself]
- v11 #2 r=Y s=Y p=Y model conduct 64s $0.0086 :: [conduct failed: did_not_search_itself]
- v11 #3 r=Y s=Y p=Y model conduct 72s $0.0107 :: [conduct failed: did_not_search_itself]

#### workflow / workflow-judge-panel / glm-5.3: Δg -2
- v13 #1 r=Y s=Y p=Y cache under floor 224s $0.3764 :: 
- v13 #2 r=Y s=Y p=Y cache under floor 160s $0.2150 :: 
- v13 #3 r=Y s=Y p=Y cache under floor 345s $0.6368 :: 
- v11 #1 r=Y s=Y p=Y green 186s $0.2960 :: 
- v11 #2 r=Y s=Y p=Y green 251s $0.3224 :: 
- v11 #3 r=Y s=Y p=Y cache under floor 213s $0.3261 :: 

#### workflow / workflow-loop-until-dry / deepseek-flash: Δg +2
- v13 #1 r=Y s=Y p=Y green 53s $0.0037 :: 
- v13 #2 r=Y s=Y p=Y green 60s $0.0044 :: 
- v13 #3 r=Y s=Y p=Y green 74s $0.0049 :: 
- v11 #1 r=Y s=Y p=Y model conduct 55s $0.0040 :: [conduct failed: one_item_per_pass]
- v11 #2 r=Y s=Y p=Y green 72s $0.0060 :: 
- v11 #3 r=N s=— p=Y model conduct 60s $0.0057 :: no iteration: 15 pass(es), 1 item touches ({"bash" => 15}) [conduct failed: one_item_per_pass]

#### workflow / workflow-loop-until-dry / glm-5.3-flash: Δr +2, Δs +2, Δg +2
- v13 #1 r=Y s=Y p=Y green 93s $0.0173 :: 
- v13 #2 r=Y s=Y p=Y green 101s $0.0188 :: 
- v13 #3 r=Y s=Y p=Y green 74s $0.0066 :: 
- v11 #1 r=N s=— p=Y model conduct 103s $0.0176 :: no iteration: 8 pass(es), 0 item touches ({"bash" => 7, "todo_write" => 7})
- v11 #2 r=Y s=Y p=Y green 64s $0.0062 :: 
- v11 #3 r=N s=— p=N model conduct 48s $0.0035 :: no iteration: 4 pass(es), 0 item touches ({"bash" => 4}) [conduct failed: one_item_per_pass]

### Picture cells whose picture fact or usable count moved by >= 2 of 3 (the floor's picture is a fact, not its bar)

#### compose-background-suite / deepseek-flash (floor): picture 2 -> 0 (-2), usable 3 -> 3 (+0)
- v13 #1 r=Y s=Y p=— green 94s $0.0303 ::  {picture: the script was refused script_error: Error: g.model: unknown; usable_on_call: 2}
- v13 #2 r=Y s=Y p=— green 210s $0.0276 ::  {picture: the picture is not the objective's (silent: suite_waited_on,; usable_on_call: 1}
- v13 #3 r=Y s=Y p=— green 75s $0.0132 ::  {picture: the picture is not the objective's (silent: suite_waited_on,; usable_on_call: 1}
- v11 #1 r=Y s=Y p=— green 96s $0.0165 ::  {picture: true; usable_on_call: 1}
- v11 #2 r=Y s=Y p=— green 89s $0.0216 ::  {picture: true; usable_on_call: 1}
- v11 #3 r=Y s=Y p=— green 64s $0.0134 ::  {picture: the picture is not the objective's (silent: suite_waited_on,; usable_on_call: 1}

#### compose-three-stage-pairing / deepseek-flash (floor): picture 1 -> 3 (+2), usable 3 -> 3 (+0)
- v13 #1 r=Y s=Y p=— green 38s $0.0062 ::  {picture: true; usable_on_call: 1}
- v13 #2 r=Y s=Y p=— green 49s $0.0053 ::  {picture: true; usable_on_call: 1}
- v13 #3 r=Y s=Y p=— green 59s $0.0141 ::  {picture: true; usable_on_call: 1}
- v11 #1 r=Y s=Y p=— green 35s $0.0060 ::  {picture: the picture is not the objective's (silent: over_read): {"no; usable_on_call: 1}
- v11 #2 r=Y s=Y p=— green 35s $0.0056 ::  {picture: true; usable_on_call: 1}
- v11 #3 r=Y s=Y p=— green 35s $0.0050 ::  {picture: the picture is not the objective's (silent: over_read): {"no; usable_on_call: 1}

#### compose-three-stage-pairing / glm-5.3-flash (floor): picture 3 -> 1 (-2), usable 3 -> 2 (-1)
- v13 #1 r=N s=— p=— model conduct 283s $0.0151 :: no compose call: the model called {"write" => 1, "bash" => 3, "read" => 1, "edit" => 1} {picture: no compose call to score; usable_on_call: None}
- v13 #2 r=Y s=Y p=— green 196s $0.0161 ::  {picture: the picture is not the objective's (silent: over_read): {"no; usable_on_call: 1}
- v13 #3 r=Y s=Y p=— green 329s $0.0204 ::  {picture: true; usable_on_call: 1}
- v11 #1 r=Y s=Y p=— green 209s $0.0237 ::  {picture: true; usable_on_call: 1}
- v11 #2 r=Y s=Y p=— green 221s $0.0160 ::  {picture: true; usable_on_call: 1}
- v11 #3 r=Y s=Y p=— green 278s $0.0178 ::  {picture: true; usable_on_call: 1}

#### compose-two-source-fan-in / glm-5.3-flash (floor): picture 3 -> 1 (-2), usable 3 -> 3 (+0)
- v13 #1 r=Y s=Y p=— green 120s $0.0130 ::  {picture: true; usable_on_call: 1}
- v13 #2 r=Y s=Y p=— green 159s $0.0126 ::  {picture: the picture is not the objective's (silent: over_read): {"no; usable_on_call: 1}
- v13 #3 r=Y s=Y p=— green 242s $0.0152 ::  {picture: the picture is not the objective's (silent: over_read): {"no; usable_on_call: 1}
- v11 #1 r=Y s=Y p=— green 217s $0.0118 ::  {picture: true; usable_on_call: 1}
- v11 #2 r=Y s=Y p=— green 357s $0.0200 ::  {picture: true; usable_on_call: 1}
- v11 #3 r=Y s=Y p=— green 244s $0.0121 ::  {picture: true; usable_on_call: 1}

#### workflow-barrier-free-pipeline / kimi-k3 (strong): picture 0 -> 0 (+0), usable 2 -> 0 (-2)
- v13 #1 r=N s=— p=Y model conduct 31s $0.0459 :: no compose call and no round fanned two task calls: {"ls" => 1, "read" => 1, "bash" => 1} {picture: no compose call to score; usable_on_call: None}
- v13 #2 r=N s=— p=Y model conduct 40s $0.0897 :: no compose call and no round fanned two task calls: {"ls" => 1, "bash" => 5} {picture: no compose call to score; usable_on_call: None}
- v13 #3 r=N s=— p=Y model conduct 34s $0.0525 :: no compose call and no round fanned two task calls: {"ls" => 1, "read" => 1, "bash" => 1} {picture: no compose call to score; usable_on_call: None}
- v11 #1 r=Y s=N p=Y disagreement 57s $0.0828 :: the picture is not the objective's (silent: edit_as_tool, missing_steps): {"nodes" => ["tool-1:tool", "tool-2:tool", "tool-3:tool", "tool-4:… {picture: the picture is not the objective's (silent: edit_as_tool, mi; usable_on_call: 1}
- v11 #2 r=N s=— p=Y model conduct 46s $0.1293 :: no compose call and no round fanned two task calls: {"ls" => 1, "bash" => 5, "read" => 2} {picture: no compose call to score; usable_on_call: None}
- v11 #3 r=Y s=N p=Y disagreement 60s $0.1524 :: the picture is not the objective's (silent: edit_as_tool, missing_steps): {"nodes" => ["tool-1:tool", "tool-2:tool", "tool-3:tool", "tool-4:… {picture: the picture is not the objective's (silent: edit_as_tool, mi; usable_on_call: 1}


## Reds by reason kind, per family (every record whose class is not green)


### task: v13 18 reds, v11 26

| reason kind | v13 | v11 | v13 by model (glm / kimi / ds-flash / glm-flash) | v13 by task |
|---|---|---|---|---|
| no `task` call; start_process in the tally | 12 | 12 | 2 / 3 / 3 / 4 | background-suite 4, mail 8 |
| fewer than five `task` calls in the first message | 2 | 3 | 0 / 0 / 2 / 0 | fan-five 2 |
| cache under floor (success held) | 2 | 2 | 0 / 2 / 0 / 0 | background-suite 2 |
| the merged reply misses a finding | 1 | 1 | 0 / 0 / 0 / 1 | fan-five 1 |
| no `task` call; no start_process | 1 | 0 | 0 / 1 / 0 / 0 | mail 1 |
| start_process was used for a command whose result was needed | 0 | 3 | 0 / 0 / 0 / 0 |  |
| only 1 loop completed on the feed: the receipt woke no turn — the call asked `wa | 0 | 2 | 0 / 0 / 0 / 0 |  |
| a second task for a.rb, b.rb, c.rb, d.rb, e.rb | 0 | 1 | 0 / 0 / 0 / 0 |  |
| the calls covered 0 of the 3 files (config/app.yml, config/db.yml, config/cache. | 0 | 1 | 0 / 0 / 0 / 0 |  |
| the receipt woke no turn (passive wake) | 0 | 1 | 0 / 0 / 0 / 0 |  |

v13 conduct checks failed/checked: named_db_and_cache 0/12, no_false_claim 0/12

v11 conduct checks failed/checked: named_db_and_cache 0/12, no_false_claim 0/12

### compose: v13 25 reds, v11 23

| reason kind | v13 | v11 | v13 by model (glm / kimi / ds-flash / glm-flash) | v13 by task |
|---|---|---|---|---|
| picture red (first compose call) | 16 | 16 | 8 / 8 / 0 / 0 | background-suite 3, grep-then-edit 5, three-stage-pairing 2, two-source-fan-in 6 |
| cache under floor (success held) | 4 | 3 | 0 / 0 / 4 / 0 | grep-then-edit 1, race 1, race-anon 1, rendezvous 1 |
| deadline stop, 0 rounds settled, no call at all | 2 | 0 | 1 / 0 / 0 / 1 | background-suite 1, grep-then-edit 1 |
| compose refused (script_error) | 1 | 1 | 0 / 0 / 0 / 1 | rendezvous 1 |
| compose refused (script_syntax_error) | 1 | 1 | 1 / 0 / 0 / 0 | review-angles 1 |
| no compose call (did it with tools) | 1 | 1 | 0 / 0 / 0 / 1 | three-stage-pairing 1 |
| stopped deadline: r2t0-model-3 | 0 | 1 | 0 / 0 / 0 / 0 |  |

v13 picture-red buckets over 16 picture-red records: over_read 9, extra_steps 5, over_sync 4, suite_waited_on 3, missing_steps 3

v11 picture-red buckets over 16 picture-red records: over_read 11, suite_waited_on 5, extra_steps 5, over_sync 5, missing_steps 2

v13 conduct checks failed/checked: no_wrong_winner 0/24

### workflow: v13 30 reds, v11 46

| reason kind | v13 | v11 | v13 by model (glm / kimi / ds-flash / glm-flash) | v13 by task |
|---|---|---|---|---|
| cache under floor (success held) | 13 | 8 | 5 / 8 / 0 / 0 | adversarial-verify 2, barrier-free-pipeline 1, fan-out-finders 3, judge-panel 5, loop-until-dry 2 |
| no compose call and no two-`task` fan (did it with tools) | 7 | 5 | 1 / 3 / 2 / 1 | barrier-free-pipeline 7 |
| no task_result receipt ("the kernel mailed no receipt") | 5 | 8 | 2 / 2 / 0 / 1 | adversarial-verify 5 |
| conduct only: did_not_judge_itself | 4 | 4 | 0 / 0 / 3 / 1 | adversarial-verify 4 |
| picture red (first compose call) | 1 | 5 | 1 / 0 / 0 / 0 | barrier-free-pipeline 1 |
| conduct only: did_not_search_itself | 0 | 10 | 0 / 0 / 0 / 0 |  |
| no iteration (loop reach) | 0 | 3 | 0 / 0 / 0 / 0 |  |
| conduct only: one_item_per_pass | 0 | 1 | 0 / 0 / 0 / 0 |  |
| r4t0 composed 4 tasks and no step reads two model members; r5t0 composed 5 tasks | 0 | 1 | 0 / 0 / 0 / 0 |  |
| stopped deadline: no compose call and no round fanned two task calls | 0 | 1 | 0 / 0 / 0 / 0 |  |

v13 picture-red buckets over 1 picture-red records: edit_as_tool 1

v11 picture-red buckets over 5 picture-red records: missing_steps 4, edit_as_tool 3

v13 conduct checks failed/checked: did_not_judge_itself 6/12, did_not_search_itself 0/12, one_item_per_pass 0/12

v11 conduct checks failed/checked: did_not_judge_itself 12/12, did_not_search_itself 10/12, one_item_per_pass 3/12

## Cost and duration per model

| model | tier | v13 task $ | v13 compose $ | v13 workflow $ | v13 total $ | v11 total $ | Δ$ | v13 seconds (h) | v11 seconds (h) | v13 mean s/run | v11 mean s/run |
|---|---|---|---|---|---|---|---|---|---|---|---|
| glm-5.3 | strong | 0.7986 | 4.2624 | 3.5806 | 8.6416 | 9.5537 | -0.9121 | 9692 (2.69) | 8336 (2.32) | 162 | 146 |
| kimi-k3 | strong | 1.9536 | 4.4196 | 6.2633 | 12.6364 | 11.6580 | +0.9785 | 5172 (1.44) | 5268 (1.46) | 86 | 92 |
| deepseek-flash | floor | 0.0809 | 0.4665 | 0.3919 | 0.9393 | 1.0523 | -0.1130 | 4379 (1.22) | 4345 (1.21) | 73 | 76 |
| glm-5.3-flash | floor | 0.1492 | 0.4253 | 0.4127 | 0.9871 | 1.4691 | -0.4820 | 10332 (2.87) | 9525 (2.65) | 172 | 167 |

Per model and family (v13 includes compose-race-anon's 12 runs; v11 had no such cell):

| model | task $ v13 / v11 / Δ | compose $ v13 / v11 / Δ | workflow $ v13 / v11 / Δ | seconds v13 / v11 / Δ |
|---|---|---|---|---|
| glm-5.3 | 0.7986 / 1.0663 / -0.2677 | 4.2624 / 5.1489 / -0.8865 | 3.5806 / 3.3385 / +0.2421 | 9692 / 8336 / +1356 |
| kimi-k3 | 1.9536 / 1.4128 / +0.5408 | 4.4196 / 4.3049 / +0.1147 | 6.2633 / 5.9403 / +0.3230 | 5172 / 5268 / -96 |
| deepseek-flash | 0.0809 / 0.1014 / -0.0205 | 0.4665 / 0.3651 / +0.1014 | 0.3919 / 0.5859 / -0.1940 | 4379 / 4345 / +34 |
| glm-5.3-flash | 0.1492 / 0.1026 / +0.0466 | 0.4253 / 0.4179 / +0.0073 | 0.4127 / 0.9486 / -0.5359 | 10332 / 9525 / +807 |

v13: total $23.2045 (2 null-cost records); by family task $2.9823 / 4328 s, compose $9.5737 / 16616 s, workflow $10.6485 / 8631 s; seconds 29575 (8.22 h)

v11: total $23.7331 (0 null-cost records); by family task $2.6831 / 4096 s, compose $10.2368 / 14128 s, workflow $10.8132 / 9250 s; seconds 27474 (7.63 h)

v13 null-cost records: compose-background-suite glm-5.3 #3 (class lane bug, stopped deadline, rounds_settled 0, input_tokens 0); compose-grep-then-edit glm-5.3-flash #1 (class lane bug, stopped deadline, rounds_settled 0, input_tokens 0)

Top 8 v13 records by cost:
- $1.0803 workflow-adversarial-verify kimi-k3 #1 (201 s, class model conduct)
- $0.8356 workflow-adversarial-verify kimi-k3 #2 (182 s, class cache under floor)
- $0.8218 workflow-adversarial-verify kimi-k3 #3 (272 s, class model conduct)
- $0.6472 workflow-adversarial-verify glm-5.3 #1 (264 s, class cache under floor)
- $0.6368 workflow-judge-panel glm-5.3 #3 (345 s, class cache under floor)
- $0.5714 workflow-judge-panel kimi-k3 #2 (187 s, class cache under floor)
- $0.4684 workflow-judge-panel kimi-k3 #1 (132 s, class None)
- $0.4135 workflow-fan-out-finders kimi-k3 #1 (85 s, class cache under floor)

Top 8 v13 records by seconds:
- 611 s compose-rendezvous glm-5.3-flash #3 ($0.0436, class None, stopped None)
- 607 s compose-background-suite glm-5.3 #3 ($0.0000, class lane bug, stopped deadline)
- 607 s compose-grep-then-edit glm-5.3-flash #1 ($0.0000, class lane bug, stopped deadline)
- 587 s compose-three-stage-pairing glm-5.3 #1 ($0.2886, class None, stopped None)
- 475 s compose-rendezvous glm-5.3-flash #1 ($0.0315, class model conduct, stopped None)
- 421 s compose-three-stage-pairing glm-5.3 #3 ($0.2430, class None, stopped None)
- 416 s compose-grep-then-edit glm-5.3 #1 ($0.2584, class disagreement, stopped None)
- 401 s workflow-barrier-free-pipeline glm-5.3 #2 ($0.3319, class disagreement, stopped None)

## usable_on_call on the picture tasks (every run, both tiers)

| task | model | tier | v13 reach | v13 usable | v13 picture | v13 on call 1/2/3/none | v11 reach | v11 usable | v11 picture | v11 on call 1/2/3/none |
|---|---|---|---|---|---|---|---|---|---|---|
| compose-background-suite | glm-5.3 | strong | 2/3 | 2/3 | 1/3 | 2/0/0/1 | 3/3 | 3/3 | 1/3 | 3/0/0/0 |
| compose-background-suite | kimi-k3 | strong | 3/3 | 3/3 | 1/3 | 3/0/0/0 | 3/3 | 3/3 | 0/3 | 3/0/0/0 |
| compose-background-suite | deepseek-flash | floor | 3/3 | 3/3 | 0/3 | 2/1/0/0 | 3/3 | 3/3 | 2/3 | 3/0/0/0 |
| compose-background-suite | glm-5.3-flash | floor | 3/3 | 3/3 | 1/3 | 3/0/0/0 | 3/3 | 3/3 | 0/3 | 3/0/0/0 |
| compose-grep-then-edit | glm-5.3 | strong | 3/3 | 3/3 | 0/3 | 2/1/0/0 | 3/3 | 3/3 | 0/3 | 2/0/1/0 |
| compose-grep-then-edit | kimi-k3 | strong | 3/3 | 3/3 | 1/3 | 3/0/0/0 | 3/3 | 3/3 | 2/3 | 3/0/0/0 |
| compose-grep-then-edit | deepseek-flash | floor | 3/3 | 3/3 | 2/3 | 2/1/0/0 | 3/3 | 3/3 | 2/3 | 3/0/0/0 |
| compose-grep-then-edit | glm-5.3-flash | floor | 2/3 | 2/3 | 0/3 | 2/0/0/1 | 3/3 | 3/3 | 0/3 | 3/0/0/0 |
| compose-race | glm-5.3 | strong | 3/3 | 3/3 | 3/3 | 3/0/0/0 | 3/3 | 3/3 | 2/3 | 3/0/0/0 |
| compose-race | kimi-k3 | strong | 3/3 | 3/3 | 3/3 | 3/0/0/0 | 3/3 | 3/3 | 2/3 | 2/1/0/0 |
| compose-race | deepseek-flash | floor | 3/3 | 3/3 | 2/3 | 2/1/0/0 | 3/3 | 3/3 | 2/3 | 3/0/0/0 |
| compose-race | glm-5.3-flash | floor | 3/3 | 3/3 | 2/3 | 2/1/0/0 | 3/3 | 3/3 | 1/3 | 3/0/0/0 |
| compose-race-anon | glm-5.3 | strong | 3/3 | 3/3 | 3/3 | 3/0/0/0 | new | new | new | new |
| compose-race-anon | kimi-k3 | strong | 3/3 | 3/3 | 3/3 | 3/0/0/0 | new | new | new | new |
| compose-race-anon | deepseek-flash | floor | 3/3 | 3/3 | 2/3 | 2/1/0/0 | new | new | new | new |
| compose-race-anon | glm-5.3-flash | floor | 3/3 | 3/3 | 3/3 | 3/0/0/0 | new | new | new | new |
| compose-review-angles | glm-5.3 | strong | 3/3 | 3/3 | 2/3 | 2/1/0/0 | 3/3 | 3/3 | 3/3 | 3/0/0/0 |
| compose-review-angles | kimi-k3 | strong | 3/3 | 3/3 | 3/3 | 3/0/0/0 | 3/3 | 3/3 | 3/3 | 3/0/0/0 |
| compose-review-angles | deepseek-flash | floor | 3/3 | 3/3 | 3/3 | 3/0/0/0 | 3/3 | 3/3 | 3/3 | 3/0/0/0 |
| compose-review-angles | glm-5.3-flash | floor | 3/3 | 3/3 | 2/3 | 2/1/0/0 | 3/3 | 3/3 | 3/3 | 3/0/0/0 |
| compose-three-stage-pairing | glm-5.3 | strong | 3/3 | 3/3 | 2/3 | 3/0/0/0 | 3/3 | 3/3 | 2/3 | 3/0/0/0 |
| compose-three-stage-pairing | kimi-k3 | strong | 3/3 | 3/3 | 2/3 | 2/1/0/0 | 3/3 | 3/3 | 3/3 | 3/0/0/0 |
| compose-three-stage-pairing | deepseek-flash | floor | 3/3 | 3/3 | 3/3 | 3/0/0/0 | 3/3 | 3/3 | 1/3 | 3/0/0/0 |
| compose-three-stage-pairing | glm-5.3-flash | floor | 2/3 | 2/3 | 1/3 | 2/0/0/1 | 3/3 | 3/3 | 3/3 | 3/0/0/0 |
| compose-two-source-fan-in | glm-5.3 | strong | 3/3 | 3/3 | 0/3 | 3/0/0/0 | 3/3 | 3/3 | 1/3 | 3/0/0/0 |
| compose-two-source-fan-in | kimi-k3 | strong | 3/3 | 3/3 | 0/3 | 3/0/0/0 | 3/3 | 3/3 | 0/3 | 3/0/0/0 |
| compose-two-source-fan-in | deepseek-flash | floor | 3/3 | 3/3 | 1/3 | 3/0/0/0 | 3/3 | 3/3 | 2/3 | 3/0/0/0 |
| compose-two-source-fan-in | glm-5.3-flash | floor | 3/3 | 3/3 | 1/3 | 3/0/0/0 | 3/3 | 3/3 | 3/3 | 3/0/0/0 |
| workflow-barrier-free-pipeline | glm-5.3 | strong | 2/3 | 2/3 | 1/3 | 2/0/0/1 | 3/3 | 3/3 | 0/3 | 3/0/0/0 |
| workflow-barrier-free-pipeline | kimi-k3 | strong | 0/3 | 0/3 | 0/3 | 0/0/0/3 | 2/3 | 2/3 | 0/3 | 2/0/0/1 |
| workflow-barrier-free-pipeline | deepseek-flash | floor | 1/3 | 1/3 | 0/3 | 1/0/0/2 | 1/3 | 1/3 | 0/3 | 0/1/0/2 |
| workflow-barrier-free-pipeline | glm-5.3-flash | floor | 2/3 | 2/3 | 0/3 | 2/0/0/1 | 1/3 | 1/3 | 0/3 | 1/0/0/2 |

| scope | model | tier | runs | usable | picture | on call 1 / 2 / 3 / none | first-call usable / runs | first-call usable / usable |
|---|---|---|---|---|---|---|---|---|
| v11 | glm-5.3 | strong | 21 | 21 | 9 | 20 / 0 / 1 / 0 | 20/21 (95 %) | 20/21 (95 %) |
| v11 | kimi-k3 | strong | 21 | 20 | 10 | 19 / 1 / 0 / 1 | 19/21 (90 %) | 19/20 (95 %) |
| v11 | deepseek-flash | floor | 21 | 19 | 12 | 18 / 1 / 0 / 2 | 18/21 (86 %) | 18/19 (95 %) |
| v11 | glm-5.3-flash | floor | 21 | 19 | 10 | 19 / 0 / 0 / 2 | 19/21 (90 %) | 19/19 (100 %) |
| v11 compose-only | glm-5.3 | strong | 18 | 18 | 9 | 17 / 0 / 1 / 0 | 17/18 (94 %) | 17/18 (94 %) |
| v11 compose-only | kimi-k3 | strong | 18 | 18 | 10 | 17 / 1 / 0 / 0 | 17/18 (94 %) | 17/18 (94 %) |
| v11 compose-only | deepseek-flash | floor | 18 | 18 | 12 | 18 / 0 / 0 / 0 | 18/18 (100 %) | 18/18 (100 %) |
| v11 compose-only | glm-5.3-flash | floor | 18 | 18 | 10 | 18 / 0 / 0 / 0 | 18/18 (100 %) | 18/18 (100 %) |
| v13 | glm-5.3 | strong | 24 | 22 | 12 | 20 / 2 / 0 / 2 | 20/24 (83 %) | 20/22 (91 %) |
| v13 | kimi-k3 | strong | 24 | 21 | 13 | 20 / 1 / 0 / 3 | 20/24 (83 %) | 20/21 (95 %) |
| v13 | deepseek-flash | floor | 24 | 22 | 13 | 18 / 4 / 0 / 2 | 18/24 (75 %) | 18/22 (82 %) |
| v13 | glm-5.3-flash | floor | 24 | 21 | 10 | 19 / 2 / 0 / 3 | 19/24 (79 %) | 19/21 (90 %) |
| v13 compose-only | glm-5.3 | strong | 21 | 20 | 11 | 18 / 2 / 0 / 1 | 18/21 (86 %) | 18/20 (90 %) |
| v13 compose-only | kimi-k3 | strong | 21 | 21 | 13 | 20 / 1 / 0 / 0 | 20/21 (95 %) | 20/21 (95 %) |
| v13 compose-only | deepseek-flash | floor | 21 | 21 | 13 | 17 / 4 / 0 / 0 | 17/21 (81 %) | 17/21 (81 %) |
| v13 compose-only | glm-5.3-flash | floor | 21 | 19 | 10 | 17 / 2 / 0 / 2 | 17/21 (81 %) | 17/19 (89 %) |
- v13 floor: runs 48, usable 43, picture 23, on call 1/2/3/none 37/6/0/5
- v13 strong: runs 48, usable 43, picture 25, on call 1/2/3/none 40/3/0/5
- v11 floor: runs 42, usable 38, picture 22, on call 1/2/3/none 37/1/0/4
- v11 strong: runs 42, usable 41, picture 19, on call 1/2/3/none 39/1/1/1
- v13 compose-only floor: runs 42, usable 40, picture 23, on call 1/2/3/none 34/6/0/2
- v13 compose-only strong: runs 42, usable 41, picture 24, on call 1/2/3/none 38/3/0/1
- v11 compose-only floor: runs 36, usable 36, picture 22, on call 1/2/3/none 36/0/0/0
- v11 compose-only strong: runs 36, usable 36, picture 19, on call 1/2/3/none 34/1/1/0

Floor picture-task runs NOT usable on call 1 (v13):
- compose-background-suite deepseek-flash #1 r=Y s=Y p=— green 94s $0.0303 ::  {picture: the script was refused script_error: Error: g.model: unknown; usable_on_call: 2}
- compose-grep-then-edit deepseek-flash #2 r=Y s=Y p=Y cache under floor 106s $0.0336 ::  {picture: the script was refused script_syntax_error: SyntaxError: Une; usable_on_call: 2}
- compose-grep-then-edit glm-5.3-flash #1 r=N s=— p=N lane bug 607s $null :: [stopped deadline at 607 s] no compose call: the model called {} {picture: no compose call to score; usable_on_call: None}
- compose-race deepseek-flash #1 r=Y s=Y p=— cache under floor 38s $0.0089 ::  {picture: the script was refused script_syntax_error: SyntaxError: Inv; usable_on_call: 2}
- compose-race glm-5.3-flash #1 r=Y s=Y p=— green 295s $0.0109 ::  {picture: the picture is not the objective's (silent: missing_join, mi; usable_on_call: 2}
- compose-race-anon deepseek-flash #3 r=Y s=Y p=— cache under floor 37s $0.0081 ::  {picture: the script was refused script_error: Error: g.parallel: ever; usable_on_call: 2}
- compose-review-angles glm-5.3-flash #1 r=Y s=Y p=— green 218s $0.0249 ::  {picture: the script was refused script_error: Error: g.model: results; usable_on_call: 2}
- compose-three-stage-pairing glm-5.3-flash #1 r=N s=— p=— model conduct 283s $0.0151 :: no compose call: the model called {"write" => 1, "bash" => 3, "read" => 1, "edit" => 1} {picture: no compose call to score; usable_on_call: None}
- workflow-barrier-free-pipeline deepseek-flash #1 r=N s=— p=Y model conduct 28s $0.0017 :: no compose call and no round fanned two task calls: {"bash" => 2, "ls" => 1} {picture: no compose call to score; usable_on_call: None}
- workflow-barrier-free-pipeline deepseek-flash #2 r=N s=— p=Y model conduct 41s $0.0046 :: no compose call and no round fanned two task calls: {"bash" => 4, "write" => 2} {picture: no compose call to score; usable_on_call: None}
- workflow-barrier-free-pipeline glm-5.3-flash #2 r=N s=— p=Y model conduct 48s $0.0037 :: no compose call and no round fanned two task calls: {"ls" => 1, "find" => 1, "read" => 1, "bash" => 1} {picture: no compose call to score; usable_on_call: None}

Strong picture-task runs NOT usable on call 1 (v13):
- compose-background-suite glm-5.3 #3 r=N s=— p=— lane bug 607s $null :: [stopped deadline at 607 s] no compose call: the model called {} {picture: no compose call to score; usable_on_call: None}
- compose-grep-then-edit glm-5.3 #1 r=Y s=N p=Y disagreement 416s $0.2584 :: the picture is not the objective's (silent: missing_steps): {"nodes" => [], "edges" => [], "reads" => {}} {picture: the picture is not the objective's (silent: missing_steps): ; usable_on_call: 2}
- compose-review-angles glm-5.3 #3 r=Y s=N p=— model conduct 387s $0.3183 :: the script was refused script_syntax_error: SyntaxError: Invalid or unexpected token at line 1, column 11: g.script({\n script: `\n const se… {picture: the script was refused script_syntax_error: SyntaxError: Inv; usable_on_call: 2}
- compose-three-stage-pairing kimi-k3 #1 r=Y s=N p=— model conduct 137s $0.3014 :: the picture is not the objective's (silent: missing_steps): {"nodes" => ["script-1/tool-1:tool", "script-1/model-1:model", "script-1/tool-2:… {picture: the picture is not the objective's (silent: missing_steps): ; usable_on_call: 2}
- workflow-barrier-free-pipeline glm-5.3 #1 r=N s=— p=Y model conduct 171s $0.1470 :: no compose call and no round fanned two task calls: {"ls" => 1, "read" => 1, "todo_write" => 3, "bash" => 4} {picture: no compose call to score; usable_on_call: None}
- workflow-barrier-free-pipeline kimi-k3 #1 r=N s=— p=Y model conduct 31s $0.0459 :: no compose call and no round fanned two task calls: {"ls" => 1, "read" => 1, "bash" => 1} {picture: no compose call to score; usable_on_call: None}
- workflow-barrier-free-pipeline kimi-k3 #2 r=N s=— p=Y model conduct 40s $0.0897 :: no compose call and no round fanned two task calls: {"ls" => 1, "bash" => 5} {picture: no compose call to score; usable_on_call: None}
- workflow-barrier-free-pipeline kimi-k3 #3 r=N s=— p=Y model conduct 34s $0.0525 :: no compose call and no round fanned two task calls: {"ls" => 1, "read" => 1, "bash" => 1} {picture: no compose call to score; usable_on_call: None}

## The floor's bars, v13 (v11)

- v13 floor: usable generation on the picture tasks 43/48 (compose tasks only 40/42); usable on call 1 37/48; runs that made a compose call 43/48; picture (the strong bar, a fact on the floor) 23/48 (compose only 23/42); non-picture cells: reach 63/72, success 60/72; task pass 35/36; green 95/120
- v11 floor: usable generation on the picture tasks 38/42 (compose tasks only 36/36); usable on call 1 37/42; runs that made a compose call 38/42; picture (the strong bar, a fact on the floor) 22/42 (compose only 22/36); non-picture cells: reach 57/72, success 51/72; task pass 34/36; green 78/114

Floor picture-task runs with no usable call (v13):
- compose-grep-then-edit glm-5.3-flash #1 r=N s=— p=N lane bug 607s $null :: [stopped deadline at 607 s] no compose call: the model called {} {picture: no compose call to score; usable_on_call: None}
- compose-three-stage-pairing glm-5.3-flash #1 r=N s=— p=— model conduct 283s $0.0151 :: no compose call: the model called {"write" => 1, "bash" => 3, "read" => 1, "edit" => 1} {picture: no compose call to score; usable_on_call: None}
- workflow-barrier-free-pipeline deepseek-flash #1 r=N s=— p=Y model conduct 28s $0.0017 :: no compose call and no round fanned two task calls: {"bash" => 2, "ls" => 1} {picture: no compose call to score; usable_on_call: None}
- workflow-barrier-free-pipeline deepseek-flash #2 r=N s=— p=Y model conduct 41s $0.0046 :: no compose call and no round fanned two task calls: {"bash" => 4, "write" => 2} {picture: no compose call to score; usable_on_call: None}
- workflow-barrier-free-pipeline glm-5.3-flash #2 r=N s=— p=Y model conduct 48s $0.0037 :: no compose call and no round fanned two task calls: {"ls" => 1, "find" => 1, "read" => 1, "bash" => 1} {picture: no compose call to score; usable_on_call: None}

## Watcher facts (d), (e), (a) from the records

- (d) task-mail glm-5.3 v11: reached 0/3, succeeded 0/3
- (d) task-mail glm-5.3 v13: reached 1/3, succeeded 1/3
- (e) judge-panel glm-5.3-flash #2 v11: #2 r=N s=— p=Y model conduct 1420s $0.6408 :: [stopped deadline at 1420 s] no compose call and no round fanned two task calls: {"todo_write" => 2, "ls" => 1, "spawn" => 3, "status" => 39…; rounds_settled 398, called {'todo_write': 2, 'ls': 1, 'spawn': 3, 'status': 399, 'read': 1}, round_errors {}
- (e) judge-panel glm-5.3-flash #2 v13: #2 r=Y s=Y p=Y green 281s $0.0358 :: ; rounds_settled 22, called {'ls': 1, 'find': 1, 'bash': 10, 'compose': 1, 'read': 9, 'write': 2}, round_errors {}
- (a) lane bug: compose-background-suite glm-5.3 #3: stopped deadline, seconds 607, rounds_settled 0, called {}, loops [{'id': '01a0d4e2-60b1-7b12-80fd-4ba523f31311', 'status': 'canceling'}], note 'the loop never settled in 599.9999929999467 s: r1(model_task/running)'
- (a) lane bug: compose-grep-then-edit glm-5.3-flash #1: stopped deadline, seconds 607, rounds_settled 0, called {}, loops [{'id': '01a0d51c-dd96-776d-adc7-79d9a934ec7b', 'status': 'canceling'}], note 'the loop never settled in 599.9999969999772 s: r1(model_task/running)'
~~~

### A2_evidence.py

<!-- script:A2_evidence.py -->
```python
#!/usr/bin/env python3
"""SECTION A, THE EVIDENCE BEHIND THE MOVED CELLS AND THE DOMINANT MISSES (read-only).

Reads the v11 and v13 nexus records and, where a record's facts do not say it, the
record's own artifact JSON (`record["artifact"]`: tasks, sealed_request). Prints:
1. the task family's tool choice per run on task-mail and task-background-suite;
2. task-detached-receipt kimi-k3: the `wake` each `task` call asked for;
3. workflow-adversarial-verify: door, waited, receipts, the `wait` flag on every
   `task` row, verification marks (watcher fact (c));
4. workflow-loop-until-dry: reach reason, conduct, round_errors;
5. the cache rate after round 1 (Trace.after_first_round_rate: rounds 2..n of
   cache_read_series pooled) on every cache-under-floor record, and on the cells
   whose green moved on cache;
6. the lane-isolation facts v12 promised: the live-process developer sentence in
   the sealed request, and project directories shared between records.
"""
import json
import os
from collections import Counter

REPO = "/Users/jasl/Workspaces/cybros-ai.alt2"
RUNS = os.path.join(REPO, "e2e/evals/runs")
LABELS = {"v11": [f"2026-09-24-v11-{f}" for f in ("task", "compose", "workflow")],
          "v13": [f"2026-09-25-v13-{f}" for f in ("task", "compose", "workflow")]}
MODELS = ["openrouter/z-ai/glm-5.3", "openrouter/moonshotai/kimi-k3",
          "deepseek/deepseek-flash", "openrouter/z-ai/glm-5.3-flash"]
SENTENCE = "Processes started earlier"


def read(label):
    with open(os.path.join(RUNS, label, "records.jsonl"), encoding="utf-8") as fh:
        return [json.loads(line) for line in fh if line.strip()]


V = {ver: [r for label in labels for r in read(label)] for ver, labels in LABELS.items()}


def short(model):
    return model.split("/")[-1]


def order(r):
    return (r["task"], MODELS.index(r["model"]), r["run"])


def artifact(r):
    with open(r["artifact"], encoding="utf-8") as fh:
        return json.load(fh)


def after_r1(series):
    rest = list((series or {}).values())[1:]
    tokens = sum(int(t or 0) for t, _ in rest)
    return None if tokens == 0 else round(sum(int(c or 0) for _, c in rest) / tokens, 4)


def verdict(r):
    v = r["verdict"]
    return f"r={v['reached']} s={v['succeeded']} p={v['task_pass']} class={v['class']}"


print("## 1. task-mail and task-background-suite: turn-1 tool choice per run\n")
for task in ("task-mail", "task-background-suite"):
    for ver in ("v11", "v13"):
        for r in sorted((r for r in V[ver] if r["task"] == task), key=order):
            f = r["facts"]
            called = f.get("turn_1_called") or f.get("called") or {}
            pick = {k: called[k] for k in ("task", "start_process", "bash") if k in called}
            print(f"- {task} {ver} {short(r['model'])} #{r['run']}: {verdict(r)}; {pick}; wake_passive {f.get('wake_passive')}")
    print()

print("## 2. task-detached-receipt kimi-k3: the wake each `task` call asked for\n")
for ver in ("v11", "v13"):
    for r in sorted((r for r in V[ver] if r["task"] == "task-detached-receipt" and "kimi" in r["model"]), key=order):
        rows = [t for t in artifact(r)["tasks"] if t.get("tool_name") == "task"]
        wakes = [(t["key"], t["tool_input"].get("wake")) for t in rows]
        print(f"- {ver} #{r['run']}: {verdict(r)}; task rows {wakes}; wake_passive {r['facts'].get('wake_passive')}; "
              f"receipt_woke_a_turn {r['facts'].get('receipt_woke_a_turn')}; loops {len(r['loops'])}")

print("\n## 3. workflow-adversarial-verify: waited fans, receipts, the wait flag on every task row\n")
tally = Counter()
for ver in ("v11", "v13"):
    for r in sorted((r for r in V[ver] if r["task"] == "workflow-adversarial-verify"), key=order):
        f = r["facts"]
        rows = [t for t in artifact(r)["tasks"] if t.get("tool_name") == "task"]
        waits = Counter(str(t["tool_input"].get("wait")) for t in rows)
        no_receipt = (r.get("reason") or "").startswith("no input_accepted{origin: task_result}")
        if no_receipt:
            tally[(ver, "no-receipt reason")] += 1
            tally[(ver, "no-receipt reason AND every task row wait: true")] += int(set(waits) == {"True"})
            tally[(ver, "no-receipt reason AND receipts 0")] += int(f.get("receipts") == 0)
        marks = " ".join((f.get("verification_output") or "").split())[:110]
        print(f"- {ver} {short(r['model'])} #{r['run']}: {verdict(r)}; waited {f.get('waited')}; receipts {f.get('receipts')}; "
              f"task rows {len(rows)} wait {dict(waits)}; spine-read conduct {r.get('conduct', {}).get('did_not_judge_itself')}; {marks}")
print("\n" + "; ".join(f"{k[0]} {k[1]}: {v}" for k, v in sorted(tally.items())))

print("\n## 4. workflow-loop-until-dry\n")
for ver in ("v11", "v13"):
    for r in sorted((r for r in V[ver] if r["task"] == "workflow-loop-until-dry"), key=order):
        f = r["facts"]
        print(f"- {ver} {short(r['model'])} #{r['run']}: {verdict(r)}; reason {(r.get('reason') or '')[:70]!r}; "
              f"conduct {r.get('conduct')}; round_errors {f.get('round_errors')}")

print("\n## 5. cache after round 1\n")
for ver in ("v11", "v13"):
    cuf = [r for r in V[ver] if r["verdict"].get("class") == "cache under floor"]
    by_model = Counter(short(r["model"]) for r in cuf)
    print(f"- {ver} cache under floor: {len(cuf)} records, by model {dict(by_model)}")
    for r in sorted(cuf, key=order):
        s = r["efficiency"].get("cache_read_series")
        print(f"    - {r['task']} {short(r['model'])} #{r['run']}: after-r1 {after_r1(s)} over {max(len(s or {}) - 1, 0)} rounds")
for task, model in (("compose-single-read", "openrouter/moonshotai/kimi-k3"), ("workflow-judge-panel", "openrouter/z-ai/glm-5.3")):
    for ver in ("v11", "v13"):
        rates = [(r["run"], after_r1(r["efficiency"].get("cache_read_series")), r["verdict"]["class"])
                 for r in sorted(V[ver], key=order) if r["task"] == task and r["model"] == model]
        print(f"- {task} {short(model)} {ver}: {rates}")

print("\n## 5b. the adaptations fact per model (the row each daemon booted under)\n")
for ver in ("v11", "v13"):
    rows_by = Counter((short(r["model"]), json.dumps(r.get("adaptations"), sort_keys=True)) for r in V[ver])
    print(f"- {ver}: " + "; ".join(f"{m} {a} x{n}" for (m, a), n in sorted(rows_by.items())))

print("\n## 6. lane isolation: the live-process sentence and shared project directories\n")
for ver in ("v11", "v13"):
    hits = Counter()
    for r in V[ver]:
        sealed = artifact(r).get("sealed_request") or {}
        hit = any(SENTENCE in (p.get("text") or "") for e in sealed.get("entries") or [] for p in e.get("parts") or [])
        hits[(r["family"], hit)] += 1
    dirs = Counter(os.path.basename(r["facts"].get("root") or "") for r in V[ver])
    print(f"- {ver}: records whose sealed request carries '{SENTENCE}': "
          + ", ".join(f"{fam} {hits[(fam, True)]}/{hits[(fam, True)] + hits[(fam, False)]}" for fam in ("task", "compose", "workflow"))
          + f"; distinct project dirs {len(dirs)} of {len(V[ver])} records (max records on one dir {max(dirs.values())})")

print("\n## 7. success against the tier's bar on every reached picture-task record\n")
for ver in ("v11", "v13"):
    checked, off = 0, []
    for r in V[ver]:
        f, v = r["facts"], r["verdict"]
        if "picture" not in f or v.get("reached") is not True:
            continue
        checked += 1
        bar = (f.get("usable_on_call") is not None) if f.get("tier") == "floor" else (f.get("picture") is True)
        if bool(v.get("succeeded")) != bar:
            off.append((r["task"], short(r["model"]), r["run"]))
    print(f"- {ver}: {checked} reached picture-task records; success differs from the tier's bar on {len(off)} {off}")
```

#### A2_evidence.py output

~~~text
## 1. task-mail and task-background-suite: turn-1 tool choice per run

- task-mail v11 glm-5.3 #1: r=False s=None p=None class=model conduct; {'start_process': 1, 'bash': 1}; wake_passive None
- task-mail v11 glm-5.3 #2: r=False s=None p=None class=model conduct; {'start_process': 1, 'bash': 1}; wake_passive None
- task-mail v11 glm-5.3 #3: r=False s=None p=None class=model conduct; {'start_process': 1, 'bash': 1}; wake_passive None
- task-mail v11 kimi-k3 #1: r=False s=None p=None class=model conduct; {'start_process': 1, 'bash': 1}; wake_passive None
- task-mail v11 kimi-k3 #2: r=False s=None p=None class=model conduct; {'start_process': 1, 'bash': 1}; wake_passive None
- task-mail v11 kimi-k3 #3: r=True s=True p=None class=None; {'task': 1, 'bash': 2}; wake_passive False
- task-mail v11 deepseek-flash #1: r=False s=None p=None class=model conduct; {'start_process': 1, 'bash': 1}; wake_passive None
- task-mail v11 deepseek-flash #2: r=True s=False p=None class=model conduct; {'task': 1, 'bash': 3}; wake_passive True
- task-mail v11 deepseek-flash #3: r=True s=True p=None class=None; {'task': 1, 'bash': 4}; wake_passive False
- task-mail v11 glm-5.3-flash #1: r=False s=None p=None class=model conduct; {'start_process': 1, 'bash': 1}; wake_passive None
- task-mail v11 glm-5.3-flash #2: r=False s=None p=None class=model conduct; {'start_process': 1, 'bash': 1}; wake_passive None
- task-mail v11 glm-5.3-flash #3: r=False s=None p=None class=model conduct; {'start_process': 1, 'bash': 1}; wake_passive None
- task-mail v13 glm-5.3 #1: r=False s=None p=None class=model conduct; {'start_process': 1, 'bash': 1}; wake_passive None
- task-mail v13 glm-5.3 #2: r=False s=None p=None class=model conduct; {'start_process': 1, 'bash': 1}; wake_passive None
- task-mail v13 glm-5.3 #3: r=True s=True p=None class=None; {'task': 1, 'bash': 4}; wake_passive False
- task-mail v13 kimi-k3 #1: r=False s=None p=None class=model conduct; {'start_process': 1, 'bash': 1}; wake_passive None
- task-mail v13 kimi-k3 #2: r=False s=None p=None class=model conduct; {'bash': 2}; wake_passive None
- task-mail v13 kimi-k3 #3: r=False s=None p=None class=model conduct; {'start_process': 1, 'bash': 1}; wake_passive None
- task-mail v13 deepseek-flash #1: r=True s=True p=None class=None; {'task': 1, 'bash': 5}; wake_passive False
- task-mail v13 deepseek-flash #2: r=True s=True p=None class=None; {'task': 1, 'bash': 2}; wake_passive False
- task-mail v13 deepseek-flash #3: r=False s=None p=None class=model conduct; {'start_process': 1, 'bash': 1}; wake_passive None
- task-mail v13 glm-5.3-flash #1: r=False s=None p=None class=model conduct; {'start_process': 1, 'bash': 1}; wake_passive None
- task-mail v13 glm-5.3-flash #2: r=False s=None p=None class=model conduct; {'start_process': 1, 'bash': 1}; wake_passive None
- task-mail v13 glm-5.3-flash #3: r=False s=None p=None class=model conduct; {'start_process': 1, 'bash': 1}; wake_passive None

- task-background-suite v11 glm-5.3 #1: r=True s=False p=None class=model conduct; {'task': 1, 'start_process': 1, 'bash': 9}; wake_passive None
- task-background-suite v11 glm-5.3 #2: r=True s=False p=None class=model conduct; {'task': 1, 'start_process': 1, 'bash': 15}; wake_passive None
- task-background-suite v11 glm-5.3 #3: r=True s=True p=None class=None; {'task': 1, 'bash': 13}; wake_passive None
- task-background-suite v11 kimi-k3 #1: r=True s=True p=None class=cache under floor; {'task': 1, 'bash': 9}; wake_passive None
- task-background-suite v11 kimi-k3 #2: r=True s=False p=None class=model conduct; {'task': 1, 'start_process': 1, 'bash': 12}; wake_passive None
- task-background-suite v11 kimi-k3 #3: r=True s=True p=None class=None; {'task': 1, 'bash': 10}; wake_passive None
- task-background-suite v11 deepseek-flash #1: r=True s=True p=None class=None; {'task': 1, 'bash': 15}; wake_passive None
- task-background-suite v11 deepseek-flash #2: r=False s=None p=None class=model conduct; {'start_process': 1, 'bash': 9}; wake_passive None
- task-background-suite v11 deepseek-flash #3: r=True s=True p=None class=None; {'task': 1, 'bash': 11}; wake_passive None
- task-background-suite v11 glm-5.3-flash #1: r=False s=None p=None class=model conduct; {'start_process': 2, 'bash': 12}; wake_passive None
- task-background-suite v11 glm-5.3-flash #2: r=False s=None p=None class=model conduct; {'start_process': 1, 'bash': 6}; wake_passive None
- task-background-suite v11 glm-5.3-flash #3: r=True s=True p=None class=None; {'task': 1, 'bash': 7}; wake_passive None
- task-background-suite v13 glm-5.3 #1: r=True s=True p=None class=None; {'task': 1, 'bash': 10}; wake_passive None
- task-background-suite v13 glm-5.3 #2: r=True s=True p=None class=None; {'task': 1, 'bash': 11}; wake_passive None
- task-background-suite v13 glm-5.3 #3: r=True s=True p=None class=None; {'task': 1, 'bash': 13}; wake_passive None
- task-background-suite v13 kimi-k3 #1: r=True s=True p=None class=cache under floor; {'task': 1, 'bash': 10}; wake_passive None
- task-background-suite v13 kimi-k3 #2: r=False s=None p=None class=model conduct; {'start_process': 2, 'bash': 9}; wake_passive None
- task-background-suite v13 kimi-k3 #3: r=True s=True p=None class=cache under floor; {'task': 1, 'bash': 7}; wake_passive None
- task-background-suite v13 deepseek-flash #1: r=False s=None p=None class=model conduct; {'start_process': 1, 'bash': 8}; wake_passive None
- task-background-suite v13 deepseek-flash #2: r=False s=None p=None class=model conduct; {'start_process': 1, 'bash': 7}; wake_passive None
- task-background-suite v13 deepseek-flash #3: r=True s=True p=None class=None; {'task': 1, 'bash': 10}; wake_passive None
- task-background-suite v13 glm-5.3-flash #1: r=True s=True p=None class=None; {'task': 1, 'bash': 15}; wake_passive None
- task-background-suite v13 glm-5.3-flash #2: r=False s=None p=None class=model conduct; {'start_process': 1, 'bash': 11}; wake_passive None
- task-background-suite v13 glm-5.3-flash #3: r=True s=True p=None class=None; {'task': 1, 'bash': 4}; wake_passive None

## 2. task-detached-receipt kimi-k3: the wake each `task` call asked for

- v11 #1: r=True s=True p=None class=None; task rows [('r2t0', None)]; wake_passive False; receipt_woke_a_turn True; loops 2
- v11 #2: r=True s=False p=None class=model conduct; task rows [('r2t0', 'passive')]; wake_passive True; receipt_woke_a_turn False; loops 1
- v11 #3: r=True s=False p=None class=model conduct; task rows [('r2t0', 'passive')]; wake_passive True; receipt_woke_a_turn False; loops 1
- v13 #1: r=True s=True p=None class=None; task rows [('r2t0', None)]; wake_passive False; receipt_woke_a_turn True; loops 2
- v13 #2: r=True s=True p=None class=None; task rows [('r2t0', None)]; wake_passive False; receipt_woke_a_turn True; loops 2
- v13 #3: r=True s=True p=None class=None; task rows [('r2t0', 'auto')]; wake_passive False; receipt_woke_a_turn True; loops 2

## 3. workflow-adversarial-verify: waited fans, receipts, the wait flag on every task row

- v11 glm-5.3 #1: r=True s=False p=True class=disagreement; waited True; receipts 0; task rows 12 wait {'True': 12}; spine-read conduct False; marks {1 => "FALSE", 2 => "STANDS", 3 => "STANDS", 4 => "FALSE", 5 => "FALSE", 6 => "STANDS"}
- v11 glm-5.3 #2: r=True s=False p=True class=disagreement; waited True; receipts 0; task rows 13 wait {'True': 13}; spine-read conduct False; marks {1 => "FALSE", 2 => "STANDS", 3 => "STANDS", 4 => "FALSE", 5 => "FALSE", 6 => "STANDS"}
- v11 glm-5.3 #3: r=True s=False p=True class=disagreement; waited True; receipts 0; task rows 14 wait {'True': 14}; spine-read conduct False; marks {1 => "FALSE", 2 => "STANDS", 3 => "STANDS", 4 => "FALSE", 5 => "FALSE", 6 => "STANDS"}
- v11 kimi-k3 #1: r=True s=False p=True class=disagreement; waited True; receipts 0; task rows 12 wait {'True': 12}; spine-read conduct False; marks {1 => "FALSE", 2 => "STANDS", 3 => "STANDS", 4 => "FALSE", 5 => "FALSE", 6 => "STANDS"}
- v11 kimi-k3 #2: r=True s=True p=True class=model conduct; waited False; receipts 13; task rows 12 wait {'None': 12}; spine-read conduct False; marks {1 => "FALSE", 2 => "STANDS", 3 => "STANDS", 4 => "FALSE", 5 => "FALSE", 6 => "STANDS"}
- v11 kimi-k3 #3: r=True s=False p=True class=disagreement; waited True; receipts 0; task rows 12 wait {'True': 12}; spine-read conduct False; marks {1 => "FALSE", 2 => "STANDS", 3 => "STANDS", 4 => "FALSE", 5 => "FALSE", 6 => "STANDS"}
- v11 deepseek-flash #1: r=True s=False p=True class=disagreement; waited True; receipts 0; task rows 12 wait {'True': 12}; spine-read conduct False; marks {1 => "FALSE", 2 => "STANDS", 3 => "STANDS", 4 => "FALSE", 5 => "FALSE", 6 => "STANDS"}
- v11 deepseek-flash #2: r=True s=False p=True class=disagreement; waited True; receipts 0; task rows 12 wait {'True': 12}; spine-read conduct False; marks {1 => "FALSE", 2 => "STANDS", 3 => "STANDS", 4 => "FALSE", 5 => "FALSE", 6 => "STANDS"}
- v11 deepseek-flash #3: r=True s=True p=True class=model conduct; waited False; receipts 12; task rows 12 wait {'None': 12}; spine-read conduct False; marks {1 => "FALSE", 2 => "STANDS", 3 => "STANDS", 4 => "FALSE", 5 => "FALSE", 6 => "STANDS"}
- v11 glm-5.3-flash #1: r=True s=False p=False class=model conduct; waited True; receipts 0; task rows 12 wait {'True': 12}; spine-read conduct False; marks {1 => "FALSE", 2 => "FALSE", 3 => "STANDS", 4 => "FALSE", 5 => "FALSE", 6 => "STANDS"}
- v11 glm-5.3-flash #2: r=True s=True p=True class=model conduct; waited False; receipts 12; task rows 12 wait {'None': 12}; spine-read conduct False; marks {1 => "FALSE", 2 => "STANDS", 3 => "STANDS", 4 => "FALSE", 5 => "FALSE", 6 => "STANDS"}
- v11 glm-5.3-flash #3: r=True s=True p=True class=model conduct; waited False; receipts 12; task rows 12 wait {'None': 12}; spine-read conduct False; marks {1 => "FALSE", 2 => "STANDS", 3 => "STANDS", 4 => "FALSE", 5 => "FALSE", 6 => "STANDS"}
- v13 glm-5.3 #1: r=True s=True p=True class=cache under floor; waited False; receipts 12; task rows 12 wait {'None': 12}; spine-read conduct True; marks {1 => "FALSE", 2 => "STANDS", 3 => "STANDS", 4 => "FALSE", 5 => "FALSE", 6 => "STANDS"}
- v13 glm-5.3 #2: r=True s=False p=True class=disagreement; waited True; receipts 0; task rows 12 wait {'True': 12}; spine-read conduct True; marks {1 => "FALSE", 2 => "STANDS", 3 => "STANDS", 4 => "FALSE", 5 => "FALSE", 6 => "STANDS"}
- v13 glm-5.3 #3: r=True s=False p=True class=disagreement; waited True; receipts 0; task rows 12 wait {'True': 12}; spine-read conduct False; marks {1 => "FALSE", 2 => "STANDS", 3 => "STANDS", 4 => "FALSE", 5 => "FALSE", 6 => "STANDS"}
- v13 kimi-k3 #1: r=True s=False p=False class=model conduct; waited True; receipts 0; task rows 12 wait {'True': 12}; spine-read conduct True; marks {1 => "FALSE", 2 => "FALSE", 3 => "FALSE", 4 => "FALSE", 5 => "FALSE", 6 => "STANDS"}
- v13 kimi-k3 #2: r=True s=True p=True class=cache under floor; waited False; receipts 12; task rows 12 wait {'None': 12}; spine-read conduct True; marks {1 => "FALSE", 2 => "STANDS", 3 => "STANDS", 4 => "FALSE", 5 => "FALSE", 6 => "STANDS"}
- v13 kimi-k3 #3: r=True s=False p=False class=model conduct; waited True; receipts 0; task rows 13 wait {'True': 13}; spine-read conduct True; marks {1 => "FALSE", 2 => "FALSE", 3 => "STANDS", 4 => "FALSE", 5 => "FALSE", 6 => "STANDS"}
- v13 deepseek-flash #1: r=True s=True p=True class=model conduct; waited False; receipts 13; task rows 13 wait {'None': 13}; spine-read conduct False; marks {1 => "FALSE", 2 => "STANDS", 3 => "STANDS", 4 => "FALSE", 5 => "FALSE", 6 => "STANDS"}
- v13 deepseek-flash #2: r=True s=True p=True class=model conduct; waited False; receipts 12; task rows 12 wait {'None': 12}; spine-read conduct False; marks {1 => "FALSE", 2 => "STANDS", 3 => "STANDS", 4 => "FALSE", 5 => "FALSE", 6 => "STANDS"}
- v13 deepseek-flash #3: r=True s=True p=True class=model conduct; waited False; receipts 12; task rows 12 wait {'None': 12}; spine-read conduct False; marks {1 => "FALSE", 2 => "STANDS", 3 => "STANDS", 4 => "FALSE", 5 => "FALSE", 6 => "STANDS"}
- v13 glm-5.3-flash #1: r=True s=True p=True class=model conduct; waited False; receipts 12; task rows 12 wait {'None': 12}; spine-read conduct False; marks {1 => "FALSE", 2 => "STANDS", 3 => "STANDS", 4 => "FALSE", 5 => "FALSE", 6 => "STANDS"}
- v13 glm-5.3-flash #2: r=True s=False p=True class=disagreement; waited True; receipts 0; task rows 12 wait {'True': 12}; spine-read conduct False; marks {1 => "FALSE", 2 => "STANDS", 3 => "STANDS", 4 => "FALSE", 5 => "FALSE", 6 => "STANDS"}
- v13 glm-5.3-flash #3: r=True s=True p=True class=None; waited False; receipts 12; task rows 12 wait {'None': 12}; spine-read conduct True; marks {1 => "FALSE", 2 => "STANDS", 3 => "STANDS", 4 => "FALSE", 5 => "FALSE", 6 => "STANDS"}

v11 no-receipt reason: 8; v11 no-receipt reason AND every task row wait: true: 8; v11 no-receipt reason AND receipts 0: 8; v13 no-receipt reason: 5; v13 no-receipt reason AND every task row wait: true: 5; v13 no-receipt reason AND receipts 0: 5

## 4. workflow-loop-until-dry

- v11 glm-5.3 #1: r=True s=True p=True class=None; reason ''; conduct {'one_item_per_pass': True}; round_errors {}
- v11 glm-5.3 #2: r=True s=True p=True class=None; reason ''; conduct {'one_item_per_pass': True}; round_errors {}
- v11 glm-5.3 #3: r=True s=True p=True class=None; reason ''; conduct {'one_item_per_pass': True}; round_errors {}
- v11 kimi-k3 #1: r=True s=True p=True class=cache under floor; reason ''; conduct {'one_item_per_pass': True}; round_errors {}
- v11 kimi-k3 #2: r=True s=True p=True class=cache under floor; reason ''; conduct {'one_item_per_pass': True}; round_errors {}
- v11 kimi-k3 #3: r=True s=True p=True class=cache under floor; reason ''; conduct {'one_item_per_pass': True}; round_errors {}
- v11 deepseek-flash #1: r=True s=True p=True class=model conduct; reason ''; conduct {'one_item_per_pass': False}; round_errors {}
- v11 deepseek-flash #2: r=True s=True p=True class=None; reason ''; conduct {'one_item_per_pass': True}; round_errors {}
- v11 deepseek-flash #3: r=False s=None p=True class=model conduct; reason 'no iteration: 15 pass(es), 1 item touches ({"bash" => 15})'; conduct {'one_item_per_pass': False}; round_errors {}
- v11 glm-5.3-flash #1: r=False s=None p=True class=model conduct; reason 'no iteration: 8 pass(es), 0 item touches ({"bash" => 7, "todo_write" ='; conduct {'one_item_per_pass': True}; round_errors {}
- v11 glm-5.3-flash #2: r=True s=True p=True class=None; reason ''; conduct {'one_item_per_pass': True}; round_errors {}
- v11 glm-5.3-flash #3: r=False s=None p=False class=model conduct; reason 'no iteration: 4 pass(es), 0 item touches ({"bash" => 4})'; conduct {'one_item_per_pass': False}; round_errors {'round_expansion_refused': 1}
- v13 glm-5.3 #1: r=True s=True p=True class=None; reason ''; conduct {'one_item_per_pass': True}; round_errors {}
- v13 glm-5.3 #2: r=True s=True p=True class=None; reason ''; conduct {'one_item_per_pass': True}; round_errors {}
- v13 glm-5.3 #3: r=True s=True p=True class=None; reason ''; conduct {'one_item_per_pass': True}; round_errors {}
- v13 kimi-k3 #1: r=True s=True p=True class=cache under floor; reason ''; conduct {'one_item_per_pass': True}; round_errors {}
- v13 kimi-k3 #2: r=True s=True p=True class=cache under floor; reason ''; conduct {'one_item_per_pass': True}; round_errors {}
- v13 kimi-k3 #3: r=True s=True p=True class=None; reason ''; conduct {'one_item_per_pass': True}; round_errors {}
- v13 deepseek-flash #1: r=True s=True p=True class=None; reason ''; conduct {'one_item_per_pass': True}; round_errors {}
- v13 deepseek-flash #2: r=True s=True p=True class=None; reason ''; conduct {'one_item_per_pass': True}; round_errors {}
- v13 deepseek-flash #3: r=True s=True p=True class=None; reason ''; conduct {'one_item_per_pass': True}; round_errors {}
- v13 glm-5.3-flash #1: r=True s=True p=True class=None; reason ''; conduct {'one_item_per_pass': True}; round_errors {}
- v13 glm-5.3-flash #2: r=True s=True p=True class=None; reason ''; conduct {'one_item_per_pass': True}; round_errors {}
- v13 glm-5.3-flash #3: r=True s=True p=True class=None; reason ''; conduct {'one_item_per_pass': True}; round_errors {}

## 5. cache after round 1

- v11 cache under floor: 13 records, by model {'kimi-k3': 10, 'deepseek-flash': 2, 'glm-5.3': 1}
    - compose-grep-then-edit deepseek-flash #1: after-r1 0.6211 over 2 rounds
    - compose-single-read kimi-k3 #2: after-r1 0.4512 over 2 rounds
    - compose-single-read kimi-k3 #3: after-r1 0.5076 over 2 rounds
    - task-background-suite kimi-k3 #1: after-r1 0.7891 over 10 rounds
    - task-fan-five deepseek-flash #3: after-r1 0.6997 over 5 rounds
    - workflow-fan-out-finders kimi-k3 #3: after-r1 0.4517 over 2 rounds
    - workflow-judge-panel glm-5.3 #3: after-r1 0.7431 over 3 rounds
    - workflow-judge-panel kimi-k3 #1: after-r1 0.5476 over 4 rounds
    - workflow-judge-panel kimi-k3 #2: after-r1 0.4591 over 3 rounds
    - workflow-judge-panel kimi-k3 #3: after-r1 0.5629 over 3 rounds
    - workflow-loop-until-dry kimi-k3 #1: after-r1 0.5363 over 21 rounds
    - workflow-loop-until-dry kimi-k3 #2: after-r1 0.6642 over 25 rounds
    - workflow-loop-until-dry kimi-k3 #3: after-r1 0.7484 over 19 rounds
- v13 cache under floor: 19 records, by model {'kimi-k3': 10, 'deepseek-flash': 4, 'glm-5.3': 5}
    - compose-grep-then-edit deepseek-flash #2: after-r1 0.5114 over 2 rounds
    - compose-race deepseek-flash #1: after-r1 0.7283 over 2 rounds
    - compose-race-anon deepseek-flash #3: after-r1 0.7375 over 2 rounds
    - compose-rendezvous deepseek-flash #2: after-r1 0.7934 over 2 rounds
    - task-background-suite kimi-k3 #1: after-r1 0.5097 over 9 rounds
    - task-background-suite kimi-k3 #3: after-r1 0.7982 over 7 rounds
    - workflow-adversarial-verify glm-5.3 #1: after-r1 0.4358 over 3 rounds
    - workflow-adversarial-verify kimi-k3 #2: after-r1 0.5158 over 10 rounds
    - workflow-barrier-free-pipeline glm-5.3 #3: after-r1 0.7702 over 4 rounds
    - workflow-fan-out-finders kimi-k3 #1: after-r1 0.2869 over 3 rounds
    - workflow-fan-out-finders kimi-k3 #2: after-r1 0.2983 over 3 rounds
    - workflow-fan-out-finders kimi-k3 #3: after-r1 0.0 over 3 rounds
    - workflow-judge-panel glm-5.3 #1: after-r1 0.7061 over 5 rounds
    - workflow-judge-panel glm-5.3 #2: after-r1 0.5793 over 3 rounds
    - workflow-judge-panel glm-5.3 #3: after-r1 0.7685 over 4 rounds
    - workflow-judge-panel kimi-k3 #2: after-r1 0.328 over 3 rounds
    - workflow-judge-panel kimi-k3 #3: after-r1 0.6045 over 3 rounds
    - workflow-loop-until-dry kimi-k3 #1: after-r1 0.6306 over 25 rounds
    - workflow-loop-until-dry kimi-k3 #2: after-r1 0.7048 over 25 rounds
- compose-single-read kimi-k3 v11: [(1, 0.0, None), (2, 0.4512, 'cache under floor'), (3, 0.5076, 'cache under floor')]
- compose-single-read kimi-k3 v13: [(1, 0.9695, None), (2, 0.9764, None), (3, 0.9694, None)]
- workflow-judge-panel glm-5.3 v11: [(1, 0.8299, None), (2, 0.8479, None), (3, 0.7431, 'cache under floor')]
- workflow-judge-panel glm-5.3 v13: [(1, 0.7061, 'cache under floor'), (2, 0.5793, 'cache under floor'), (3, 0.7685, 'cache under floor')]

## 5b. the adaptations fact per model (the row each daemon booted under)

- v11: deepseek-flash {"row": "bench-nexus", "source": "local", "tool_style": ["nexus"]} x57; glm-5.3 {"row": "bench-nexus", "source": "local", "tool_style": ["nexus"]} x57; glm-5.3-flash {"row": "bench-nexus", "source": "local", "tool_style": ["nexus"]} x57; kimi-k3 {"row": "bench-nexus", "source": "local", "tool_style": ["nexus"]} x57
- v13: deepseek-flash {"row": "bench-nexus", "source": "local", "tool_style": ["nexus"]} x60; glm-5.3 {"row": "bench-nexus", "source": "local", "tool_style": ["nexus"]} x60; glm-5.3-flash {"row": "bench-nexus", "source": "local", "tool_style": ["nexus"]} x60; kimi-k3 {"row": "bench-nexus", "source": "local", "tool_style": ["nexus"]} x60

## 6. lane isolation: the live-process sentence and shared project directories

- v11: records whose sealed request carries 'Processes started earlier': task 10/72, compose 2/96, workflow 0/60; distinct project dirs 57 of 228 records (max records on one dir 4)
- v13: records whose sealed request carries 'Processes started earlier': task 0/72, compose 0/108, workflow 0/60; distinct project dirs 240 of 240 records (max records on one dir 1)

## 7. success against the tier's bar on every reached picture-task record

- v11: 79 reached picture-task records; success differs from the tier's bar on 0 []
- v13: 86 reached picture-task records; success differs from the tier's bar on 0 []
~~~

### A3_logs.py

<!-- script:A3_logs.py -->
```python
#!/usr/bin/env python3
"""SECTION A, WHAT THE WORLD LOGS SAY (read-only; greps, never cats).

Each record's log directory, e2e/artifacts/evals/<label>/logs/<artifact stem>/, holds
nexus.jobs.rails.log as a WINDOW cut at the record's own start (its MANIFEST says
"window from byte N"), and the whole world's nexus.model_runner.log up to the record.
1. For every v13 picture-task record NOT usable on its first compose call: every
   compose tool output in its jobs window, in order (the kernel's answer to each
   call), and whether the successful answers name the record's own loop.
2. S1's refusal sentence ("a member of the race on line N" / "a member of an earlier
   race", nexus/lib/nexus/compose/builder.js:397) across every v13 compose and
   workflow window.
3. Watcher fact (a): for each lane-bug record, the reasoning_delta and stream_reset
   broadcasts on its own loop in the model runner log.
"""
import json
import os
import re

REPO = "/Users/jasl/Workspaces/cybros-ai.alt2"
RUNS = os.path.join(REPO, "e2e/evals/runs")
ART = os.path.join(REPO, "e2e/artifacts/evals")
COMPOSE_OUT = re.compile(r'"name":"compose","output":"((?:[^"\\]|\\.){0,240})')
S1 = re.compile(r"a member of the race on line \d+|a member of an earlier race")


def read(label):
    with open(os.path.join(RUNS, label, "records.jsonl"), encoding="utf-8") as fh:
        return [json.loads(line) for line in fh if line.strip()]


def logdir(r):
    stem = os.path.basename(r["artifact"])[:-len(".json")]
    return os.path.join(ART, os.path.dirname(r["artifact"]).split("/")[-1], "logs", stem)


def lines(path):
    with open(path, encoding="utf-8", errors="replace") as fh:
        yield from fh


rows = read("2026-09-25-v13-compose") + read("2026-09-25-v13-workflow")

print("## 1. picture-task records not usable on call 1: the kernel's answer to each compose call\n")
for r in sorted(rows, key=lambda r: (r["facts"].get("tier"), r["task"], r["model"], r["run"])):
    f = r["facts"]
    if "picture" not in f or f.get("usable_on_call") == 1:
        continue
    window = os.path.join(logdir(r), "nexus.jobs.rails.log")
    outs = [m.group(1) for line in lines(window) for m in COMPOSE_OUT.finditer(line)]
    loops = {l["id"] for l in r["loops"]}
    named = [re.search(r'agent_loop=\\"([0-9a-f-]{36})', o) for o in outs]
    own = [m.group(1) in loops for m in named if m]
    print(f"- {f['tier']} {r['task']} {r['model'].split('/')[-1]} #{r['run']} (usable_on_call {f.get('usable_on_call')}); "
          f"{len(outs)} compose answer(s) in the window; answers naming a loop name the record's own: {own}")
    for i, o in enumerate(outs, 1):
        print(f"    {i}. {o[:200]}")
    with open(r["artifact"], encoding="utf-8") as fh:
        calls = [t for t in json.load(fh)["tasks"] if t.get("tool_name") == "compose"]
    for t in calls[:1]:
        print(f"    first compose call {t['key']}: script starts {t['tool_input'].get('script', '')[:70]!r}")

print("\n## 2. S1's refusal sentence in the v13 windows\n")
hits, windows = [], 0
for label in ("2026-09-25-v13-compose", "2026-09-25-v13-workflow"):
    for r in read(label):
        windows += 1
        n = sum(len(S1.findall(line)) for line in lines(os.path.join(logdir(r), "nexus.jobs.rails.log")))
        if n:
            hits.append((r["task"], r["model"], r["run"], n))
print(f"windows read {windows}; windows carrying the sentence {len(hits)} {hits}")

print("\n## 3. the two lane bugs: reasoning deltas on their own loop\n")
for r in rows:
    if r["verdict"].get("class") != "lane bug":
        continue
    loop = r["loops"][0]["id"]
    tag = f'agent_loop_public_id: "{loop}"'
    deltas, resets, first, last, total = 0, [], None, None, 0
    keys = set()
    for n, line in enumerate(lines(os.path.join(logdir(r), "nexus.model_runner.log")), 1):
        total = n
        if tag not in line:
            continue
        if 'type: "reasoning_delta"' in line:
            deltas += 1
            first = first or n
            last = n
            keys.add(re.search(r'task_key: "([^"]+)"', line).group(1))
        elif 'type: "stream_reset"' in line:
            resets.append((n, re.search(r'task_key: "([^"]+)"', line).group(1), re.search(r'reason: "([^"]+)"', line).group(1)))
    print(f"- {r['task']} {r['model'].split('/')[-1]} #{r['run']}: loop {loop}; reasoning_delta broadcasts {deltas} "
          f"(task keys {sorted(keys)}), first at line {first}, last at line {last} of {total}; "
          f"stream_reset {len(resets)} (line, task, reason) {resets}; "
          f"record: stopped {r.get('stopped')}, {r['seconds']} s, rounds_settled {r['facts'].get('rounds_settled')}")
    others = {name: sum(1 for line in lines(os.path.join(logdir(r), name)) if loop in line and 'reasoning_delta' in line)
              for name in ("nexus.server.log", "nexus.rails.log", "nexus.model_runner.rails.log")}
    print(f"    the same loop's reasoning_delta lines in the other logs: {others}")
```

#### A3_logs.py output

~~~text
## 1. picture-task records not usable on call 1: the kernel's answer to each compose call

- floor compose-background-suite deepseek-flash #1 (usable_on_call 2); 2 compose answer(s) in the window; answers naming a loop name the record's own: []
    1. <tool_use_error>script_error: Error: g.model: unknown option \"prompt_note\". The options are prompt, model, tools, instructions, key, after, results.</tool_use_error>
    2. Composed 5 tasks: r3t0-tool-1, r3t0-tool-2, r3t0-model-1, r3t0-tool-3, r3t0-model-2.\nThey run in the background: each result reaches you later as a message that is not from the person.\nTask referenc
    first compose call r2t0: script starts '// (1) The whole test suite: fired off in the background. Nothing belo'
- floor compose-grep-then-edit deepseek-flash #2 (usable_on_call 2); 2 compose answer(s) in the window; answers naming a loop name the record's own: [True]
    1. <tool_use_error>script_syntax_error: SyntaxError: Unexpected identifier ''Finish'' at line 54, column 12: prompt: `Finish this job in the repository. The steps abov…</tool_use_error>
    2. Composed 4 tasks: r3t0-tool-1, r3t0-tool-2, r3t0-tool-3, r3t0-script-1.\nTheir results reach you in the next round.\nTask reference: agent_loop=\"01a0d51a-6076-79e1-bc19-780bb5cf1d86\", task=\"r3t0\".
    first compose call r2t0: script starts "const files = ['app/models/user.rb', 'app/models/account.rb', 'app/mod"
- floor compose-grep-then-edit glm-5.3-flash #1 (usable_on_call None); 0 compose answer(s) in the window; answers naming a loop name the record's own: []
- floor compose-race deepseek-flash #1 (usable_on_call 2); 2 compose answer(s) in the window; answers naming a loop name the record's own: [True]
    1. <tool_use_error>script_syntax_error: SyntaxError: Invalid or unexpected token at line 1, column 45: …[''alpha'', ''bravo'', ''charlie''];\\nconst probes = hosts.map(fun…</tool_use_error>
    2. Composed 5 tasks: r3t0-script-1, r3t0-script-2, r3t0-script-3, r3t0-parallel-1, r3t0-model-1.\nTheir results reach you in the next round.\nTask reference: agent_loop=\"01a0d536-22ff-717b-9d46-57883028
    first compose call r2t0: script starts "const hosts = ['alpha', 'bravo', 'charlie'];\\nconst probes = hosts.map"
- floor compose-race glm-5.3-flash #1 (usable_on_call 2); 2 compose answer(s) in the window; answers naming a loop name the record's own: [True, True]
    1. The script built no tasks.\nTask reference: agent_loop=\"01a0d537-a6dd-7de8-8a14-21798ae2aeab\", task=\"r2t0\".
    2. Composed 5 tasks: r3t0-tool-1, r3t0-tool-2, r3t0-tool-3, r3t0-parallel-1, r3t0-script-1.\nTheir results reach you in the next round.\nTask reference: agent_loop=\"01a0d537-a6dd-7de8-8a14-21798ae2aeab\
    first compose call r2t0: script starts '`    const alpha   = g.tool({ name: "bash", input: { command: "bin/pro'
- floor compose-race-anon deepseek-flash #3 (usable_on_call 2); 2 compose answer(s) in the window; answers naming a loop name the record's own: [True]
    1. <tool_use_error>script_error: Error: g.parallel: every member must be a step built for this group, e.g. g.parallel([g.tool({...}), g.model({...})]). \"script-1\" was already placed earlier in the scri
    2. Composed 8 tasks: r3t0-tool-1, r3t0-script-1, r3t0-tool-2, r3t0-script-2, r3t0-tool-3, r3t0-script-3, r3t0-parallel-1, r3t0-model-1.\nTheir results reach you in the next round.\nTask reference: agent_
    first compose call r2t0: script starts 'const hosts = ["alpha", "bravo", "charlie"];\nconst members = hosts.map'
- floor compose-review-angles glm-5.3-flash #1 (usable_on_call 2); 2 compose answer(s) in the window; answers naming a loop name the record's own: [True]
    1. <tool_use_error>script_error: Error: g.model: results names an \"all\" group, which is not one step; list its steps instead: results: [a, b].</tool_use_error>
    2. Composed 4 tasks: r3t0-model-1, r3t0-model-2, r3t0-model-3, r3t0-model-4.\nThey run in the background: each result reaches you later as a message that is not from the person.\nTask reference: agent_lo
    first compose call r2t0: script starts '// Three fresh reviewers open patch.diff themselves, in parallel; one '
- floor compose-three-stage-pairing glm-5.3-flash #1 (usable_on_call None); 0 compose answer(s) in the window; answers naming a loop name the record's own: []
- floor workflow-barrier-free-pipeline deepseek-flash #1 (usable_on_call None); 0 compose answer(s) in the window; answers naming a loop name the record's own: []
- floor workflow-barrier-free-pipeline deepseek-flash #2 (usable_on_call None); 0 compose answer(s) in the window; answers naming a loop name the record's own: []
- floor workflow-barrier-free-pipeline glm-5.3-flash #2 (usable_on_call None); 0 compose answer(s) in the window; answers naming a loop name the record's own: []
- strong compose-background-suite glm-5.3 #3 (usable_on_call None); 0 compose answer(s) in the window; answers naming a loop name the record's own: []
- strong compose-grep-then-edit glm-5.3 #1 (usable_on_call 2); 2 compose answer(s) in the window; answers naming a loop name the record's own: [True, True]
    1. Composed 1 task: r2t0-script-1.\nTheir results reach you in the next round.\nTask reference: agent_loop=\"01a0d505-b360-7780-b00a-d7904c4a5a6d\", task=\"r2t0\".
    2. Composed 1 task: r3t0-script-1.\nTheir results reach you in the next round.\nTask reference: agent_loop=\"01a0d505-b360-7780-b00a-d7904c4a5a6d\", task=\"r3t0\".
    first compose call r2t0: script starts 'g.script({\n  script: `\nvar gu = g.tool({ name: "grep", input: { patter'
- strong compose-review-angles glm-5.3 #3 (usable_on_call 2); 2 compose answer(s) in the window; answers naming a loop name the record's own: [True]
    1. <tool_use_error>script_syntax_error: SyntaxError: Invalid or unexpected token at line 1, column 11: g.script({\\n  script: `\\n    const security = g.model({ prom…</tool_use_error>
    2. Composed 4 tasks: r3t0-model-1, r3t0-model-2, r3t0-model-3, r3t0-model-4.\nTheir results reach you in the next round.\nTask reference: agent_loop=\"01a0d582-411d-72b4-b8b3-56393027676d\", task=\"r3t0\
    first compose call r2t0: script starts 'g.script({\\n  script: `\\n    const security = g.model({ prompt: "Open '
- strong compose-three-stage-pairing kimi-k3 #1 (usable_on_call 2); 2 compose answer(s) in the window; answers naming a loop name the record's own: [True, True]
    1. Composed 1 task: r2t0-script-1.\nTheir results reach you in the next round.\nTask reference: agent_loop=\"01a0d5b7-7807-7016-96d5-dd9953645312\", task=\"r2t0\".
    2. Composed 1 task: r3t0-script-1.\nTheir results reach you in the next round.\nTask reference: agent_loop=\"01a0d5b7-7807-7016-96d5-dd9953645312\", task=\"r3t0\".
    first compose call r2t0: script starts 'g.script({\n  script: `\n    const names = ["a", "b", "c"];\n    const le'
- strong workflow-barrier-free-pipeline kimi-k3 #1 (usable_on_call None); 0 compose answer(s) in the window; answers naming a loop name the record's own: []
- strong workflow-barrier-free-pipeline kimi-k3 #2 (usable_on_call None); 0 compose answer(s) in the window; answers naming a loop name the record's own: []
- strong workflow-barrier-free-pipeline kimi-k3 #3 (usable_on_call None); 0 compose answer(s) in the window; answers naming a loop name the record's own: []
- strong workflow-barrier-free-pipeline glm-5.3 #1 (usable_on_call None); 0 compose answer(s) in the window; answers naming a loop name the record's own: []

## 2. S1's refusal sentence in the v13 windows

windows read 168; windows carrying the sentence 0 []

## 3. the two lane bugs: reasoning deltas on their own loop

- compose-background-suite glm-5.3 #3: loop 01a0d4e2-60b1-7b12-80fd-4ba523f31311; reasoning_delta broadcasts 1679 (task keys ['r1']), first at line 15161, last at line 31715 of 32194; stream_reset 0 (line, task, reason) []; record: stopped deadline, 607 s, rounds_settled 0
    the same loop's reasoning_delta lines in the other logs: {'nexus.server.log': 1679, 'nexus.rails.log': 1679, 'nexus.model_runner.rails.log': 1679}
- compose-grep-then-edit glm-5.3-flash #1: loop 01a0d51c-dd96-776d-adc7-79d9a934ec7b; reasoning_delta broadcasts 4060 (task keys ['r1']), first at line 219328, last at line 243589 of 243608; stream_reset 1 (line, task, reason) [(236061, 'r1', 'retry')]; record: stopped deadline, 607 s, rounds_settled 0
    the same loop's reasoning_delta lines in the other logs: {'nexus.server.log': 4060, 'nexus.rails.log': 4060, 'nexus.model_runner.rails.log': 4060}
~~~
