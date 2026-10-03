# Explicit reads A/B — 2026-09-27: the free re-read

## Provenance

- main tree `/Users/jasl/Workspaces/cybros-ai.alt2` at 757a89f801b2; uncommitted under nexus/ e2e/: none
- reads tree `/Users/jasl/Workspaces/cybros-ai.alt2-reads` at 7fdaf8a05f9c; uncommitted under nexus/ e2e/: none
- the voided stamp `/Users/jasl/Workspaces/cybros-ai.alt2-reads/e2e/artifacts/bench/2026-09-27-explicit-reads/logs/launch.txt` sha256 3874473cb90a23fcb33ba4d190cb785cedab6fdab77cabb23faf4db55af96993; head_with 283e372a8d95254b6a4afeee5f0fd924d569c942, head_without 8357955698793f057ffea518f9fd36d74fbedab5; c_verdict HOLDS
- R-WO's bytes under the main tree: sha256 1e69b087f7b773c5a7f1385970a164f65585216ed22b6a9388e136a986499ad6 (7994 bytes); the stamp's 1e69b087f7b773c5a7f1385970a164f65585216ed22b6a9388e136a986499ad6
- R-EX's bytes under the reads tree: sha256 e6bbb0a6542ea3a7eee4e959153e5b066afbb9675b574832b0e274c932fcc8d8 (8470 bytes); the stamp's e6bbb0a6542ea3a7eee4e959153e5b066afbb9675b574832b0e274c932fcc8d8
- R-MIN's bytes under the reads tree: sha256 bed2c651b28ec1cd1775e07ad67b5a22624db650e58bc4e17ad64ca8e35149db (8206 bytes); the stamp's bed2c651b28ec1cd1775e07ad67b5a22624db650e58bc4e17ad64ca8e35149db
- bench digest (deviation 1: it differs, the trees are the fix commits): stamp with 24baa74deaf49804, without 772186a893d5b304; now main 7ec4531d884f921f, reads c12f9aa01b49a95f
- the frozen dimensions: no_match, matched_path, runner_detail, record_format, compound_command, model_effect; each tree's rehearsal: main the same, reads the same
- worlds sha256 (worlds.rb + world_calls.rb + rehearsal.rb + drawing.rb + inline.rb): main b2e248b61dfc62ba, reads b2e248b61dfc62ba
- this analyzer's sha256 (analyze_reads_posthoc.rb + posthoc.rb + reread_tree.rb): eafc14a123d9e1661c0a75e4867594655d42ad3fb12d865e22ed0b4111361dbc
- the arithmetic: the voided analyzer's (Wilson score bounds, Newcombe's hybrid difference, one-sided 90 % at z 1.2816; the guard at z 2.1893)

