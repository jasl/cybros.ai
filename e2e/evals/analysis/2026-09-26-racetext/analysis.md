# The race-text A/B — 2026-09-26 (analysis)

## Provenance (resolution 0)

- tree read: `/Users/jasl/Workspaces/cybros-ai.alt2-racetext` — branch `bench/racetext` at 6bbf6582, on main e26dad18 (main now 4a8cf2ea)
- differs from main e26dad18 under nexus/ and e2e/: e2e/support/compose_bench/rows.rb; e2e/test/compose_bench_rows_harness_test.rb (uncommitted: none)
- batch 1 launched 2026-09-25T15:16:27Z (`logs/launch.txt`) at 6bbf6582ccf54b7b63fc0e25c4b63d3a33142a0d, on main e26dad18f350a46b6489b58eb42510f2b05c341a: the tree read is that HEAD, nothing uncommitted
- this analyzer's sha256 6f6555f6a5c9296fd6f8eeb700a7ee2c6ffc43af702d319fab188c21ab32f052: batch 1's launch's
- R-WO: batch 1: deepseek_deepseek-flash/A exit 0, deepseek_deepseek-flash/B exit 0, openrouter_z-ai_glm-5.3-flash/A exit 0, openrouter_z-ai_glm-5.3-flash/B exit 0, openrouter_z-ai_glm-5.3/O3 exit 0, openrouter_moonshotai_kimi-k3/O3 exit 0 — 216 samples (deepseek-flash 96, glm-5.3-flash 96, glm-5.3 12, kimi-k3 12)
- R-CHAIN: batch 1: deepseek_deepseek-flash/A exit 0, deepseek_deepseek-flash/B exit 0, openrouter_z-ai_glm-5.3-flash/A exit 0, openrouter_z-ai_glm-5.3-flash/B exit 0, openrouter_z-ai_glm-5.3/O3 exit 0, openrouter_moonshotai_kimi-k3/O3 exit 0 — 216 samples (deepseek-flash 96, glm-5.3-flash 96, glm-5.3 12, kimi-k3 12)
- R-GROUP: batch 1: deepseek_deepseek-flash/A exit 0, deepseek_deepseek-flash/B exit 0, openrouter_z-ai_glm-5.3-flash/A exit 0, openrouter_z-ai_glm-5.3-flash/B exit 0, openrouter_z-ai_glm-5.3/O3 exit 0, openrouter_moonshotai_kimi-k3/O3 exit 0 — 216 samples (deepseek-flash 96, glm-5.3-flash 96, glm-5.3 12, kimi-k3 12)
- R-BOTH: batch 1: deepseek_deepseek-flash/A exit 0, deepseek_deepseek-flash/B exit 0, openrouter_z-ai_glm-5.3-flash/A exit 0, openrouter_z-ai_glm-5.3-flash/B exit 0, openrouter_z-ai_glm-5.3/O3 exit 0, openrouter_moonshotai_kimi-k3/O3 exit 0 — 216 samples (deepseek-flash 96, glm-5.3-flash 96, glm-5.3 12, kimi-k3 12)
- NULL (the no-effect input): batch 1: `/Users/jasl/Workspaces/cybros-ai.alt2/e2e/artifacts/bench/2026-09-26-t1/R-L3` — 216 samples (deepseek-flash 96, glm-5.3-flash 96, glm-5.3 12, kimi-k3 12); 168 sample(s) outside the registered cells set aside
- harness-fault reruns read in place of the launch's directories: batch 1 R-WO/openrouter_z-ai_glm-5.3-flash/A; batch 1 R-WO/openrouter_z-ai_glm-5.3-flash/B; batch 1 R-WO/openrouter_z-ai_glm-5.3/O3; batch 1 R-CHAIN/openrouter_z-ai_glm-5.3-flash/A; batch 1 R-CHAIN/openrouter_z-ai_glm-5.3-flash/B; batch 1 R-CHAIN/openrouter_z-ai_glm-5.3/O3; batch 1 R-GROUP/openrouter_z-ai_glm-5.3-flash/A; batch 1 R-GROUP/openrouter_z-ai_glm-5.3-flash/B; batch 1 R-GROUP/openrouter_z-ai_glm-5.3/O3; batch 1 R-BOTH/openrouter_z-ai_glm-5.3-flash/A; batch 1 R-BOTH/openrouter_z-ai_glm-5.3-flash/B; batch 1 R-BOTH/openrouter_z-ai_glm-5.3/O3
- the rows' compose text under this tree (the stand-ins' own texts differ in a dry run): R-WO 7994 B, R-CHAIN 8246 B, R-GROUP 8144 B, R-BOTH 8396 B

## The pre-registered figures, computed

E1 (resolution 3):

