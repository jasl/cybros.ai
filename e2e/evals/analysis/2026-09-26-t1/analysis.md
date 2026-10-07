# T1 text-bench batch and the R-NORACE pair — 2026-09-26 (analysis)

## Provenance (resolution 0)

- tree read: `/Users/jasl/Workspaces/cybros-ai.alt2-t1` — branch `bench/t1-r-l3` at b4124dde, on main ed54f7d8 (main now 563a86aa)
- differs from main ed54f7d8 under nexus/ and e2e/: e2e/support/compose_bench/rows.rb; e2e/test/compose_bench_rows_harness_test.rb (uncommitted: none)
- launched 2026-09-25T06:52:46Z (`logs/launch.txt`) at b4124dde98c5501560117f0138de33118d4275f3, on main ed54f7d88277b59beaa315ac209dba3e2c4fc728: the tree read is that HEAD, nothing uncommitted
- this analyzer's sha256 e6e6b390f02c5ef4599cd402d287fc28fb41f46713d251790d6cd0cb9798c9b3: the launch's
- the pair's builder: 56469b97:nexus/lib/nexus/compose/builder.js read in memory; the swap checked (main refuses a member reference with race_member, 56469b97 builds it)
- R-WO: `/Users/jasl/Workspaces/cybros-ai.alt2/e2e/artifacts/bench/2026-09-26-t1/R-WO/openrouter_z-ai_glm-5.3` (exit 0) + `/Users/jasl/Workspaces/cybros-ai.alt2/e2e/artifacts/bench/2026-09-26-t1/R-WO/openrouter_moonshotai_kimi-k3` (exit 0) + `/Users/jasl/Workspaces/cybros-ai.alt2/e2e/artifacts/bench/2026-09-26-t1/R-WO/deepseek_deepseek-flash` (exit 0) + `/Users/jasl/Workspaces/cybros-ai.alt2/e2e/artifacts/bench/2026-09-26-t1/R-WO/openrouter_z-ai_glm-5.3-flash` (exit 0) — 384 samples (glm-5.3 96, kimi-k3 96, deepseek-flash 96, glm-5.3-flash 96)
- R-L3: `/Users/jasl/Workspaces/cybros-ai.alt2/e2e/artifacts/bench/2026-09-26-t1/R-L3/openrouter_z-ai_glm-5.3` (exit 0) + `/Users/jasl/Workspaces/cybros-ai.alt2/e2e/artifacts/bench/2026-09-26-t1/R-L3/openrouter_moonshotai_kimi-k3` (exit 0) + `/Users/jasl/Workspaces/cybros-ai.alt2/e2e/artifacts/bench/2026-09-26-t1/R-L3/deepseek_deepseek-flash` (exit 0) + `/Users/jasl/Workspaces/cybros-ai.alt2/e2e/artifacts/bench/2026-09-26-t1/R-L3/openrouter_z-ai_glm-5.3-flash` (exit 0) — 384 samples (glm-5.3 96, kimi-k3 96, deepseek-flash 96, glm-5.3-flash 96)
- R-NORACE: `/Users/jasl/Workspaces/cybros-ai.alt2/e2e/artifacts/bench/2026-09-26-t1/R-NORACE/openrouter_z-ai_glm-5.3` (exit 0) + `/Users/jasl/Workspaces/cybros-ai.alt2/e2e/artifacts/bench/2026-09-26-t1/R-NORACE/openrouter_moonshotai_kimi-k3` (exit 0) + `/Users/jasl/Workspaces/cybros-ai.alt2/e2e/artifacts/bench/2026-09-26-t1/R-NORACE/deepseek_deepseek-flash` (exit 0) + `/Users/jasl/Workspaces/cybros-ai.alt2/e2e/artifacts/bench/2026-09-26-t1/R-NORACE/openrouter_z-ai_glm-5.3-flash` (exit 0) — 384 samples (glm-5.3 96, kimi-k3 96, deepseek-flash 96, glm-5.3-flash 96)
- OLD (the third column): `/Users/jasl/Workspaces/cybros-ai.alt2/e2e/artifacts/bench/2026-09-23-arms/arms/R-WO` — 192 samples (glm-5.3 48, kimi-k3 48, deepseek-flash 48, glm-5.3-flash 48)
- harness-fault reruns read in place of the launch's directories: none

## The pre-registered figures, computed

Guard no-effect veto probability (resolution 5; operational reading b, from `/Users/jasl/Workspaces/cybros-ai.alt2/e2e/artifacts/bench/2026-09-23-arms/arms/R-WO`):

