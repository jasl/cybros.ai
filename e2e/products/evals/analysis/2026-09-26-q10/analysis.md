# Q10 readout over `2026-09-26-v14-compose` (2026-09-26T00:54:56Z)

- tree read: `/Users/jasl/Workspaces/cybros-ai.alt2-q10read` at 4a8cf2ea (branch `HEAD`, on main 4a8cf2ea); uncommitted under nexus/ or e2e/: none
- bench.yml: version 14, digest f69dc4cc6ab4
- this file: sha256 1a3d6a9416229e41
- the harness's reader: `E2E::Evals::Predicates.follower_envelopes`, re-read beside this file's on every follower
- stamped 2026-09-25T16:01:57Z at 4a8cf2ea (bench f69dc4cc6ab4); this file is the stamp's
- THE STAMP WAS RECONSTRUCTED: `--stamp` was not run before the launch; logs/launch.txt was written after the batch from launch-time facts (logs/prelaunch-analyze_q10.sha256, written 16 s before the launch; logs/bench-v14.log.line1; the records' bench_digest) and carries a `reconstructed=` line. Read under a detached worktree at the launch commit 4a8cf2ea.

## 1. Unit
- 24 race-cell records; 22 followers (composed 16, spine 6); unreadable (a substituted tip): none

## 2. The invariant (kernel)
- canceled exits 0 over 22 followers; unselected exits: none
- residue (a canceled non-exit, never a stop): none

## 3. The arithmetic (harness)
- 16 of 16 composed followers agree with their bytes
- the recorded `follower_envelopes` fact against this file's reading: 22 of 22 agree

## 4. The census
- followers 22; reading a race with a stage exit 0 (version 13: 5 of 18)
- over that subset: delivered 0, canceled exits 0 — version 13's 18 / 10 as recorded, 8 / 0 under the rewrite
- **5. FALLBACK**: version 14 carries no stage-exit follower — the floor is the kernel tests and the dry run; nothing is drawn from the cells' pictures for this row

## 6. Beside it, never deciding (version 14 against version 13, per model)
- compose-race success: v14 glm-5.3 3/3, kimi-k3 3/3, deepseek-flash 3/3, glm-5.3-flash 3/3 — v13 glm-5.3 3/3, kimi-k3 3/3, deepseek-flash 3/3, glm-5.3-flash 3/3
- compose-race picture: v14 glm-5.3 3/3, kimi-k3 3/3, deepseek-flash 3/3, glm-5.3-flash 2/3 — v13 glm-5.3 3/3, kimi-k3 3/3, deepseek-flash 2/3, glm-5.3-flash 2/3
- compose-race no_wrong_winner: v14 glm-5.3 3/3, kimi-k3 3/3, deepseek-flash 3/3, glm-5.3-flash 3/3 — v13 glm-5.3 3/3, kimi-k3 3/3, deepseek-flash 3/3, glm-5.3-flash 3/3
- compose-race authored_labels: v14 glm-5.3 1/3, kimi-k3 0/3, deepseek-flash 0/3, glm-5.3-flash 2/3 — v13 glm-5.3 1/3, kimi-k3 3/3, deepseek-flash 3/3, glm-5.3-flash 2/3
- compose-race success_filter: v14 glm-5.3 0/3, kimi-k3 0/3, deepseek-flash 0/3, glm-5.3-flash 1/3 — v13 glm-5.3 0/3, kimi-k3 0/3, deepseek-flash 2/3, glm-5.3-flash 0/3
- compose-race losers_completed == 0: v14 glm-5.3 3/3, kimi-k3 3/3, deepseek-flash 3/3, glm-5.3-flash 3/3 — v13 glm-5.3 3/3, kimi-k3 3/3, deepseek-flash 3/3, glm-5.3-flash 3/3
- compose-race-anon success: v14 glm-5.3 3/3, kimi-k3 3/3, deepseek-flash 3/3, glm-5.3-flash 3/3 — v13 glm-5.3 3/3, kimi-k3 3/3, deepseek-flash 3/3, glm-5.3-flash 3/3
- compose-race-anon picture: v14 glm-5.3 3/3, kimi-k3 3/3, deepseek-flash 3/3, glm-5.3-flash 3/3 — v13 glm-5.3 3/3, kimi-k3 3/3, deepseek-flash 2/3, glm-5.3-flash 3/3
- compose-race-anon no_wrong_winner: v14 glm-5.3 2/3, kimi-k3 3/3, deepseek-flash 3/3, glm-5.3-flash 3/3 — v13 glm-5.3 3/3, kimi-k3 3/3, deepseek-flash 3/3, glm-5.3-flash 3/3
- compose-race-anon authored_labels: v14 glm-5.3 0/3, kimi-k3 1/3, deepseek-flash 1/3, glm-5.3-flash 1/3 — v13 glm-5.3 3/3, kimi-k3 3/3, deepseek-flash 3/3, glm-5.3-flash 3/3
- compose-race-anon success_filter: v14 glm-5.3 0/3, kimi-k3 0/3, deepseek-flash 0/3, glm-5.3-flash 0/3 — v13 glm-5.3 1/3, kimi-k3 0/3, deepseek-flash 2/3, glm-5.3-flash 0/3
- compose-race-anon losers_completed == 0: v14 glm-5.3 3/3, kimi-k3 3/3, deepseek-flash 3/3, glm-5.3-flash 3/3 — v13 glm-5.3 3/3, kimi-k3 3/3, deepseek-flash 3/3, glm-5.3-flash 3/3
