# Explicit reads A/B — 2026-09-27: KERNEL FINDING

## Provenance (the stamp is the header)

```text
launch_sha256=497931394c84974da6c458ec6dd8cd4685a6b9d356e9394c5a6d20d73ce32f7b
head_with=283e372a8d95254b6a4afeee5f0fd924d569c942
head_without=8357955698793f057ffea518f9fd36d74fbedab5
base=8357955698793f057ffea518f9fd36d74fbedab5
main_head=8357955698793f057ffea518f9fd36d74fbedab5
with_root=/Users/jasl/Workspaces/cybros-ai.alt2-reads
without_root=/Users/jasl/Workspaces/cybros-ai.alt2-reads/e2e/artifacts/bench/2026-09-27-explicit-reads/without-tree
corpus_root=/Users/jasl/Workspaces/cybros-ai.alt2
bench_digest_with=24baa74deaf498040ddac82e8d5011de8408876a7dea89064a446efccfe542fc
bench_digest_without=772186a893d5b304bd1f2ddc94b17577313a27d9a550adc1dfb0a703126df814
row_sha256_R-WO=1e69b087f7b773c5a7f1385970a164f65585216ed22b6a9388e136a986499ad6 bytes=7994 tree=without
row_sha256_R-EX=e6bbb0a6542ea3a7eee4e959153e5b066afbb9675b574832b0e274c932fcc8d8 bytes=8470 tree=with
row_sha256_R-MIN=bed2c651b28ec1cd1775e07ad67b5a22624db650e58bc4e17ad64ca8e35149db bytes=8206 tree=with
row_sha256_R-FIX=71310f86d3cf7f87b5dd3869e6f1d6c6a0d898375c7cd43d1019409ac05caecf bytes=8271 tree=with
row_sha256_R-EX-C=bc98bc1f22e9ed6158b959171945b32aaf432febf663d937ed6ba304eb0a58b6 bytes=8603 tree=with
row_sha256_R-MIN-C=63ae767053cc4db17a7dd34f5a4af5072216b0aceba3ca648e470c04095c6bf3 bytes=8339 tree=with
row_sha256_R-FIX-C=cafa874f217f6b949b3fdd518062a38e1e03825710ce213027b0498bd1611758 bytes=8404 tree=with
analyzer_sha256=2e418caed51bb5cedf2b4aad9d5587f4054c775bb10682d8ce5c7d5d46c0e275
replay_sha256=56ef51dc215bcfbe54e18e95da5adee1500d5c76fa8494d26ce9d424359a8d64+9381cd19bec55a75fb813fdd722f22683fda18ba19887077c2badd94486aa023
replay_without=total: built 270, compared 270, refused alike 0, mismatches 0
replay_with=total: built 270, compared 270, refused alike 0, mismatches 0
c_sha256=ec30643d118db609325ca5308e13154630a9794b5b6c3f657cf49d8b5e16cbb6
c_a=v13 21/21 freed of 28 (expected 28); v14 18/18 freed of 21 (expected 21); v15 17/17 freed of 18 (expected 18); v15 kept line 7 background-suite gpt-6-luna #1; opus/sol freed 10/10 → HOLDS
c_b=v13 9 of 51 exact (listed 9); v14 4 of 61 exact (listed 4); v15 5 of 46 exact (listed 5); differences none → HOLDS
c_c=control v13+v14 185/186 (≥ 185), v15 74/74 (= 74); readings v13 90, v14 96, v15 74; differs v13 line 135 grep-then-edit kimi-k3 #2: record ["wrong_task_read"] → HOLDS
c_d=delivery canonicals 9/9 agree, fixtures 14/14 agree, built 23/23, bound 257, within bound true, distribution {"1" => 17, "2" => 3, "3" => 1, "4" => 1, "7" => 1}; mismatches none → HOLDS
c_verdict=HOLDS
design_section_8_sha256=be9a29ceebbde1cb283c3f78b53dbfbd0af4732f7e65ece7c5bc3d5ff4a30aef
luna=1
rows=R-WO,R-EX,R-MIN
process=R-EX deepseek/deepseek-flash with 24
process=R-EX openrouter/z-ai/glm-5.3-flash with 24
process=R-MIN openrouter/z-ai/glm-5.3-flash with 24
process=R-MIN deepseek/deepseek-flash with 24
process=R-WO openrouter/z-ai/glm-5.3-flash without 24
process=R-WO deepseek/deepseek-flash without 24
process=R-EX openrouter/moonshotai/kimi-k3 with 24
process=R-EX openrouter/z-ai/glm-5.3 with 24
process=R-EX anthropic/claude-opus-5-5 with 24
process=R-EX openai_api/gpt-6-sol with 24
process=R-MIN openai_api/gpt-6-sol with 24
process=R-MIN anthropic/claude-opus-5-5 with 24
process=R-MIN openrouter/z-ai/glm-5.3 with 24
process=R-MIN openrouter/moonshotai/kimi-k3 with 24
process=R-WO openrouter/z-ai/glm-5.3 without 24
process=R-WO openrouter/moonshotai/kimi-k3 without 24
process=R-WO anthropic/claude-opus-5-5 without 24
process=R-WO openai_api/gpt-6-sol without 24
process=R-EX openai_api/gpt-6-luna with 12
process=R-MIN openai_api/gpt-6-luna with 12
process=R-WO openai_api/gpt-6-luna without 12
launched_at=2026-09-26T19:56:39Z
mode=REAL
launch_home=/Users/jasl/Workspaces/cybros-ai.alt2-reads/e2e/artifacts/bench/2026-09-27-explicit-reads
main_root=/Users/jasl/Workspaces/cybros-ai.alt2
main_status_sha256=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
tree_state_with=283e372a8d95254b6a4afeee5f0fd924d569c942 e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 7dd2694ec2665f692a05f060971543a44e0cec6a41ccd53066b60fd5b5a11367
tree_state_without=8357955698793f057ffea518f9fd36d74fbedab5 e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 72d05375f6b4d9a87d73b1d488fd18dff49664bcf2a186914ea22d8ddfc667f7
transport_diff=none (paths: e2e/support/manual_client.rb e2e/support/provider_lanes.rb e2e/support/output_caps.rb nexus/vendor/simple_inference nexus/config/model_catalog)
launch_replay_sha256=278734cb49a90282924d3097bcdf83e5895e7a24a220f41896723e5ceb25b53e
launch_replay.corpus=canonicals 16; first scripts v13 106, v14 104, v15 97 in 2 declared set(s)
launch_replay.with=built 307, compared 307, refused alike 0 {}, mismatches 0 (reads in order)
launch_replay.with.agree_as_sets_only=0
launch_replay.without=built 307, compared 307, refused alike 0 {}, mismatches 0 (reads as sets)
launch_replay.without.agree_as_sets_only=3
launch_replay.without.order_only=2026-09-26-v15-compose compose-race openai_api/gpt-6-sol #1; 2026-09-26-v15-compose compose-race-anon openai_api/gpt-6-sol #1; 2026-09-26-v15-compose compose-race-anon openai_api/gpt-6-sol #2
row_bytes.R-WO=without bytes=7994 sha256=1e69b087f7b773c5a7f1385970a164f65585216ed22b6a9388e136a986499ad6
row_bytes.R-EX=with bytes=8470 sha256=e6bbb0a6542ea3a7eee4e959153e5b066afbb9675b574832b0e274c932fcc8d8
row_bytes.R-MIN=with bytes=8206 sha256=bed2c651b28ec1cd1775e07ad67b5a22624db650e58bc4e17ad64ca8e35149db
row_bytes.R-FIX=with bytes=8271 sha256=71310f86d3cf7f87b5dd3869e6f1d6c6a0d898375c7cd43d1019409ac05caecf
row_bytes.R-EX-C=with bytes=8603 sha256=bc98bc1f22e9ed6158b959171945b32aaf432febf663d937ed6ba304eb0a58b6
row_bytes.R-MIN-C=with bytes=8339 sha256=63ae767053cc4db17a7dd34f5a4af5072216b0aceba3ca648e470c04095c6bf3
row_bytes.R-FIX-C=with bytes=8404 sha256=cafa874f217f6b949b3fdd518062a38e1e03825710ce213027b0498bd1611758
analyzer_dry_sha256=35327290a7355948ce3e582947a18b3cf2b9e82b4f7d8c0d0efe9c8b97e8d0bc
sim.E1=n 480, base 40.6 %, zero-effect 94.5 %, at -7.5 2.8 %; single p 86.1 % / 10.0 %
sim.E2=n 192, base 10.9 %, zero-effect 9.1 %, at +20.0 100.0 %; single p 9.9 % / 100.0 %
sim.E2_40=n 192, base 10.9 %, zero-effect 9.1 %, at +40.0 100.0 %; single p 9.9 % / 100.0 %
sim.E3=n 192, base 0.0 %, zero-effect 100.0 %, at +5.0 7.8 %; single p 100.0 % / 7.8 %
sim.E4=n 48, base 11.5 %, zero-effect 10.2 %, at +20.0 87.6 %; single p 10.3 % / 87.5 %
sim.E4_40=n 48, base 11.5 %, zero-effect 10.2 %, at +40.0 99.9 %; single p 10.3 % / 99.9 %
sim.G=n 336, base 88.7 %, zero-effect 79.2 %, at -5.0 8.8 %; single p 77.6 % / 10.1 %
sim.guard=n 96 per objective, family-wise no-effect veto 6.7 %
sim.base=BASE (/Users/jasl/Workspaces/cybros-ai.alt2/e2e/artifacts/bench/2026-09-26-t1/R-WO); lacks claude-opus-5-5, gpt-6-sol (each at the objective's pooled rate)
c_out_sha256=7f9f05c006b97f6a22eda82be3409eacd9beced4d35f7c1c2054d9684c81ceac
stage0_c_file_sha256=ec30643d118db609325ca5308e13154630a9794b5b6c3f657cf49d8b5e16cbb6
watch_sha256=67d079defd5e68ff098fdcac17556e38d0cfc6ac90922f2e1aacdee163e64504
watch_test_sha256=060d650895b776d5b9c339f686558af3982a6454f9d2cf86325887d330fee1b7
record_stream_sha256=3622a6aba0c2eb094c350d553b3bd3d3523a0665100247a7ff2cd099d6e30faa
sync_stdout_sha256=220fae825bbd01fb436665ff809011a78cf2d213f0bc50bc2dac2bba125bb219
row_bytes_sha256=68057d13189f7c8bc81191ddfe0aa18f26fbabc0794b86162ec42685b4a059dc
fake_bench_sha256=150b1aef130321f5c23c519192ac5026614ac18a4da0b57effc509f3f84bd01b
rates_sha256=2b834426a278abf22ff2b62fbca499f9172642002b0b8a8ef7096736ee8761ca
smoke.without.anthropic_claude-opus-5-5=ok reached=True finish=tool_use in=6124 out=562
smoke.without.openai_api_gpt-6-sol=ok reached=True finish=completed in=3572 out=291
smoke.without.openai_api_gpt-6-luna=ok reached=True finish=completed in=3572 out=350
smoke.with.anthropic_claude-opus-5-5=ok reached=True finish=tool_use in=6281 out=300
smoke.with.openai_api_gpt-6-sol=ok reached=True finish=completed in=3715 out=148
smoke.with.openai_api_gpt-6-luna=ok reached=True finish=completed in=3715 out=478
smoke_spend_usd=0.097117
aborted_smoke_spend_usd=0.087081
carried_spend_usd=0.087081
objectives=O1,O2,O3,O4,O5,O7,O7b,T5
samples=24
samples_luna=12
max_output_tokens=65536
style=nexus
stagger_seconds=0
smoke_timeout_seconds=3000
budget_estimate_usd=210
spend_inflight_bound_usd=84.04 (the processes' draws in flight, two calls of four attempts each at full price, beyond what the records show)
watch.spend_stop_usd=400.0
watch.wall_stop_seconds=43200
watch.stall_flag_seconds=1800
watch.stall_stop_seconds=3600
watch.storm_share=0.1
watch.storm_min_events=5
watch.ceiling_share=0.05
watch.blind_gap=3
watch.take_error_limit=3
watch.poll_seconds=15.0
watch.heartbeat_seconds=600.0
watch.kill_grace_seconds=30.0
watch.fallback_input_tokens=12000
processes=21
process.1=R-EX deepseek/deepseek-flash with n=24 /Users/jasl/Workspaces/cybros-ai.alt2-reads/e2e/artifacts/bench/2026-09-27-explicit-reads/R-EX/deepseek_deepseek-flash
process.2=R-EX openrouter/z-ai/glm-5.3-flash with n=24 /Users/jasl/Workspaces/cybros-ai.alt2-reads/e2e/artifacts/bench/2026-09-27-explicit-reads/R-EX/openrouter_z-ai_glm-5.3-flash
process.3=R-MIN openrouter/z-ai/glm-5.3-flash with n=24 /Users/jasl/Workspaces/cybros-ai.alt2-reads/e2e/artifacts/bench/2026-09-27-explicit-reads/R-MIN/openrouter_z-ai_glm-5.3-flash
process.4=R-MIN deepseek/deepseek-flash with n=24 /Users/jasl/Workspaces/cybros-ai.alt2-reads/e2e/artifacts/bench/2026-09-27-explicit-reads/R-MIN/deepseek_deepseek-flash
process.5=R-WO openrouter/z-ai/glm-5.3-flash without n=24 /Users/jasl/Workspaces/cybros-ai.alt2-reads/e2e/artifacts/bench/2026-09-27-explicit-reads/R-WO/openrouter_z-ai_glm-5.3-flash
process.6=R-WO deepseek/deepseek-flash without n=24 /Users/jasl/Workspaces/cybros-ai.alt2-reads/e2e/artifacts/bench/2026-09-27-explicit-reads/R-WO/deepseek_deepseek-flash
process.7=R-EX openrouter/moonshotai/kimi-k3 with n=24 /Users/jasl/Workspaces/cybros-ai.alt2-reads/e2e/artifacts/bench/2026-09-27-explicit-reads/R-EX/openrouter_moonshotai_kimi-k3
process.8=R-EX openrouter/z-ai/glm-5.3 with n=24 /Users/jasl/Workspaces/cybros-ai.alt2-reads/e2e/artifacts/bench/2026-09-27-explicit-reads/R-EX/openrouter_z-ai_glm-5.3
process.9=R-EX anthropic/claude-opus-5-5 with n=24 /Users/jasl/Workspaces/cybros-ai.alt2-reads/e2e/artifacts/bench/2026-09-27-explicit-reads/R-EX/anthropic_claude-opus-5-5
process.10=R-EX openai_api/gpt-6-sol with n=24 /Users/jasl/Workspaces/cybros-ai.alt2-reads/e2e/artifacts/bench/2026-09-27-explicit-reads/R-EX/openai_api_gpt-6-sol
process.11=R-MIN openai_api/gpt-6-sol with n=24 /Users/jasl/Workspaces/cybros-ai.alt2-reads/e2e/artifacts/bench/2026-09-27-explicit-reads/R-MIN/openai_api_gpt-6-sol
process.12=R-MIN anthropic/claude-opus-5-5 with n=24 /Users/jasl/Workspaces/cybros-ai.alt2-reads/e2e/artifacts/bench/2026-09-27-explicit-reads/R-MIN/anthropic_claude-opus-5-5
process.13=R-MIN openrouter/z-ai/glm-5.3 with n=24 /Users/jasl/Workspaces/cybros-ai.alt2-reads/e2e/artifacts/bench/2026-09-27-explicit-reads/R-MIN/openrouter_z-ai_glm-5.3
process.14=R-MIN openrouter/moonshotai/kimi-k3 with n=24 /Users/jasl/Workspaces/cybros-ai.alt2-reads/e2e/artifacts/bench/2026-09-27-explicit-reads/R-MIN/openrouter_moonshotai_kimi-k3
process.15=R-WO openrouter/z-ai/glm-5.3 without n=24 /Users/jasl/Workspaces/cybros-ai.alt2-reads/e2e/artifacts/bench/2026-09-27-explicit-reads/R-WO/openrouter_z-ai_glm-5.3
process.16=R-WO openrouter/moonshotai/kimi-k3 without n=24 /Users/jasl/Workspaces/cybros-ai.alt2-reads/e2e/artifacts/bench/2026-09-27-explicit-reads/R-WO/openrouter_moonshotai_kimi-k3
process.17=R-WO anthropic/claude-opus-5-5 without n=24 /Users/jasl/Workspaces/cybros-ai.alt2-reads/e2e/artifacts/bench/2026-09-27-explicit-reads/R-WO/anthropic_claude-opus-5-5
process.18=R-WO openai_api/gpt-6-sol without n=24 /Users/jasl/Workspaces/cybros-ai.alt2-reads/e2e/artifacts/bench/2026-09-27-explicit-reads/R-WO/openai_api_gpt-6-sol
process.19=R-EX openai_api/gpt-6-luna with n=12 /Users/jasl/Workspaces/cybros-ai.alt2-reads/e2e/artifacts/bench/2026-09-27-explicit-reads/R-EX/openai_api_gpt-6-luna
process.20=R-MIN openai_api/gpt-6-luna with n=12 /Users/jasl/Workspaces/cybros-ai.alt2-reads/e2e/artifacts/bench/2026-09-27-explicit-reads/R-MIN/openai_api_gpt-6-luna
process.21=R-WO openai_api/gpt-6-luna without n=12 /Users/jasl/Workspaces/cybros-ai.alt2-reads/e2e/artifacts/bench/2026-09-27-explicit-reads/R-WO/openai_api_gpt-6-luna
python=/Users/jasl/.venv/bin/python3
```