| rule | O1 | O2 | O3 | O4 | O7 | O7b | T5 | family-wise |
|---|---|---|---|---|---|---|---|---|
| rate, z = 2.1893 (THE RULE) | 0.0 % | 0.0 % | 0.0 % | 0.82 % | 1.47 % | 0.04 % | 0.0 % | **2.3 %** |
| rate, plain z = 1.28 | 0.0 % | 0.0 % | 0.0 % | 7.73 % | 9.66 % | 2.66 % | 0.0 % | 18.9 % |
| pooled count ≥ 4 of 48 | 0.0 % | 2.6 % | 20.0 % | 19.1 % | 20.0 % | 11.6 % | 0.0 % | 55.4 % |
| per-cell count ≥ 2 of 6 | 0.0 % | 11.5 % | 46.6 % | 44.5 % | 47.1 % | 27.3 % | 0.0 % | 89.9 % |

Inputs (the record's right / readable of the cell's draws): O1 deepseek-flash 6/6 of 6, kimi-k3 6/6 of 6, glm-5.3 6/6 of 6, glm-5.3-flash 6/6 of 6; O2 deepseek-flash 0/0 of 6, kimi-k3 0/0 of 6, glm-5.3 1/1 of 6, glm-5.3-flash 0/1 of 6; O3 deepseek-flash 3/3 of 6, kimi-k3 2/2 of 6, glm-5.3 0/0 of 6, glm-5.3-flash 3/3 of 6; O4 deepseek-flash 2/6 of 6, kimi-k3 2/4 of 6, glm-5.3 0/6 of 6, glm-5.3-flash 2/5 of 6; O7 deepseek-flash 2/6 of 6, kimi-k3 1/2 of 6, glm-5.3 1/2 of 6, glm-5.3-flash 2/3 of 6; O7b deepseek-flash 0/5 of 6, kimi-k3 0/6 of 6, glm-5.3 4/5 of 6, glm-5.3-flash 1/6 of 6; T5 deepseek-flash 0/6 of 6, kimi-k3 0/4 of 6, glm-5.3 0/5 of 6, glm-5.3-flash 0/6 of 6

Guard power at 48 readable per arm (z = 2.1893): a fall of 12 of 48 at a 50 % base 64.3 %; 10 of 48 at 30 % 66.3 %.
Zero-difference lower bounds at n = 168 (z = 1.2816): floor gate at 163/168 -2.5, at 151/168 -4.3; the pair's gate at 151/168 -4.3.

## (1) The endpoint: O3 `authored_labels` over first scripts that built (resolution 3)

| arm | pooled | glm-5.3 | kimi-k3 | deepseek-flash | glm-5.3-flash |
|---|---|---|---|---|---|
| R-WO | 19/36 (52.8 %) | 10/12 (83.3 %) | 3/7 (42.9 %) | 5/9 (55.6 %) | 1/8 (12.5 %) |
| R-L3 | 4/45 (8.9 %) | 1/12 (8.3 %) | 2/11 (18.2 %) | 0/11 (0.0 %) | 1/11 (9.1 %) |

Drop R-WO − R-L3: +43.9 pts, one-sided 90 % lower +31.2 → **(1) HOLDS**.
Under no effect at these readable n (36, 45) and the pooled share 0.284, the bound lands 10.6 % of the time.
Built by the record, unread by the re-read (out of the denominator): none.