## Deviations from the registered read (fixed before any clause was computed)

  1. the trees are the fix commits named on the command line, not the stamp's; both must rehearse alike
     (the worlds, the rehearsal, the drawing and the inliner hash the same), else a HARNESS FINDING;
  2. the deciding value is the RE-READ under each row's own tree (R-WO under main, R-EX and R-MIN under
     the reads tree; R-WO also under the reads tree, B′). The record must agree with its re-read on
     `valid_first`, `first_time_right`, `usable`, `opaque` and `expanded.first_time_right`; a difference
     stands only where the kernel explains it — `valid_first` moved and the kernel's replay of that
     draw gives the re-read's validity and refusal: the kernel is the authority, the draw takes its
     verdict and is listed. The kernel has no verdict on the other keys, so any other difference is a
     HARNESS FINDING that stops the read;
  3. right″ = the re-read's `rehearsed.first_time_right` on every valid draw (one reader, uncredited,
     right in every world; a closing value on a race member counts not right), the registered
     `ftr && !opaque` and the static `first_time_right` beside every clause; the guard reads right″; G
     is untouched (usable only under today's rule);
  4. the replay in both trees at the fix commits (the reads tree's `Replay` against each tree's Nexus): a
     mismatch whose kernel code is `invalid_script`/`invalid_script_params` is classified by that code
     and the draw takes the kernel's verdict — refused, not usable, not right — in every column; any
     other mismatch, or `over_read_positional` on an E3 cell, is a KERNEL FINDING that stops the read.
     The positional clause cannot fire on a rehearsed reads-tree plan, whose drawing names every read;
  5. the landing is R-MIN against R-WO; R-EX is read beside and can only change which row ships; §8.3's
     registered landing ("at least one with row") is printed beside;
  6. the stage-fed credit: uncredited deciding, credited beside, a clause the credit flips NOT DECIDED;
  7. the worlds: a world-dependent draw is not right in every row; the liberal count prints beside.

## What stops the read

- harness findings (the record and its re-read differ where the kernel explains nothing — any move but a `valid_first` the replay confirms): 0
- tree facts: none
- kernel findings (a replay mismatch the kernel's code does not classify): 0
- `over_read_positional` on the with rows' E3 cells: R-EX 0, R-MIN 0 — none can fire: a rehearsed reads-tree plan names every read
- differences the replay settles (`valid_first` moved and the kernel gives the re-read's validity; the draw takes its verdict): 3
  - R-EX gpt-6-sol O2 #16: valid_first true→false, opaque false→nil, expanded.first_time_right false→nil (the kernel's replay gives the re-read's validity)
  - R-MIN gpt-6-sol O2 #23: valid_first true→false, opaque false→nil, expanded.first_time_right false→nil (the kernel's replay gives the re-read's validity)
  - R-MIN glm-5.3 O3 #16: valid_first true→false, opaque false→nil, expanded.first_time_right false→nil (the kernel's replay gives the re-read's validity)
- draws the kernel refused (deviation 4: refused, not usable, not right): none

## The pre-registered figures at the registered layout, each cell at R-WO's rate under this reading

- E1 (lower ≥ −7.5), at −7.5: n 480, base 81.3 %: zero-effect passes 98.1 %, at the margin 6.4 % (one pooled p: 95.5 % / 10.1 %)
- E2 (lower > 0), at +20: n 192, base 9.9 %: zero-effect passes 6.2 %, at the margin 100.0 % (one pooled p: 9.9 % / 100.0 %)
- E4 (lower > 0; opus), at +20: n 48, base 0.0 %: zero-effect passes 0.0 %, at the margin 100.0 % (one pooled p: 0.0 % / 100.0 %)
- G (lower ≥ −5), at −5: n 336, base 93.5 %: zero-effect passes 91.8 %, at the margin 9.2 % (one pooled p: 90.5 % / 10.1 %)
- the guard's no-effect veto rate: O1 0.0 %, O2 0.94 %, O3 0.01 %, O4 1.03 %, O7 0.43 %, O7b 0.45 %, T5 0.39 %; family-wise 3.2 %

## Lost draws and the storm per (row, model)

| row | model | draws | lost | > 5 % lost | storm |
|---|---|---|---|---|---|
| R-WO | claude-opus-5-5 | 192 | 0 | — | — |
| R-WO | deepseek-flash | 192 | 0 | — | — |
| R-WO | gpt-6-luna | 96 | 0 | — | — |
| R-WO | gpt-6-sol | 192 | 0 | — | — |
| R-WO | kimi-k3 | 192 | 0 | — | — |
| R-WO | glm-5.3-flash | 192 | 0 | — | — |
| R-WO | glm-5.3 | 192 | 0 | — | — |
| R-WO(B′) | claude-opus-5-5 | 192 | 0 | — | — |
| R-WO(B′) | deepseek-flash | 192 | 0 | — | — |
| R-WO(B′) | gpt-6-luna | 96 | 0 | — | — |
| R-WO(B′) | gpt-6-sol | 192 | 0 | — | — |
| R-WO(B′) | kimi-k3 | 192 | 0 | — | — |
| R-WO(B′) | glm-5.3-flash | 192 | 0 | — | — |
| R-WO(B′) | glm-5.3 | 192 | 0 | — | — |
| R-EX | claude-opus-5-5 | 192 | 0 | — | — |
| R-EX | deepseek-flash | 192 | 0 | — | — |
| R-EX | gpt-6-luna | 96 | 0 | — | — |
| R-EX | gpt-6-sol | 192 | 0 | — | — |
| R-EX | kimi-k3 | 192 | 0 | — | — |
| R-EX | glm-5.3-flash | 192 | 0 | — | — |
| R-EX | glm-5.3 | 192 | 0 | — | — |
| R-MIN | claude-opus-5-5 | 192 | 0 | — | — |
| R-MIN | deepseek-flash | 192 | 0 | — | — |
| R-MIN | gpt-6-luna | 96 | 0 | — | — |
| R-MIN | gpt-6-sol | 192 | 0 | — | — |
| R-MIN | kimi-k3 | 192 | 0 | — | — |
| R-MIN | glm-5.3-flash | 192 | 0 | — | — |
| R-MIN | glm-5.3 | 192 | 0 | — | — |

## R-EX against R-WO — §8.3's clauses on right″

- E1: R-EX: 384/480 (80.0 %) against R-WO 390/480 (81.3 %); Δ -1.25 pts, lower -4.52, upper +2.02 (lower ≥ -7.5; credited: holds) → **HOLDS**
  - beside: registered 246/480 vs 280/480; static 343/480 vs 348/480; credited 388/480 vs 390/480; liberal 413/480 vs 410/480
  - per model: glm-5.3 83/120 vs 94/120; kimi-k3 89/120 vs 91/120; claude-opus-5-5 119/120 vs 119/120; gpt-6-sol 93/120 vs 86/120
- E2: R-EX: 186/192 (96.9 %) against R-WO 19/192 (9.9 %); Δ +86.98 pts, lower +83.25, upper +89.71 (lower > 0; credited: holds) → **HOLDS**
  - beside: registered 186/192 vs 16/192; static 186/192 vs 17/192; credited 186/192 vs 19/192; liberal 186/192 vs 19/192
  - per model: glm-5.3 48/48 vs 15/48; kimi-k3 46/48 vs 0/48; claude-opus-5-5 48/48 vs 0/48; gpt-6-sol 44/48 vs 4/48
- E4: R-EX: 48/48 (100.0 %) against R-WO 0/48 (0.0 %); Δ +100.00 pts, lower +95.32, upper +100.00 (lower > 0 and opus positional = 0; credited: holds) → **HOLDS**
  - beside: registered 48/48 vs 0/48; static 48/48 vs 0/48; credited 48/48 vs 0/48; liberal 48/48 vs 0/48
  - per model: claude-opus-5-5 48/48 vs 0/48
- E3: `over_read_named` R-EX: 1/192 (0.5 %) against R-WO(B′) 1/192 (0.5 %); Δ +0.00 pts, lower -1.26, upper +1.26 (upper ≤ +5.0; credited: holds) → **HOLDS**; positional 0
- G: R-EX: 322/336 (95.8 %) against R-WO 314/336 (93.5 %); Δ +2.38 pts, lower +0.14, upper +4.66 (lower ≥ -5.0; credited: holds) → **HOLDS**
- G after repair (beside): R-EX: 333/336 (99.1 %) against R-WO 331/336 (98.5 %); Δ +0.60 pts, lower -0.54, upper +1.80 (lower ≥ -5.0; credited: holds) → **HOLDS**
- misses on E1 and E2 cells: world-dependent 29, over_sync 15, refused group_reference 11, missing_steps 10, refused member_not_a_step 6, refused syntax 5, exact in W0, not in another world 4, extra_steps+over_read_named 3, over_read_named 3, stage_fed 3, suite_waited_on+over_sync 3, missing_steps+blind_model 2, no compose call 2, edit_as_stage 1, extra_steps 1, over_sync+under_sync+blind_model 1, refused invalid_script 1, suite_waited_on+extra_steps+over_read_named 1, suite_waited_on+over_sync+over_read_named+blind_model 1

| guard | R-WO right″ | R-EX right″ | fall | lower (z 2.1893) | verdict | registered (expanded) | static | credited | liberal |
|---|---|---|---|---|---|---|---|---|---|
| O1 | 96/96 | 85/96 | +11.46 | +4.30 | **VETO** | 96/96 · 83/96 | 96/96 · 85/96 | 96/96 · 85/96 | 96/96 · 85/96 |
| O2 | 73/96 | 63/96 | +10.42 | -3.93 | — | 29/96 · 6/96 | 30/96 · 7/96 | 73/96 · 65/96 | 73/96 · 71/96 |
| O3 | 95/96 | 90/96 | +5.21 | -1.40 | — | 46/96 · 27/96 | 87/96 · 84/96 | 95/96 · 90/96 | 95/96 · 90/96 |
| O4 | 73/96 | 81/96 | -8.33 | -20.77 | — | 71/96 · 77/96 | 69/96 · 81/96 | 73/96 · 83/96 | 73/96 · 81/96 |
| O7 | 53/96 | 65/96 | -12.50 | -27.03 | — | 42/96 · 53/96 | 66/96 · 86/96 | 53/96 · 65/96 | 73/96 · 86/96 |
| O7b | 16/96 | 95/96 | -82.29 | -89.04 | — | 15/96 · 95/96 | 14/96 · 95/96 | 16/96 · 95/96 | 16/96 · 95/96 |
| T5 | 3/96 | 91/96 | -91.67 | -95.50 | — | 2/96 · 91/96 | 3/96 · 91/96 | 3/96 · 91/96 | 3/96 · 91/96 |

**R-EX: FAIL** — decided failures none; vetoes guard O1; not decided none

## R-MIN against R-WO — §8.3's clauses on right″

- E1: R-MIN: 389/480 (81.0 %) against R-WO 390/480 (81.3 %); Δ -0.21 pts, lower -3.45, upper +3.03 (lower ≥ -7.5; credited: holds) → **HOLDS**
  - beside: registered 260/480 vs 280/480; static 374/480 vs 348/480; credited 390/480 vs 390/480; liberal 429/480 vs 410/480
  - per model: glm-5.3 93/120 vs 94/120; kimi-k3 80/120 vs 91/120; claude-opus-5-5 120/120 vs 119/120; gpt-6-sol 96/120 vs 86/120
- E2: R-MIN: 187/192 (97.4 %) against R-WO 19/192 (9.9 %); Δ +87.50 pts, lower +83.84, upper +90.18 (lower > 0; credited: holds) → **HOLDS**
  - beside: registered 186/192 vs 16/192; static 187/192 vs 17/192; credited 187/192 vs 19/192; liberal 187/192 vs 19/192
  - per model: glm-5.3 47/48 vs 15/48; kimi-k3 47/48 vs 0/48; claude-opus-5-5 48/48 vs 0/48; gpt-6-sol 45/48 vs 4/48
- E4: R-MIN: 48/48 (100.0 %) against R-WO 0/48 (0.0 %); Δ +100.00 pts, lower +95.32, upper +100.00 (lower > 0 and opus positional = 0; credited: holds) → **HOLDS**
  - beside: registered 48/48 vs 0/48; static 48/48 vs 0/48; credited 48/48 vs 0/48; liberal 48/48 vs 0/48
  - per model: claude-opus-5-5 48/48 vs 0/48
- E3: `over_read_named` R-MIN: 1/192 (0.5 %) against R-WO(B′) 1/192 (0.5 %); Δ +0.00 pts, lower -1.26, upper +1.26 (upper ≤ +5.0; credited: holds) → **HOLDS**; positional 0
- G: R-MIN: 321/336 (95.5 %) against R-WO 314/336 (93.5 %); Δ +2.08 pts, lower -0.19, upper +4.39 (lower ≥ -5.0; credited: holds) → **HOLDS**
- G after repair (beside): R-MIN: 332/336 (98.8 %) against R-WO 331/336 (98.5 %); Δ +0.30 pts, lower -0.92, upper +1.54 (lower ≥ -5.0; credited: holds) → **HOLDS**
- misses on E1 and E2 cells: world-dependent 40, over_sync 13, missing_steps 12, refused group_reference 4, extra_steps 3, extra_steps+over_read_named 3, no compose call 3, over_read_named 3, refused member_not_a_step 3, refused syntax 3, missing_steps+blind_model 2, suite_waited_on+extra_steps+over_read_named 2, edit_as_stage 1, exact in W0, not in another world 1, extra_steps+stage_fed 1, refused invalid_script 1, refused no_step 1

| guard | R-WO right″ | R-MIN right″ | fall | lower (z 2.1893) | verdict | registered (expanded) | static | credited | liberal |
|---|---|---|---|---|---|---|---|---|---|
| O1 | 96/96 | 93/96 | +3.12 | -2.10 | — | 96/96 · 88/96 | 96/96 · 93/96 | 96/96 · 93/96 | 96/96 · 93/96 |
| O2 | 73/96 | 65/96 | +8.33 | -5.85 | — | 29/96 · 22/96 | 30/96 · 25/96 | 73/96 · 66/96 | 73/96 · 74/96 |
| O3 | 95/96 | 87/96 | +8.33 | +1.06 | **VETO** | 46/96 · 24/96 | 87/96 · 79/96 | 95/96 · 87/96 | 95/96 · 87/96 |
| O4 | 73/96 | 86/96 | -13.54 | -25.30 | — | 71/96 · 81/96 | 69/96 · 86/96 | 73/96 · 86/96 | 73/96 · 86/96 |
| O7 | 53/96 | 58/96 | -5.21 | -20.27 | — | 42/96 · 45/96 | 66/96 · 91/96 | 53/96 · 58/96 | 73/96 · 89/96 |
| O7b | 16/96 | 92/96 | -79.17 | -86.38 | — | 15/96 · 91/96 | 14/96 · 92/96 | 16/96 · 92/96 | 16/96 · 92/96 |
| T5 | 3/96 | 95/96 | -95.83 | -98.18 | — | 2/96 · 95/96 | 3/96 · 95/96 | 3/96 · 95/96 | 3/96 · 95/96 |

**R-MIN: FAIL** — decided failures none; vetoes guard O3; not decided none

## The opaque flag (as registered; opaque is no longer a penalty — every opaque draw is rehearsed)

- R-EX: 263/1008 (26.1 %) against R-MIN 264/1008 (26.2 %); Δ -0.10 pts, lower -2.61, upper +2.41 (fires when the lower > 0; credited: does not hold) → **does not hold**

## The attribution column: R-WO(B′) − R-WO(A′), right″

- E1: B′ 321/480 (66.9 %), A′ 390/480 (81.3 %); -14.38 (lower -17.93, upper -10.78)
- E2: B′ 137/192 (71.4 %), A′ 19/192 (9.9 %); +61.46 (lower +56.11, upper +66.13)
- E4: B′ 42/48 (87.5 %), A′ 0/48 (0.0 %); +87.50 (lower +79.41, upper +92.40)
- G usable: B′ 314/336 (93.5 %), A′ 314/336 (93.5 %); +0.00 (lower -2.48, upper +2.48)
- guard O1: B′ 80/96 (83.3 %), A′ 96/96 (100.0 %); -16.67 (lower -22.09, upper -12.04)
- guard O2: B′ 57/96 (59.4 %), A′ 73/96 (76.0 %); -16.67 (lower -24.96, upper -8.04)
- guard O3: B′ 94/96 (97.9 %), A′ 95/96 (99.0 %); -1.04 (lower -3.96, upper +1.63)
- guard O4: B′ 48/96 (50.0 %), A′ 73/96 (76.0 %); -26.04 (lower -34.30, upper -17.21)
- guard O7: B′ 42/96 (43.8 %), A′ 53/96 (55.2 %); -11.46 (lower -20.43, upper -2.21)
- guard O7b: B′ 82/96 (85.4 %), A′ 16/96 (16.7 %); +68.75 (lower +61.23, upper +74.64)
- guard T5: B′ 55/96 (57.3 %), A′ 3/96 (3.1 %); +54.17 (lower +46.90, upper +60.66)

## Beside, never deciding: per objective per row (the tier models)

| row | objective | draws | right″ | credited | liberal | opaque | world-dependent | touched | stages | unknown-command draws | failed on model output | edited | closing value on a race member |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| R-WO | O1 | 144 | 137 | 137 | 137 | 0 | 0 | none | none | 0 | 0 | none | 0 |
| R-WO | O2 | 144 | 100 | 100 | 102 | 87 | 2 | matched_path 130, no_match 130, model_effect 59, runner_detail 56 | expanded 87, value 45, failed 14 | 15 | 0 | app/models/team.rb 56 | 0 |
| R-WO | O3 | 144 | 141 | 141 | 141 | 62 | 0 | none | value 77, expanded 18, canceled 8 | 0 | 0 | none | 0 |
| R-WO | O4 | 144 | 105 | 105 | 105 | 9 | 0 | model_effect 141, compound_command 4 | expanded 10, value 9, failed 2 | 14 | 0 | none | 0 |
| R-WO | O7 | 144 | 75 | 75 | 100 | 54 | 25 | record_format 139 | failed 35, value 31, expanded 16 | 0 | 27 | none | 0 |
| R-WO | O7b | 144 | 30 | 30 | 30 | 1 | 0 | runner_detail 140, compound_command 1 | expanded 7, value 1 | 1 | 0 | none | 0 |
| R-WO | T5 | 144 | 5 | 5 | 5 | 25 | 0 | compound_command 14 | expanded 55, failed 9, value 3 | 16 | 0 | none | 0 |
| R-WO(B′) | O1 | 144 | 105 | 105 | 105 | 0 | 0 | none | none | 0 | 0 | none | 0 |
| R-WO(B′) | O2 | 144 | 79 | 81 | 81 | 87 | 2 | matched_path 130, no_match 130, model_effect 59, runner_detail 56 | expanded 87, value 45, failed 14 | 15 | 0 | app/models/team.rb 56 | 0 |
| R-WO(B′) | O3 | 144 | 139 | 139 | 139 | 62 | 0 | none | value 77, expanded 18, canceled 8 | 0 | 0 | none | 0 |
| R-WO(B′) | O4 | 144 | 73 | 73 | 73 | 9 | 0 | model_effect 141, compound_command 4 | expanded 10, value 9, failed 2 | 14 | 0 | none | 0 |
| R-WO(B′) | O7 | 144 | 67 | 67 | 89 | 54 | 22 | record_format 139 | failed 35, value 31, expanded 16 | 0 | 27 | none | 0 |
| R-WO(B′) | O7b | 144 | 114 | 114 | 114 | 1 | 0 | runner_detail 140, compound_command 1 | expanded 7, value 1 | 1 | 0 | none | 0 |
| R-WO(B′) | T5 | 144 | 76 | 95 | 76 | 25 | 0 | compound_command 14 | expanded 55, failed 9, value 3 | 16 | 0 | none | 0 |
| R-EX | O1 | 144 | 126 | 126 | 126 | 2 | 0 | none | value 2 | 0 | 0 | none | 0 |
| R-EX | O2 | 144 | 91 | 93 | 102 | 124 | 11 | matched_path 137, no_match 137, runner_detail 87, model_effect 15 | expanded 119, value 77, failed 25 | 18 | 1 | app/models/team.rb 87 | 0 |
| R-EX | O3 | 144 | 136 | 136 | 136 | 74 | 0 | none | value 95, expanded 18, canceled 14 | 0 | 0 | none | 0 |
| R-EX | O4 | 144 | 117 | 119 | 117 | 14 | 0 | model_effect 142, compound_command 8 | expanded 13, value 7, failed 2 | 10 | 1 | none | 0 |
| R-EX | O7 | 144 | 100 | 100 | 126 | 49 | 26 | record_format 134 | failed 29, value 23 | 0 | 29 | none | 0 |
| R-EX | O7b | 144 | 140 | 140 | 140 | 0 | 0 | runner_detail 143 | none | 0 | 0 | none | 0 |
| R-EX | T5 | 144 | 136 | 136 | 136 | 0 | 0 | compound_command 14 | none | 14 | 0 | none | 0 |
| R-MIN | O1 | 144 | 130 | 130 | 130 | 8 | 0 | none | value 8 | 0 | 0 | none | 0 |
| R-MIN | O2 | 144 | 85 | 88 | 100 | 109 | 15 | matched_path 137, no_match 137, runner_detail 62, model_effect 42 | expanded 101, value 63, failed 24 | 26 | 0 | app/models/team.rb 62 | 0 |
| R-MIN | O3 | 144 | 128 | 128 | 128 | 69 | 0 | none | value 90, expanded 18, canceled 10 | 0 | 0 | none | 0 |
| R-MIN | O4 | 144 | 123 | 123 | 123 | 13 | 0 | model_effect 141, compound_command 9 | expanded 10, value 9, failed 4 | 13 | 2 | none | 0 |
| R-MIN | O7 | 144 | 99 | 99 | 132 | 64 | 33 | record_format 137 | failed 42, value 31 | 0 | 34 | none | 0 |
| R-MIN | O7b | 144 | 135 | 135 | 135 | 1 | 0 | runner_detail 143, compound_command 1 | value 1 | 1 | 0 | none | 0 |
| R-MIN | T5 | 144 | 136 | 136 | 136 | 0 | 0 | compound_command 12 | none | 13 | 0 | none | 0 |

## Cost per (row, model), the catalog's rates per call, first and repair

- R-WO claude-opus-5-5: $6.59
- R-WO deepseek-flash: $0.83
- R-WO gpt-6-luna: $0.07
- R-WO gpt-6-sol: $2.51
- R-WO kimi-k3: $12.36
- R-WO glm-5.3-flash: $0.73
- R-WO glm-5.3: $15.22
- R-EX claude-opus-5-5: $6.41
- R-EX deepseek-flash: $0.84
- R-EX gpt-6-luna: $0.07
- R-EX gpt-6-sol: $2.36
- R-EX kimi-k3: $10.26
- R-EX glm-5.3-flash: $0.56
- R-EX glm-5.3: $12.73
- R-MIN claude-opus-5-5: $6.26
- R-MIN deepseek-flash: $0.89
- R-MIN gpt-6-luna: $0.07
- R-MIN gpt-6-sol: $2.3
- R-MIN kimi-k3: $11.32
- R-MIN glm-5.3-flash: $0.59
- R-MIN glm-5.3: $12.39

## The landing (R-MIN against R-WO; R-EX beside)

- C (the voided stamp): HOLDS; the replay modulo deviation 4: holds
- rows: R-EX FAIL, R-MIN FAIL
- head to head, R-EX − R-MIN: E1 R-EX: 384/480 (80.0 %) against R-MIN 389/480 (81.0 %); Δ -1.04 pts, lower -4.32, upper +2.24 (lower ≥ -7.5; credited: holds) → **HOLDS**; G R-EX: 322/336 (95.8 %) against R-MIN 321/336 (95.5 %); Δ +0.30 pts, lower -1.75, upper +2.35 (lower ≥ -5.0; credited: holds) → **HOLDS**; E2 points R-EX +86.98, R-MIN +87.50
- §8.3's registered landing, beside (at least one with row passes): no with row passes

**The verdict: DOES-NOT-LAND — R-MIN fails: guard O3 veto; ships none.**

## Machine lines

```text
verdict=DOES-NOT-LAND
ships=none
reading=posthoc-rehearsed
worlds_sha256_main=b2e248b61dfc62bafd6a87b964e979be37c1ef86967a63e674485ddc1eee2f81
worlds_sha256_reads=b2e248b61dfc62bafd6a87b964e979be37c1ef86967a63e674485ddc1eee2f81
analyzer_sha256=eafc14a123d9e1661c0a75e4867594655d42ad3fb12d865e22ed0b4111361dbc
original_stamp_sha256=3874473cb90a23fcb33ba4d190cb785cedab6fdab77cabb23faf4db55af96993
```