- zero-difference bound at the shipped 153/168: -4.0; the smallest landing rise from it: 160/168 (+4.2 pts, lower +0.6)
- zero-difference bound at this batch's R-WO 158/168: -3.4; the smallest landing rise from it: 163/168 (+3.0 pts, lower +0.1)
- the procedure's false-landing rate at the shipped 153/168, n = 168 per arm: **12.7 %** (the stage-1 bound 9.8 %, a near miss 15.3 %, batch 2's pooled look 2.9 %) — against the bound's own 10 %
- the procedure's false-landing rate at this batch's R-WO 158/168, n = 168 per arm: **12.2 %** (the stage-1 bound 10.0 %, a near miss 10.9 %, batch 2's pooled look 2.2 %) — against the bound's own 10 %

Power at this batch's base (operational reading e; both arms random, the one-sided 90 % bound):

| read | base → full effect | point | bound at the full effect | chance to read at this n (168) | at twice it (336, batch 2 pooled) |
|---|---|---|---|---|---|
| E1 on R-BOTH | 158 → 161/168 | +1.8 | -1.3 | 29.6 % | 40.0 % |
| E1-form on R-GROUP | 158 → 161/168 | +1.8 | -1.3 | 29.6 % | 40.0 % |
| E1-form on R-CHAIN | 158 → 158/168 | +0.0 | -3.4 | 10.0 % | 9.5 % |

The attribution reads' thresholds and power at this batch's base (resolution 4; the fall's bound above 0):

| read | base side (net) | targeted on it | holds at ≤ | full sweep → | half → | power full / half / no effect | at twice this n: holds at ≤ |
|---|---|---|---|---|---|---|---|
| A1 pooled | 3/384 | 3 | 0 | 0 | 1.5 | 57.8 % / 21.3 % / 7.8 % | 1 of 768 |
| A1 single (R-WO → R-CHAIN) | 1/192 | 1 | none | | | | none of 384 |
| A2 pooled | 4/384 | 4 | 0 | 0 | 2 | 76.3 % / 27.2 % / 8.6 % | 3 of 768 |
| A2 single (R-WO → R-GROUP) | 3/192 | 3 | 0 | | | | 2 of 384 |

The guards' no-effect veto rates (resolution 6; operational reading d, from `/Users/jasl/Workspaces/cybros-ai.alt2/e2e/artifacts/bench/2026-09-26-t1/R-L3`, re-read under this tree):

| guard | the input's cell | this batch's n per arm | veto rate under no effect | beside |
|---|---|---|---|---|
| G1 judged usable, floors | 165/168 (98.2 %) | 168 | 3.3 % | |
| G2 the race read, O3 | 45/45 (100.0 %) | 48 | 0.0 % | at p = 0.99 5.2 %, at 0.98 10.0 % |
| G3 labels over judged, O3 | 7/48 (14.6 %) | 48 | 10.1 % | at z = 2.1893 1.1 %; power to catch a doubling 67.3 % (32.1 % at z = 2.1893) |
| G4 shape, per objective, family-wise over all but O2 | O1 0.4 %, O2 0.0 % (never a veto), O3 0.0 %, O4 0.6 %, O7 1.0 %, O7b 0.9 %, T5 0.0 % | 12.0 per cell | 3.0 % | |
| G5 the control, floor O5 | 0/24 (0.0 %) | 24 | 0.0 % | at a 1 % rate 2.4 % |

Combined no-effect veto rate: **15.7 %**. Landing power at the full effect net of the vetoes: R-BOTH 29.6 % × 84.3 % = **25.0 %**.

## E1: first-script usable, the two floors × the seven objectives (resolution 3)

| row | first-script usable | against R-WO | lower | unreached | judged usable | valid_after_repair (record) |
|---|---|---|---|---|---|---|
| R-WO | 158/168 (94.0 %) | — | — | 4 | 163/168 (97.0 %) | 163/168 (97.0 %) |
| R-CHAIN | 159/168 (94.6 %) | +0.6 | -2.7 | 3 | 162/168 (96.4 %) | 163/168 (97.0 %) |
| R-GROUP | 158/168 (94.0 %) | +0.0 | -3.4 | 6 | 161/168 (95.8 %) | 162/168 (96.4 %) |
| R-BOTH | 154/168 (91.7 %) | -2.4 | -6.1 | 5 | 161/168 (95.8 %) | 163/168 (97.0 %) |

R-BOTH − R-WO: -2.4 pts, lower -6.1 → **E1 does not hold**. The single rows print beside and never decide E1.
- sensitivity, provider `error` finishes and client exceptions dropped (R-WO 4, R-CHAIN 3): R-CHAIN − R-WO +0.0 pts, lower -2.8
- sensitivity, provider `error` finishes and client exceptions dropped (R-WO 4, R-GROUP 5): R-GROUP − R-WO +0.6 pts, lower -2.1
- sensitivity, provider `error` finishes and client exceptions dropped (R-WO 4, R-BOTH 4): R-BOTH − R-WO -2.4 pts, lower -5.7
- deepseek-flash: R-WO 82/84 (97.6 %); R-CHAIN -2.4 pts, lower -6.6; R-GROUP +2.4 pts, lower +0.0; R-BOTH +0.0 pts, lower -3.5
- glm-5.3-flash: R-WO 76/84 (90.5 %); R-CHAIN +3.6 pts, lower -1.8; R-GROUP -2.4 pts, lower -8.6; R-BOTH -4.8 pts, lower -11.3

Per (floor, objective), first-script usable R-WO → row (a loss ≥ 2 of 12 is a flag, never a veto):

| row | floor | O1 | O2 | O3 | O4 | O7 | O7b | T5 |
|---|---|---|---|---|---|---|---|---|
| R-CHAIN | deepseek-flash | 12/12→12/12 | 11/12→12/12 | 12/12→12/12 | 11/12→10/12 | 12/12→12/12 | 12/12→11/12 | 12/12→11/12 |
| R-CHAIN | glm-5.3-flash | 10/12→12/12 | 12/12→10/12 ⚑ | 10/12→11/12 | 12/12→12/12 | 11/12→12/12 | 12/12→11/12 | 9/12→11/12 |
| R-GROUP | deepseek-flash | 12/12→12/12 | 11/12→12/12 | 12/12→12/12 | 11/12→12/12 | 12/12→12/12 | 12/12→12/12 | 12/12→12/12 |
| R-GROUP | glm-5.3-flash | 10/12→11/12 | 12/12→9/12 ⚑ | 10/12→9/12 | 12/12→12/12 | 11/12→12/12 | 12/12→12/12 | 9/12→9/12 |
| R-BOTH | deepseek-flash | 12/12→12/12 | 11/12→12/12 | 12/12→11/12 | 11/12→11/12 | 12/12→12/12 | 12/12→12/12 | 12/12→12/12 |
| R-BOTH | glm-5.3-flash | 10/12→11/12 | 12/12→7/12 ⚑ | 10/12→9/12 | 12/12→10/12 ⚑ | 11/12→12/12 | 12/12→12/12 | 9/12→11/12 |

Flags: R-CHAIN glm-5.3-flash O2 12→10; R-GROUP glm-5.3-flash O2 12→9; R-BOTH glm-5.3-flash O2 12→7; R-BOTH glm-5.3-flash O4 12→10.

## A1, A2: the net first-call refusals, every draw on the seven objectives (resolution 4)

| row | draws | chain net | group net | member_not_a_step | group_reference | reference_value | other | strong O3 member_not_a_step |
|---|---|---|---|---|---|---|---|---|
| R-WO | 192 | 1 | 3 | 1 | 3 | 0 | 0 | 1/24 |
| R-CHAIN | 192 | 2 | 1 | 2 | 1 | 0 | 0 | 0/24 |
| R-GROUP | 192 | 2 | 0 | 2 | 0 | 0 | 0 | 1/24 |
| R-BOTH | 192 | 5 | 0 | 5 | 0 | 0 | 0 | 0/24 |

**A1 (the chain clause):** {R-WO, R-GROUP} 3/384 (0.8 %) → {R-CHAIN, R-BOTH} 7/384 (1.8 %): fall -1.0 pts, lower -2.2 → **A1 does not hold**
- single contrast R-WO → R-CHAIN: 1/192 (0.5 %) → 2/192 (1.0 %), fall -0.5 pts, lower -2.0
- joint contrast R-WO → R-BOTH: 1/192 (0.5 %) → 5/192 (2.6 %), fall -2.1 pts, lower -4.0

**A2 (the group clause):** {R-WO, R-CHAIN} 4/384 (1.0 %) → {R-GROUP, R-BOTH} 0/384 (0.0 %): fall +1.0 pts, lower +0.4 → **A2 HOLDS**
- single contrast R-WO → R-GROUP: 3/192 (1.6 %) → 0/192 (0.0 %), fall +1.6 pts, lower +0.4
- joint contrast R-WO → R-BOTH: 3/192 (1.6 %) → 0/192 (0.0 %), fall +1.6 pts, lower +0.4

`member_not_a_step` by the builder sentence that refused it (first calls):

- R-WO: regroup 1 — kimi-k3 O3 #12 regroup
- R-CHAIN: regroup 2 — deepseek-flash O4 #10 regroup; deepseek-flash O7b #1 regroup
- R-GROUP: regroup 2 — glm-5.3-flash O3 #12 regroup; kimi-k3 O3 #3 regroup
- R-BOTH: regroup 5 — deepseek-flash O3 #12 regroup; deepseek-flash O4 #6 regroup; glm-5.3-flash O1 #2 regroup; glm-5.3-flash O3 #2 regroup; glm-5.3-flash O3 #3 regroup

`group_reference`, `reference_value` and `other` first calls, by draw:

- R-WO group_reference: glm-5.3-flash T5 #8; glm-5.3-flash O1 #1; glm-5.3-flash O7 #3
- R-WO reference_value: none
- R-WO other: none
- R-CHAIN group_reference: deepseek-flash T5 #1
- R-CHAIN reference_value: none
- R-CHAIN other: none
- R-GROUP group_reference: none
- R-GROUP reference_value: none
- R-GROUP other: none
- R-BOTH group_reference: none
- R-BOTH reference_value: none
- R-BOTH other: none

## The guards (resolution 6)

| row | G1 judged usable, R-WO → row | G2 race read, R-WO → row | G3 labels over judged, R-WO → row | G4 shape | G5 control | vetoes |
|---|---|---|---|---|---|---|
| R-CHAIN | 163/168 (97.0 %) → 162/168 (96.4 %): -0.6 pts, lower -3.3 | 43/44 (97.7 %) → 42/46 (91.3 %): fall +6.4 pts, lower +0.0 | 7/45 (15.6 %) → 11/47 (23.4 %): rise +7.8 pts, lower -2.8 | **FAILS** on O7b | 0/24 (0.0 %) | G4 (O7b) |
| R-GROUP | 163/168 (97.0 %) → 161/168 (95.8 %): -1.2 pts, lower -4.0 | 43/44 (97.7 %) → 42/45 (93.3 %): fall +4.4 pts, lower -1.7 | 7/45 (15.6 %) → 8/46 (17.4 %): rise +1.8 pts, lower -8.3 | no objective vetoes | 0/24 (0.0 %) | none |
| R-BOTH | 163/168 (97.0 %) → 161/168 (95.8 %): -1.2 pts, lower -4.0 | 43/44 (97.7 %) → 44/44 (100.0 %): fall -2.3 pts, lower -7.3 | 7/45 (15.6 %) → 12/46 (26.1 %): rise +10.5 pts, lower -0.4 | no objective vetoes | 0/24 (0.0 %) | none |

G1 per floor and G2, G3 per tier:

- R-CHAIN: G1 deepseek-flash -2.4 pts, lower -5.6, glm-5.3-flash +1.2 pts, lower -3.5; floors: race 22/22 (100.0 %) → 23/23 (100.0 %) (fall +0.0 pts, lower -6.9); labels 5/22 (22.7 %) → 4/23 (17.4 %) (rise -5.3 pts, lower -20.6); strong: race 21/22 (95.5 %) → 19/23 (82.6 %) (fall +12.8 pts, lower +0.5); labels 2/23 (8.7 %) → 7/24 (29.2 %) (rise +20.5 pts, lower +5.8)
  - G1 with provider `error` finishes and client exceptions dropped: -1.2 pts, lower -3.1
- R-GROUP: G1 deepseek-flash +0.0 pts, lower -1.9, glm-5.3-flash -2.4 pts, lower -7.7; floors: race 22/22 (100.0 %) → 21/22 (95.5 %) (fall +4.5 pts, lower -3.1); labels 5/22 (22.7 %) → 3/23 (13.0 %) (rise -9.7 pts, lower -24.3); strong: race 21/22 (95.5 %) → 21/23 (91.3 %) (fall +4.2 pts, lower -6.6); labels 2/23 (8.7 %) → 5/23 (21.7 %) (rise +13.0 pts, lower -0.8)
  - G1 with provider `error` finishes and client exceptions dropped: -0.6 pts, lower -2.4
- R-BOTH: G1 deepseek-flash +0.0 pts, lower -1.9, glm-5.3-flash -2.4 pts, lower -7.7; floors: race 22/22 (100.0 %) → 20/20 (100.0 %) (fall +0.0 pts, lower -6.9); labels 5/22 (22.7 %) → 6/22 (27.3 %) (rise +4.5 pts, lower -12.1); strong: race 21/22 (95.5 %) → 24/24 (100.0 %) (fall -4.5 pts, lower -14.0); labels 2/23 (8.7 %) → 6/24 (25.0 %) (rise +16.3 pts, lower +2.1)
  - G1 with provider `error` finishes and client exceptions dropped: -1.2 pts, lower -3.2

G2's race-member refusals in the denominator and the built first scripts the race reading could not build (named as not naming the race):

- R-WO: race_member none; unread none; built, naming no race kimi-k3 O3 #7
- R-CHAIN: race_member none; unread none; built, naming no race glm-5.3 O3 #1; glm-5.3 O3 #5; glm-5.3 O3 #8; kimi-k3 O3 #2
- R-GROUP: race_member none; unread none; built, naming no race glm-5.3-flash O3 #5; kimi-k3 O3 #7; kimi-k3 O3 #11
- R-BOTH: race_member none; unread none; built, naming no race none

G3 beside (not the rule): the built-first-script form, both forms at z = 2.1893, and the per-model flags (a rise ≥ 2 of 12):

- R-CHAIN: over built first scripts 6/44 (13.6 %) → 10/46 (21.7 %) (rise +8.1 pts, lower -2.3); at z = 2.1893 judged lower -10.6, built lower -10.0; flags glm-5.3 0/11→4/12
- R-GROUP: over built first scripts 6/44 (13.6 %) → 7/45 (15.6 %) (rise +1.9 pts, lower -7.9); at z = 2.1893 judged lower -15.7, built lower -15.2; flags glm-5.3 0/11→4/12
- R-BOTH: over built first scripts 6/44 (13.6 %) → 10/44 (22.7 %) (rise +9.1 pts, lower -1.5); at z = 2.1893 judged lower -8.4, built lower -9.3; flags glm-5.3 0/11→5/12

G4, per objective pooled over the floors, right/readable R-WO → row (z = 2.1893; O2 in for form, never a veto):

| row | O1 | O2 | O3 | O4 | O7 | O7b | T5 |
|---|---|---|---|---|---|---|---|
| R-CHAIN | 22/22→23/24, lower -14.1 | 10/10→6/9, lower -6.2 | 15/15→14/14, lower -24.2 | 18/23→17/20, lower -31.7 | 10/19→17/20, lower -57.5 | 7/24→0/21, lower +5.0 **VETO** | 1/21→0/19, lower -15.8 |
| R-GROUP | 22/22→23/23, lower -17.9 | 10/10→5/5, lower -32.4 | 15/15→12/13, lower -17.4 | 18/23→19/22, lower -32.7 | 10/19→8/19, lower -22.5 | 7/24→9/24, lower -35.1 | 1/21→0/20, lower -15.0 |
| R-BOTH | 22/22→22/23, lower -13.9 | 10/10→2/4, lower +0.9 ⚑ (never a veto) | 15/15→12/12, lower -24.2 | 18/23→15/21, lower -20.9 | 10/19→9/16, lower -35.7 | 7/24→11/23, lower -44.8 | 1/21→0/21, lower -14.3 |

G4 per (floor, objective), right/readable R-WO → row (a fall ≥ 2 is a flag, never a veto):

| row | floor | O1 | O2 | O3 | O4 | O7 | O7b | T5 |
|---|---|---|---|---|---|---|---|---|
| R-CHAIN | deepseek-flash | 12/12→11/12 | 10/10→6/8 ⚑ | 10/10→10/10 | 9/11→8/10 | 5/12→8/10 | 4/12→0/11 ⚑ | 0/12→0/11 |
| R-CHAIN | glm-5.3-flash | 10/10→12/12 | 0/0→0/1 | 5/5→4/4 | 9/12→9/10 | 5/7→9/10 | 3/12→0/10 ⚑ | 1/9→0/8 |
| R-GROUP | deepseek-flash | 12/12→12/12 | 10/10→5/5 ⚑ | 10/10→10/10 | 9/11→12/12 | 5/12→3/10 ⚑ | 4/12→3/12 | 0/12→0/12 |
| R-GROUP | glm-5.3-flash | 10/10→11/11 | 0/0→0/0 | 5/5→2/3 ⚑ | 9/12→7/10 ⚑ | 5/7→5/9 | 3/12→6/12 | 1/9→0/8 |
| R-BOTH | deepseek-flash | 12/12→11/12 | 10/10→2/3 ⚑ | 10/10→9/9 | 9/11→11/11 | 5/12→6/12 | 4/12→4/12 | 0/12→0/12 |
| R-BOTH | glm-5.3-flash | 10/10→11/11 | 0/0→0/1 | 5/5→3/3 ⚑ | 9/12→4/10 ⚑ | 5/7→3/4 ⚑ | 3/12→7/11 | 1/9→0/9 |

Flags: R-CHAIN deepseek-flash O2 10/10→6/8; R-CHAIN deepseek-flash O7b 4/12→0/11; R-CHAIN glm-5.3-flash O7b 3/12→0/10; R-GROUP deepseek-flash O2 10/10→5/5; R-GROUP deepseek-flash O7 5/12→3/10; R-GROUP glm-5.3-flash O3 5/5→2/3; R-GROUP glm-5.3-flash O4 9/12→7/10; R-BOTH deepseek-flash O2 10/10→2/3; R-BOTH glm-5.3-flash O3 5/5→3/3; R-BOTH glm-5.3-flash O4 9/12→4/10; R-BOTH glm-5.3-flash O7 5/7→3/4.

## The landing (resolution 5)

**E1 fails**: E1: R-BOTH − R-WO -2.4 pts, lower -6.1; E1 fails; the point is under +2.0: no batch 2, the ledger row stays with the numbers.
Batch 2: none.

## Beside, never deciding (resolution 7)

The `until` misuse read: floor first scripts that built placing an `until` race, per objective:

- R-WO: O1 0/22 (0.0 %), O4 0/23 (0.0 %), T5 0/21 (0.0 %)
- R-CHAIN: O1 0/24 (0.0 %), O4 0/22 (0.0 %), T5 0/22 (0.0 %)
- R-GROUP: O1 0/23 (0.0 %), O4 0/24 (0.0 %), T5 0/21 (0.0 %)
- R-BOTH: O1 0/23 (0.0 %), O4 0/22 (0.0 %), T5 0/23 (0.0 %)

The other endpoints, over non-control first scripts that built (re-read):

| row | wrapped_or_overfed | ungrouped_loop | closing_gather | success_filter |
|---|---|---|---|---|
| R-WO | 48/180 (26.7 %) | 0/180 (0.0 %) | 141/180 (78.3 %) | 6/180 (3.3 %) |
| R-CHAIN | 48/183 (26.2 %) | 2/183 (1.1 %) | 133/183 (72.7 %) | 7/183 (3.8 %) |
| R-GROUP | 51/182 (28.0 %) | 5/182 (2.7 %) | 134/182 (73.6 %) | 7/182 (3.8 %) |
| R-BOTH | 50/180 (27.8 %) | 3/180 (1.7 %) | 131/180 (72.8 %) | 10/180 (5.6 %) |

The O3 winner kind, first scripts that built, per tier:

- R-WO: floors model-step winner 15, value stage naming the race 7, no winner step 0 of 22; strong model-step winner 19, value stage naming the race 2, no winner step 1 of 22
- R-CHAIN: floors model-step winner 14, value stage naming the race 9, no winner step 0 of 23; strong model-step winner 15, value stage naming the race 5, no winner step 3 of 23
- R-GROUP: floors model-step winner 13, value stage naming the race 8, no winner step 1 of 22; strong model-step winner 15, value stage naming the race 8, no winner step 0 of 23
- R-BOTH: floors model-step winner 12, value stage naming the race 8, no winner step 0 of 20; strong model-step winner 15, value stage naming the race 9, no winner step 0 of 24

First-call and repair refusals by bucket per (row, model), the seven objectives (flags against R-WO, per objective: ≥ 2 of 12 on a (model, objective), ≥ 4 pooled over the models that ran it):

- R-WO deepseek-flash: first after_in_input 1, syntax 1; repair none
- R-WO glm-5.3-flash: first group_reference 3, syntax 1; repair group_reference 1
- R-WO glm-5.3: first none; repair none
- R-WO kimi-k3: first member_not_a_step 1; repair none
- R-CHAIN deepseek-flash: first member_not_a_step 2, group_reference 1, tool_name 1; repair member_not_a_step 1, reference_value 1
- R-CHAIN glm-5.3-flash: first syntax 1; repair none
- R-CHAIN glm-5.3: first none; repair none
- R-CHAIN kimi-k3: first not_a_verb 1; repair none
- R-GROUP deepseek-flash: first none; repair none
- R-GROUP glm-5.3-flash: first after_in_input 1, member_not_a_step 1, syntax 1; repair none
- R-GROUP glm-5.3: first none; repair none
- R-GROUP kimi-k3: first member_not_a_step 1; repair reference_value 1
- R-BOTH deepseek-flash: first member_not_a_step 2; repair none
- R-BOTH glm-5.3-flash: first member_not_a_step 3, deleted_word 1, syntax 1; repair none
- R-BOTH glm-5.3: first none; repair none
- R-BOTH kimi-k3: first none; repair none
- differential flags (R-WO→row): R-BOTH first member_not_a_step glm-5.3-flash O3 0→2
- `other` first calls per row: R-WO 0, R-CHAIN 0, R-GROUP 0, R-BOTH 0

Finishes, tokens, cost (the seven objectives per model; O5 on its own line, operational reading f):

- R-WO deepseek-flash: first completed 84; repairs 2 (completed 2); tokens in 392686, out 208179
- R-WO glm-5.3-flash: first tool_calls 80, error (client) 4; repairs 4 (tool_calls 4); tokens in 348510, out 825769, cost $0.44
- R-WO glm-5.3: first tool_calls 11, error (client) 1; repairs 0 (none); tokens in 45128, out 76109, cost $0.32
- R-WO kimi-k3: first tool_calls 12; repairs 1 (tool_calls 1); tokens in 52958, out 36467, cost $0.59
- R-WO control O5: compose called on 0/24 (compose 0 on 24); first completed 12, tool_calls 12; repairs 0 (none); tokens in 100296, out 2316, cost $0.0
- R-CHAIN deepseek-flash: first completed 84; repairs 4 (completed 4); tokens in 406324, out 212223
- R-CHAIN glm-5.3-flash: first tool_calls 81, error (client) 2, error 1; repairs 1 (tool_calls 1); tokens in 348041, out 894906, cost $0.47
- R-CHAIN glm-5.3: first tool_calls 12; repairs 0 (none); tokens in 49976, out 138015, cost $0.56
- R-CHAIN kimi-k3: first tool_calls 12; repairs 1 (tool_calls 1); tokens in 53067, out 19379, cost $0.34
- R-CHAIN control O5: compose called on 0/24 (compose 0 on 24); first completed 12, tool_calls 12; repairs 0 (none); tokens in 101784, out 2224, cost $0.0
- R-GROUP deepseek-flash: first completed 84; repairs 0 (none); tokens in 371772, out 242821
- R-GROUP glm-5.3-flash: first tool_calls 78, error (client) 5, length 1; repairs 3 (tool_calls 3); tokens in 344551, out 953125, cost $0.5
- R-GROUP glm-5.3: first tool_calls 12; repairs 0 (none); tokens in 49824, out 172924, cost $0.69
- R-GROUP kimi-k3: first tool_calls 12; repairs 1 (tool_calls 1); tokens in 53005, out 22447, cost $0.37
- R-GROUP control O5: compose called on 0/24 (compose 0 on 24); first completed 12, tool_calls 12; repairs 0 (none); tokens in 101460, out 2277, cost $0.0
- R-BOTH deepseek-flash: first completed 84; repairs 2 (completed 2); tokens in 398073, out 292336
- R-BOTH glm-5.3-flash: first tool_calls 79, error (client) 4, length 1; repairs 5 (tool_calls 5); tokens in 362856, out 1009437, cost $0.53
- R-BOTH glm-5.3: first tool_calls 12; repairs 0 (none); tokens in 50552, out 156652, cost $0.64
- R-BOTH kimi-k3: first tool_calls 12; repairs 0 (none); tokens in 49296, out 21325, cost $0.35
- R-BOTH control O5: compose called on 0/24 (compose 0 on 24); first completed 12, tool_calls 12; repairs 0 (none); tokens in 102948, out 2457, cost $0.0

## Record vs re-read (the bench branch's builder; resolution 2)

- R-WO: 0 draw(s) differ
- R-CHAIN: 0 draw(s) differ
- R-GROUP: 0 draw(s) differ
- R-BOTH: 1 draw(s) differ
  - glm-5.3-flash O3 #3: repair valid true→false, the record says the repaired script built; the re-read refused it (script_error: TypeError: Cannot read properties of undefined (reading 'map')) — counted by the record
- NULL: 1 draw(s) differ
  - glm-5.3-flash O7 #6: repair valid true→false, the record says the repaired script built; the re-read refused it (script_error: TypeError: Cannot read properties of undefined (reading 'map')) — counted by the record

## Resolutions (this script's header, fixed before the data)

```text
The race-text A/B of 2026-09-26 (the floors' first call), read by the resolutions below.

The batch: four rows on the bench branch bench/racetext, each cut at run time from the compose bytes
the registry ships on that branch's base — R-WO (the shipped text, 7,994 B: the same-day baseline),
R-CHAIN (the chain sentence says what a helper function that builds a member's chain returns, the
whole chain, and how a later step reads a chain, by its last step: 8,246 B), R-GROUP (the reference
sentence says what an "all" group is — a g.parallel with no `until` or `until: "all"` — that the
step after it already waits for all of it, and that a reader lists the steps it reads: 8,144 B) and
R-BOTH (both edits, 8,396 B) — style nexus, the 65,536 cap, n = 12 per (row, model, objective): the
floors deepseek/deepseek-flash and openrouter/z-ai/glm-5.3-flash on every objective (O1 O2 O3 O4 O5
O7 O7b T5), the strong tier openrouter/z-ai/glm-5.3 and openrouter/moonshotai/kimi-k3 on O3 alone;
864 draws in 24 processes launched together by launch.sh — one per (row, floor, part), part A =
O2,T5 and part B = O1,O3,O4,O5,O7,O7b (about half of a floor's output tokens each), and one per
(row, strong model) on O3.

Resolutions fixed BEFORE the data (written 2026-09-25, before any sample file under
2026-09-26-racetext/ existed):

0. PROVENANCE. The bench branch's HEAD and the main commit it sits on are printed; every reading
   below is re-read under that tree (its builder for every row). launch.sh stamps logs/launch.txt
   (HEAD, its merge base with main, this file's sha256, the time); nothing is decided on a tree
   whose HEAD is not the stamp's or that holds uncommitted changes under nexus/ or e2e/, and this
   file's sha256 against the stamp's is printed — a mismatch disclosed, never refused. A later
   tree's re-read is a second column, never the verdict.
1. UNIT. One draw = (row, model, objective, index), tagged by batch. The JUDGED script is the first
   when it built (`valid_first`), else the repaired when `repaired == "valid"`, else none. An
   unreached draw (no compose call, a provider error, `length`, refused twice, `no_second_call`) is
   NOT usable and stays in every denominator that holds draws. O5 is out of everything but its own
   line (G5).
2. READER. Every first and repaired script is re-read at analysis time under the bench branch's
   builder (`reread`: `valid_first`/`loud`, `usable`, `endpoints`, `expanded`/`opaque`), and every
   O1, O3, O4 and T5 first script the record built is read for its races and the steps reading them,
   stage bodies included (`race_reading`). Validity and the loud bucket are the record's; `usable`,
   the endpoints, the expanded reading and the race reading are the re-read's. A script the record
   built and the re-read refuses counts by the record (usable) and is listed; every
   record-vs-re-read disagreement is listed.
3. E1, THE LANDING ENDPOINT. First-script usable = the record's `valid_first` AND the re-read's
   `usable == true`, pooled over the two floors and O1 O2 O3 O4 O7 O7b T5: 168 per row. E1 HOLDS
   when the rise R-BOTH − R-WO has a one-sided 90 % lower bound above 0. Zero-difference bound at
   the shipped text's 153/168: −4.0; the smallest landing rise from 153 is to 160/168 (+4.2, lower
   +0.6). The single rows' rises against R-WO print beside with their bounds and never decide E1.
   Printed: the zero-difference bound at R-WO's observed rate, and the procedure's false-landing
   rate — the stage-1 bound plus batch 2's pooled look after a near miss (rule 5) — 12.7 % at
   153/168 and recomputed at this batch's R-WO rate, beside the bound's own 10 %.
4. A1, A2, ATTRIBUTION BY THE NET REFUSAL COUNTS. Over every draw that ran on the seven objectives
   (the floors × O1 O2 O3 O4 O7 O7b T5 plus the strong tier × O3: 192 per row), the first-call
   refusals by the record's bucket. CHAIN NET = {member_not_a_step, reference_value, other}; GROUP
   NET = {group_reference, reference_value, other}. Each edit's read is its 2×2 main effect, the
   fall of its net rate from the two rows without the edit to the two rows with it, 384 per side —
   A1 {R-WO, R-GROUP} → {R-CHAIN, R-BOTH}, A2 {R-WO, R-CHAIN} → {R-GROUP, R-BOTH} — and HOLDS when
   the fall's one-sided 90 % lower bound is above 0. Under no effect both contrasts are null and the
   pool is the null test. Printed beside, never deciding: the single contrast R-WO → R-CHAIN
   (R-GROUP), 192 per side, and the joint contrast R-WO → R-BOTH; the exact holding thresholds at
   this n from the batch's own base counts, with the power at a full sweep of the targeted bucket,
   at half of it, and under no effect; the targeted bucket alone, `reference_value` and `other` per
   row; `member_not_a_step` split by the builder sentence that refused it (the regroup rule,
   `_claim`'s "Got …", `_elsewhere`); the strong tier's O3 `member_not_a_step` per row.
5. THE LANDING, in this order:
   (1) E1 fails → nothing lands. Batch 2 is pre-bought when R-BOTH's point estimate is ≥ +2.0
       points with the bound ≤ 0 (the same four rows, models, objectives, n = 12, on the batch-1
       tree); otherwise the ledger row stays with the numbers.
   (2) E1 holds → the text is chosen by attribution: A1 and A2 both hold → R-BOTH; exactly one holds
       → that single row, only if its own first-script usable point estimate against R-WO is ≥ 0,
       else R-BOTH — the other edit stays in the ledger with its counts, and batch 2 is pre-bought
       for it when its pooled net count fell by ≥ 3 draws of 384 with the bound ≤ 0; neither holds →
       R-BOTH whole.
   (3) The chosen text's guards (6) fail → R-BOTH if R-BOTH's guards hold, else nothing lands and
       the failing guard is the finding.
   Printed: the branch taken, the text named, the single row's own usable point where it decides,
   and the batch-2 condition with its tree. Nothing else lands or unlands on this batch.
6. GUARDS, vetoes on the landing text, each printed for every row against R-WO with its bound and
   verdict:
   G1 the judged-usable floor gate: usable on the judged script, the floors × the seven objectives,
      R-row − R-WO; FAILS when the lower bound is under −5.0 points.
   G2 the race read: over O3, pooled over the four models and printed per tier, the share of first
      scripts whose plan has a step reading a race that names the race, over the first scripts that
      built PLUS the first calls refused `race_member` (a member-naming reader the builder refuses,
      counted as not naming the race); FAILS when the fall R-WO − R-row has a lower bound above 0.
      Said in advance: on the strong tier R-CHAIN's rescued helper chains sit inside a race whose
      reader names it, so a RISE there is a rescue, not a change in how models read the race.
   G3 T1's labels: O3 `authored_labels` over the JUDGED script — a draw with no judged script, or
      one whose judged script the re-read cannot read, leaves the denominator on both arms — pooled
      over the four models and printed per tier; FAILS when the rise R-row − R-WO has a lower bound
      above 0; per-model flags at a rise ≥ 2 of 12, never a veto. The built-first-script form and
      both forms at z = 2.1893 print beside, not the rule.
   G4 the shape guard: expanded `first_time_right` per objective (O1 O2 O3 O4 O7 O7b T5), pooled over
      the two floors, over readable draws (each arm's readable n printed); FAILS when on any
      objective but O2 the fall R-WO − R-row has a lower bound above 0 at z = 2.1893. Per-(floor,
      objective) cells print with a flag on a fall ≥ 2. O2 is in for form: its fall and bound
      print and never veto. The expanded reading counts a stage-decided edit out as opaque, so O2
      is readable on few draws, and on those few the bound can still clear 0 (2/2 → 0/2 reads a
      lower bound of +0.2): O2's exclusion is this rule, not a property of the arithmetic.
   G5 the control: the floors' O5 draws whose first call called compose, 24 per row; FAILS at ≥ 2;
      1 is a flag.
   Each guard's no-effect veto rate, computed from the T1 batch's R-L3 cells (the shipped text,
   re-read under this tree) at this batch's n with both arms drawn from them — G1 from its
   judged-usable floor rate, G2 from its race share, G3 from its judged-label share, G4 from its
   per-(floor, objective) readable cells, family-wise over the objectives that veto, G5 from its
   floor O5 compose rate and at a 1 % rate — and the landing power at the full effect net of the
   five vetoes (E1's power times the chance that no guard vetoes a harmless text).
7. BESIDE, never deciding: the `until` misuse read (floor O1, O4 and T5 first scripts placing an
   `until` race, per objective); the other four endpoints per row; the O3 winner kind per row and
   tier; first-call AND repair refusals by bucket per (row, model), flagged per objective at a
   differential ≥ 2 of 12 on a (model, objective) cell or ≥ 4 pooled over the models that ran the
   objective (48 draws on O3, 24 elsewhere) — the repair buckets because the builder throws on the
   first refusal, so a `member_not_a_step` at a g.parallel masks a later `group_reference` that
   R-CHAIN can unmask; `other` per row, flagged alike; `valid_after_repair`; E1 and G1 with provider
   `error` finishes and client exceptions dropped from both denominators; per-(floor, objective)
   first-script usable R-WO → R-row, flagged at a loss ≥ 2 of 12; finishes, tokens and cost per
   (row, model); the record-vs-re-read listing; the compose text's byte size per row.
8. BATCH 2. When batch 2 was bought (rule 5), it runs on the batch-1 tree — the HEAD batch 1's
   stamp names, its worktree kept — with the same launch.sh into batch2/<row>/<slug>/<part>/; its
   draws are tagged by batch, and every read above is re-read on the pooled n = 24 per cell, the
   pooled reading final — no third batch. After an E1 near miss, the landing rule reads the pooled
   draws as it read batch 1's. After a single-row landing, the other edit lands iff its pooled A
   holds (768 per side) AND R-BOTH's E1 and guards hold at the pooled n; else it stays in the
   ledger with the pooled counts. A batch 2 that no branch of batch 1 bought decides nothing.

Arithmetic: analyze_t1.rb's `wilson`/`difference` verbatim (Wilson per arm, Newcombe's hybrid), z =
1.2815515655446004 (one-sided 90 %) for E1, the count reads, the floor gate and the O3 guards,
2.1893 for the shape guard (one-sided 90 % family-wise over seven objectives). A bound is compared
as printed, rounded to 0.1 point: "above 0" means a printed bound of +0.1 or more. A count read is
a rate over the same draws on both sides. The no-effect and power figures are exact sums over two
binomials (both arms random), the shape guard's over the pooled cells (T1's guard_null method).

OPERATIONAL READINGS (fixed with this file, before the data):
a. A FIRST-CALL REFUSAL is a draw whose first call composed (`reached`) and whose first script the
   record did not build; its bucket is the record's `loud`. A repair refusal is `repaired ==
   "refused"`, its bucket the record's `repaired_loud` (else the re-read's), and `no_second_call`
   is a bucket of its own there.
b. G2's reading of a built first script is `race_reading` under the bench branch's builder: it NAMES
   THE RACE when any step reading any race of its plan (stage bodies included) lists the race's
   key. A first script with no race names none. A first script the record built and the race
   reading cannot build names none and is listed. G2's denominator admits a first call refused
   `race_member` by the record's bucket.
c. G5 counts an O5 draw whose first call called compose (`called["compose"] > 0`), reached or not.
d. The no-effect inputs are the T1 batch's R-L3 draws (`NULL=`), read exactly as a row's are,
   at the cells this batch registers (the floors' eight objectives, the strong tier's O3). Each
   guard's arms are drawn at this batch's R-WO denominator: G1 its floor-seven draws, G2 and G3 its
   O3 draws, G5 its floor O5 draws, G4 each (floor, objective) cell's readable count scaled from the
   R-L3 cell's draws to this batch's per-cell draws.
e. E1's full effect is R-WO's first-script usable count plus R-WO's floor-seven first-call refusals
   in both targeted buckets (a text that removes them all and costs nothing else); R-CHAIN's plus its
   `member_not_a_step`, R-GROUP's plus its `group_reference`. A read's full sweep removes its
   targeted bucket from the base side's net count, its half effect half of it — half the
   targeted bucket on both reads, never half the net: at the shipped text's rates A1's half is
   10 → 6 of 384 and A2's 16 → 9 (half A2's net would be 16 → 8).
f. The finishes, repairs, tokens and cost per (row, model) cover the seven objectives; each row's
   control line carries O5's compose calls and O5's own spend.
g. The record-vs-re-read listing compares, where both built the first script, `usable`, the shared
   scorer's `first_time_right`, `opaque`, the expanded `first_time_right` and every endpoint; where
   neither built, the loud bucket; and the repair's validity. A reading the record does not carry
   is tallied apart, never listed as a disagreement.

Usage (cwd = the bench branch's e2e, /Users/jasl/Workspaces/cybros-ai.alt2-racetext/e2e):
  bundle exec ruby /Users/jasl/Workspaces/cybros-ai.alt2/e2e/artifacts/bench/2026-09-26-racetext/analyze_racetext.rb [[batch2/]ROW/<slug>/<part>=DIR …]
    → analysis.md beside this file. Each (row, model, part) is read from its launch directory,
      <this dir>/<row>/<slug>/<part>/compose_matrix.json (batch 2's under batch2/), unless
      ROW/<slug>/<part>=DIR names a harness-fault rerun, which reruns the (model, part) for all
      four rows together, so an override names all four rows of its (slug, part) or nothing is
      read. Parts: a floor's A (O2 T5) and B (O1 O3 O4 O5 O7 O7b), a strong model's O3. Batch 2 is
      read when batch2/logs/launch.txt exists. REFUSED, as a harness fault to rerun: a missing
      compose_matrix.json, a launch log (logs/<row>.<slug>.<part>.log three levels above the
      directory) recording a non-zero exit or none (no log, or no `exit=` line: the process is
      still running or was killed), a sample whose `error` or `repaired_error` is one the matrix
      test's own gate calls the harness's (NoMethodError, ArgumentError, TypeError). REFUSED, as
      not this batch: a sample of another row, model, part, style (not nexus) or candidate cell, a
      duplicate (row, batch, model, objective, sample), a batch whose samples are not exactly the
      registered set (the floors × the eight objectives, the strong tier × O3, samples 1–12).
      REFUSED, as a moved tree: a HEAD that is not the one launch.sh stamped, or uncommitted
      changes under nexus/ or e2e/.
  A dry run names its stand-ins by role and writes dryrun-<name>.md, never analysis.md:
    bundle exec ruby <this file> --dry <name> R-WO=<dir>[,<dir>] ROLE=<dir>[,…] … [NULL=<dir>]
  R-WO and one to three of R-CHAIN, R-GROUP, R-BOTH, each a directory holding
  <model slug>/compose_matrix.json, several pooled by their index as batches; a read whose role is
  not named prints "not named". Only the registered cells are read (a stand-in's strong-tier
  objectives other than O3 are set aside and counted); neither the samples' own row nor the size is
  checked. NULL (the no-effect input) defaults to the T1 batch's R-L3. RACETEXT_ROOT overrides the
  tree the readings load (default: the bench branch's worktree).
```