O3 first-call refusals by bucket (the record's), reached and unreached:

- R-WO: refused 11/48 (member_not_a_step 9, race_member 1, syntax 1); unreached 1; per model glm-5.3 0 (none), kimi-k3 4 (member_not_a_step 4), deepseek-flash 3 (member_not_a_step 3), glm-5.3-flash 4 (member_not_a_step 2, race_member 1, syntax 1)
- R-L3: refused 3/48 (member_not_a_step 3); unreached 0; per model glm-5.3 0 (none), kimi-k3 1 (member_not_a_step 1), deepseek-flash 1 (member_not_a_step 1), glm-5.3-flash 1 (member_not_a_step 1)
- differential flags (≥ 2 of 12 on a model, ≥ 4 of 48 pooled; R-WO→R-L3): kimi-k3 4→1; deepseek-flash 3→1; glm-5.3-flash 4→1; pooled 11→3
- opaque among the built O3 first scripts (labels read on the visible plan, kept in): R-WO 29/36, R-L3 10/45
- over judged scripts (reported): R-WO 27/46 (58.7 %), R-L3 7/48 (14.6 %); drop +44.1 pts (lower +31.9)

## (2) The floor gate: usable on the judged script, the two floors × the seven objectives (resolution 4)

| arm | usable (judged) | unreached | first-script usable | valid_after_repair (record) |
|---|---|---|---|---|
| R-WO | 163/168 (97.0 %) | 1 | 149/168 (88.7 %) | 165/168 (98.2 %) |
| R-L3 | 165/168 (98.2 %) | 2 | 153/168 (91.1 %) | 165/168 (98.2 %) |

Difference R-L3 − R-WO: +1.2 pts, one-sided 90 % lower -1.1 (floor -5.0) → **(2) HOLDS**. No second batch.
Zero-difference bound at this batch's R-WO rate (163/168): -2.5.

Reported beside, never deciding:

- first-script usable: Δ +2.4 pts (lower -1.9)
- `valid_after_repair`: Δ +0.0 pts (lower -2.1)
- provider `error` finishes and client exceptions dropped (R-WO 1, R-L3 2): R-WO 163/167 (97.6 %), R-L3 165/166 (99.4 %); Δ +1.8 pts (lower +0.0)
- deepseek-flash: R-WO 84/84 (100.0 %), R-L3 84/84 (100.0 %); Δ +0.0 pts (lower -1.9)
- glm-5.3-flash: R-WO 79/84 (94.0 %), R-L3 81/84 (96.4 %); Δ +2.4 pts (lower -2.0)

Per (floor, objective), usable R-WO → R-L3 (a loss ≥ 2/12 is a flag, never a veto):

| floor | O1 | O2 | O3 | O4 | O7 | O7b | T5 |
|---|---|---|---|---|---|---|---|
| deepseek-flash | 12/12→12/12 | 12/12→12/12 | 12/12→12/12 | 12/12→12/12 | 12/12→12/12 | 12/12→12/12 | 12/12→12/12 |
| glm-5.3-flash | 12/12→12/12 | 11/12→12/12 | 10/12→12/12 | 12/12→12/12 | 11/12→12/12 | 12/12→11/12 | 11/12→10/12 |

Flags: none.

## (3) The guard: expanded first_time_right over readable draws, per objective, pooled (resolution 5)

| objective | R-WO right/readable | R-L3 right/readable | fall | lower, z 2.1893 (THE RULE) | veto | lower, z 1.28 (not the rule) | count fall ≥ 4 |
|---|---|---|---|---|---|---|---|
| O1 | 46/46 (100.0 %) | 43/45 (95.6 %) | +4.4 | -5.6 | — | +0.1 | — |
| O2 | 2/3 (66.7 %) | 13/13 (100.0 %) | -33.3 | -81.9 | — | -67.9 | — |
| O3 | 7/7 (100.0 %) | 35/35 (100.0 %) | +0.0 | -40.6 | — | -19.0 | — |
| O4 | 31/44 (70.5 %) | 35/44 (79.5 %) | -9.1 | -28.4 | — | -20.6 | — |
| O7 | 18/24 (75.0 %) | 16/26 (61.5 %) | +13.5 | -14.9 | — | -3.4 | — |
| O7b | 7/45 (15.6 %) | 9/46 (19.6 %) | -4.0 | -21.5 | — | -14.2 | — |
| T5 | 4/38 (10.5 %) | 2/37 (5.4 %) | +5.1 | -10.7 | — | -3.3 | — |

**(3) HOLDS: no objective vetoes.** Pooled count flags (≥ 4): none.

Per (model, objective), right/readable R-WO → R-L3 (a fall ≥ 2 is a flag, never a veto):

| model | O1 | O2 | O3 | O4 | O7 | O7b | T5 |
|---|---|---|---|---|---|---|---|
| glm-5.3 | 11/11→11/11 | 1/1→3/3 | 1/1→11/11 | 11/12→9/11 ⚑ | 2/2→3/5 | 2/10→5/12 | 3/11→1/11 ⚑ |
| kimi-k3 | 12/12→12/12 | 0/0→3/3 | 3/3→7/7 | 4/11→6/11 | 2/4→1/3 | 0/12→0/12 | 0/10→0/11 |
| deepseek-flash | 11/11→9/11 ⚑ | 1/1→6/6 | 3/3→11/11 | 10/11→11/12 | 7/10→6/11 | 3/12→1/12 ⚑ | 0/12→0/9 |
| glm-5.3-flash | 12/12→11/11 | 0/1→1/1 | 0/0→6/6 | 6/10→9/10 | 7/8→6/7 | 2/11→3/10 | 1/5→1/6 |

Cell flags: glm-5.3 O4 11/12→9/11; glm-5.3 T5 3/11→1/11; deepseek-flash O1 11/11→9/11; deepseek-flash O7b 3/12→1/12.

## Verdict (resolution 6)

**T1 LANDS**: (1), (2) and (3) hold — (1) at the row's one-sided 90 % bound, which a no-effect sentence passes about one time in ten (10.6 % at this batch's n).

## Beside the verdict (resolution 7)

