# Compose text-bench A/B — 2026-09-23 (analysis)

Samples: R-WO 192, R-L1L2 192, R-L4 192, R-L9 192; pre-S6 96.

## Endpoints (pooled over the four models, non-control objectives, first scripts that built)

| arm | wrapped_or_overfed | ungrouped_loop | closing_gather | targeted Δ vs R-WO (90 % one-sided upper) | meets |
|---|---|---|---|---|---|
| R-WO | 57/159 (35.8 %) | 5/159 (3.1 %) | 118/159 (74.2 %) | — | — |
| R-L1L2 | 37/153 (24.2 %) | 5/153 (3.3 %) | 117/153 (76.5 %) | wrapped_or_overfed -11.7 pts (upper -5.0) | yes |
| R-L4 | 49/159 (30.8 %) | 2/159 (1.3 %) | 124/159 (78.0 %) | ungrouped_loop -1.9 pts (upper 0.3) | no |
| R-L9 | 50/159 (31.4 %) | 4/159 (2.5 %) | 122/159 (76.7 %) | closing_gather 2.5 pts (upper 8.7) | no |

## Floor gate (pooled usable on the two floors, non-control objectives)

| arm | usable | Δ vs R-WO (90 % one-sided lower) | gate | per-objective flags (loss ≥ 2/6) |
|---|---|---|---|---|
| R-WO | 79/84 (94.0 %) | — | — | — |
| R-L1L2 | 76/84 (90.5 %) | -3.6 pts (lower -9.1) | REJECTED | deepseek-flash O3 6→4 |
| R-L4 | 78/84 (92.9 %) | -1.2 pts (lower -6.3) | REJECTED | none |
| R-L9 | 78/84 (92.9 %) | -1.2 pts (lower -6.3) | REJECTED | none |

## Strong rule (EXPANDED first_time_right, opaque counted out)

- **R-L1L2**: no — rises ≥ 2: glm-5.3 O7, kimi-k3 O7b; falls ≥ 2: kimi-k3 O4; not-reproduced falls: none
  - glm-5.3 O1 6/6→6/6 · glm-5.3 O2 1/2→2/2 · glm-5.3 O3 0/0→0/1 · glm-5.3 O4* 0/6→0/4 · glm-5.3 O7* 1/2→5/5 · glm-5.3 O7b* 4/5→3/6 · glm-5.3 T5 0/5→0/3 · kimi-k3 O1 6/6→6/6 · kimi-k3 O2 0/0→0/0 · kimi-k3 O3 2/5→2/2 · kimi-k3 O4* 2/4→0/6 · kimi-k3 O7* 1/3→2/2 · kimi-k3 O7b* 0/6→3/6 · kimi-k3 T5 0/4→0/3
- **R-L4**: no — rises ≥ 2: none; falls ≥ 2: none; not-reproduced falls: none
  - glm-5.3 O1 6/6→6/6 · glm-5.3 O2 1/2→0/0 · glm-5.3 O3 0/0→0/0 · glm-5.3 O4* 0/6→0/5 · glm-5.3 O7* 1/2→1/1 · glm-5.3 O7b* 4/5→3/6 · glm-5.3 T5 0/5→0/5 · kimi-k3 O1 6/6→6/6 · kimi-k3 O2 0/0→1/1 · kimi-k3 O3 2/5→3/4 · kimi-k3 O4* 2/4→3/6 · kimi-k3 O7* 1/3→0/4 · kimi-k3 O7b* 0/6→1/6 · kimi-k3 T5 0/4→0/3
- **R-L9**: no — rises ≥ 2: none; falls ≥ 2: glm-5.3 O7b; not-reproduced falls: none
  - glm-5.3 O1 6/6→6/6 · glm-5.3 O2 1/2→0/1 · glm-5.3 O3 0/0→1/1 · glm-5.3 O4* 0/6→0/5 · glm-5.3 O7* 1/2→2/2 · glm-5.3 O7b* 4/5→2/6 · glm-5.3 T5 0/5→2/6 · kimi-k3 O1 6/6→6/6 · kimi-k3 O2 0/0→1/1 · kimi-k3 O3 2/5→2/3 · kimi-k3 O4* 2/4→3/6 · kimi-k3 O7* 1/3→0/3 · kimi-k3 O7b* 0/6→0/6 · kimi-k3 T5 0/4→0/5

(* = a rule cell)

## Refusal text (pre-S6 vs post-S6, R-WO on the floors, every script re-read by main's kernel)

- post-S6: first-call refusals 3/84 reached (is_not_defined 1, other 1, member_not_a_step 1); valid after repair 3/3 (100.0 %); usable (main's reading) 79/84 (94.0 %)
- pre-S6: first-call refusals 7/84 reached (other 2, syntax 1, member_not_a_step 3, is_not_defined 1); valid after repair 7/7 (100.0 %); usable (main's reading) 77/84 (91.7 %)

## First-call finishes (every sample)

- R-WO: completed 48, length 1, tool_calls 143
- R-L1L2: completed 48, error 1, tool_calls 143
- R-L4: completed 48, length 1, tool_calls 143
- R-L9: completed 48, error 1, length 1, tool_calls 142
- pre-S6: completed 48, tool_calls 48