## The replay check (§8.5 step 8): every first script through its tree's kernel

- R-WO (without tree): 1089 of 1089 reached first scripts replayed — built 1033, compared 1032, refused alike 1 {"unknown_tool_name" => 1}, mismatches 0
- R-EX (with tree): 1089 of 1089 reached first scripts replayed — built 1037, compared 1036, refused alike 0 {}, mismatches 1
  - mismatch gpt-6-sol O2 #16: the harness lowers a graph where the kernel refused invalid_script
- R-MIN (with tree): 1087 of 1087 reached first scripts replayed — built 1047, compared 1046, refused alike 0 {}, mismatches 1
  - mismatch gpt-6-sol O2 #23: the harness lowers a graph where the kernel refused invalid_script

## `over_read_positional` on the with rows' registered E3 cells (strong tier, O7b/T5; expected 0 by construction)

- R-EX: 0 — none
- R-MIN: 0 — none

**KERNEL FINDING — stop, fix, relaunch the whole batch under a new stamp.** No clause verdict and no relaunch line is written (§8.3 E3; reading l).

## Machine lines (reading l; the launch reads them)

```text
verdict=KERNEL-FINDING
ships=none
relaunch_rows=none
analyzer_sha256=2e418caed51bb5cedf2b4aad9d5587f4054c775bb10682d8ce5c7d5d46c0e275
stamp_sha256=3874473cb90a23fcb33ba4d190cb785cedab6fdab77cabb23faf4db55af96993
```