O3 labels by winner kind (first scripts that built; main's builder):

- R-WO: model-step winner 6/13 (46.2 %); value stage naming the race 13/23 (56.5 %); no winner step —
- R-L3: model-step winner 0/35 (0.0 %); value stage naming the race 4/10 (40.0 %); no winner step —

O3 silent (built first scripts) and loud (first-call refusals), the record's:

- R-WO: silent exact 13, missing_join 9, missing_steps 9, wrong_task_read 8, extra_steps 6, over_read 2, over_sync 1; loud member_not_a_step 9, race_member 1, syntax 1
- R-L3: silent exact 39, extra_steps 4, missing_join 1, missing_steps 1, over_read 1, wrong_task_read 1; loud member_not_a_step 3
- R-NORACE: silent exact 13, extra_steps 13, over_read 13, wrong_task_read 10, missing_join 4, missing_steps 4, over_sync 1; loud race_member 4, member_not_a_step 3, syntax 1

The other endpoints, over non-control first scripts that built (re-read):

| row | wrapped_or_overfed | ungrouped_loop | closing_gather | success_filter |
|---|---|---|---|---|
| R-WO | 100/309 (32.4 %) | 7/309 (2.3 %) | 215/309 (69.6 %) | 13/309 (4.2 %) |
| R-L3 | 85/316 (26.9 %) | 7/316 (2.2 %) | 240/316 (75.9 %) | 3/316 (0.9 %) |
| R-NORACE | 121/320 (37.8 %) | 8/320 (2.5 %) | 257/320 (80.3 %) | 20/320 (6.3 %) |

Finishes, tokens, cost (the seven objectives per model; O5 on its own line, operational reading f):

- R-WO glm-5.3: first tool_calls 83, error (client) 1; repairs 1 (tool_calls 1); tokens in 344344, out 1855469, cost $8.04
- R-WO kimi-k3: first tool_calls 83, stop 1; repairs 7 (tool_calls 7); tokens in 366358, out 310528, cost $5.03
- R-WO deepseek-flash: first completed 84; repairs 8 (completed 8); tokens in 421062, out 281138
- R-WO glm-5.3-flash: first tool_calls 83, error 1; repairs 8 (tool_calls 8); tokens in 381180, out 879810, cost $0.46
- R-WO control O5: compose 0 on 48/48; first tool_calls 36, completed 12; repairs 0 (none); tokens in 194517, out 3897, cost $0.08
- R-L3 glm-5.3: first tool_calls 81, length 2, error 1; repairs 0 (none); tokens in 345863, out 1594413, cost $6.83
- R-L3 kimi-k3: first tool_calls 84; repairs 2 (tool_calls 2); tokens in 346707, out 303711, cost $4.85
- R-L3 deepseek-flash: first completed 84; repairs 5 (completed 5); tokens in 401802, out 222867
- R-L3 glm-5.3-flash: first tool_calls 82, error 1, error (client) 1; repairs 8 (tool_calls 8); tokens in 380028, out 860945, cost $0.45
- R-L3 control O5: compose 0 on 48/48; first tool_calls 36, completed 12; repairs 0 (none); tokens in 196103, out 3903, cost $0.13
- R-NORACE glm-5.3: first tool_calls 84; repairs 2 (tool_calls 2); tokens in 342655, out 1677572, cost $7.2
- R-NORACE kimi-k3: first tool_calls 84; repairs 2 (tool_calls 2); tokens in 333341, out 304413, cost $4.85
- R-NORACE deepseek-flash: first completed 84; repairs 7 (completed 7); tokens in 409274, out 302737
- R-NORACE glm-5.3-flash: first tool_calls 84; repairs 5 (tool_calls 5); tokens in 356903, out 799009, cost $0.44
- R-NORACE control O5: compose 0 on 48/48; first tool_calls 36, completed 12; repairs 0 (none); tokens in 188765, out 4012, cost $0.1

## The R-NORACE pair, first scripts under the 56469b97 builder (resolution 8)

| read (O3 first scripts built) | R-NORACE | R-WO | 09-23 R-WO (drift check) |
|---|---|---|---|
| names a MEMBER | 4/44 (9.1 %) | 1/37 (2.7 %) | 5/22 (22.7 %) |
| names the RACE | 0/44 (0.0 %) | 37/37 (100.0 %) | 1/22 (4.5 %) |
| a g.model follower | 40/44 (90.9 %) | 13/37 (35.1 %) | 17/22 (77.3 %) |
| places a race | 44/44 (100.0 %) | 37/37 (100.0 %) | 22/22 (100.0 %) |
| reading steps (race / member / implicit model) | 0 / 4 / 40 | 37 / 1 / 0 | 1 / 5 / 16 |

Reads (the registered counts held as rates; R-NORACE → R-WO):

- MEMBER share falls by +6.4 pts (≥ 12.5 registered) → not met; rises by ≥ 33.3 pts on no model → met (glm-5.3 +0.0, kimi-k3 +0.0, deepseek-flash -36.4, glm-5.3-flash +11.1)
- RACE share rises by +100.0 pts (≥ 12.5 registered) → met
- guard: the g.model follower share falls by +55.8 pts, one-sided 90 % lower +43.1 → fails (registered as < 6 of 48, held as a bounded rate)
- guard: O1 first scripts placing an `until` race, R-NORACE 0/47 (0.0 %) → R-WO 0/47 (0.0 %): rises by +0.0 pts (< 8.3 registered) → holds; 09-23 0/24 (0.0 %)
- guard: O4 first scripts placing an `until` race, R-NORACE 2/48 (4.2 %) → R-WO 0/47 (0.0 %): rises by -4.2 pts (< 8.3 registered) → holds; 09-23 2/23 (8.7 %)
- guard: T5 first scripts placing an `until` race, R-NORACE 0/46 (0.0 %) → R-WO 0/45 (0.0 %): rises by +0.0 pts (< 8.3 registered) → holds; 09-23 0/24 (0.0 %)
- beside: the three pooled, R-NORACE 2/141 (1.4 %) → R-WO 0/139 (0.0 %)

Floor gate for the pair: first-script usable under 56469b97, the two floors × the seven objectives: R-NORACE 160/168 (95.2 %), R-WO 150/168 (89.3 %) (09-23 79/84 (94.0 %)); Δ R-WO − R-NORACE -6.0 pts, lower -9.8 → **does not hold (a finding and a queue row; nothing unlands)**.

Beside it:

- R-NORACE: O3 first-call refusals (the record's kernel) 8/48 (race_member 4, member_not_a_step 3, syntax 1; glm-5.3 0/12, kimi-k3 2/12, deepseek-flash 5/12, glm-5.3-flash 1/12); 56469b97 did not build 4 (kimi-k3 O3 #2 member_not_a_step; kimi-k3 O3 #11 member_not_a_step; deepseek-flash O3 #10 member_not_a_step; glm-5.3-flash O3 #6 syntax); O3 first-script usable per floor deepseek-flash 11/12, glm-5.3-flash 11/12
- R-WO: O3 first-call refusals (the record's kernel) 11/48 (member_not_a_step 9, race_member 1, syntax 1; glm-5.3 0/12, kimi-k3 4/12, deepseek-flash 3/12, glm-5.3-flash 4/12); 56469b97 did not build 10 (kimi-k3 O3 #1 member_not_a_step; kimi-k3 O3 #4 member_not_a_step; kimi-k3 O3 #6 member_not_a_step; kimi-k3 O3 #10 member_not_a_step; deepseek-flash O3 #1 member_not_a_step; deepseek-flash O3 #3 member_not_a_step; deepseek-flash O3 #6 member_not_a_step; glm-5.3-flash O3 #1 syntax; glm-5.3-flash O3 #10 member_not_a_step; glm-5.3-flash O3 #12 member_not_a_step); O3 first-script usable per floor deepseek-flash 9/12, glm-5.3-flash 8/12
- OLD: O3 first-call refusals (the record's kernel) 3/24 (member_not_a_step 2, other 1; glm-5.3 0/6, kimi-k3 3/6, deepseek-flash 0/6, glm-5.3-flash 0/6); 56469b97 did not build 2 (kimi-k3 O3 #3 member_not_a_step; kimi-k3 O3 #5 member_not_a_step); O3 first-script usable per floor deepseek-flash 6/6, glm-5.3-flash 6/6
- R-NORACE: 56469b97 did not build, outside O3 (out of the `until` guards' shares on O1, O4, T5; in the gate, not usable): O1 1 (glm-5.3-flash O1 #3 syntax), O2 2 (glm-5.3 O2 #4 syntax; glm-5.3-flash O2 #3 syntax), O4 0, O7 2 (glm-5.3 O7 #3 syntax; glm-5.3-flash O7 #12 member_not_a_step), O7b 1 (deepseek-flash O7b #5 syntax), T5 2 (deepseek-flash T5 #11 member_order; glm-5.3-flash T5 #8 unknown_option)
- R-WO: 56469b97 did not build, outside O3 (out of the `until` guards' shares on O1, O4, T5; in the gate, not usable): O1 1 (deepseek-flash O1 #3 group_reference), O2 4 (glm-5.3 O2 #2 other; kimi-k3 O2 #1 syntax; deepseek-flash O2 #6 group_reference; deepseek-flash O2 #12 syntax), O4 1 (deepseek-flash O4 #12 member_not_a_step), O7 4 (kimi-k3 O7 #2 syntax; kimi-k3 O7 #7 syntax; deepseek-flash O7 #1 syntax; glm-5.3-flash O7 #8 group_reference), O7b 1 (glm-5.3-flash O7b #10 syntax), T5 2 (glm-5.3-flash T5 #1 group_reference; glm-5.3-flash T5 #10 after_in_input)
- OLD: 56469b97 did not build, outside O3 (out of the `until` guards' shares on O1, O4, T5; in the gate, not usable): O1 0, O2 2 (glm-5.3 O2 #6 syntax; glm-5.3-flash O2 #4 group_reference), O4 1 (glm-5.3-flash O4 #6 member_not_a_step), O7 1 (kimi-k3 O7 #3 syntax), O7b 1 (deepseek-flash O7b #6 is_not_defined), T5 0
- R-NORACE, member-naming O3 first scripts: deepseek-flash O3 #5; deepseek-flash O3 #6; deepseek-flash O3 #8; deepseek-flash O3 #9
- R-WO, member-naming O3 first scripts: glm-5.3-flash O3 #11
- OLD, member-naming O3 first scripts: deepseek-flash O3 #5; deepseek-flash O3 #6; glm-5.3 O3 #4; glm-5.3-flash O3 #2; glm-5.3-flash O3 #5
- stated apart and not read: R-NORACE's repairs (played back under today's S1 sentence).

## Record vs re-read (main's builder; resolution 2)

- R-WO: 0 draw(s) differ
- R-L3: 1 draw(s) differ
  - glm-5.3-flash O7 #6: repair valid true→false, the record says the repaired script built; the re-read refused it (script_error: TypeError: Cannot read properties of undefined (reading 'map')) — counted by the record
- R-NORACE: 2 draw(s) differ
  - glm-5.3 O7 #3: repair valid true→false, the record says the repaired script built; the re-read refused it (script_error: TypeError: sources is not iterable) — counted by the record
  - deepseek-flash O3 #5: repair valid true→false, the record says the repaired script built; the re-read refused it (script_error: TypeError: Cannot read properties of undefined (reading 'map')) — counted by the record

## Resolutions (this script's header, fixed before the data)

```text
The T1 text-bench batch of 2026-09-26 and the R-NORACE pair, read by the resolutions below.

The batch: three rows on the bench branch bench/t1-r-l3 — R-WO (main's compose bytes, 7,863 B),
R-L3 (R-WO + the T1 sentence after the two sentences on what a model step reads past a group or a
race, 7,994 B), R-NORACE (R-WO with the two race edits reversed: the pre-race reference rule back,
the race's stage slot gone, 7,446 B — the v11 text) — on openrouter/z-ai/glm-5.3,
openrouter/moonshotai/kimi-k3, deepseek/deepseek-flash and openrouter/z-ai/glm-5.3-flash, style
nexus, every objective (O1 O2 O3 O4 O5 O7 O7b T5), n = 12 per (row, model, objective), the 65,536
cap: 1,152 draws in twelve processes, one per (row, model), launched together.

Resolutions fixed BEFORE the data (written 2026-09-25, before any sample file under 2026-09-26-t1/
existed):

0. PROVENANCE. The bench branch's HEAD and the main commit it sits on are printed; every reading
   below is re-read under that tree (main's builder for every row; 56469b97's builder read in
   memory for resolution 8 alone, B's script-3 mechanism). A later tree's re-read is a second
   column, never the verdict.
1. UNIT. One draw = (row, model, objective, index). The JUDGED script is the first when it built
   (`valid_first`), else the repaired when `repaired == "valid"`, else none. O5 is out of
   everything but its own compose-0 line.
2. READER. Every first and repaired script of every row is re-read at analysis time
   (analyze_ab.rb's `reread`): `valid_first`/`loud`, `usable`, `endpoints`, `expanded`/`opaque`.
   The record's validity rides as `kernel_valid_first`/`kernel_loud`; every record-vs-re-read
   disagreement is listed (all three rows ran on one builder, so a disagreement is a harness
   finding). Validity is the record's; `usable`, endpoints and the expanded reading are the
   re-read's. A repaired script the record says built and the re-read cannot build (the repair
   call's params are not recorded) counts by the record — usable — and is listed by name, S1's
   rule (analyze_s1.rb#usable_after_repair).
3. ENDPOINT (T1). Over O3 first scripts that built, R-WO against R-L3, pooled over the four
   models: the share with `endpoints.authored_labels == true`. Drop = p(R-WO) − p(R-L3); (1) HOLDS
   when the one-sided 90 % lower bound of the drop is above 0. Under no effect the bound lands
   ≈ 10 % of the time at any readable n from 18 to 48 per arm and any base from 0.15 to 0.60
   (computed: 9.2–11.4 %) — the bound's own α; a landing is stated at that rate. Printed beside:
   the same share per model; refusals per arm by bucket, per model and pooled, flagged at a
   differential ≥ 2 of 12 on any model or ≥ 4 of 48 pooled; opaque per arm (labels are read on
   the visible plan and stay in); the endpoint over judged scripts.
4. FLOOR GATE. Usable on the judged script, pooled over the two floors and O1 O2 O3 O4 O7 O7b T5
   (168 draws per arm); an unreached draw (no compose call, a provider error, `length`, refused
   twice, `no_second_call`) is NOT usable and STAYS in the denominator. Difference = R-L3 − R-WO;
   (2) HOLDS when the lower bound is ≥ −5.0 points. Zero-difference bound at the S1 base rate
   (163/168): −2.5; at 151/168: −4.3 (both computed and printed below). Per-(floor, objective)
   losses ≥ 2/12 are flags. Reported beside with their own bounds, never deciding: first-script
   usable, `valid_after_repair`, and the sensitivity with provider `error` finishes and client
   exceptions dropped from both denominators. NO SECOND BATCH: 168 is the pre-registered size; a
   failure is a finding.
5. GUARD. Expanded `first_time_right` per objective (O1 O2 O3 O4 O7 O7b T5) pooled over the four
   models, as rates over the readable denominators (opaque draws out of both, each arm's readable
   n printed beside its rate); (3) FAILS when, on any objective, the fall R-WO − R-L3 has a
   one-sided lower bound above 0 at z = 2.1893 (one-sided 90 % family-wise over seven objectives,
   1 − 0.10/7). The no-effect veto probability, computed exactly as the difference of two sums of
   binomials per objective (guard_null.py's method) on the 09-23 R-WO's readable per-cell rates:
   2.3 % family-wise (O4 0.8 %, O7 1.5 %, the rest 0); the same computation gives 18.9 % for a
   plain z = 1.28 bound, 55.4 % for the pooled count "≥ 4 of 48", 90 % for the row's per-cell
   "≥ 2 of 6" (all computed and printed below). The S1 pair is the dry run: with `with` read as
   R-WO, the plain bound vetoes on O7 (14/19 vs 7/17, lower +11.4) and O7b (8/20 vs 4/21, +2.7) —
   two false vetoes on a pair whose text never differed — and the family-wise bound vetoes on
   none (O7 −3.0 the closest). Power at 48 readable per arm: a fall of 12 of 48 at a 50 % base is
   caught with 64 %, 10 of 48 at 30 % with 66 %; smaller falls print as flags. Per-(model,
   objective) cells at n = 12 print with a flag on a fall ≥ 2; per-objective falls ≥ 4 of 48
   print as flags. O2 is in the guard for form: the expanded reading counts a stage-decided edit
   out as opaque, so O2 is readable on about 1–2 draws per cell and the family-wise bound can
   never veto on it.
6. VERDICT. T1 lands iff (1) ∧ (2) ∧ (3); otherwise it does not land and the readout names the
   clause.
7. BESIDE THE VERDICT, never deciding. O3 labels split by winner kind per arm (a model-step
   winner, a value stage naming the race, no winner step) — the sentence excludes stages by its
   own words ("read by a model step or delivered to you"; a stage's `results[i]` gains no
   `<call>` line), so a stage winner still needs a label and dilutes the pooled drop; O3 silent
   and loud tallies; the other four endpoints; first-call and repair finishes, tokens and cost
   per (row, model); the control's compose-0.
8. THE R-NORACE PAIR (same day). Reader: every first script of R-NORACE and R-WO built by the
   56469b97 builder in memory, its result-free stages inlined and each result-reading stage body
   run once with `results: []`, every step after a race classed by B's script-3 `readers`
   (names_race / names_member / implicit_model; a script that builder refuses is "did not
   build", listed). THIS DEPARTS FROM the v12 note's "on the STATIC reading", which cannot see a
   member reference inside a stage body: the script-3 reading finds them (v11 reads 4
   member-naming runs this way against the note's 3). Reads, the registered counts held as rates:
   the MEMBER share falls by ≥ 6 of 48 and rises by ≥ 4 of 12 on no model; the RACE share rises
   by ≥ 6 of 48. Guards, per objective: the `g.model` follower share on O3 — a rate over each
   row's O3 first scripts the 56469b97 builder built — fails when the one-sided lower bound of the
   fall p(R-NORACE) − p(R-WO) is above 0 at z = 1.2816: the v12 note's 'fewer than 3 of 24' held
   as a bounded rate, as resolution 5 holds the row's count (a point rule at 12.5 points fails a
   no-effect pair 9–21 % of the time and moves with n; the bound ≈ 10 % at any n). Revised
   before the data; a reading nothing lands on. The share of first scripts placing an `until`
   race on O1, O4 and T5 rises by < 4 of 48 on each (the pooled rise over the three printed
   beside). FLOOR GATE FOR THE PAIR: first-script usable under
   the 56469b97 builder for both rows, pooled over the two floors on the seven non-control
   objectives (168 per arm), difference R-WO − R-NORACE, holds at a lower bound ≥ −5; the
   zero-difference bound at the race text's first-script rate, 151/168, is −4.3, so the gate
   holds only when R-WO loses at most 1 draw net of 168 against R-NORACE and fails after a loss
   of 2 — readable, weak, and said. Beside it: O3 first-call refusals per row by bucket
   (`member_not_a_step` is the example-priming candidate: S1 floors 5/24 and 6/24 under the race
   text, 0/12 on the 09-23 floors); the O3 first-script usable per floor (S1 17/24 and 16/24
   against 12/12 on 09-23). Stated apart and NOT read: R-NORACE's repairs (played back under
   today's S1 sentence). The 09-23 arms' R-WO is a third column of the same reads (not same day,
   its own kernel; a drift check). Nothing lands or unlands on this resolution; a failed gate is a
   finding and a queue row.

Arithmetic: analyze_ab.rb's `wilson`/`difference` verbatim (Wilson per arm, Newcombe's hybrid),
the z a parameter: 1.2815515655446004 (one-sided 90 %) for the endpoint, the gates and the pair's
follower guard, 2.1893 for resolution 5's guard (3). A bound is compared as printed (rounded to 0.1 point). The
pair's reads and `until` guards (8), the registered counts held as rates, compare exact fractions
against 6 of 48, 4 of 12 and 4 of 48, so a share exactly at a bar reads as the count would.

OPERATIONAL READINGS (fixed with this file, before the data; each the one reading the words above
and the figures they quote admit):
a. The guard's READABLE draw: the record built the first script and its re-read's expanded
   reading exists (`opaque == false`) — the definition that reproduces the S1 figures in 5 (O7
   14/19 and 7/17, O7b 8/20 and 4/21).
b. The no-effect veto probability's inputs: the 09-23 R-WO RECORD's per-(model, objective)
   readable counts (right k of readable r, rate k/r), readable n scaled from the cell's 6 draws to
   this batch's 12 (2r); both arms drawn from them. The count rules use guard_null.py's rates
   (right of all 6 draws), 12 a cell pooled, and 6 a cell per cell. These reproduce 2.3 % / 18.9 %
   / 55.4 % / 90 %.
c. A judged FIRST script the record built and the re-read refuses counts by the record too (S1's
   rule covers the judged script, first or repaired); it has no expanded reading and no endpoints,
   so it leaves those two denominators, and it is listed.
d. The pair's shares are over the first scripts the 56469b97 builder built, objective by
   objective: O3's for the reads and the follower guard, each of O1's, O4's and T5's for its own
   `until` guard (a refusal is not a reference decision). BUILT is the record's `valid_first`
   under that builder: the evaluator built the script AND the harness lowering accepted its plan
   (`Shape.lowering_refusal`). B's script 3 refused on the evaluator alone and used the lowering
   only to cross-check the kernel, so a lowering refusal is "did not build" here and was not
   there. "Did not build" is listed apart per row and objective; in the pair's floor gate such a
   draw stays in the denominator, not usable, as an unreached one does. A draw is MEMBER-naming
   (RACE-naming) when any step reading any race of its plan — stage bodies included — names a
   member (the race); a `g.model` FOLLOWER when any such reading step is a `g.model`, whatever it
   names; it PLACES a race when its plan holds an `until` other than "all", stage bodies included.
e. The winner kind (7) is read under main's builder by the same walk: a `g.model` reading a race,
   else a `g.script` reading it, else none.
f. O5 is out of everything but its own line (1): the finishes, repairs, tokens and cost per (row,
   model) cover the seven other objectives, and each row's control line carries O5's compose 0
   and O5's own spend, so the batch's spend is the lines' sum.
g. The record-vs-re-read listing (2) compares, where both built the first script: `usable`, the
   shared scorer's `first_time_right`, `opaque`, the expanded `first_time_right` and every
   endpoint (the readings the gate, the guard and the endpoint decide on); where neither built, the
   loud bucket; and the repair's validity. A reading the record does not carry (an older
   harness's record) is tallied apart, never listed as a disagreement.

Usage (cwd = the bench branch's e2e, /Users/jasl/Workspaces/cybros-ai.alt2-t1/e2e):
  bundle exec ruby /Users/jasl/Workspaces/cybros-ai.alt2/e2e/artifacts/bench/2026-09-26-t1/analyze_t1.rb [ROW/<model slug>=DIR …]
    → analysis.md beside this file. Each (row, model) is read from its own launch directory,
      <this dir>/<row>/<model slug>/compose_matrix.json, unless ROW/<model slug>=DIR names another:
      a harness-fault rerun, which reruns all three rows of the model together, so an override
      names all three rows of its slug or nothing is read. REFUSED, as a harness fault to rerun: a
      missing compose_matrix.json (the process ended before its report), a launch log
      (logs/<row>.<model slug>.log two levels above the directory) recording a non-zero exit, a
      sample whose `error` (the first call's) or `repaired_error` (the repair call's) is one the
      matrix test's own gate calls the harness's (NoMethodError, ArgumentError, TypeError).
      REFUSED, as not this batch: a sample of another row or model, a duplicate (row, model,
      objective, sample), a row whose samples are not exactly the four models × the eight
      objectives × samples 1–12, which also fixes the gates' 168 floor draws. REFUSED, as a moved
      tree: a worktree whose HEAD is not the one launch.sh stamped in logs/launch.txt, or that
      holds uncommitted changes under nexus/ or e2e/; this file's sha256 against the stamp's is
      printed, a mismatch disclosed, never refused.
  A dry run names every role and writes dryrun-<name>.md, never analysis.md. Its batches pool by
  their index; a duplicate (role, batch, model, objective, sample) and a harness-fault sample are
  refused, and neither the samples' own row and model nor the size is checked (the stand-ins are
  other benches' R-WO, at n = 6):
    bundle exec ruby <this file> --dry <name> R-WO=<dir>[,<dir>] R-L3=<dir>[,…] R-NORACE=<dir>[,…] [OLD=<dir>]
  OLD (the third column and the null computation's input) defaults to the 09-23 arms' R-WO.
  T1_ROOT overrides the tree the readings load (default: the bench branch's worktree).
```