## Resolutions (this script's header, fixed before the data)

```text
The explicit-reads A/B of 2026-09-27 (design: docs/plans/2026-09-26-explicit-reads-design.md §8, the
committed record; bench.yml VERSION 16 carries §8 verbatim), read by the resolutions below.

The batch (§8.2): R-WO on the WITHOUT tree (main at the merge base — the shipped kernel, text and
harness, read by its own Shape); R-EX (the with registry's bytes) and R-MIN (the VARIANTS re-cut) on the
WITH tree (branch feat/explicit-reads, the whole change), each read by its own Shape; R-FIX, R-EX-C,
R-MIN-C and R-FIX-C committed as VARIANTS and run ONLY on the one relaunch. Models: the strong tier
glm-5.3, kimi-k3, claude-opus-5-5, gpt-6-sol; the floors deepseek-flash, glm-5.3-flash; gpt-6-luna
named-only at n = 12 (LUNA=1, the owner's answer of 2026-09-26). Style nexus, every objective (O1 O2 O3
O4 O5 O7 O7b T5), n = 24 on the six tier models, the 65,536 cap: 3 rows × 6 models × 8 × 24 = 3,456
draws + luna 288 = 3,744 in 21 processes of 192 draws (luna's 3 of 96). ≈ $210 estimated, the $400 spend
stop and the 12 h wall stop (the owner's answers, §12).

THE RESOLUTIONS ARE THE DESIGN'S §8.3, VERBATIM (fixed before any draw):

  ### 8.3 Endpoints, gate, guard, denominators, landing rule (fixed before the data)

  Denominators: every endpoint's denominator is ALL draws of its cells; an unreached draw and an OPAQUE draw (a
  plan holding a result-reading stage, `probe.rb:137-140`) count as not exact, not first-time-right and — for G —
  usable only under today's rule, in every row alike. The analyzer computes `blind_after_work`, `named_final`,
  `results_on_tool`, `group_named`, `nested_list`, `opaque` from the stored scripts and refusal details with one
  code path for every row — every stored script re-evaluated under ONE evaluator, the with tree's, since a refusal
  bucket differs by tree (main files a nested list under `reference_value`, the with tree under `nested_list`).

  - **E1, primary — non-inferiority where over_read never lived.** First-script `first_time_right` on **O1 O2 O3
    O4 O7** (v14 C moved O7 8 → 8) pooled over the four strong models (4 × 5 × 24 = **480 per row**), R-EX − R-WO,
    Newcombe hybrid one-sided 90 %: HOLDS when the lower bound ≥ **−7.5** points (the critique's simulation at
    T1's base rates: 480 at −7.5 passes a zero-effect change 86 % of the time and a change at the margin 10 %;
    the previous 336 pooled over seven at −5 let a −10 fall on five objectives land ≈ 45 % of the time because
    O7b/T5's mechanical +40 masked it). The stamp prints the zero-effect and at-margin pass rates at the batch's
    actual n and R-WO base rate.
  - **E2, mechanism — superiority where the defect lives.** First-script exact pictures on **O7b and T5** pooled
    over the strong tier (4 × 2 × 24 = **192 per row**), R-EX − R-WO: HOLDS when the one-sided 90 % lower bound
    is above 0. Not by construction: a model can fall to `blind_model` or `reads_mismatch` instead of rising.
  - **E3, the owner's endpoint — over_read on the strong tier's first scripts, split.** `over_read_positional`
    (reads outside `results:`): expected **0 of 192** on O7b/T5 under R-EX and R-MIN by construction (nonzero is a
    KERNEL FINDING: stop, fix, relaunch) — the static lowering never builds a positional read, so on Stage 1 its
    evidence is the replay's mismatch count on every first script (§8.5 steps 3 and 8). `over_read_named`
    (`results:` naming more than the picture), O7b/T5, R-EX − R-WO(B) — R-WO's samples carry only the recorded,
    unsplit `over_read`, so its side is the attribution column's: its first scripts lowered and read under the with
    tree's Shape and Picture: HOLDS when the one-sided 90 % UPPER bound of the rise is ≤ +5.0 points (a text with
    `results:` in every example could teach naming too much).
  - **E4, the owner's literal bar — Opus alone.** claude-opus-5-5 first-script exact on O7b and T5 (2 × 24 = **48
    per row**), R-EX − R-WO: HOLDS when the one-sided 90 % lower bound is above 0; and opus's
    `over_read_positional` = 0. Deciding (v15: 0/3 on two-source with over_read; AS WRITTEN all its two-source
    scripts are exact under the rule).
  - **G, the floor gate.** Usable on the FIRST script, both floors × the seven non-control objectives (2 × 7 × 24 =
    **336 per row**), each `with` row − R-WO: HOLDS when the lower bound ≥ −5.0 points (at 336 a zero-cost text
    passes ≈ 78 % per row, a −5 text ≈ 10 %); an unreached draw is not usable and stays in the denominator.
    After-repair usable reported beside with its own bound.
  - **The guard.** Expanded `first_time_right` per objective on the strong tier (96 per row per objective), each
    `with` row against R-WO, at z = 2.1893 (one-sided 90 % family-wise over seven): a fall whose lower bound is
    above 0 VETOES that row.
  - **The opaque flag.** The opaque share per objective per row; a pooled rise of R-EX over R-MIN whose one-sided
    90 % lower bound is above 0 picks R-MIN over R-EX in the landing rule.
  - **The kernel/text attribution column (free, offline).** R-WO's first scripts lowered under the `with` tree's
    Shape (rule B) beside their R-WO reading (rule A): kernel-only effect = R-WO(B) − R-WO(A); text effect =
    R-EX(B) − R-WO(B), R-MIN(B) − R-WO(B). The rerun rule's attribution below is computed against this column.
  - **Beside, never deciding:** sol and luna on their own (E1–E4 per model — a read); `blind_after_work`,
    `named_final`, `results_on_tool`, `group_named`, `nested_list`, `handle_throw`, refusals per bucket, each
    row's bytes, per-objective exact and usable, cost per (model, row).
  - **Sex2, the Ex2-shape predicate** (mechanical, on the stored script text by bracket matching): a first-call
    `syntax` refusal whose evaluator `Failure.line` (the stored detail's line) lies inside a `.map(` callback whose
    body returns an array literal; or a first-call `member_not_a_step`, `handle_throw` or `invalid_reference`
    refusal — builder throws, which the evaluator returns as `script_error` with no line — on a script holding such
    a callback, where the construct the refusal's message names (the member, the handle, the `results:` list it
    quotes) is found inside that callback. *(Re-registered at script level after review, 2026-09-26.)*
  - **The ONE relaunch** (total, across both triggers; memory `rerun-triggers-bind-the-orchestrator`: the whole
    batch, never a partial rerun): evaluate R-EX AND R-MIN first; relaunch only if BOTH fail, and only when every
    failure is one of two named classes — (i) every vetoing guard fall is `blind_model`/`reads_mismatch` on steps
    that named nothing (attributed against the kernel/text column) → relaunch with R-FIX; (ii) both rows fail G
    with first-call refusals on Sex2's shape → relaunch with R-EX-C and R-MIN-C; both classes at once → R-FIX-C
    (R-FIX with the consts Ex2, also committed now). The relaunch reruns R-WO too (a paired comparison), under a
    new stamp. Any other failure, or a failure on the relaunch, stops the change: a readout and a ledger row.
  - **Landing rule.** The KERNEL lands iff C holds, the replay check holds in both trees, and at least one `with`
    row passes G, E1, E2, E3 and E4 with the guard vetoing nothing. **R-MIN ships** unless R-EX also passes all
    five, is non-inferior to R-MIN head to head on G and E1 (lower bound ≥ the same margins), the opaque flag does
    not fire, and R-EX's E2 point estimate ≥ R-MIN's — then R-EX ships and R-MIN is deleted; otherwise R-EX's
    extras go to the ledger with their numbers. There is no partial landing (kernel without text, text without
    kernel, or a row that was not run).

And §8.5 step 8, the analyzer's own contract, verbatim: "the analyzer as the script's LAST act after
`ALL-DONE`: it refuses to decide when `launch.txt` is missing or its own sha differs from the stamp's; asserts
exactly 8 × 24 samples per (model, row) (8 × 12 for luna), none written before `launched_at`; replays every
first script of every row through its tree's kernel and refuses to decide on a mismatch (counts printed);
reads only the rows' `compose_matrix.json`; refuses to decide a (model, row) with > 5 % unreached draws, and
prints its retries per (model, row) beside them; writes `analysis.md` with the stamp as its header and every
registered clause with its verdict, the kernel/text column, the cost per (model, row) from the catalog's
rates, and the relaunch verdict if any. The script exits 0 whenever `analysis.md` was written (the verdict is
inside it) and non-zero only when it was not."

OPERATIONAL READINGS (fixed with this file, before any draw; each the one reading the words above admit,
and the choice named where the words left one):
a. THE DECIDING VALUE of every clause is the RECORD's, each row read by its own tree's Shape and Picture as
   §8.2 says ("read by its own Shape"; the stamp pins both trees, the launch refuses a dirty one and the
   watch stops the batch if either moves): R-WO's `first_time_right`, `expanded.first_time_right` and
   `usable` are rule A's (main's, at the merge base), the with rows' the with tree's. Every stored first
   script is ALSO re-read under the with tree's evaluator, Shape, Picture and Probe (`reread`, one code
   path for every row): for R-WO that re-read IS rule B, the attribution column; for a with row it runs
   the very code that wrote the record, so a disagreement is a reader that is not a function of the
   script (reading m). The side facts (`blind_after_work`, `named_final`, `results_on_tool`,
   `group_named`, `nested_list`, `handle_throw`, `opaque`, `over_read_positional`, `over_read_named`,
   Sex2) are the re-read's for every row.
b. THE DENOMINATOR of every clause is every draw of its cells (§8.3's first paragraph); a value that is
   absent — a lost draw, a draw with no compose call, a refused script — reads as false, and an OPAQUE
   draw is not exact and not first-time-right whatever its record says: `first_time_right` is read as
   `first_time_right == true && opaque != true` in every clause, column and figure, the record's and the
   re-read's alike (the probe compares an opaque plan's visible steps and can record true; §8.3 counts it
   not first-time-right). The guard's expanded right is `expanded.first_time_right == true` (absent on an
   opaque draw). G's usable is the record's `usable == true` (the Probe reads a result-reading stage for
   its parse alone: "usable only under today's rule").
c. BLIND_AFTER_WORK: the first script built (with tree) and holds a `model` step with no `results:` that
   comes after another step in its own sequence — the script's top level, a nested sequence (which
   continues the sequence it sits in), or a `parallel` member's own sequence (`[lint, g.model({…})]`; a
   member that is one step alone follows nothing). NAMED_FINAL: the script's last top-level step is a
   `model` or `script` leaf with a non-empty `results:` (a closing `parallel` is not one).
   RESULTS_ON_TOOL, GROUP_NAMED, NESTED_LIST, HANDLE_THROW: a first-call refusal in the with tree's bucket
   of that name (`Buckets.LOUD`: `tool_reads`, `group_reference`, `nested_list`, `handle_throw`).
   OVER_READ_POSITIONAL / OVER_READ_NAMED: the re-read's first-script silent buckets. BLIND_OR_MISMATCH
   (the relaunch's class (i)): the re-read's EXPANDED silent buckets — the reading the guard's expanded
   right is taken on — hold `blind_model` or `reads_mismatch`. OPAQUE: the re-read's `opaque == true`.
d. SEX2 by bracket matching: a `.map(` callback is an arrow or `function` argument of `.map(`; its body
   "returns an array literal" when a block body holds `return [` or an expression body starts with `[`
   (parenthesised or not). (i) a `syntax` refusal whose detail's `at line N` lies within such a callback's
   lines; (ii) a `member_not_a_step` refusal on a script whose such callback is an argument of an open
   `g.parallel(` (the member the message names is what the callback returned); a `handle_throw` refusal on a
   script whose such callback concatenates or interpolates a handle it declared (`+ h`, `h +`, `${h}`) — the
   handle the message names by its minted key, which the text cannot carry; an invalid-reference refusal
   (the with tree's `nested_list`, `reference_value`, `group_reference`, `race_member`, `race_unwrapped`
   buckets — the builder's one `_referenceKey` family) on a script whose such callback writes a `results:` or
   `after:` list. Each is the nearest mechanical reading of "found inside that callback".
e. THE OPAQUE FLAG pools over the six tier models × the seven non-control objectives (luna is beside, never
   deciding), on the batch's pair — R-EX over R-MIN, or R-EX-C over R-MIN-C on their relaunch; the
   per-objective shares print per row.
f. THE RELAUNCH CLASSES, mechanically, on the first batch's pair (R-EX, R-MIN), once BOTH rows fail. Every
   decided failure of each row is classified: a guard veto is class (i) when the row's draws on that
   objective whose expanded buckets hold `blind_model` or `reads_mismatch` AND whose script holds a step
   that named nothing (`blind_after_work`) number at least the fall in draws (R-WO's expanded right − the
   row's); a G failure is class (ii) when BOTH rows fail G and each row's Sex2-shaped first-call refusals
   on the floors' seven objectives number at least one and at least its G loss in draws (R-WO's usable −
   the row's; R-WO's own Sex2 count prints beside); every other failure — E1, E2, E3, E4, an uncovered
   veto, a G failure outside (ii) — is unclassified. The relaunch holds only when nothing is unclassified
   and nothing is pending: (i) alone → R-WO,R-FIX; (ii) alone → R-WO,R-EX-C,R-MIN-C; both → R-WO,R-FIX-C.
   "Attributed against the kernel/text column": each vetoed objective's kernel-only column (R-WO(B) −
   R-WO(A)) and text column (row(B) − R-WO(B)) print beside its classification; the sign of neither is a
   condition, since §8.3 names none (OWNER TO CONFIRM before the stamp: the column is read, never gated).
g. LOST DRAWS AND THE STORM take the watch's definitions (`watch.py`): a draw is LOST when its first call
   ended in an error left after the client's retries (`error`), other than a harness-fault class; a draw
   whose model answered without calling compose was REACHED — a no-call, a miss in every denominator,
   never lost — and its count prints beside. §8.5's unreached ceiling is lost draws > 5 % of the (model,
   row)'s draws over all eight objectives. The storm column is the watch's rule: calls (the first, and
   the repair when made) that ended in such an error or carry `retries`/`repaired_retries`, ≥ 10 % of the
   (model, row)'s calls once there are at least 5 such calls (the watch's `storm_min_events`, a parameter
   §8.5 does not set, stamped as `watch.storm_min_events`). COST per (model, row) is priced from the
   catalog's rates as §8.2 registers ("the analyzer prices every lane from the catalog's rates"):
   `input_per_mtok` (or `input_cache_miss_per_mtok`) × input + `output_per_mtok` × output, per call, first
   and repair, the long-context multipliers above their threshold, a cached read priced as plain input;
   the broker's reported `cost` prints beside; a batch model without catalog rates refuses (never a lane
   priced at $0). RETRIES per (model, row): the samples' `retries` and `repaired_retries` entries.
h. "NONE WRITTEN BEFORE launched_at": every `compose_matrix.json` and every file under its `captures/`
   carries an mtime at or after the `launched_at` of the stamp that launched it (a rerun's, for a rerun).
i. THE PRE-REGISTERED FIGURES (E1, E2, E3, E4, G and the guard) are computed over the REGISTERED layout
   whatever TIERS a dry run names — the strong tier's four models, the two floors, opus alone for E4,
   each (model, objective) cell n = 24 (TIERS drives only a dry run's clause mechanics): exact sums over
   two pooled binomials per clause (T1's `firing`), each cell at the base source's rate — this batch's
   R-WO on a real run; on a dry run BASE's draws alone (T1's R-WO by default: the design's "T1's base
   rates"), a model the source lacks at the source's pooled rate for the objective over every model it
   holds (named in the figures). A change AT THE MARGIN moves the POOLED rate by exactly the margin: one
   per-cell shift solved so the clamped cells' mean moves by it (the effective shift prints). E1: pass =
   lower ≥ −7.5, under no effect and at −7.5. E2 and E4: pass = lower > 0, under no effect and at +20 and
   +40. E3 named: pass = upper ≤ +5, under no effect and at +5 (base: R-WO(B)'s `over_read_named`). G:
   pass = lower ≥ −5, under no effect and at −5. Each prints beside the same figure for ONE pooled p of
   the same mean: stratified cells have less binomial variance than one p, while the Newcombe bounds are
   sized from the pooled rate, so the stratified figure passes a zero-effect change more often and an
   at-margin one less often than the single-p figure the design quoted. The guard's family-wise
   no-effect veto rate at n = 96 per objective prints as T1 computed it. A dry run writes the figures as
   stamp lines (`sim.*`, dryrun-<name>.figures.txt); the launch copies them into the stamp. Every bound
   is compared unrounded, rounded only where it prints.
j. THE REPLAY (§8.5 steps 3 and 8) runs `ComposeBench::Replay.lowered` with `root:` set to the tree and
   compares each script's two graphs with `Executed.same_graph?` — the reads IN ORDER on the with tree,
   whose rule fixes the order a step reads in, and AS SETS on the without tree, whose Shape never fixed the
   order of a positional read: main's own picture compares a step's reads sorted (`picture.rb:247` at the
   merge base, `reads_at(graph, label, key).sort == expected.sort`) and its `agree!` compares sets. The
   first dry run found three v15 race scripts whose model reads the same six keys in another order on
   main's kernel; the launch's stamp names them (`launch_replay.without.order_only`). A dry run replays
   the first REPLAY (default 24) scripts per row and prints the counts without refusing (REPLAY=all
   replays every one).
k. A DRY RUN reads whole directories (S1's `without` and `with` — the same text on two trees, the design's
   null pair — or any batch's) and may name TIERS= so every clause's mechanics run on a pair that lacks a
   tier: `TIERS=strong:<ref>,<ref>;floor:<ref>,<ref>;opus:<ref>`; the registered layout (models, n) is not
   checked, no stamp is read, nothing is decided, a kernel finding is printed and the rest still run, a
   lost-draw ceiling or a record/re-read disagreement prints what it would leave undecided on a real run,
   and the file written is dryrun-<name>.md.
l. THE VERDICT (a real run). A replay mismatch on any row's first scripts, or an `over_read_positional` on
   a with row's registered E3 cells (the strong tier's first scripts on O7b/T5), is a KERNEL FINDING:
   analysis.md then holds the stamp, the mismatches and the positional draws, no clause verdict and no
   relaunch line — "stop, fix, relaunch", the whole batch under a new stamp. Otherwise each with row is
   PASS (G, E1, E2, E3, E4 decided and holding, every guard objective decided and none vetoing), FAIL (a
   decided clause fails, or a decided guard objective vetoes) or PENDING (no decided failure, a clause or
   objective not decided). THE LANDING VERDICT: LANDS when a row passes and every row of the pair is
   decided (the landing rule then picks the row that ships — R-EX against R-MIN, or R-EX-C against
   R-MIN-C, head to head); DOES NOT LAND when every row fails and the relaunch verdict is decided; NOT
   DECIDED otherwise (a pending row whose result could change what lands or ships — lost draws over the
   ceiling mean the whole batch relaunched under a new stamp, never the ONE relaunch; a record/re-read
   disagreement is a harness finding, fixed, then the whole batch relaunched). The last lines of
   analysis.md are machine lines the launch reads: `verdict=` (LANDS, DOES-NOT-LAND, NOT-DECIDED,
   KERNEL-FINDING), `ships=`, `relaunch_rows=` (R-WO,R-FIX | R-WO,R-EX-C,R-MIN-C | R-WO,R-FIX-C | none),
   `analyzer_sha256=`, `stamp_sha256=`.
m. RECORD VS RE-READ: on a with row, a draw whose record and re-read differ on `valid_first`,
   `first_time_right`, `usable`, `expanded.first_time_right` or `opaque` leaves every clause and guard
   objective whose cells hold it NOT DECIDED on a real run (counted in the verdict section); `silent` and
   `loud` differences print beside.
n. RERUNS (§8.5 step 9): ROW/<slug>=DIR names a harness-fault rerun's directory,
   <home>/rerun-<slug>-<time>/<row>/<slug>, for every row of that model together. Its stamp
   (DIR/../../logs/launch.txt) must say `rerun=<model>` and carry this batch stamp's sha256
   (`batch_stamp_sha256`); the rerun must have finished (logs/all-done), must not have been STOPPED, and
   must be the newest unstopped rerun of that model. Its exit is read from its own log
   (DIR/../../logs/<row>.<slug>.log) and its files are checked against its own `launched_at`.
o. HOME=<dir> reads a FAKE rehearsal's home (its stamp says `mode=FAKE`) through every real-run check;
   its analysis.md is written in that home and decides nothing. A real stamp is read only from this
   file's own directory.

Usage (cwd = the with tree's e2e, so `bundle exec` loads its Gemfile):
  bundle exec ruby <this file> [ROW/<model slug>=DIR …] [HOME=<fake home>]
    → analysis.md beside this file (in HOME for a FAKE rehearsal). Each (row, model) is read from
      <home>/<row>/<slug>/compose_matrix.json unless ROW/<slug>=DIR names a harness-fault rerun's directory
      (reading n). REFUSED (nothing written, exit 1): no stamp, or this file's sha256 differs from the
      stamp's; a moved tree (HEAD ≠ the stamp's, or uncommitted changes under nexus/ or e2e/) in either
      tree; a missing compose_matrix.json; a non-zero process exit; a harness-fault sample
      (NoMethodError, ArgumentError, TypeError); a sample of another row or model; not exactly the
      registered draws; a file written before launched_at; a rerun that fails reading n. WRITTEN, exit 0:
      a KERNEL FINDING, or every clause with its verdict (reading l).
  bundle exec ruby <this file> --dry <name> R-WO=<dir>[,<dir>] R-EX=<dir>[,…] R-MIN=<dir>[,…] [BASE=<dir>] [TIERS=…]
    → dryrun-<name>.md and dryrun-<name>.figures.txt; operational readings i and k.
  bundle exec ruby <this file> --replay
    → logs/replay_without.txt and logs/replay_with.txt (§8.5 step 3): every canonical and every v13–v15 first
      script (stage0_c.rb --scripts writes first_scripts.json beside this file) replayed in each tree, in
      groups by the trace's declared names; exit 1 on any mismatch.
  bundle exec ruby <this file> --stamp [LUNA=1] [LAUNCH=<launch.sh>] [ROWS=R-WO,R-EX,R-MIN] [RELAUNCH=<why>]
    → logs/launch.txt (§8.5 step 6), before any draw: REFUSED over an existing stamp, a dirty tree, a without
      tree not at the merge base, main's HEAD not the merge base (main moved past the with branch), a
      missing logs/replay_*.txt or stage0_c.txt, or a C that does not HOLD. The launch reads its `process=`
      lines. REHEARSAL=1 writes logs/launch.rehearsal.txt instead, skipping the tree and merge-base checks
      and saying so inside it — a file no launch and no analysis reads.
  READS_WITHOUT_ROOT names the without tree (the launch's detached worktree at the merge base; a real run
  reads it from the stamp); READS_CORPUS_ROOT the checkout holding the gitignored benches (S1, T1) —
  main's live checkout, /Users/jasl/Workspaces/cybros-ai.alt2, by default.
```
