# D. v11's workflow records reread with the fixed readers

**Headline.** I reread the 60 v11 workflow records offline with main's readers. 20 of them change a verdict, class or
conduct value. All 60 traces are present, and no reader raised under any of the five reader trees. Three changes
account for all 20. The spine-reader fix (`bf6e5af0`, v12) moves 15, and all 15 are conduct checks going from fail to
pass; it changes no reach or success. QueuePass (same commit) moves 4 loop-until-dry records. The computed-normalise
picture (`a8623359`, v13) moves 1 barrier-free success. S1 and v12's race reference in `builder.js` move 0. All 16
compose scripts in the traces build or refuse the same way under all four builders.

Like-for-like workflow totals. Reached: 51 → **54**/60. Succeeded: 37/51 → **40/54**. Task pass: 58/60 as recorded.
Conduct passes: 11/36 → **28/36**. Clean: 14 → **25**/60. By class, model conduct goes 25 → 11, disagreement 13 → 12
and cache under floor 8 → 12. The v13 column, scored by the same readers, reads 53/60, 47/53, 58/60, 30/36 and 30/60.

Everything below comes from the scripts in the appendix. `d_run_all.sh` reruns the whole read from scratch. It writes
only under `…/scratchpad/v13/readout/`, and `git status --short` is empty afterwards (`d_repo_status.out`, 0 lines).

## 1. Method

- **Rescore path.** Each record goes through `E2E::Evals::Rescore.trace_of` and then `Rescore.rescored`. This is the
  pure half of `rake evals_rescore`. `Records.append`, which writes, is never called, and nothing touches the
  committed `records.jsonl`.
  - `task_pass`, `stopped` and `efficiency` are kept as recorded, as the rake rescore keeps them. The verification is
    not rerun.
  - The class comes from `Scorecard.classify` against that tree's `bench.yml`.
- **Five reader trees** (`d_rescore.rb`). The three old trees come from `git archive` of `e2e/support`,
  `e2e/evals/tasks`, `e2e/evals/bench.yml` and `nexus/lib` (plus two small support paths):
  - `old` is `fc76e859`. For every reader path it equals `320d2050`, the commit the v11 workflow family ran on
    (`d_git_checks.out`: empty diff).
  - `v12` is `bf6e5af0`.
  - `v13pre` is `a8623359`, v13 before S1. From `a8623359` to main, the reader paths differ only by S1:
    `builder.js`, `buckets.rb` and a RATIONALE.
  - `head` is main. It is also the reader tree v13 was scored with (`c576fe9c..HEAD`: empty diff).
  - `keyshape` is main with `Trace#spine_calls` put back to the v11 key-shape read (a call whose own key matches
    `/\Ar\d+(t\d+)?\z/`). It reproduces the old conduct lambdas exactly: `old → keyshape` moves nothing on
    fan-out-finders or adversarial-verify. So `keyshape → head` is the spine fix alone.
- **Sanity check.** Under the `old` tree, the offline read reproduces all 60 records: verdict, class, conduct, reason
  and conduct reasons, 0 differences (`d_compare.out`, "recorded -> old: 0"). The saved traces are enough to rescore.
- **Independent check.** `d_spine_check.py` recounts the two "itself" checks in plain Python off the graph's `spine`
  mark and each call's `after`, without using the harness.
- **Builder check.** `d_compose_rows.rb` re-evaluates every compose call's script under each tree's `builder.js`.
  The readers themselves re-evaluate scripts only for barrier-free.
- **Missing or raised: none.** All 60 artifacts were found at their recorded paths, and each of the five modes wrote
  60 rows with 0 raised (`d_rescore.log`).

## 2. What moves, by cause

| step (commit) | reader change | records moved | kind of move |
|---|---|---|---|
| `old → v12` (`bf6e5af0`) | **spine-reader fix**: `did_not_search_itself` / `did_not_judge_itself` read `trace.spine_calls`, the kernel's mark, instead of `Gallery.spine?`'s key shape | 15 + 1 reason-only | conduct only; 12 class moves |
| `old → v12` (`bf6e5af0`) | **QueuePass**: loop-until-dry's reach and `one_item_per_pass` read what each bash command did to `queue/` | 4 | reach ×3, success ×3, conduct ×2, class ×2 |
| `v12 → v13pre` (`a8623359`) | **computed-normalise picture**: O7 admits a value stage or tool normaliser, and the executed reading keeps completed stages that placed nothing | 1 + 1 reason-only | success ×1, class ×1 |
| `v13pre → head` (`6c0059e0`) | **S1** (`race_member` refusal in `builder.js`) | 0 | none; the 16 compose rows evaluate identically |
| (all steps) | v12's race reference in `builder.js` | 0 | none |
| `old → v12` | v12's L3 facts `leaked_calls` / `reissued_calls` | 0 verdicts | facts only: `reissued_calls` 0 on 60/60. `leaked_calls` is nil on 60/60 (v11 traces carry no round text) |
| n/a | `bench.yml` cache floors | 0 | v11 → main differs only in the `version:` line, so `cache under floor` reads the same |

### 2.1 Spine-reader fix: 15 records flip a conduct check to pass

`d_spine_check.out` shows how the two readers diverge:

| check | fails by key shape (v11 reader) | fails by spine mark (main) | key-shape calls not made by a spine round |
|---|---|---|---|
| fan-out-finders `did_not_search_itself` | 10/12 | **0/12** | all of them: rounds marked `spine: false` (`rNtM-model-1` roots and delegates' own `rN` rounds) |
| adversarial-verify `did_not_judge_itself` | 12/12 | **7/12** | the refuters' rounds; the 7 that still fail each have 3 `lib/` reads on a spine round |

The same numbers appear in the v11 readout's §7.9 item 4 ("fails 7/12 in v11", "passes 12/12"). They now come from
main's reader itself, not a side script.

| record | recorded | main | class recorded → main |
|---|---|---|---|
| fan-out-finders glm-5.3 #1, #2, #3 | F (3×, 8×, 1× "spine" greps) | T | model conduct → clean (×3) |
| fan-out-finders kimi-k3 #1, #2 | F (9×, 9×) | T | model conduct → **cache under floor** (0.5466, 0.6254 < 0.8) |
| fan-out-finders deepseek-flash #2, #3 | F (7×, 3×) | T | model conduct → clean (×2) |
| fan-out-finders glm-5.3-flash #1, #2, #3 | F (8× each) | T | model conduct → clean (×3) |
| adversarial-verify kimi-k3 #2 | F | T | model conduct → **cache under floor** (0.0455) |
| adversarial-verify glm-5.3-flash #3 | F | T | model conduct → clean |
| adversarial-verify kimi-k3 #1, #3, deepseek-flash #1 | F | T | disagreement → disagreement: the waited fan's receipt reason ranks above conduct |
| adversarial-verify glm-5.3 #1 (reason only) | F | F | none. The reason drops the refuters' absolute `…/lib/*.rb` paths and keeps the spine's own `lib/ledger.rb, lib/rate.rb, lib/wallet.rb` |

After the fix, fan-out-finders passes 12/12 and adversarial-verify 5/12. Of the 7 adversarial runs still failing,
5 also fail success (glm-5.3 #1–#3, deepseek-flash #2, glm-5.3-flash #1). The other two, deepseek-flash #3 and
glm-5.3-flash #2, are the only conduct-only reds left on the spine mark: their spines read `lib/` in rounds the kernel
marks as the spine's own.

### 2.2 QueuePass: 4 loop-until-dry records

| record | recorded | main | why (`d_detail.out`, `d_adv_reasons.out`) |
|---|---|---|---|
| deepseek-flash #1 | r T s T, conduct **F** ("a shell loop over the queue: `for f in results/item-0*.txt; …; ls -A queue/ \| wc -l`"), model conduct | conduct **T**, **clean** | The loop runs over `results/`. The old `LOOP_WORDS` test matched `for` and the word `queue` in the trailing `ls`. QueuePass: 0 loops. |
| deepseek-flash #3 | **r F** ("15 pass(es), 1 item touches"), conduct F | **r T s T**, conduct F, still model conduct | 6 takes are read, where the item-name count saw 1. The conduct stays red for a new reason: "one bash call handles 6 items: `cat queue/item-01.txt; …`" (read_several). |
| glm-5.3-flash #1 | **r F** ("8 pass(es), 0 item touches"), model conduct | **r T s T**, **clean** | Head-pick commands spell no item name. QueuePass reads 6 takes. |
| glm-5.3-flash #3 | **r F** ("4 pass(es), 0 item touches"), conduct F (`ls -1 queue/*.txt \| … head -n 1` matched `queue/*`) | **r T s F** ("loop … never completed on the feed"), conduct **T**, still model conduct | 3 takes. The run was braked at r5 (v11 readout's dated correction), and task_pass is false. |

Minor: QueuePass counts takes as the commands spell them. In glm-5.3 #1 it counts 7 takes from a 6-item queue, because
r7t0 repeats r5t0's `mv queue/item-01.txt …` after a `mkdir -p done`. That touches only the ≥ 2 reach threshold and
changes no verdict here.

### 2.3 Computed-normalise picture (v13): barrier-free glm-5.3 #2

- **#2: red → exact.** The recorded reading was `missing_steps`. The script is one `g.script` stage that places three
  `[fetch tool, value stage]` pairs and a merge stage (the static graph is the single `script-1`). v12's executed
  reading dropped the completed value stages that placed nothing, so it saw 3 tools and a merge. v13 keeps them, and
  the placed graph is exact (`d_detail.out`). The class moves from disagreement to **cache under floor** (0.7935
  against 0.8).
- **#1: reason only.** It moves from `missing_steps` to `over_read`, because the merge model reads the raw fetches
  beside the normalisers. It stays red and stays a disagreement.
- This is exactly bench.yml's VERSION 13 preview ("ONE verdict moves … glm-5.3 #2 (v11) red -> exact"; "v11 glm-5.3 #1,
  `missing_steps` -> `over_read`").

### 2.4 S1 and the v12 race reference: nothing

- **Compose calls.** The 60 traces hold 16 compose calls in 12 records: barrier-free 8 calls in 7 records,
  judge-panel 8 calls in 5 records.
- **Same results under every builder.** Under the fc76e859, bf6e5af0, a8623359 and main `builder.js`, each call builds
  or refuses the same way with the same code (`d_compose_rows_diff.out`: identical three times). Two are refused, and
  both refusals are older than v11: barrier-free deepseek-flash #3 r6t0 is the `tool_reads` text, and judge-panel
  deepseek-flash #2 r4t0 is `member_not_a_step`. Both runs repaired on the next call.
- **No `race_member` refusal.** No v11 workflow script names a member of a formed race, so S1's bucket is empty in
  this family.

## 3. Rescored v11 workflow totals, like-for-like with v13

`d_side_by_side.out`. "v11 on main" is this rescore. v13 is as recorded; its readers are main's.

| model | set | reached | succeeded / reached | task pass | conduct pass | clean | classes |
|---|---|---|---|---|---|---|---|
| glm-5.3 | v11 recorded | 15/15 | 9/15 | 15/15 | 3/9 | 5/15 | cache 1, disagreement 6, model conduct 3 |
| glm-5.3 | **v11 on main** | 15/15 | **10/15** | 15/15 | **6/9** | **8/15** | cache 2, disagreement 5 |
| glm-5.3 | v13 recorded | 14/15 | 11/14 | 15/15 | 8/9 | 6/15 | cache 5, disagreement 3, model conduct 1 |
| kimi-k3 | v11 recorded | 14/15 | 10/14 | 15/15 | 4/9 | 0/15 | cache 7, disagreement 4, model conduct 4 |
| kimi-k3 | **v11 on main** | 14/15 | 10/14 | 15/15 | **9/9** | 0/15 | cache **10**, disagreement 4, model conduct 1 |
| kimi-k3 | v13 recorded | 12/15 | 10/12 | 13/15 | 9/9 | 2/15 | cache 8, model conduct 5 |
| deepseek-flash | v11 recorded | 12/15 | 9/12 | 15/15 | 2/9 | 5/15 | disagreement 3, model conduct 7 |
| deepseek-flash | **v11 on main** | **13/15** | **10/13** | 15/15 | **6/9** | **8/15** | disagreement 3, model conduct 4 |
| deepseek-flash | v13 recorded | 13/15 | 13/13 | 15/15 | 6/9 | 10/15 | model conduct 5 |
| glm-5.3-flash | v11 recorded | 10/15 | 9/10 | 13/15 | 2/9 | 4/15 | model conduct 11 |
| glm-5.3-flash | **v11 on main** | **12/15** | **10/12** | 13/15 | **7/9** | **9/15** | model conduct 6 |
| glm-5.3-flash | v13 recorded | 14/15 | 13/14 | 15/15 | 7/9 | 12/15 | disagreement 1, model conduct 2 |
| **ALL** | v11 recorded | 51/60 | 37/51 | 58/60 | 11/36 | 14/60 | cache 8, disagreement 13, model conduct 25 |
| **ALL** | **v11 on main** | **54/60** | **40/54** | 58/60 | **28/36** | **25/60** | cache **12**, disagreement **12**, model conduct **11** |
| **ALL** | v13 recorded | 53/60 | 47/53 | 58/60 | 30/36 | 30/60 | cache 13, disagreement 4, model conduct 13 |

("cache" is the class `cache under floor`.)

The per-cell table (task × model; reached, succeeded, task pass, conduct, clean) is in `d_side_by_side.out`, which is
reproduced in the appendix. Cells that the rescore moves:

- adversarial-verify:
  - kimi-k3 conduct 0/3 → 3/3.
  - deepseek-flash conduct 0/3 → 1/3.
  - glm-5.3-flash conduct 0/3 → 1/3; clean 0 → 1.
- barrier-free glm-5.3: success 0 → 1.
- fan-out-finders:
  - conduct → 3/3 on all four models.
  - clean → 3 on glm-5.3, deepseek-flash and glm-5.3-flash. kimi-k3 stays at 0: all 3 of its runs are now cache under
    floor.
- loop-until-dry:
  - deepseek-flash: reached 2 → 3, success 2 → 3, conduct 1 → 2, clean 1 → 2.
  - glm-5.3-flash: reached 1 → 3, success 1 → 2, conduct 2 → 3, clean 1 → 2.

What this does to the v11 → v13 reading:

- **Success-when-reached rises either way.** As recorded, v11 → v13 is 37/51 → 47/53. Like-for-like, it is
  **40/54 → 47/53**. 3 of the recorded +10 were readers.
- **Conduct is nearly flat.** As recorded, the gain is 11 → 30. Like-for-like, it is **28 → 30**; 17 of the recorded
  +19 were readers.
- **Clean is 25 → 30, not 14 → 30.**
- **Model-conduct reds rise.** Like-for-like, they go **11 → 13**. As recorded, they appeared to fall 25 → 13.
- **Disagreement falls 12 → 4.** The rescore does not touch it: 7 of v11's 12 disagreements are adversarial-verify
  runs with waited fans (below).
- **kimi-k3 clean stays 0 on v11.** With every conduct check passing, 10 of its 15 records are cache under floor. The
  conduct misread had been hiding 3 of those 10 (fan-out-finders #1, #2; adversarial-verify #2).

## 4. What the rescore does not change

- **adversarial-verify's receipt wording (watcher fact (c)).** Under main's readers, v11 has 8 reds with the reason
  "no input_accepted{origin: task_result}: the kernel mailed no receipt". All 8 are `waited: true` with 0 receipts;
  7 are classed disagreement and 1 model conduct (glm-5.3-flash #1, task pass false) (`d_adv_reasons.out`).
  `receipt_loop` has not changed since v11, so the wording blames the kernel for the model's `wait: true` in both
  columns.
- **Task pass (58/60)** stays as recorded. The verification is not rerun because the projects are gone.
- **The kernel and driver changes** since v11 change what a run does, not how a trace is read, so no offline rescore
  can preview them: v12's attended watch and `<call>` line, and v13's novelty brake, `timeout_ms` rows and S1 as a
  refusal a model would meet. This rescore makes the **readers** like-for-like, not the runs. Watcher fact (e), the
  brake replay, is a kernel question outside this section.

## 5. The draft script (`scratchpad/rescore_v11.rb`): reviewed, left unchanged

Its v11 numbers agree with mine (`d_draft_run.out`): fan-out-finders conduct passes go 2 → 12 and adversarial-verify
0 → 5, and its loop-until-dry reach and conduct match main's. It is correct for what it reads, but it is not a Section
D rescore:

1. It rereads only three tasks' conduct and reach. It never reads barrier-free or judge-panel, never computes success
   or class, and produces no totals.
2. It builds the trace with `Trace.draw(graph, tasks, events, facts:, loops:, spend:)`, without the sealed request and
   without the summaries merged into facts. That differs from `Rescore.trace_of`, the rake rescore's path. It is
   harmless for the checks it reads, but it would be wrong on barrier-free, whose `declared_names` reads the sealed
   request.
3. It also reads v10, the pack labels and a task-family task, all outside this section. It requires `test_helper`
   (minitest autorun; no world boots, 0 runs).

I did not edit it. `d_rescore.rb` replaces it and calls the committed `Rescore.trace_of` / `Rescore.rescored`.

## 6. Owed / open

- **Whether to record the rescored column anywhere.** These numbers exist only as a scratch read. The committed path,
  `rake evals_rescore`, refuses a record of another bench (`bench_digest` c0b22996… ≠ main's ab836ee0…) unless given
  `force`, which is reserved for repairing a harness fault on the record's own bench. The owner decides whether a
  v11 → v13 comparison cites this scratch column, or whether the readout carries both columns with the reason.
- **The adversarial-verify reason text for a waited fan** (fact (c)): a harness wording fix, owed on both columns.

---

## Appendix: scripts and their outputs

To re-run everything: `/private/tmp/claude-501/-Users-jasl-Workspaces-cybros-ai-alt2/fe6d4094-2f85-4b52-abfc-78043a70e275/scratchpad/v13/readout/d_run_all.sh`
(it extracts the three old trees with `git archive` if they are absent, then runs every script below). All files are
in the same directory. Rerunning gives byte-identical `d_compare.out` and `d_steps.out` (md5 checked across three
runs).

In the outputs below, the readout directory prefix is cut for width; the scripts are verbatim.

### Runner

`d_run_all.sh`

```zsh
#!/bin/zsh
# SECTION D: the whole re-read, end to end, offline (no world, no paid call, no test suite).
# Writes only under the readout directory; the repo is read.
set -e
D=/private/tmp/claude-501/-Users-jasl-Workspaces-cybros-ai-alt2/fe6d4094-2f85-4b52-abfc-78043a70e275/scratchpad/v13/readout
REPO=/Users/jasl/Workspaces/cybros-ai.alt2
for c in fc76e859 bf6e5af0 a8623359; do
  [[ -d "$D/old-tree-$c" ]] || { mkdir -p "$D/old-tree-$c"; git -C "$REPO" archive "$c" e2e/support e2e/evals/tasks e2e/evals/bench.yml nexus/lib \
    nexus/app/services/conversations/compaction agents/rho/rho-mcp/test/support | tar -x -C "$D/old-tree-$c"; }
done
cd "$REPO/e2e"
: > "$D/d_rescore.log"
for m in old v12 v13pre keyshape head; do
  BUNDLE_FROZEN=true bundle exec ruby "$D/d_rescore.rb" "$m" "$D/d_rescored_$m.jsonl" 2>> "$D/d_rescore.log"
done
for m in old v12 v13pre head; do
  BUNDLE_FROZEN=true bundle exec ruby "$D/d_compose_rows.rb" "$m" > "$D/d_compose_rows_$m.out"
done
{ for m in v12 v13pre head; do echo "== old vs $m (built/refusal/bucket per compose row; detail text left out):"
    diff <(sed '$d' "$D/d_compose_rows_old.out" | sed 's/ detail=.*//') <(sed '$d' "$D/d_compose_rows_$m.out" | sed 's/ detail=.*//') && echo "identical"
  done; } > "$D/d_compose_rows_diff.out"
BUNDLE_FROZEN=true bundle exec ruby "$D/d_detail.rb" > "$D/d_detail.out"
for s in d_compare d_steps d_facts d_spine_check d_adv_reasons d_reds d_side_by_side; do python3 "$D/$s.py" > "$D/$s.out"; done
"$D/d_git_checks.sh" > "$D/d_git_checks.out"
git -C "$REPO" status --short > "$D/d_repo_status.out"
echo "done; repo status lines: $(wc -l < "$D/d_repo_status.out")"
```

### Git reader-tree checks (script)

`d_git_checks.sh`

```zsh
#!/bin/zsh
# SECTION D: the reader-tree facts the attribution leans on (read-only git).
cd /Users/jasl/Workspaces/cybros-ai.alt2
echo "== readers the workflow family ran on (320d2050) vs the v11 records commit tree (fc76e859):"
git diff --stat 320d2050 fc76e859 -- e2e/support e2e/evals/tasks nexus/lib | cat; echo "(end)"
echo "== v13's run commit (c576fe9c) vs main, reader paths:"
git diff --stat c576fe9c HEAD -- e2e/support e2e/evals/tasks nexus/lib e2e/evals/bench.yml | cat; echo "(end)"
echo "== a8623359 (v13 before S1) vs main, reader paths:"
git diff --stat a8623359 HEAD -- e2e/support e2e/evals/tasks nexus/lib | cat; echo "(end)"
echo "== bench.yml v11 -> main, non-comment lines:"
git diff fc76e859 HEAD -- e2e/evals/bench.yml | grep '^[-+]' | grep -v '^[-+]#' | grep -v '^[-+][-+]' | cat; echo "(end)"
echo "== the commits that landed each reader:"
git log --format='%h %s' -S 'def spine_calls' -- e2e/support/evals/trace.rb | cat
git log --format='%h %s' -- e2e/support/evals/queue_pass.rb | cat
git log --format='%h %s' -S 'computes' -- e2e/support/compose_bench | head -1 | cat
git log --format='%h %s' -S 'race_member' -- e2e/support/compose_bench/buckets.rb | cat
```

### Git reader-tree checks (output)

`d_git_checks.out`

```text
== readers the workflow family ran on (320d2050) vs the v11 records commit tree (fc76e859):
(end)
== v13's run commit (c576fe9c) vs main, reader paths:
(end)
== a8623359 (v13 before S1) vs main, reader paths:
 e2e/evals/tasks/compose-race/RATIONALE.md | 13 ++++++------
 e2e/support/compose_bench/buckets.rb      |  1 +
 nexus/lib/nexus/compose/builder.js        | 34 +++++++++++++++++++++++++++++--
 3 files changed, 40 insertions(+), 8 deletions(-)
(end)
== bench.yml v11 -> main, non-comment lines:
-version: 11
+version: 13
(end)
== the commits that landed each reader:
bf6e5af0 feat: bench version 12 — a race is a result reference, a tool result names its call, every wait answers, and each run is its own
bf6e5af0 feat: bench version 12 — a race is a result reference, a tool result names its call, every wait answers, and each run is its own
a8623359 feat: bench version 13 — the repeat brake reads novelty, the candidates go, and the pairing picture admits a computed normalise
6c0059e0 feat(compose): refuse a reference to a member of a formed race (S1)
```

### The rescore (script)

`d_rescore.rb`

```ruby
# SECTION D: re-score the 60 v11 workflow records OFFLINE over their saved traces, under one reader
# tree, and write one JSON line per record. Never writes into the repo: the committed records are
# read (Records.read), each artifact is read (Rescore.artifact_of / Rescore.trace_of), and the
# lane-shaped record is rebuilt by Rescore.rescored — the pure half of `rake evals_rescore`
# (Rescore.call's only write, Records.append, is never called).
#
#   cd e2e && BUNDLE_FROZEN=true bundle exec ruby <this> <mode> <out.jsonl>
#   mode  head      main's readers (e2e/support, e2e/evals/tasks, bench.yml, nexus/lib/compose)
#         keyshape  main's readers with Trace#spine_calls put back to the v11 key-shape read
#                   (a call keyed /\Ar\d+(t\d+)?\z/), which is exactly what the two v11 conduct
#                   lambdas selected — isolates the spine-reader fix
#         old       the v11 readers: the fc76e859 tree extracted by `git archive` under OLD_TREE
#                   (fc76e859 == 320d2050, the commit the workflow family ran on, for every reader
#                   path — `git diff --stat 320d2050 fc76e859 -- e2e/support e2e/evals/tasks nexus/lib`
#                   is empty)
#         v12       the bf6e5af0 tree (bench version 12's readers: the spine fix, QueuePass, the race
#                   reference in builder.js)
#         v13pre    the a8623359 tree (bench version 13 before S1: the computed-normalise picture);
#                   a8623359 -> main differs in reader paths only by S1 (builder.js, buckets.rb)
# The trees are `git archive <commit> e2e/support e2e/evals/tasks e2e/evals/bench.yml nexus/lib
# nexus/app/services/conversations/compaction agents/rho/rho-mcp/test/support | tar -x -C <dir>`.
require "json"
require "time"

REPO = "/Users/jasl/Workspaces/cybros-ai.alt2".freeze
READOUT = "/private/tmp/claude-501/-Users-jasl-Workspaces-cybros-ai-alt2/fe6d4094-2f85-4b52-abfc-78043a70e275/scratchpad/v13/readout".freeze
TREES = { "old" => "fc76e859", "v12" => "bf6e5af0", "v13pre" => "a8623359" }.freeze
LABEL = "2026-09-24-v11-workflow".freeze
RUN_DIR = File.join(REPO, "e2e/evals/runs", LABEL).freeze
ARTIFACTS = File.join(REPO, "e2e/artifacts/evals").freeze
NOW = Time.utc(2026, 9, 25, 12, 0, 0) # a fixed stamp: the rescored_at field is not read here

mode, out = ARGV
abort "usage: d_rescore.rb head|keyshape|old|v12|v13pre <out.jsonl>" unless (%w[head keyshape] + TREES.keys).include?(mode) && out

root = TREES.key?(mode) ? File.join(READOUT, "old-tree-#{TREES.fetch(mode)}", "e2e") : File.join(REPO, "e2e")
require File.join(root, "support/evals")

if mode == "keyshape"
  E2E::Evals::Trace.class_eval do
    def spine_calls = calls.select { |row| E2E::Gallery::ROUND_KEY.match?(row["key"].to_s) }
  end
end

bench = E2E::Evals::Bench.read
corpus = E2E::Evals::Corpus.load(canary: bench.canary)
records = E2E::Evals::Records.read(RUN_DIR)
warn "#{mode}: tree #{root}, bench #{bench.digest[0, 12]}, #{records.size} records"

FACT_KEYS = %w[door loop_style waited refuters judges per_file usable_on_call picture score tier receipts rounds_settled round_errors leaked_calls reissued_calls].freeze

lines = records.map do |record|
  row = { "task" => record["task"], "model" => record["model"], "run" => record["run"] }
  begin
    artifact = E2E::Evals::Rescore.artifact_of(record, ARTIFACTS, LABEL)
    raise "no artifact for #{record["artifact"]}" if artifact.nil?

    trace = E2E::Evals::Rescore.trace_of(record, artifact)
    fresh = E2E::Evals::Rescore.rescored(record, corpus.find(record.fetch("task")), trace, NOW)
    row.merge("verdict" => fresh["verdict"], "reason" => fresh["reason"], "conduct" => fresh["conduct"],
      "conduct_reasons" => fresh["conduct_reasons"],
      "facts" => Hash(fresh["facts"]).slice(*FACT_KEYS), "spine_calls" => (mode == "old" ? nil : trace.spine_calls.size))
  rescue StandardError, ScriptError => error
    row.merge("raised" => "#{error.class}: #{error.message[0, 300]}", "at" => Array(error.backtrace).first(3))
  end
end

File.write(out, lines.map { |line| JSON.generate(line) }.join("\n") + "\n", encoding: "UTF-8")
raised = lines.count { |line| line.key?("raised") }
warn "#{mode}: wrote #{lines.size} lines to #{out} (#{raised} raised)"
```

### The rescore (stderr of the five modes)

`d_rescore.log`

```text
old: tree old-tree-fc76e859/e2e, bench c0b22996599e, 60 records
old: wrote 60 lines to d_rescored_old.jsonl (0 raised)
v12: tree old-tree-bf6e5af0/e2e, bench 9cea0d0f58a4, 60 records
v12: wrote 60 lines to d_rescored_v12.jsonl (0 raised)
v13pre: tree old-tree-a8623359/e2e, bench 8434f4afc386, 60 records
v13pre: wrote 60 lines to d_rescored_v13pre.jsonl (0 raised)
keyshape: tree /Users/jasl/Workspaces/cybros-ai.alt2/e2e, bench ab836ee0d8be, 60 records
keyshape: wrote 60 lines to d_rescored_keyshape.jsonl (0 raised)
head: tree /Users/jasl/Workspaces/cybros-ai.alt2/e2e, bench ab836ee0d8be, 60 records
head: wrote 60 lines to d_rescored_head.jsonl (0 raised)
```

### Recorded vs the offline reads, and family totals (script)

`d_compare.py`

```python
#!/usr/bin/env python3
"""SECTION D: compare the committed v11 workflow records with the three offline re-scores.

recorded  e2e/evals/runs/2026-09-24-v11-workflow/records.jsonl (read only)
old       d_rescored_old.jsonl       the v11 readers (fc76e859 tree) over the saved traces
keyshape  d_rescored_keyshape.jsonl  main's readers, Trace#spine_calls put back to the key shape
head      d_rescored_head.jsonl      main's readers as they are

Step moves:  recorded->old (must be none: the offline read reproduces the record),
             old->keyshape (every reader change EXCEPT the spine fix),
             keyshape->head (the spine-reader fix alone).
"""
import collections
import json
import sys

REPO = "/Users/jasl/Workspaces/cybros-ai.alt2"
D = "/private/tmp/claude-501/-Users-jasl-Workspaces-cybros-ai-alt2/fe6d4094-2f85-4b52-abfc-78043a70e275/scratchpad/v13/readout"
MODELS = ["openrouter/z-ai/glm-5.3", "openrouter/moonshotai/kimi-k3", "deepseek/deepseek-flash", "openrouter/z-ai/glm-5.3-flash"]
SHORT = {"openrouter/z-ai/glm-5.3": "glm-5.3", "openrouter/moonshotai/kimi-k3": "kimi-k3",
         "deepseek/deepseek-flash": "deepseek-flash", "openrouter/z-ai/glm-5.3-flash": "glm-5.3-flash"}


def load(path):
    with open(path, encoding="utf-8") as f:
        return {(r["task"], r["model"], r["run"]): r for r in (json.loads(l) for l in f if l.strip())}


def view(r):
    v = r.get("verdict") or {}
    return {"reached": v.get("reached"), "succeeded": v.get("succeeded"), "task_pass": v.get("task_pass"),
            "class": v.get("class"), "reason": r.get("reason"), "conduct": r.get("conduct") or {},
            "conduct_reasons": r.get("conduct_reasons") or {}}


rec = load(f"{REPO}/e2e/evals/runs/2026-09-24-v11-workflow/records.jsonl")
modes = {m: load(f"{D}/d_rescored_{m}.jsonl") for m in ("old", "keyshape", "head")}
readings = {"recorded": {k: view(r) for k, r in rec.items()}}
for m, rows in modes.items():
    raised = {k: r["raised"] for k, r in rows.items() if "raised" in r}
    if raised:
        print(f"## {m}: {len(raised)} raised")
        for k, e in sorted(raised.items()):
            print(f"- {k}: {e}")
    readings[m] = {k: view(r) for k, r in rows.items() if "raised" not in r}

keys = sorted(rec, key=lambda k: (k[0], MODELS.index(k[1]), k[2]))
print(f"records {len(rec)}; " + ", ".join(f"{m} {len(readings[m])}" for m in readings))
missing = [k for k in keys if any(k not in readings[m] for m in readings)]
print(f"keys missing from a reading: {missing}")

FIELDS = ["reached", "succeeded", "task_pass", "class", "conduct"]


def diff(a, b):
    out = []
    for f in FIELDS:
        if a[f] != b[f]:
            out.append(f)
    return out


def fmt(x):
    v = x
    c = ",".join(f"{n}={'T' if ok else 'F'}" for n, ok in sorted(v["conduct"].items())) or "-"
    return f"r={v['reached']} s={v['succeeded']} p={v['task_pass']} cls={v['class']} [{c}]"


for a, b in (("recorded", "old"), ("old", "keyshape"), ("keyshape", "head"), ("recorded", "head")):
    moved = [k for k in keys if diff(readings[a][k], readings[b][k])]
    reason_only = [k for k in keys if not diff(readings[a][k], readings[b][k]) and readings[a][k]["reason"] != readings[b][k]["reason"]]
    creason_only = [k for k in keys if not diff(readings[a][k], readings[b][k])
                    and readings[a][k]["conduct_reasons"] != readings[b][k]["conduct_reasons"]]
    print(f"\n## {a} -> {b}: {len(moved)} record(s) move a verdict, class or conduct; "
          f"{len(reason_only)} more change only the reason text; {len(creason_only)} more change only a conduct reason")
    for k in moved:
        x, y = readings[a][k], readings[b][k]
        print(f"- {k[0]} {SHORT[k[1]]} #{k[2]} [{','.join(diff(x, y))}]")
        print(f"    {a:8}: {fmt(x)}")
        print(f"    {b:8}: {fmt(y)}")
        if x["reason"] != y["reason"]:
            print(f"    reason {a}: {str(x['reason'])[:240]!r}")
            print(f"    reason {b}: {str(y['reason'])[:240]!r}")
        for n in sorted(set(x["conduct_reasons"]) | set(y["conduct_reasons"])):
            if x["conduct_reasons"].get(n) != y["conduct_reasons"].get(n):
                print(f"    {n} {a}: {str(x['conduct_reasons'].get(n))[:200]!r}")
                print(f"    {n} {b}: {str(y['conduct_reasons'].get(n))[:200]!r}")
    for k in reason_only:
        x, y = readings[a][k], readings[b][k]
        print(f"  (reason only) {k[0]} {SHORT[k[1]]} #{k[2]}")
        print(f"    reason {a}: {str(x['reason'])[:240]!r}")
        print(f"    reason {b}: {str(y['reason'])[:240]!r}")
    for k in creason_only:
        x, y = readings[a][k], readings[b][k]
        print(f"  (conduct reason only) {k[0]} {SHORT[k[1]]} #{k[2]}: "
              f"{str(x['conduct_reasons'])[:160]!r} -> {str(y['conduct_reasons'])[:160]!r}")


def totals(reading, pred=lambda k: True):
    ks = [k for k in keys if pred(k)]
    rs = [reading[k] for k in ks]
    reached = sum(1 for r in rs if r["reached"])
    succ = sum(1 for r in rs if r["reached"] and r["succeeded"] is True)
    tp = sum(1 for r in rs if r["task_pass"] is True)
    checks = collections.Counter()
    checked = collections.Counter()
    for r in rs:
        for n, ok in r["conduct"].items():
            checked[n] += 1
            checks[n] += 1 if ok else 0
    cls = collections.Counter(r["class"] or "clean" for r in rs)
    return {"n": len(rs), "reached": reached, "succeeded": succ, "task_pass": tp,
            "conduct": {n: f"{checks[n]}/{checked[n]}" for n in sorted(checked)}, "class": dict(sorted(cls.items()))}


print("\n## family totals (workflow, 60 records)")
for m in ("recorded", "old", "keyshape", "head"):
    t = totals(readings[m])
    print(f"- {m:8}: reached {t['reached']}/{t['n']}, succeeded {t['succeeded']}/{t['reached']}, task_pass {t['task_pass']}/{t['n']}, "
          f"conduct pass {t['conduct']}, class {t['class']}")

print("\n## per model, recorded -> head (reached, succeeded/reached, task_pass, conduct pass, clean)")
for model in MODELS:
    a = totals(readings["recorded"], lambda k: k[1] == model)
    b = totals(readings["head"], lambda k: k[1] == model)
    print(f"- {SHORT[model]:15}: reached {a['reached']}->{b['reached']}/{a['n']}, succ {a['succeeded']}/{a['reached']}->{b['succeeded']}/{b['reached']}, "
          f"pass {a['task_pass']}->{b['task_pass']}, conduct {a['conduct']}->{b['conduct']}, "
          f"clean {a['class'].get('clean', 0)}->{b['class'].get('clean', 0)}, classes {a['class']} -> {b['class']}")

print("\n## per task x model, head (reached/succeeded/pass/conduct-pass/clean of 3); '*' marks a cell that differs from recorded")
tasks = sorted({k[0] for k in keys})
for task in tasks:
    cells = []
    for model in MODELS:
        a = totals(readings["recorded"], lambda k: k[0] == task and k[1] == model)
        b = totals(readings["head"], lambda k: k[0] == task and k[1] == model)
        cp = "/".join(v.split("/")[0] for v in b["conduct"].values()) or "-"
        star = "*" if a != b else ""
        cells.append(f"{SHORT[model]} r{b['reached']} s{b['succeeded']} p{b['task_pass']} c{cp} g{b['class'].get('clean', 0)}{star}")
    print(f"- {task}: " + " | ".join(cells))
```

### Recorded vs the offline reads, and family totals (output)

`d_compare.out`

```text
records 60; recorded 60, old 60, keyshape 60, head 60
keys missing from a reading: []

## recorded -> old: 0 record(s) move a verdict, class or conduct; 0 more change only the reason text; 0 more change only a conduct reason

## old -> keyshape: 5 record(s) move a verdict, class or conduct; 1 more change only the reason text; 0 more change only a conduct reason
- workflow-barrier-free-pipeline glm-5.3 #2 [succeeded,class]
    old     : r=True s=False p=True cls=disagreement [-]
    keyshape: r=True s=True p=True cls=cache under floor [-]
    reason old: 'the picture is not the objective\'s (silent: missing_steps): {"nodes" => ["script-1/tool-1:tool", "script-1/tool-2:tool", "script-1/tool-3:tool", "script-1/script-4:script"], "edges" => ["script-1/tool-1->script-1/script-4", "script-1/tool-2'
    reason keyshape: 'None'
- workflow-loop-until-dry deepseek-flash #1 [class,conduct]
    old     : r=True s=True p=True cls=model conduct [one_item_per_pass=F]
    keyshape: r=True s=True p=True cls=None [one_item_per_pass=T]
    one_item_per_pass old: 'a shell loop over the queue: "for f in results/item-0*.txt; do printf \'%s: \' \\"$f\\"; cat \\"$f\\"; done; echo \\"--- queue:\\"; ls -A queue/ | wc -l"'
    one_item_per_pass keyshape: 'None'
- workflow-loop-until-dry deepseek-flash #3 [reached,succeeded]
    old     : r=False s=None p=True cls=model conduct [one_item_per_pass=F]
    keyshape: r=True s=True p=True cls=model conduct [one_item_per_pass=F]
    reason old: 'no iteration: 15 pass(es), 1 item touches ({"bash" => 15})'
    reason keyshape: 'None'
- workflow-loop-until-dry glm-5.3-flash #1 [reached,succeeded,class]
    old     : r=False s=None p=True cls=model conduct [one_item_per_pass=T]
    keyshape: r=True s=True p=True cls=None [one_item_per_pass=T]
    reason old: 'no iteration: 8 pass(es), 0 item touches ({"bash" => 7, "todo_write" => 7})'
    reason keyshape: 'None'
- workflow-loop-until-dry glm-5.3-flash #3 [reached,succeeded,conduct]
    old     : r=False s=None p=False cls=model conduct [one_item_per_pass=F]
    keyshape: r=True s=False p=False cls=model conduct [one_item_per_pass=T]
    reason old: 'no iteration: 4 pass(es), 0 item touches ({"bash" => 4})'
    reason keyshape: 'loop 01a0d1f8-0d06-75e3-a61a-cc3d5205875a never completed on the feed'
    one_item_per_pass old: 'a shell loop over the queue: "f=$(ls -1 queue/*.txt | sort | head -n 1)\\nn=$(cat \\"$f\\")\\necho $((n * 2)) > \\"results/$(basename \\"$f\\")\\"\\nmv \\"$f\\" \\"done/$(bas"'
    one_item_per_pass keyshape: 'None'
  (reason only) workflow-barrier-free-pipeline glm-5.3 #1
    reason old: 'the picture is not the objective\'s (silent: missing_steps): {"nodes" => ["tool-1:tool", "tool-2:tool", "tool-3:tool", "model-1:model"], "edges" => ["tool-1->model-1", "tool-2->model-1", "tool-3->model-1"], "reads" => {"model-1" => ["tool-1"'
    reason keyshape: 'the picture is not the objective\'s (silent: over_read): {"nodes" => ["tool-1:tool", "script-1:script", "tool-2:tool", "script-2:script", "tool-3:tool", "script-3:script", "model-1:model"], "edges" => ["tool-1->script-1", "tool-2->script-2",'

## keyshape -> head: 15 record(s) move a verdict, class or conduct; 0 more change only the reason text; 1 more change only a conduct reason
- workflow-adversarial-verify kimi-k3 #1 [conduct]
    keyshape: r=True s=False p=True cls=disagreement [did_not_judge_itself=F]
    head    : r=True s=False p=True cls=disagreement [did_not_judge_itself=T]
    did_not_judge_itself keyshape: 'the spine read /var/folders/_6/7vgpkxd14klg0lpvxyh5nk2h0000gn/T/rho-evals-e2e20260924-10943-mmnqqn/projects/workflow-adversarial-verify.nexus.1/lib/wallet.rb, /var/folders/_6/7vgpkxd14klg0lpvxyh5nk2h0'
    did_not_judge_itself head: 'None'
- workflow-adversarial-verify kimi-k3 #2 [class,conduct]
    keyshape: r=True s=True p=True cls=model conduct [did_not_judge_itself=F]
    head    : r=True s=True p=True cls=cache under floor [did_not_judge_itself=T]
    did_not_judge_itself keyshape: 'the spine read lib/wallet.rb, lib/ledger.rb, lib/rate.rb itself'
    did_not_judge_itself head: 'None'
- workflow-adversarial-verify kimi-k3 #3 [conduct]
    keyshape: r=True s=False p=True cls=disagreement [did_not_judge_itself=F]
    head    : r=True s=False p=True cls=disagreement [did_not_judge_itself=T]
    did_not_judge_itself keyshape: 'the spine read lib/wallet.rb, lib/ledger.rb, lib/rate.rb itself'
    did_not_judge_itself head: 'None'
- workflow-adversarial-verify deepseek-flash #1 [conduct]
    keyshape: r=True s=False p=True cls=disagreement [did_not_judge_itself=F]
    head    : r=True s=False p=True cls=disagreement [did_not_judge_itself=T]
    did_not_judge_itself keyshape: 'the spine read /var/folders/_6/7vgpkxd14klg0lpvxyh5nk2h0000gn/T/rho-evals-e2e20260924-10943-mmnqqn/projects/workflow-adversarial-verify.nexus.1/lib/wallet.rb, /var/folders/_6/7vgpkxd14klg0lpvxyh5nk2h0'
    did_not_judge_itself head: 'None'
- workflow-adversarial-verify glm-5.3-flash #3 [class,conduct]
    keyshape: r=True s=True p=True cls=model conduct [did_not_judge_itself=F]
    head    : r=True s=True p=True cls=None [did_not_judge_itself=T]
    did_not_judge_itself keyshape: 'the spine read lib/wallet.rb, lib/ledger.rb, lib/rate.rb itself'
    did_not_judge_itself head: 'None'
- workflow-fan-out-finders glm-5.3 #1 [class,conduct]
    keyshape: r=True s=True p=True cls=model conduct [did_not_search_itself=F]
    head    : r=True s=True p=True cls=None [did_not_search_itself=T]
    did_not_search_itself keyshape: 'the spine grepped 3× itself'
    did_not_search_itself head: 'None'
- workflow-fan-out-finders glm-5.3 #2 [class,conduct]
    keyshape: r=True s=True p=True cls=model conduct [did_not_search_itself=F]
    head    : r=True s=True p=True cls=None [did_not_search_itself=T]
    did_not_search_itself keyshape: 'the spine grepped 8× itself'
    did_not_search_itself head: 'None'
- workflow-fan-out-finders glm-5.3 #3 [class,conduct]
    keyshape: r=True s=True p=True cls=model conduct [did_not_search_itself=F]
    head    : r=True s=True p=True cls=None [did_not_search_itself=T]
    did_not_search_itself keyshape: 'the spine grepped 1× itself'
    did_not_search_itself head: 'None'
- workflow-fan-out-finders kimi-k3 #1 [class,conduct]
    keyshape: r=True s=True p=True cls=model conduct [did_not_search_itself=F]
    head    : r=True s=True p=True cls=cache under floor [did_not_search_itself=T]
    did_not_search_itself keyshape: 'the spine grepped 9× itself'
    did_not_search_itself head: 'None'
- workflow-fan-out-finders kimi-k3 #2 [class,conduct]
    keyshape: r=True s=True p=True cls=model conduct [did_not_search_itself=F]
    head    : r=True s=True p=True cls=cache under floor [did_not_search_itself=T]
    did_not_search_itself keyshape: 'the spine grepped 9× itself'
    did_not_search_itself head: 'None'
- workflow-fan-out-finders deepseek-flash #2 [class,conduct]
    keyshape: r=True s=True p=True cls=model conduct [did_not_search_itself=F]
    head    : r=True s=True p=True cls=None [did_not_search_itself=T]
    did_not_search_itself keyshape: 'the spine grepped 7× itself'
    did_not_search_itself head: 'None'
- workflow-fan-out-finders deepseek-flash #3 [class,conduct]
    keyshape: r=True s=True p=True cls=model conduct [did_not_search_itself=F]
    head    : r=True s=True p=True cls=None [did_not_search_itself=T]
    did_not_search_itself keyshape: 'the spine grepped 3× itself'
    did_not_search_itself head: 'None'
- workflow-fan-out-finders glm-5.3-flash #1 [class,conduct]
    keyshape: r=True s=True p=True cls=model conduct [did_not_search_itself=F]
    head    : r=True s=True p=True cls=None [did_not_search_itself=T]
    did_not_search_itself keyshape: 'the spine grepped 8× itself'
    did_not_search_itself head: 'None'
- workflow-fan-out-finders glm-5.3-flash #2 [class,conduct]
    keyshape: r=True s=True p=True cls=model conduct [did_not_search_itself=F]
    head    : r=True s=True p=True cls=None [did_not_search_itself=T]
    did_not_search_itself keyshape: 'the spine grepped 8× itself'
    did_not_search_itself head: 'None'
- workflow-fan-out-finders glm-5.3-flash #3 [class,conduct]
    keyshape: r=True s=True p=True cls=model conduct [did_not_search_itself=F]
    head    : r=True s=True p=True cls=None [did_not_search_itself=T]
    did_not_search_itself keyshape: 'the spine grepped 8× itself'
    did_not_search_itself head: 'None'
  (conduct reason only) workflow-adversarial-verify glm-5.3 #1: "{'did_not_judge_itself': 'the spine read lib/ledger.rb, lib/rate.rb, lib/wallet.rb, /var/folders/_6/7vgpkxd14klg0lpvxyh5nk2h0000gn/T/rho-evals-e2e20260924-10943" -> "{'did_not_judge_itself': 'the spine read lib/ledger.rb, lib/rate.rb, lib/wallet.rb itself'}"

## recorded -> head: 20 record(s) move a verdict, class or conduct; 1 more change only the reason text; 1 more change only a conduct reason
- workflow-adversarial-verify kimi-k3 #1 [conduct]
    recorded: r=True s=False p=True cls=disagreement [did_not_judge_itself=F]
    head    : r=True s=False p=True cls=disagreement [did_not_judge_itself=T]
    did_not_judge_itself recorded: 'the spine read /var/folders/_6/7vgpkxd14klg0lpvxyh5nk2h0000gn/T/rho-evals-e2e20260924-10943-mmnqqn/projects/workflow-adversarial-verify.nexus.1/lib/wallet.rb, /var/folders/_6/7vgpkxd14klg0lpvxyh5nk2h0'
    did_not_judge_itself head: 'None'
- workflow-adversarial-verify kimi-k3 #2 [class,conduct]
    recorded: r=True s=True p=True cls=model conduct [did_not_judge_itself=F]
    head    : r=True s=True p=True cls=cache under floor [did_not_judge_itself=T]
    did_not_judge_itself recorded: 'the spine read lib/wallet.rb, lib/ledger.rb, lib/rate.rb itself'
    did_not_judge_itself head: 'None'
- workflow-adversarial-verify kimi-k3 #3 [conduct]
    recorded: r=True s=False p=True cls=disagreement [did_not_judge_itself=F]
    head    : r=True s=False p=True cls=disagreement [did_not_judge_itself=T]
    did_not_judge_itself recorded: 'the spine read lib/wallet.rb, lib/ledger.rb, lib/rate.rb itself'
    did_not_judge_itself head: 'None'
- workflow-adversarial-verify deepseek-flash #1 [conduct]
    recorded: r=True s=False p=True cls=disagreement [did_not_judge_itself=F]
    head    : r=True s=False p=True cls=disagreement [did_not_judge_itself=T]
    did_not_judge_itself recorded: 'the spine read /var/folders/_6/7vgpkxd14klg0lpvxyh5nk2h0000gn/T/rho-evals-e2e20260924-10943-mmnqqn/projects/workflow-adversarial-verify.nexus.1/lib/wallet.rb, /var/folders/_6/7vgpkxd14klg0lpvxyh5nk2h0'
    did_not_judge_itself head: 'None'
- workflow-adversarial-verify glm-5.3-flash #3 [class,conduct]
    recorded: r=True s=True p=True cls=model conduct [did_not_judge_itself=F]
    head    : r=True s=True p=True cls=None [did_not_judge_itself=T]
    did_not_judge_itself recorded: 'the spine read lib/wallet.rb, lib/ledger.rb, lib/rate.rb itself'
    did_not_judge_itself head: 'None'
- workflow-barrier-free-pipeline glm-5.3 #2 [succeeded,class]
    recorded: r=True s=False p=True cls=disagreement [-]
    head    : r=True s=True p=True cls=cache under floor [-]
    reason recorded: 'the picture is not the objective\'s (silent: missing_steps): {"nodes" => ["script-1/tool-1:tool", "script-1/tool-2:tool", "script-1/tool-3:tool", "script-1/script-4:script"], "edges" => ["script-1/tool-1->script-1/script-4", "script-1/tool-2'
    reason head: 'None'
- workflow-fan-out-finders glm-5.3 #1 [class,conduct]
    recorded: r=True s=True p=True cls=model conduct [did_not_search_itself=F]
    head    : r=True s=True p=True cls=None [did_not_search_itself=T]
    did_not_search_itself recorded: 'the spine grepped 3× itself'
    did_not_search_itself head: 'None'
- workflow-fan-out-finders glm-5.3 #2 [class,conduct]
    recorded: r=True s=True p=True cls=model conduct [did_not_search_itself=F]
    head    : r=True s=True p=True cls=None [did_not_search_itself=T]
    did_not_search_itself recorded: 'the spine grepped 8× itself'
    did_not_search_itself head: 'None'
- workflow-fan-out-finders glm-5.3 #3 [class,conduct]
    recorded: r=True s=True p=True cls=model conduct [did_not_search_itself=F]
    head    : r=True s=True p=True cls=None [did_not_search_itself=T]
    did_not_search_itself recorded: 'the spine grepped 1× itself'
    did_not_search_itself head: 'None'
- workflow-fan-out-finders kimi-k3 #1 [class,conduct]
    recorded: r=True s=True p=True cls=model conduct [did_not_search_itself=F]
    head    : r=True s=True p=True cls=cache under floor [did_not_search_itself=T]
    did_not_search_itself recorded: 'the spine grepped 9× itself'
    did_not_search_itself head: 'None'
- workflow-fan-out-finders kimi-k3 #2 [class,conduct]
    recorded: r=True s=True p=True cls=model conduct [did_not_search_itself=F]
    head    : r=True s=True p=True cls=cache under floor [did_not_search_itself=T]
    did_not_search_itself recorded: 'the spine grepped 9× itself'
    did_not_search_itself head: 'None'
- workflow-fan-out-finders deepseek-flash #2 [class,conduct]
    recorded: r=True s=True p=True cls=model conduct [did_not_search_itself=F]
    head    : r=True s=True p=True cls=None [did_not_search_itself=T]
    did_not_search_itself recorded: 'the spine grepped 7× itself'
    did_not_search_itself head: 'None'
- workflow-fan-out-finders deepseek-flash #3 [class,conduct]
    recorded: r=True s=True p=True cls=model conduct [did_not_search_itself=F]
    head    : r=True s=True p=True cls=None [did_not_search_itself=T]
    did_not_search_itself recorded: 'the spine grepped 3× itself'
    did_not_search_itself head: 'None'
- workflow-fan-out-finders glm-5.3-flash #1 [class,conduct]
    recorded: r=True s=True p=True cls=model conduct [did_not_search_itself=F]
    head    : r=True s=True p=True cls=None [did_not_search_itself=T]
    did_not_search_itself recorded: 'the spine grepped 8× itself'
    did_not_search_itself head: 'None'
- workflow-fan-out-finders glm-5.3-flash #2 [class,conduct]
    recorded: r=True s=True p=True cls=model conduct [did_not_search_itself=F]
    head    : r=True s=True p=True cls=None [did_not_search_itself=T]
    did_not_search_itself recorded: 'the spine grepped 8× itself'
    did_not_search_itself head: 'None'
- workflow-fan-out-finders glm-5.3-flash #3 [class,conduct]
    recorded: r=True s=True p=True cls=model conduct [did_not_search_itself=F]
    head    : r=True s=True p=True cls=None [did_not_search_itself=T]
    did_not_search_itself recorded: 'the spine grepped 8× itself'
    did_not_search_itself head: 'None'
- workflow-loop-until-dry deepseek-flash #1 [class,conduct]
    recorded: r=True s=True p=True cls=model conduct [one_item_per_pass=F]
    head    : r=True s=True p=True cls=None [one_item_per_pass=T]
    one_item_per_pass recorded: 'a shell loop over the queue: "for f in results/item-0*.txt; do printf \'%s: \' \\"$f\\"; cat \\"$f\\"; done; echo \\"--- queue:\\"; ls -A queue/ | wc -l"'
    one_item_per_pass head: 'None'
- workflow-loop-until-dry deepseek-flash #3 [reached,succeeded]
    recorded: r=False s=None p=True cls=model conduct [one_item_per_pass=F]
    head    : r=True s=True p=True cls=model conduct [one_item_per_pass=F]
    reason recorded: 'no iteration: 15 pass(es), 1 item touches ({"bash" => 15})'
    reason head: 'None'
- workflow-loop-until-dry glm-5.3-flash #1 [reached,succeeded,class]
    recorded: r=False s=None p=True cls=model conduct [one_item_per_pass=T]
    head    : r=True s=True p=True cls=None [one_item_per_pass=T]
    reason recorded: 'no iteration: 8 pass(es), 0 item touches ({"bash" => 7, "todo_write" => 7})'
    reason head: 'None'
- workflow-loop-until-dry glm-5.3-flash #3 [reached,succeeded,conduct]
    recorded: r=False s=None p=False cls=model conduct [one_item_per_pass=F]
    head    : r=True s=False p=False cls=model conduct [one_item_per_pass=T]
    reason recorded: 'no iteration: 4 pass(es), 0 item touches ({"bash" => 4})'
    reason head: 'loop 01a0d1f8-0d06-75e3-a61a-cc3d5205875a never completed on the feed'
    one_item_per_pass recorded: 'a shell loop over the queue: "f=$(ls -1 queue/*.txt | sort | head -n 1)\\nn=$(cat \\"$f\\")\\necho $((n * 2)) > \\"results/$(basename \\"$f\\")\\"\\nmv \\"$f\\" \\"done/$(bas"'
    one_item_per_pass head: 'None'
  (reason only) workflow-barrier-free-pipeline glm-5.3 #1
    reason recorded: 'the picture is not the objective\'s (silent: missing_steps): {"nodes" => ["tool-1:tool", "tool-2:tool", "tool-3:tool", "model-1:model"], "edges" => ["tool-1->model-1", "tool-2->model-1", "tool-3->model-1"], "reads" => {"model-1" => ["tool-1"'
    reason head: 'the picture is not the objective\'s (silent: over_read): {"nodes" => ["tool-1:tool", "script-1:script", "tool-2:tool", "script-2:script", "tool-3:tool", "script-3:script", "model-1:model"], "edges" => ["tool-1->script-1", "tool-2->script-2",'
  (conduct reason only) workflow-adversarial-verify glm-5.3 #1: "{'did_not_judge_itself': 'the spine read lib/ledger.rb, lib/rate.rb, lib/wallet.rb, /var/folders/_6/7vgpkxd14klg0lpvxyh5nk2h0000gn/T/rho-evals-e2e20260924-10943" -> "{'did_not_judge_itself': 'the spine read lib/ledger.rb, lib/rate.rb, lib/wallet.rb itself'}"

## family totals (workflow, 60 records)
- recorded: reached 51/60, succeeded 37/51, task_pass 58/60, conduct pass {'did_not_judge_itself': '0/12', 'did_not_search_itself': '2/12', 'one_item_per_pass': '9/12'}, class {'cache under floor': 8, 'clean': 14, 'disagreement': 13, 'model conduct': 25}
- old     : reached 51/60, succeeded 37/51, task_pass 58/60, conduct pass {'did_not_judge_itself': '0/12', 'did_not_search_itself': '2/12', 'one_item_per_pass': '9/12'}, class {'cache under floor': 8, 'clean': 14, 'disagreement': 13, 'model conduct': 25}
- keyshape: reached 54/60, succeeded 40/54, task_pass 58/60, conduct pass {'did_not_judge_itself': '0/12', 'did_not_search_itself': '2/12', 'one_item_per_pass': '11/12'}, class {'cache under floor': 9, 'clean': 16, 'disagreement': 12, 'model conduct': 23}
- head    : reached 54/60, succeeded 40/54, task_pass 58/60, conduct pass {'did_not_judge_itself': '5/12', 'did_not_search_itself': '12/12', 'one_item_per_pass': '11/12'}, class {'cache under floor': 12, 'clean': 25, 'disagreement': 12, 'model conduct': 11}

## per model, recorded -> head (reached, succeeded/reached, task_pass, conduct pass, clean)
- glm-5.3        : reached 15->15/15, succ 9/15->10/15, pass 15->15, conduct {'did_not_judge_itself': '0/3', 'did_not_search_itself': '0/3', 'one_item_per_pass': '3/3'}->{'did_not_judge_itself': '0/3', 'did_not_search_itself': '3/3', 'one_item_per_pass': '3/3'}, clean 5->8, classes {'cache under floor': 1, 'clean': 5, 'disagreement': 6, 'model conduct': 3} -> {'cache under floor': 2, 'clean': 8, 'disagreement': 5}
- kimi-k3        : reached 14->14/15, succ 10/14->10/14, pass 15->15, conduct {'did_not_judge_itself': '0/3', 'did_not_search_itself': '1/3', 'one_item_per_pass': '3/3'}->{'did_not_judge_itself': '3/3', 'did_not_search_itself': '3/3', 'one_item_per_pass': '3/3'}, clean 0->0, classes {'cache under floor': 7, 'disagreement': 4, 'model conduct': 4} -> {'cache under floor': 10, 'disagreement': 4, 'model conduct': 1}
- deepseek-flash : reached 12->13/15, succ 9/12->10/13, pass 15->15, conduct {'did_not_judge_itself': '0/3', 'did_not_search_itself': '1/3', 'one_item_per_pass': '1/3'}->{'did_not_judge_itself': '1/3', 'did_not_search_itself': '3/3', 'one_item_per_pass': '2/3'}, clean 5->8, classes {'clean': 5, 'disagreement': 3, 'model conduct': 7} -> {'clean': 8, 'disagreement': 3, 'model conduct': 4}
- glm-5.3-flash  : reached 10->12/15, succ 9/10->10/12, pass 13->13, conduct {'did_not_judge_itself': '0/3', 'did_not_search_itself': '0/3', 'one_item_per_pass': '2/3'}->{'did_not_judge_itself': '1/3', 'did_not_search_itself': '3/3', 'one_item_per_pass': '3/3'}, clean 4->9, classes {'clean': 4, 'model conduct': 11} -> {'clean': 9, 'model conduct': 6}

## per task x model, head (reached/succeeded/pass/conduct-pass/clean of 3); '*' marks a cell that differs from recorded
- workflow-adversarial-verify: glm-5.3 r3 s0 p3 c0 g0 | kimi-k3 r3 s1 p3 c3 g0* | deepseek-flash r3 s1 p3 c1 g0* | glm-5.3-flash r3 s2 p2 c1 g1*
- workflow-barrier-free-pipeline: glm-5.3 r3 s1 p3 c- g0* | kimi-k3 r2 s0 p3 c- g0 | deepseek-flash r1 s1 p3 c- g1 | glm-5.3-flash r1 s1 p3 c- g1
- workflow-fan-out-finders: glm-5.3 r3 s3 p3 c3 g3* | kimi-k3 r3 s3 p3 c3 g0* | deepseek-flash r3 s3 p3 c3 g3* | glm-5.3-flash r3 s3 p3 c3 g3*
- workflow-judge-panel: glm-5.3 r3 s3 p3 c- g2 | kimi-k3 r3 s3 p3 c- g0 | deepseek-flash r3 s2 p3 c- g2 | glm-5.3-flash r2 s2 p3 c- g2
- workflow-loop-until-dry: glm-5.3 r3 s3 p3 c3 g3 | kimi-k3 r3 s3 p3 c3 g0 | deepseek-flash r3 s3 p3 c2 g2* | glm-5.3-flash r3 s2 p2 c3 g2*
```

### Per-commit attribution (script)

`d_steps.py`

```python
#!/usr/bin/env python3
"""SECTION D: which reader commit moved each v11 workflow record — the chain
old (fc76e859, v11) -> v12 (bf6e5af0) -> v13pre (a8623359) -> head (main, S1 on top),
and, beside it, head against keyshape (main with the v11 key-shape spine read put back).
A move is any change in reached, succeeded, task_pass, class, a conduct value, the reason text
or a conduct reason's text."""
import json

D = "/private/tmp/claude-501/-Users-jasl-Workspaces-cybros-ai-alt2/fe6d4094-2f85-4b52-abfc-78043a70e275/scratchpad/v13/readout"
SHORT = {"openrouter/z-ai/glm-5.3": "glm-5.3", "openrouter/moonshotai/kimi-k3": "kimi-k3",
         "deepseek/deepseek-flash": "deepseek-flash", "openrouter/z-ai/glm-5.3-flash": "glm-5.3-flash"}


def load(mode):
    with open(f"{D}/d_rescored_{mode}.jsonl", encoding="utf-8") as f:
        return {(r["task"], r["model"], r["run"]): r for r in (json.loads(l) for l in f if l.strip())}


def sig(r):
    v = r["verdict"]
    return (v["reached"], v["succeeded"], v["task_pass"], v["class"], json.dumps(r["conduct"], sort_keys=True),
            r.get("reason"), json.dumps(r.get("conduct_reasons"), sort_keys=True))


def picture_bucket(r):
    p = (r.get("facts") or {}).get("picture")
    if not isinstance(p, str):
        return p
    return p.split(":")[0][:90]


chain = ["old", "v12", "v13pre", "head"]
rows = {m: load(m) for m in chain + ["keyshape"]}
for m, rs in rows.items():
    bad = [k for k, r in rs.items() if "raised" in r]
    print(f"{m}: {len(rs)} rows, {len(bad)} raised")

keys = sorted(rows["old"])
for a, b in zip(chain, chain[1:]):
    moved = [k for k in keys if sig(rows[a][k]) != sig(rows[b][k])]
    print(f"\n## {a} -> {b}: {len(moved)} record(s) move")
    for k in moved:
        x, y = rows[a][k], rows[b][k]
        fields = [n for n, i in (("reached", 0), ("succeeded", 1), ("task_pass", 2), ("class", 3), ("conduct", 4),
                                 ("reason", 5), ("conduct_reason", 6)) if sig(x)[i] != sig(y)[i]]
        print(f"- {k[0]} {SHORT[k[1]]} #{k[2]}: {','.join(fields)} | class {x['verdict']['class']} -> {y['verdict']['class']}"
              f" | s {x['verdict']['succeeded']} -> {y['verdict']['succeeded']} | r {x['verdict']['reached']} -> {y['verdict']['reached']}")

moved = [k for k in keys if sig(rows["keyshape"][k]) != sig(rows["head"][k])]
print(f"\n## keyshape -> head (the spine fix alone, on main): {len(moved)} record(s) move")
for k in moved:
    print(f"- {k[0]} {SHORT[k[1]]} #{k[2]}")
moved = [k for k in keys if sig(rows["v12"][k]) != sig(rows["head"][k]) and k[0] in
         ("workflow-fan-out-finders", "workflow-adversarial-verify")]
print(f"\n## v12 -> head on the two spine-read tasks: {len(moved)} record(s) move")

print("\n## barrier-free picture fact (the first compose call's picture reason head) along the chain")
for k in keys:
    if k[0] != "workflow-barrier-free-pipeline":
        continue
    cells = [str(picture_bucket(rows[m][k])) for m in chain]
    tier = (rows["head"][k].get("facts") or {}).get("tier")
    print(f"- {SHORT[k[1]]} #{k[2]} ({tier}, door {rows['head'][k]['facts'].get('door')}): " + " -> ".join(cells))
```

### Per-commit attribution (output)

`d_steps.out`

```text
old: 60 rows, 0 raised
v12: 60 rows, 0 raised
v13pre: 60 rows, 0 raised
head: 60 rows, 0 raised
keyshape: 60 rows, 0 raised

## old -> v12: 20 record(s) move
- workflow-adversarial-verify deepseek-flash #1: conduct,conduct_reason | class disagreement -> disagreement | s False -> False | r True -> True
- workflow-adversarial-verify kimi-k3 #1: conduct,conduct_reason | class disagreement -> disagreement | s False -> False | r True -> True
- workflow-adversarial-verify kimi-k3 #2: class,conduct,conduct_reason | class model conduct -> cache under floor | s True -> True | r True -> True
- workflow-adversarial-verify kimi-k3 #3: conduct,conduct_reason | class disagreement -> disagreement | s False -> False | r True -> True
- workflow-adversarial-verify glm-5.3 #1: conduct_reason | class disagreement -> disagreement | s False -> False | r True -> True
- workflow-adversarial-verify glm-5.3-flash #3: class,conduct,conduct_reason | class model conduct -> None | s True -> True | r True -> True
- workflow-fan-out-finders deepseek-flash #2: class,conduct,conduct_reason | class model conduct -> None | s True -> True | r True -> True
- workflow-fan-out-finders deepseek-flash #3: class,conduct,conduct_reason | class model conduct -> None | s True -> True | r True -> True
- workflow-fan-out-finders kimi-k3 #1: class,conduct,conduct_reason | class model conduct -> cache under floor | s True -> True | r True -> True
- workflow-fan-out-finders kimi-k3 #2: class,conduct,conduct_reason | class model conduct -> cache under floor | s True -> True | r True -> True
- workflow-fan-out-finders glm-5.3 #1: class,conduct,conduct_reason | class model conduct -> None | s True -> True | r True -> True
- workflow-fan-out-finders glm-5.3 #2: class,conduct,conduct_reason | class model conduct -> None | s True -> True | r True -> True
- workflow-fan-out-finders glm-5.3 #3: class,conduct,conduct_reason | class model conduct -> None | s True -> True | r True -> True
- workflow-fan-out-finders glm-5.3-flash #1: class,conduct,conduct_reason | class model conduct -> None | s True -> True | r True -> True
- workflow-fan-out-finders glm-5.3-flash #2: class,conduct,conduct_reason | class model conduct -> None | s True -> True | r True -> True
- workflow-fan-out-finders glm-5.3-flash #3: class,conduct,conduct_reason | class model conduct -> None | s True -> True | r True -> True
- workflow-loop-until-dry deepseek-flash #1: class,conduct,conduct_reason | class model conduct -> None | s True -> True | r True -> True
- workflow-loop-until-dry deepseek-flash #3: reached,succeeded,reason | class model conduct -> model conduct | s None -> True | r False -> True
- workflow-loop-until-dry glm-5.3-flash #1: reached,succeeded,class,reason | class model conduct -> None | s None -> True | r False -> True
- workflow-loop-until-dry glm-5.3-flash #3: reached,succeeded,conduct,reason,conduct_reason | class model conduct -> model conduct | s None -> False | r False -> True

## v12 -> v13pre: 2 record(s) move
- workflow-barrier-free-pipeline glm-5.3 #1: reason | class disagreement -> disagreement | s False -> False | r True -> True
- workflow-barrier-free-pipeline glm-5.3 #2: succeeded,class,reason | class disagreement -> cache under floor | s False -> True | r True -> True

## v13pre -> head: 0 record(s) move

## keyshape -> head (the spine fix alone, on main): 16 record(s) move
- workflow-adversarial-verify deepseek-flash #1
- workflow-adversarial-verify kimi-k3 #1
- workflow-adversarial-verify kimi-k3 #2
- workflow-adversarial-verify kimi-k3 #3
- workflow-adversarial-verify glm-5.3 #1
- workflow-adversarial-verify glm-5.3-flash #3
- workflow-fan-out-finders deepseek-flash #2
- workflow-fan-out-finders deepseek-flash #3
- workflow-fan-out-finders kimi-k3 #1
- workflow-fan-out-finders kimi-k3 #2
- workflow-fan-out-finders glm-5.3 #1
- workflow-fan-out-finders glm-5.3 #2
- workflow-fan-out-finders glm-5.3 #3
- workflow-fan-out-finders glm-5.3-flash #1
- workflow-fan-out-finders glm-5.3-flash #2
- workflow-fan-out-finders glm-5.3-flash #3

## v12 -> head on the two spine-read tasks: 0 record(s) move

## barrier-free picture fact (the first compose call's picture reason head) along the chain
- deepseek-flash #1 (floor, door None): no compose call to score -> no compose call to score -> no compose call to score -> no compose call to score
- deepseek-flash #2 (floor, door None): no compose call to score -> no compose call to score -> no compose call to score -> no compose call to score
- deepseek-flash #3 (floor, door compose): the script was refused script_error -> the script was refused script_error -> the script was refused script_error -> the script was refused script_error
- kimi-k3 #1 (strong, door compose): the picture is not the objective's (silent -> the picture is not the objective's (silent -> the picture is not the objective's (silent -> the picture is not the objective's (silent
- kimi-k3 #2 (strong, door None): no compose call to score -> no compose call to score -> no compose call to score -> no compose call to score
- kimi-k3 #3 (strong, door compose): the picture is not the objective's (silent -> the picture is not the objective's (silent -> the picture is not the objective's (silent -> the picture is not the objective's (silent
- glm-5.3 #1 (strong, door compose): the picture is not the objective's (silent -> the picture is not the objective's (silent -> the picture is not the objective's (silent -> the picture is not the objective's (silent
- glm-5.3 #2 (strong, door compose): the picture is not the objective's (silent -> the picture is not the objective's (silent -> True -> True
- glm-5.3 #3 (strong, door compose): the picture is not the objective's (silent -> the picture is not the objective's (silent -> the picture is not the objective's (silent -> the picture is not the objective's (silent
- glm-5.3-flash #1 (floor, door None): no compose call to score -> no compose call to score -> no compose call to score -> no compose call to score
- glm-5.3-flash #2 (floor, door None): no compose call to score -> no compose call to score -> no compose call to score -> no compose call to score
- glm-5.3-flash #3 (floor, door compose): the picture is not the objective's (silent -> the picture is not the objective's (silent -> the picture is not the objective's (silent -> the picture is not the objective's (silent
```

### Facts along the chain (script)

`d_facts.py`

```python
#!/usr/bin/env python3
"""SECTION D: the task-computed facts (door, loop_style, waited, refuters, judges, per_file,
usable_on_call, picture, score, ...) along the reader chain old -> v12 -> v13pre -> head, for
every record — a fact is never a pass condition, but a builder change (v12's race reference,
S1) would show here first, on the floor's usable read and the score's refusal bucket."""
import json

D = "/private/tmp/claude-501/-Users-jasl-Workspaces-cybros-ai-alt2/fe6d4094-2f85-4b52-abfc-78043a70e275/scratchpad/v13/readout"
SHORT = {"openrouter/z-ai/glm-5.3": "glm-5.3", "openrouter/moonshotai/kimi-k3": "kimi-k3",
         "deepseek/deepseek-flash": "deepseek-flash", "openrouter/z-ai/glm-5.3-flash": "glm-5.3-flash"}
chain = ["old", "v12", "v13pre", "head"]


def load(mode):
    with open(f"{D}/d_rescored_{mode}.jsonl", encoding="utf-8") as f:
        return {(r["task"], r["model"], r["run"]): r for r in (json.loads(l) for l in f if l.strip())}


rows = {m: load(m) for m in chain}
keys = sorted(rows["old"])
for a, b in zip(chain, chain[1:]):
    print(f"## {a} -> {b}")
    n = 0
    for k in keys:
        fa, fb = rows[a][k].get("facts") or {}, rows[b][k].get("facts") or {}
        for name in sorted(set(fa) | set(fb)):
            if fa.get(name) != fb.get(name):
                n += 1
                sa, sb = json.dumps(fa.get(name))[:150], json.dumps(fb.get(name))[:150]
                print(f"- {k[0]} {SHORT[k[1]]} #{k[2]} {name}: {sa} -> {sb}")
    print(f"  ({n} fact change(s))")

print("## score fact on every composed barrier-free record, head: valid_first / first_time_right / refusal / silent")
for k in keys:
    s = (rows["head"][k].get("facts") or {}).get("score")
    if k[0] == "workflow-barrier-free-pipeline" and isinstance(s, dict):
        print(f"- {SHORT[k[1]]} #{k[2]}: valid_first={s.get('valid_first')} ftr={s.get('first_time_right')} "
              f"refusal={s.get('refusal')} silent={s.get('silent')} usable_on_call={rows['head'][k]['facts'].get('usable_on_call')}")

import collections
print("## the two v12 call-count facts on the 60 records under main's readers")
print("leaked_calls:", dict(collections.Counter(str((r.get("facts") or {}).get("leaked_calls")) for r in rows["head"].values())),
      "reissued_calls:", dict(collections.Counter(str((r.get("facts") or {}).get("reissued_calls")) for r in rows["head"].values())))
```

### Facts along the chain (output)

`d_facts.out`

```text
## old -> v12
- workflow-adversarial-verify deepseek-flash #1 reissued_calls: null -> 0
- workflow-adversarial-verify deepseek-flash #2 reissued_calls: null -> 0
- workflow-adversarial-verify deepseek-flash #3 reissued_calls: null -> 0
- workflow-adversarial-verify kimi-k3 #1 reissued_calls: null -> 0
- workflow-adversarial-verify kimi-k3 #2 reissued_calls: null -> 0
- workflow-adversarial-verify kimi-k3 #3 reissued_calls: null -> 0
- workflow-adversarial-verify glm-5.3 #1 reissued_calls: null -> 0
- workflow-adversarial-verify glm-5.3 #2 reissued_calls: null -> 0
- workflow-adversarial-verify glm-5.3 #3 reissued_calls: null -> 0
- workflow-adversarial-verify glm-5.3-flash #1 reissued_calls: null -> 0
- workflow-adversarial-verify glm-5.3-flash #2 reissued_calls: null -> 0
- workflow-adversarial-verify glm-5.3-flash #3 reissued_calls: null -> 0
- workflow-barrier-free-pipeline deepseek-flash #1 reissued_calls: null -> 0
- workflow-barrier-free-pipeline deepseek-flash #2 reissued_calls: null -> 0
- workflow-barrier-free-pipeline deepseek-flash #3 reissued_calls: null -> 0
- workflow-barrier-free-pipeline kimi-k3 #1 reissued_calls: null -> 0
- workflow-barrier-free-pipeline kimi-k3 #2 reissued_calls: null -> 0
- workflow-barrier-free-pipeline kimi-k3 #3 reissued_calls: null -> 0
- workflow-barrier-free-pipeline glm-5.3 #1 reissued_calls: null -> 0
- workflow-barrier-free-pipeline glm-5.3 #2 reissued_calls: null -> 0
- workflow-barrier-free-pipeline glm-5.3 #3 reissued_calls: null -> 0
- workflow-barrier-free-pipeline glm-5.3-flash #1 reissued_calls: null -> 0
- workflow-barrier-free-pipeline glm-5.3-flash #2 reissued_calls: null -> 0
- workflow-barrier-free-pipeline glm-5.3-flash #3 reissued_calls: null -> 0
- workflow-fan-out-finders deepseek-flash #1 reissued_calls: null -> 0
- workflow-fan-out-finders deepseek-flash #2 reissued_calls: null -> 0
- workflow-fan-out-finders deepseek-flash #3 reissued_calls: null -> 0
- workflow-fan-out-finders kimi-k3 #1 reissued_calls: null -> 0
- workflow-fan-out-finders kimi-k3 #2 reissued_calls: null -> 0
- workflow-fan-out-finders kimi-k3 #3 reissued_calls: null -> 0
- workflow-fan-out-finders glm-5.3 #1 reissued_calls: null -> 0
- workflow-fan-out-finders glm-5.3 #2 reissued_calls: null -> 0
- workflow-fan-out-finders glm-5.3 #3 reissued_calls: null -> 0
- workflow-fan-out-finders glm-5.3-flash #1 reissued_calls: null -> 0
- workflow-fan-out-finders glm-5.3-flash #2 reissued_calls: null -> 0
- workflow-fan-out-finders glm-5.3-flash #3 reissued_calls: null -> 0
- workflow-judge-panel deepseek-flash #1 reissued_calls: null -> 0
- workflow-judge-panel deepseek-flash #2 reissued_calls: null -> 0
- workflow-judge-panel deepseek-flash #3 reissued_calls: null -> 0
- workflow-judge-panel kimi-k3 #1 reissued_calls: null -> 0
- workflow-judge-panel kimi-k3 #2 reissued_calls: null -> 0
- workflow-judge-panel kimi-k3 #3 reissued_calls: null -> 0
- workflow-judge-panel glm-5.3 #1 reissued_calls: null -> 0
- workflow-judge-panel glm-5.3 #2 reissued_calls: null -> 0
- workflow-judge-panel glm-5.3 #3 reissued_calls: null -> 0
- workflow-judge-panel glm-5.3-flash #1 reissued_calls: null -> 0
- workflow-judge-panel glm-5.3-flash #2 reissued_calls: null -> 0
- workflow-judge-panel glm-5.3-flash #3 reissued_calls: null -> 0
- workflow-loop-until-dry deepseek-flash #1 reissued_calls: null -> 0
- workflow-loop-until-dry deepseek-flash #2 reissued_calls: null -> 0
- workflow-loop-until-dry deepseek-flash #3 reissued_calls: null -> 0
- workflow-loop-until-dry kimi-k3 #1 reissued_calls: null -> 0
- workflow-loop-until-dry kimi-k3 #2 reissued_calls: null -> 0
- workflow-loop-until-dry kimi-k3 #3 reissued_calls: null -> 0
- workflow-loop-until-dry glm-5.3 #1 reissued_calls: null -> 0
- workflow-loop-until-dry glm-5.3 #2 reissued_calls: null -> 0
- workflow-loop-until-dry glm-5.3 #3 reissued_calls: null -> 0
- workflow-loop-until-dry glm-5.3-flash #1 reissued_calls: null -> 0
- workflow-loop-until-dry glm-5.3-flash #2 reissued_calls: null -> 0
- workflow-loop-until-dry glm-5.3-flash #3 reissued_calls: null -> 0
  (60 fact change(s))
## v12 -> v13pre
- workflow-barrier-free-pipeline glm-5.3 #1 picture: "the picture is not the objective's (silent: missing_steps): {\"nodes\" => [\"tool-1:tool\", \"tool-2:tool\", \"tool-3:tool\", \"model-1:model\"], \"e -> "the picture is not the objective's (silent: over_read): {\"nodes\" => [\"tool-1:tool\", \"script-1:script\", \"tool-2:tool\", \"script-2:script\", \"
- workflow-barrier-free-pipeline glm-5.3 #1 score: {"valid_first": true, "steps": [{"parallel": [[{"tool": {"key": "tool-1", "name": "bash", "input": {"command": "sh bin/fetch a"}}}, {"script": {"key": -> {"valid_first": true, "steps": [{"parallel": [[{"tool": {"key": "tool-1", "name": "bash", "input": {"command": "sh bin/fetch a"}}}, {"script": {"key":
- workflow-barrier-free-pipeline glm-5.3 #2 picture: "the picture is not the objective's (silent: missing_steps): {\"nodes\" => [\"script-1/tool-1:tool\", \"script-1/tool-2:tool\", \"script-1/tool-3:tool -> true
- workflow-barrier-free-pipeline glm-5.3 #2 score: {"valid_first": true, "steps": [{"script": {"key": "script-1", "script": "var NORM = \"var r = results[0];\\nif (!r || r.status !== 'completed' || r.i -> {"valid_first": true, "steps": [{"script": {"key": "script-1", "script": "var NORM = \"var r = results[0];\\nif (!r || r.status !== 'completed' || r.i
  (4 fact change(s))
## v13pre -> head
  (0 fact change(s))
## score fact on every composed barrier-free record, head: valid_first / first_time_right / refusal / silent
- deepseek-flash #3: valid_first=False ftr=False refusal=script_error silent=None usable_on_call=2
- kimi-k3 #1: valid_first=True ftr=False refusal=None silent=['edit_as_tool', 'missing_steps'] usable_on_call=1
- kimi-k3 #3: valid_first=True ftr=False refusal=None silent=['edit_as_tool', 'missing_steps'] usable_on_call=1
- glm-5.3 #1: valid_first=True ftr=False refusal=None silent=['over_read'] usable_on_call=1
- glm-5.3 #2: valid_first=True ftr=True refusal=None silent=[] usable_on_call=1
- glm-5.3 #3: valid_first=True ftr=False refusal=None silent=['edit_as_tool'] usable_on_call=1
- glm-5.3-flash #3: valid_first=True ftr=False refusal=None silent=['edit_as_tool'] usable_on_call=1
## the two v12 call-count facts on the 60 records under main's readers
leaked_calls: {'None': 60} reissued_calls: {'0': 60}
```

### Independent spine recount (script)

`d_spine_check.py`

```python
#!/usr/bin/env python3
"""SECTION D: an independent read of the two "itself" checks over the saved v11 traces, in
plain Python (no harness code): per record, the calls the v11 reader counted (the call's own key
matches /^r\\d+(t\\d+)?$/) against the calls a round the graph marks `spine: true` made (the
call's `after` names a spine-marked round) — greps for fan-out-finders, reads of a lib/ path for
adversarial-verify — and, for the key-shape calls that are not the spine's, which round made them."""
import glob
import json
import re

ART = "/Users/jasl/Workspaces/cybros-ai.alt2/e2e/artifacts/evals/2026-09-24-v11-workflow"
ROUND_KEY = re.compile(r"\Ar\d+(?:t\d+)?\Z")
SHORT = {"openrouter_z-ai_glm-5.3": "glm-5.3", "openrouter_moonshotai_kimi-k3": "kimi-k3",
         "deepseek_deepseek-flash": "deepseek-flash", "openrouter_z-ai_glm-5.3-flash": "glm-5.3-flash"}
CHECKS = {
    "workflow-fan-out-finders": ("did_not_search_itself", lambda t: t.get("tool_name") == "grep"),
    "workflow-adversarial-verify": ("did_not_judge_itself",
                                     lambda t: t.get("tool_name") == "read" and "lib/" in str((t.get("tool_input") or {}).get("path", ""))),
}
totals = {}
for task, (check, pick) in CHECKS.items():
    print(f"## {task} ({check})")
    fail_key = fail_mark = 0
    for path in sorted(glob.glob(f"{ART}/{task}.*.json")):
        with open(path, encoding="utf-8") as f:
            d = json.load(f)
        spine = {n["key"] for n in d["graph"]["nodes"] if n.get("spine") is True}
        kinds = {n["key"]: n.get("kind") for n in d["graph"]["nodes"]}
        calls = [t for t in d["tasks"] if t.get("kind") == "tool_task" and pick(t)]
        by_key = [t for t in calls if ROUND_KEY.match(t["key"])]
        by_mark = [t for t in calls if set(t.get("after") or []) & spine]
        makers = sorted({a for t in by_key if not (set(t.get("after") or []) & spine) for a in (t.get("after") or [])})
        recorded = d["record"].get("conduct", {}).get(check)
        base = path.rsplit("/", 1)[1][len(task) + 1:-len(".json")]  # <slug>.nexus.<n>
        slug, _style, run = base.rsplit(".", 2)
        name = f"{SHORT[slug]} #{run}"
        fail_key += bool(by_key)
        fail_mark += bool(by_mark)
        print(f"- {name}: recorded {recorded}; key-shape {len(by_key)} (fails={bool(by_key)}), spine-mark {len(by_mark)} "
              f"(fails={bool(by_mark)}); non-spine makers of the key-shape calls: {len(makers)} rounds, "
              f"marked spine:false {sum(1 for m in makers if m not in spine)}, e.g. {makers[:3]}")
    print(f"  fails by key shape {fail_key}/12, by spine mark {fail_mark}/12")
```

### Independent spine recount (output)

`d_spine_check.out`

```text
## workflow-fan-out-finders (did_not_search_itself)
- deepseek-flash #1: recorded True; key-shape 0 (fails=False), spine-mark 0 (fails=False); non-spine makers of the key-shape calls: 0 rounds, marked spine:false 0, e.g. []
- deepseek-flash #2: recorded False; key-shape 7 (fails=True), spine-mark 0 (fails=False); non-spine makers of the key-shape calls: 7 rounds, marked spine:false 7, e.g. ['r3t0-model-1', 'r3t1-model-1', 'r3t2-model-1']
- deepseek-flash #3: recorded False; key-shape 3 (fails=True), spine-mark 0 (fails=False); non-spine makers of the key-shape calls: 3 rounds, marked spine:false 3, e.g. ['r14t0-model-1', 'r3t5-model-1', 'r3t6-model-1']
- kimi-k3 #1: recorded False; key-shape 9 (fails=True), spine-mark 0 (fails=False); non-spine makers of the key-shape calls: 9 rounds, marked spine:false 9, e.g. ['r12', 'r3t0-model-1', 'r3t1-model-1']
- kimi-k3 #2: recorded False; key-shape 9 (fails=True), spine-mark 0 (fails=False); non-spine makers of the key-shape calls: 9 rounds, marked spine:false 9, e.g. ['r10', 'r3t0-model-1', 'r3t1-model-1']
- kimi-k3 #3: recorded True; key-shape 0 (fails=False), spine-mark 0 (fails=False); non-spine makers of the key-shape calls: 0 rounds, marked spine:false 0, e.g. []
- glm-5.3-flash #1: recorded False; key-shape 8 (fails=True), spine-mark 0 (fails=False); non-spine makers of the key-shape calls: 8 rounds, marked spine:false 8, e.g. ['r3t0-model-1', 'r3t1-model-1', 'r3t2-model-1']
- glm-5.3-flash #2: recorded False; key-shape 8 (fails=True), spine-mark 0 (fails=False); non-spine makers of the key-shape calls: 8 rounds, marked spine:false 8, e.g. ['r3t0-model-1', 'r3t1-model-1', 'r3t2-model-1']
- glm-5.3-flash #3: recorded False; key-shape 8 (fails=True), spine-mark 0 (fails=False); non-spine makers of the key-shape calls: 8 rounds, marked spine:false 8, e.g. ['r3t1-model-1', 'r3t2-model-1', 'r3t3-model-1']
- glm-5.3 #1: recorded False; key-shape 3 (fails=True), spine-mark 0 (fails=False); non-spine makers of the key-shape calls: 3 rounds, marked spine:false 3, e.g. ['r3t2-model-1', 'r3t3-model-1', 'r3t4-model-1']
- glm-5.3 #2: recorded False; key-shape 8 (fails=True), spine-mark 0 (fails=False); non-spine makers of the key-shape calls: 8 rounds, marked spine:false 8, e.g. ['r3t0-model-1', 'r3t1-model-1', 'r3t2-model-1']
- glm-5.3 #3: recorded False; key-shape 1 (fails=True), spine-mark 0 (fails=False); non-spine makers of the key-shape calls: 1 rounds, marked spine:false 1, e.g. ['r6']
  fails by key shape 10/12, by spine mark 0/12
## workflow-adversarial-verify (did_not_judge_itself)
- deepseek-flash #1: recorded False; key-shape 35 (fails=True), spine-mark 0 (fails=False); non-spine makers of the key-shape calls: 24 rounds, marked spine:false 24, e.g. ['r10', 'r11', 'r12']
- deepseek-flash #2: recorded False; key-shape 3 (fails=True), spine-mark 3 (fails=True); non-spine makers of the key-shape calls: 0 rounds, marked spine:false 0, e.g. []
- deepseek-flash #3: recorded False; key-shape 24 (fails=True), spine-mark 3 (fails=True); non-spine makers of the key-shape calls: 16 rounds, marked spine:false 16, e.g. ['r14', 'r17', 'r5t1-model-1']
- kimi-k3 #1: recorded False; key-shape 30 (fails=True), spine-mark 0 (fails=False); non-spine makers of the key-shape calls: 13 rounds, marked spine:false 13, e.g. ['r4t0-model-1', 'r4t1-model-1', 'r4t10-model-1']
- kimi-k3 #2: recorded False; key-shape 19 (fails=True), spine-mark 0 (fails=False); non-spine makers of the key-shape calls: 14 rounds, marked spine:false 14, e.g. ['r13', 'r17', 'r3t0-model-1']
- kimi-k3 #3: recorded False; key-shape 34 (fails=True), spine-mark 0 (fails=False); non-spine makers of the key-shape calls: 13 rounds, marked spine:false 13, e.g. ['r14', 'r3t0-model-1', 'r3t1-model-1']
- glm-5.3-flash #1: recorded False; key-shape 38 (fails=True), spine-mark 3 (fails=True); non-spine makers of the key-shape calls: 15 rounds, marked spine:false 15, e.g. ['r13', 'r16', 'r4t10-model-1']
- glm-5.3-flash #2: recorded False; key-shape 26 (fails=True), spine-mark 3 (fails=True); non-spine makers of the key-shape calls: 13 rounds, marked spine:false 13, e.g. ['r11', 'r3t1-model-1', 'r3t10-model-1']
- glm-5.3-flash #3: recorded False; key-shape 36 (fails=True), spine-mark 0 (fails=False); non-spine makers of the key-shape calls: 12 rounds, marked spine:false 12, e.g. ['r4t0-model-1', 'r4t1-model-1', 'r4t10-model-1']
- glm-5.3 #1: recorded False; key-shape 36 (fails=True), spine-mark 3 (fails=True); non-spine makers of the key-shape calls: 22 rounds, marked spine:false 22, e.g. ['r10', 'r11', 'r12']
- glm-5.3 #2: recorded False; key-shape 42 (fails=True), spine-mark 3 (fails=True); non-spine makers of the key-shape calls: 15 rounds, marked spine:false 15, e.g. ['r11', 'r15', 'r4t0-model-1']
- glm-5.3 #3: recorded False; key-shape 19 (fails=True), spine-mark 3 (fails=True); non-spine makers of the key-shape calls: 15 rounds, marked spine:false 15, e.g. ['r4t1-model-1', 'r4t10-model-1', 'r4t11-model-1']
  fails by key shape 12/12, by spine mark 7/12
```

### Detail: QueuePass, the barrier-free pictures, the cache rates (script)

`d_detail.rb`

```ruby
# SECTION D: the detail behind each moved record, read with main's readers over the saved traces
# (no write anywhere but stdout):
#   - loop-until-dry: every bash call's QueuePass reading (took / looped / read several) and the
#     head reach inputs (passes, took, receipts), for the 12 records;
#   - barrier-free glm-5.3 #1/#2: main's picture reading (the executed graph and its silent buckets);
#   - every record main classes `cache under floor`: the after-round-1 rate against the floor
#     (Scorecard.cache_under_floor, the reader the class comes from).
#   cd e2e && BUNDLE_FROZEN=true bundle exec ruby <this>
require "json"
REPO = "/Users/jasl/Workspaces/cybros-ai.alt2".freeze
require File.join(REPO, "e2e/support/evals")
LABEL = "2026-09-24-v11-workflow".freeze
ARTIFACTS = File.join(REPO, "e2e/artifacts/evals").freeze
bench = E2E::Evals::Bench.read
corpus = E2E::Evals::Corpus.load(canary: bench.canary)
records = E2E::Evals::Records.read(File.join(REPO, "e2e/evals/runs", LABEL))
short = ->(model) { model.split("/").last }
trace_of = ->(record) { E2E::Evals::Rescore.trace_of(record, E2E::Evals::Rescore.artifact_of(record, ARTIFACTS, LABEL)) }

puts "## loop-until-dry: QueuePass per bash call (main's reader)"
records.select { |r| r["task"] == "workflow-loop-until-dry" }.sort_by { |r| [r["model"], r["run"]] }.each do |record|
  trace = trace_of.(record)
  readings = E2E::Evals::Predicates.queue_readings(trace, "queue")
  took = readings.count { |_c, pass| pass.took? }
  fanning = trace.spine_rounds.count { |round| trace.fanned_by(round["key"]).any? }
  passes = [fanning, trace.receipts + 1, trace.compose_rows.size].max
  verdict = corpus.find(record["task"]).expected.verdict(trace)
  puts "- #{short.(record["model"])} ##{record["run"]}: bash #{readings.size}, took #{took}, receipts #{trace.receipts}, passes #{passes}, " \
       "looped #{readings.count { |_c, p| p.looped }}, several #{readings.count { |_c, p| p.several? }}, " \
       "read_several #{readings.count { |_c, p| p.read_several? }} | reach #{verdict.reached} #{verdict.reason.to_s[0, 90]} | " \
       "conduct #{verdict.conduct["one_item_per_pass"].to_s[0, 140]}"
end

puts "\n## barrier-free glm-5.3 #1 and #2: main's picture reading"
records.select { |r| r["task"] == "workflow-barrier-free-pipeline" && r["model"].end_with?("glm-5.3") }.sort_by { |r| r["run"] }.first(2).each do |record|
  trace = trace_of.(record)
  score = E2E::Evals::Predicates.score_compose(trace, "O7")
  puts "- ##{record["run"]}: first_time_right #{score["first_time_right"]}, silent #{Array(score["silent"]).inspect}"
  puts "  graph #{score["graph"].inspect[0, 900]}"
  puts "  static graph #{Hash(score["static"])["graph"].inspect[0, 400]}" if score["static"]
end

puts "\n## records main classes `cache under floor`: the after-round-1 rate against the family floor"
head = File.readlines("/private/tmp/claude-501/-Users-jasl-Workspaces-cybros-ai-alt2/fe6d4094-2f85-4b52-abfc-78043a70e275/scratchpad/v13/readout/d_rescored_head.jsonl", encoding: "UTF-8")
  .map { |l| JSON.parse(l) }.to_h { |r| [[r["task"], r["model"], r["run"]], r] }
records.sort_by { |r| [r["task"], r["model"], r["run"]] }.each do |record|
  row = head.fetch([record["task"], record["model"], record["run"]])
  next unless row.dig("verdict", "class") == E2E::Evals::Scorecard::CACHE_UNDER_FLOOR

  series = record.dig("efficiency", "cache_read_series")
  puts "- #{record["task"]} #{short.(record["model"])} ##{record["run"]}: recorded #{record.dig("verdict", "class")} -> main cache under floor; " \
       "#{E2E::Evals::Scorecard.cache_under_floor(record, bench)} (#{E2E::Evals::Trace.measured_rounds(series)} rounds after r1)"
end
```

### Detail (output)

`d_detail.out`

```text
## loop-until-dry: QueuePass per bash call (main's reader)
- deepseek-flash #1: bash 14, took 6, receipts 0, passes 14, looped 0, several 0, read_several 0 | reach true  | conduct true
- deepseek-flash #2: bash 8, took 6, receipts 0, passes 20, looped 0, several 0, read_several 0 | reach true  | conduct true
- deepseek-flash #3: bash 15, took 6, receipts 0, passes 15, looped 0, several 0, read_several 1 | reach true  | conduct one bash call handles 6 items: "cat queue/item-01.txt; echo \"===\"; cat queue/item-02.txt; echo \"===\"; cat queue/item-03.txt; echo \"===\
- kimi-k3 #1: bash 6, took 6, receipts 0, passes 21, looped 0, several 0, read_several 0 | reach true  | conduct true
- kimi-k3 #2: bash 6, took 6, receipts 0, passes 25, looped 0, several 0, read_several 0 | reach true  | conduct true
- kimi-k3 #3: bash 6, took 6, receipts 0, passes 19, looped 0, several 0, read_several 0 | reach true  | conduct true
- glm-5.3 #1: bash 8, took 7, receipts 0, passes 22, looped 0, several 0, read_several 0 | reach true  | conduct true
- glm-5.3 #2: bash 7, took 6, receipts 0, passes 27, looped 0, several 0, read_several 0 | reach true  | conduct true
- glm-5.3 #3: bash 6, took 6, receipts 0, passes 26, looped 0, several 0, read_several 0 | reach true  | conduct true
- glm-5.3-flash #1: bash 7, took 6, receipts 0, passes 8, looped 0, several 0, read_several 0 | reach true  | conduct true
- glm-5.3-flash #2: bash 6, took 6, receipts 0, passes 13, looped 0, several 0, read_several 0 | reach true  | conduct true
- glm-5.3-flash #3: bash 4, took 3, receipts 0, passes 4, looped 0, several 0, read_several 0 | reach true loop 01a0d1f8-0d06-75e3-a61a-cc3d5205875a never completed on the feed | conduct true

## barrier-free glm-5.3 #1 and #2: main's picture reading
- #1: first_time_right false, silent ["over_read"]
  graph {"nodes" => ["tool-1:tool", "script-1:script", "tool-2:tool", "script-2:script", "tool-3:tool", "script-3:script", "model-1:model"], "edges" => ["tool-1->script-1", "tool-2->script-2", "tool-3->script-3", "script-1->model-1", "script-2->model-1", "script-3->model-1"], "reads" => {"script-1" => ["tool-1"], "script-2" => ["tool-2"], "script-3" => ["tool-3"], "model-1" => ["tool-1", "tool-2", "tool-3", "script-1", "script-2", "script-3"]}}
  static graph {"nodes" => ["tool-1:tool", "script-1:script", "tool-2:tool", "script-2:script", "tool-3:tool", "script-3:script", "model-1:model"], "edges" => ["tool-1->script-1", "tool-2->script-2", "tool-3->script-3", "script-1->model-1", "script-2->model-1", "script-3->model-1"], "reads" => {"script-1" => ["tool-1"], "script-2" => ["tool-2"], "script-3" => ["tool-3"], "model-1" => ["tool-1", "script-1", "tool
- #2: first_time_right true, silent []
  graph {"nodes" => ["script-1/tool-1:tool", "script-1/script-1:script", "script-1/tool-2:tool", "script-1/script-2:script", "script-1/tool-3:tool", "script-1/script-3:script", "script-1/script-4:script"], "edges" => ["script-1/tool-1->script-1/script-1", "script-1/tool-2->script-1/script-2", "script-1/tool-3->script-1/script-3", "script-1/script-1->script-1/script-4", "script-1/script-2->script-1/script-4", "script-1/script-3->script-1/script-4"], "reads" => {"script-1/script-1" => ["script-1/tool-1"], "script-1/script-2" => ["script-1/tool-2"], "script-1/script-3" => ["script-1/tool-3"], "script-1/script-4" => ["script-1/script-1", "script-1/script-2", "script-1/script-3"]}}
  static graph {"nodes" => ["script-1:script"], "edges" => [], "reads" => {}}

## records main classes `cache under floor`: the after-round-1 rate against the family floor
- workflow-adversarial-verify kimi-k3 #2: recorded model conduct -> main cache under floor; cache 0.0455 after round 1 under the workflow floor 0.8 (2 rounds after r1)
- workflow-barrier-free-pipeline glm-5.3 #2: recorded disagreement -> main cache under floor; cache 0.7935 after round 1 under the workflow floor 0.8 (5 rounds after r1)
- workflow-fan-out-finders kimi-k3 #1: recorded model conduct -> main cache under floor; cache 0.5466 after round 1 under the workflow floor 0.8 (3 rounds after r1)
- workflow-fan-out-finders kimi-k3 #2: recorded model conduct -> main cache under floor; cache 0.6254 after round 1 under the workflow floor 0.8 (3 rounds after r1)
- workflow-fan-out-finders kimi-k3 #3: recorded cache under floor -> main cache under floor; cache 0.4517 after round 1 under the workflow floor 0.8 (2 rounds after r1)
- workflow-judge-panel kimi-k3 #1: recorded cache under floor -> main cache under floor; cache 0.5476 after round 1 under the workflow floor 0.8 (4 rounds after r1)
- workflow-judge-panel kimi-k3 #2: recorded cache under floor -> main cache under floor; cache 0.4591 after round 1 under the workflow floor 0.8 (3 rounds after r1)
- workflow-judge-panel kimi-k3 #3: recorded cache under floor -> main cache under floor; cache 0.5629 after round 1 under the workflow floor 0.8 (3 rounds after r1)
- workflow-judge-panel glm-5.3 #3: recorded cache under floor -> main cache under floor; cache 0.7431 after round 1 under the workflow floor 0.8 (3 rounds after r1)
- workflow-loop-until-dry kimi-k3 #1: recorded cache under floor -> main cache under floor; cache 0.5363 after round 1 under the workflow floor 0.8 (21 rounds after r1)
- workflow-loop-until-dry kimi-k3 #2: recorded cache under floor -> main cache under floor; cache 0.6642 after round 1 under the workflow floor 0.8 (25 rounds after r1)
- workflow-loop-until-dry kimi-k3 #3: recorded cache under floor -> main cache under floor; cache 0.7484 after round 1 under the workflow floor 0.8 (19 rounds after r1)
```

### Adversarial-verify reasons and loop conduct reasons (script)

`d_adv_reasons.py`

```python
#!/usr/bin/env python3
"""SECTION D: adversarial-verify's reds under main's readers — the reason, whether the run waited,
the receipts, the door — to see whether the receipt wording (watcher fact (c)) stands on v11 too;
and the loop-until-dry recorded vs main conduct reasons."""
import json
D = "/private/tmp/claude-501/-Users-jasl-Workspaces-cybros-ai-alt2/fe6d4094-2f85-4b52-abfc-78043a70e275/scratchpad/v13/readout"
REC = "/Users/jasl/Workspaces/cybros-ai.alt2/e2e/evals/runs/2026-09-24-v11-workflow/records.jsonl"
short = lambda m: m.split("/")[-1]
head = [json.loads(l) for l in open(f"{D}/d_rescored_head.jsonl", encoding="utf-8")]
rec = {(r["task"], r["model"], r["run"]): r for r in (json.loads(l) for l in open(REC, encoding="utf-8"))}
print("## adversarial-verify under main")
n = w = 0
for r in sorted((r for r in head if r["task"] == "workflow-adversarial-verify"), key=lambda r: (r["model"], r["run"])):
    f = r["facts"]
    print(f"- {short(r['model'])} #{r['run']}: s={r['verdict']['succeeded']} cls={r['verdict']['class']} door={f.get('door')} "
          f"waited={f.get('waited')} receipts={f.get('receipts')} reason={str(r['reason'])[:70]!r}")
    if str(r["reason"]).startswith("no input_accepted"):
        n += 1
        w += f.get("waited") is True
print(f"  'no input_accepted' reds: {n}, of which waited: {w}")
print("## loop-until-dry conduct reasons, recorded -> main")
for r in sorted((r for r in head if r["task"] == "workflow-loop-until-dry"), key=lambda r: (r["model"], r["run"])):
    k = (r["task"], r["model"], r["run"])
    a, b = rec[k].get("conduct_reasons", {}).get("one_item_per_pass"), r["conduct_reasons"].get("one_item_per_pass")
    if a or b:
        print(f"- {short(r['model'])} #{r['run']}: {str(a)[:120]!r} -> {str(b)[:120]!r}")
```

### Adversarial-verify reasons and loop conduct reasons (output)

`d_adv_reasons.out`

```text
## adversarial-verify under main
- deepseek-flash #1: s=False cls=disagreement door=task_fan waited=True receipts=0 reason='no input_accepted{origin: task_result}: the kernel mailed no receipt ('
- deepseek-flash #2: s=False cls=disagreement door=task_fan waited=True receipts=0 reason='no input_accepted{origin: task_result}: the kernel mailed no receipt ('
- deepseek-flash #3: s=True cls=model conduct door=task_fan waited=False receipts=12 reason='None'
- kimi-k3 #1: s=False cls=disagreement door=task_fan waited=True receipts=0 reason='no input_accepted{origin: task_result}: the kernel mailed no receipt ('
- kimi-k3 #2: s=True cls=cache under floor door=task_fan waited=False receipts=13 reason='None'
- kimi-k3 #3: s=False cls=disagreement door=task_fan waited=True receipts=0 reason='no input_accepted{origin: task_result}: the kernel mailed no receipt ('
- glm-5.3 #1: s=False cls=disagreement door=task_fan waited=True receipts=0 reason='no input_accepted{origin: task_result}: the kernel mailed no receipt ('
- glm-5.3 #2: s=False cls=disagreement door=task_fan waited=True receipts=0 reason='no input_accepted{origin: task_result}: the kernel mailed no receipt ('
- glm-5.3 #3: s=False cls=disagreement door=task_fan waited=True receipts=0 reason='no input_accepted{origin: task_result}: the kernel mailed no receipt ('
- glm-5.3-flash #1: s=False cls=model conduct door=task_fan waited=True receipts=0 reason='no input_accepted{origin: task_result}: the kernel mailed no receipt ('
- glm-5.3-flash #2: s=True cls=model conduct door=task_fan waited=False receipts=12 reason='None'
- glm-5.3-flash #3: s=True cls=None door=task_fan waited=False receipts=12 reason='None'
  'no input_accepted' reds: 8, of which waited: 8
## loop-until-dry conduct reasons, recorded -> main
- deepseek-flash #1: 'a shell loop over the queue: "for f in results/item-0*.txt; do printf \'%s: \' \\"$f\\"; cat \\"$f\\"; done; echo \\"--- queue:' -> 'None'
- deepseek-flash #3: 'one bash call handles 6 items: "cat queue/item-01.txt; echo \\"===\\"; cat queue/item-02.txt; echo \\"===\\"; cat queue/item' -> 'one bash call handles 6 items: "cat queue/item-01.txt; echo \\"===\\"; cat queue/item-02.txt; echo \\"===\\"; cat queue/item'
- glm-5.3-flash #3: 'a shell loop over the queue: "f=$(ls -1 queue/*.txt | sort | head -n 1)\\nn=$(cat \\"$f\\")\\necho $((n * 2)) > \\"results/$(' -> 'None'
```

### v11 reds by class under main (script)

`d_reds.py`

```python
#!/usr/bin/env python3
"""SECTION D: v11's workflow reds as main's readers class them (d_rescored_head.jsonl), by class."""
import json
D = "/private/tmp/claude-501/-Users-jasl-Workspaces-cybros-ai-alt2/fe6d4094-2f85-4b52-abfc-78043a70e275/scratchpad/v13/readout"
rows = [json.loads(l) for l in open(f"{D}/d_rescored_head.jsonl", encoding="utf-8")]
for cls in ("model conduct", "disagreement", "cache under floor"):
    sel = sorted((r for r in rows if r["verdict"]["class"] == cls), key=lambda r: (r["task"], r["model"], r["run"]))
    print(f"## {cls}: {len(sel)}")
    for r in sel:
        v = r["verdict"]
        why = r.get("reason") or "; ".join(f"{k}: {str(x)[:70]}" for k, x in (r.get("conduct_reasons") or {}).items()) or "-"
        print(f"- {r['task'].replace('workflow-', '')} {r['model'].split('/')[-1]} #{r['run']}: r={v['reached']} s={v['succeeded']} "
              f"p={v['task_pass']} | {str(why)[:110]}")
```

### v11 reds by class under main (output)

`d_reds.out`

```text
## model conduct: 11
- adversarial-verify deepseek-flash #3: r=True s=True p=True | did_not_judge_itself: the spine read lib/wallet.rb, lib/ledger.rb, lib/rate.rb itself
- adversarial-verify glm-5.3-flash #1: r=True s=False p=False | no input_accepted{origin: task_result}: the kernel mailed no receipt ({"read" => 39, "bash" => 52, "todo_write
- adversarial-verify glm-5.3-flash #2: r=True s=True p=True | did_not_judge_itself: the spine read lib/wallet.rb, lib/ledger.rb, lib/rate.rb itself
- barrier-free-pipeline deepseek-flash #1: r=False s=None p=True | no compose call and no round fanned two task calls: {"bash" => 5, "write" => 1}
- barrier-free-pipeline deepseek-flash #2: r=False s=None p=True | no compose call and no round fanned two task calls: {"bash" => 5, "read" => 1, "write" => 2}
- barrier-free-pipeline kimi-k3 #2: r=False s=None p=True | no compose call and no round fanned two task calls: {"ls" => 1, "bash" => 5, "read" => 2}
- barrier-free-pipeline glm-5.3-flash #1: r=False s=None p=True | no compose call and no round fanned two task calls: {"bash" => 3}
- barrier-free-pipeline glm-5.3-flash #2: r=False s=None p=True | no compose call and no round fanned two task calls: {"bash" => 3}
- judge-panel glm-5.3-flash #2: r=False s=None p=True | no compose call and no round fanned two task calls: {"todo_write" => 2, "ls" => 1, "spawn" => 3, "status" => 3
- loop-until-dry deepseek-flash #3: r=True s=True p=True | one_item_per_pass: one bash call handles 6 items: "cat queue/item-01.txt; echo \"===\"; c
- loop-until-dry glm-5.3-flash #3: r=True s=False p=False | loop 01a0d1f8-0d06-75e3-a61a-cc3d5205875a never completed on the feed
## disagreement: 12
- adversarial-verify deepseek-flash #1: r=True s=False p=True | no input_accepted{origin: task_result}: the kernel mailed no receipt ({"read" => 37, "ls" => 3, "task" => 12, 
- adversarial-verify deepseek-flash #2: r=True s=False p=True | no input_accepted{origin: task_result}: the kernel mailed no receipt ({"read" => 5, "bash" => 14, "memory_writ
- adversarial-verify kimi-k3 #1: r=True s=False p=True | no input_accepted{origin: task_result}: the kernel mailed no receipt ({"read" => 35, "ls" => 7, "task" => 12, 
- adversarial-verify kimi-k3 #3: r=True s=False p=True | no input_accepted{origin: task_result}: the kernel mailed no receipt ({"read" => 35, "ls" => 3, "task" => 12, 
- adversarial-verify glm-5.3 #1: r=True s=False p=True | no input_accepted{origin: task_result}: the kernel mailed no receipt ({"read" => 38, "ls" => 10, "task" => 12,
- adversarial-verify glm-5.3 #2: r=True s=False p=True | no input_accepted{origin: task_result}: the kernel mailed no receipt ({"read" => 44, "ls" => 5, "task" => 13, 
- adversarial-verify glm-5.3 #3: r=True s=False p=True | no input_accepted{origin: task_result}: the kernel mailed no receipt ({"read" => 25, "ls" => 6, "todo_write" =
- barrier-free-pipeline kimi-k3 #1: r=True s=False p=True | the picture is not the objective's (silent: edit_as_tool, missing_steps): {"nodes" => ["tool-1:tool", "tool-2:
- barrier-free-pipeline kimi-k3 #3: r=True s=False p=True | the picture is not the objective's (silent: edit_as_tool, missing_steps): {"nodes" => ["tool-1:tool", "tool-2:
- barrier-free-pipeline glm-5.3 #1: r=True s=False p=True | the picture is not the objective's (silent: over_read): {"nodes" => ["tool-1:tool", "script-1:script", "tool-2
- barrier-free-pipeline glm-5.3 #3: r=True s=False p=True | the picture is not the objective's (silent: edit_as_tool): {"nodes" => ["tool-1:tool", "tool-2:tool", "tool-3:
- judge-panel deepseek-flash #3: r=True s=False p=True | r4t0 composed 4 tasks and no step reads two model members; r5t0 composed 5 tasks and no step reads two model m
## cache under floor: 12
- adversarial-verify kimi-k3 #2: r=True s=True p=True | -
- barrier-free-pipeline glm-5.3 #2: r=True s=True p=True | -
- fan-out-finders kimi-k3 #1: r=True s=True p=True | -
- fan-out-finders kimi-k3 #2: r=True s=True p=True | -
- fan-out-finders kimi-k3 #3: r=True s=True p=True | -
- judge-panel kimi-k3 #1: r=True s=True p=True | -
- judge-panel kimi-k3 #2: r=True s=True p=True | -
- judge-panel kimi-k3 #3: r=True s=True p=True | -
- judge-panel glm-5.3 #3: r=True s=True p=True | -
- loop-until-dry kimi-k3 #1: r=True s=True p=True | -
- loop-until-dry kimi-k3 #2: r=True s=True p=True | -
- loop-until-dry kimi-k3 #3: r=True s=True p=True | -
```

### Like-for-like table (script)

`d_side_by_side.py`

```python
#!/usr/bin/env python3
"""SECTION D: the like-for-like table — v11 workflow as recorded, v11 re-read with main's readers
(d_rescored_head.jsonl), and v13 workflow as recorded (its records were scored by the same
readers: `git diff --stat c576fe9c HEAD -- e2e/support e2e/evals/tasks nexus/lib e2e/evals/bench.yml`
is empty). Per task x model: reached, succeeded (of reached), task pass, conduct pass, clean
(class none) — each of 3."""
import collections
import json

REPO = "/Users/jasl/Workspaces/cybros-ai.alt2"
D = "/private/tmp/claude-501/-Users-jasl-Workspaces-cybros-ai-alt2/fe6d4094-2f85-4b52-abfc-78043a70e275/scratchpad/v13/readout"
MODELS = ["openrouter/z-ai/glm-5.3", "openrouter/moonshotai/kimi-k3", "deepseek/deepseek-flash", "openrouter/z-ai/glm-5.3-flash"]
short = lambda m: m.split("/")[-1]


def load(path):
    out = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            if line.strip():
                r = json.loads(line)
                out[(r["task"], r["model"], r["run"])] = r  # the newer line on a key wins (Records.merge)
    return out


sets = {"v11 recorded": load(f"{REPO}/e2e/evals/runs/2026-09-24-v11-workflow/records.jsonl"),
        "v11 on main": load(f"{D}/d_rescored_head.jsonl"),
        "v13 recorded": load(f"{REPO}/e2e/evals/runs/2026-09-25-v13-workflow/records.jsonl")}


def cell(rows):
    v = [r["verdict"] for r in rows]
    reached = sum(1 for x in v if x["reached"])
    succ = sum(1 for x in v if x["reached"] and x["succeeded"] is True)
    tp = sum(1 for x in v if x["task_pass"] is True)
    conduct = [ok for r in rows for ok in (r.get("conduct") or {}).values()]
    clean = sum(1 for x in v if not x["class"])
    c = f"{sum(conduct)}/{len(conduct)}" if conduct else "-"
    return f"r{reached} s{succ} p{tp} c{c} g{clean}", (len(rows), reached, succ, tp, sum(conduct), len(conduct), clean)


tasks = sorted({k[0] for k in sets["v11 recorded"]})
print("cell = r reached, s succeeded (of reached), p task pass, c conduct pass/checked, g clean (class none); n = 3 each\n")
print("| task | model | v11 recorded | v11 on main | v13 recorded |")
print("|---|---|---|---|---|")
for t in tasks:
    for m in MODELS:
        cells = [cell([r for k, r in s.items() if k[0] == t and k[1] == m])[0] for s in sets.values()]
        print(f"| {t.replace('workflow-', '')} | {short(m)} | " + " | ".join(cells) + " |")

print("\n| model | set | reached | succeeded/reached | task pass | conduct pass | clean | classes |")
print("|---|---|---|---|---|---|---|---|")
for m in MODELS + [None]:
    for name, s in sets.items():
        rows = [r for k, r in s.items() if m is None or k[1] == m]
        _, (n, re_, su, tp, cp, cn, cl) = cell(rows)
        cls = collections.Counter(r["verdict"]["class"] or "clean" for r in rows)
        print(f"| {short(m) if m else 'ALL'} | {name} | {re_}/{n} | {su}/{re_} | {tp}/{n} | {cp}/{cn} | {cl}/{n} | "
              + ", ".join(f"{k} {v}" for k, v in sorted(cls.items())) + " |")
```

### Like-for-like table (output)

`d_side_by_side.out`

```text
cell = r reached, s succeeded (of reached), p task pass, c conduct pass/checked, g clean (class none); n = 3 each

| task | model | v11 recorded | v11 on main | v13 recorded |
|---|---|---|---|---|
| adversarial-verify | glm-5.3 | r3 s0 p3 c0/3 g0 | r3 s0 p3 c0/3 g0 | r3 s1 p3 c2/3 g0 |
| adversarial-verify | kimi-k3 | r3 s1 p3 c0/3 g0 | r3 s1 p3 c3/3 g0 | r3 s1 p1 c3/3 g0 |
| adversarial-verify | deepseek-flash | r3 s1 p3 c0/3 g0 | r3 s1 p3 c1/3 g0 | r3 s3 p3 c0/3 g0 |
| adversarial-verify | glm-5.3-flash | r3 s2 p2 c0/3 g0 | r3 s2 p2 c1/3 g1 | r3 s2 p3 c1/3 g1 |
| barrier-free-pipeline | glm-5.3 | r3 s0 p3 c- g0 | r3 s1 p3 c- g0 | r2 s1 p3 c- g0 |
| barrier-free-pipeline | kimi-k3 | r2 s0 p3 c- g0 | r2 s0 p3 c- g0 | r0 s0 p3 c- g0 |
| barrier-free-pipeline | deepseek-flash | r1 s1 p3 c- g1 | r1 s1 p3 c- g1 | r1 s1 p3 c- g1 |
| barrier-free-pipeline | glm-5.3-flash | r1 s1 p3 c- g1 | r1 s1 p3 c- g1 | r2 s2 p3 c- g2 |
| fan-out-finders | glm-5.3 | r3 s3 p3 c0/3 g0 | r3 s3 p3 c3/3 g3 | r3 s3 p3 c3/3 g3 |
| fan-out-finders | kimi-k3 | r3 s3 p3 c1/3 g0 | r3 s3 p3 c3/3 g0 | r3 s3 p3 c3/3 g0 |
| fan-out-finders | deepseek-flash | r3 s3 p3 c1/3 g1 | r3 s3 p3 c3/3 g3 | r3 s3 p3 c3/3 g3 |
| fan-out-finders | glm-5.3-flash | r3 s3 p3 c0/3 g0 | r3 s3 p3 c3/3 g3 | r3 s3 p3 c3/3 g3 |
| judge-panel | glm-5.3 | r3 s3 p3 c- g2 | r3 s3 p3 c- g2 | r3 s3 p3 c- g0 |
| judge-panel | kimi-k3 | r3 s3 p3 c- g0 | r3 s3 p3 c- g0 | r3 s3 p3 c- g1 |
| judge-panel | deepseek-flash | r3 s2 p3 c- g2 | r3 s2 p3 c- g2 | r3 s3 p3 c- g3 |
| judge-panel | glm-5.3-flash | r2 s2 p3 c- g2 | r2 s2 p3 c- g2 | r3 s3 p3 c- g3 |
| loop-until-dry | glm-5.3 | r3 s3 p3 c3/3 g3 | r3 s3 p3 c3/3 g3 | r3 s3 p3 c3/3 g3 |
| loop-until-dry | kimi-k3 | r3 s3 p3 c3/3 g0 | r3 s3 p3 c3/3 g0 | r3 s3 p3 c3/3 g1 |
| loop-until-dry | deepseek-flash | r2 s2 p3 c1/3 g1 | r3 s3 p3 c2/3 g2 | r3 s3 p3 c3/3 g3 |
| loop-until-dry | glm-5.3-flash | r1 s1 p2 c2/3 g1 | r3 s2 p2 c3/3 g2 | r3 s3 p3 c3/3 g3 |

| model | set | reached | succeeded/reached | task pass | conduct pass | clean | classes |
|---|---|---|---|---|---|---|---|
| glm-5.3 | v11 recorded | 15/15 | 9/15 | 15/15 | 3/9 | 5/15 | cache under floor 1, clean 5, disagreement 6, model conduct 3 |
| glm-5.3 | v11 on main | 15/15 | 10/15 | 15/15 | 6/9 | 8/15 | cache under floor 2, clean 8, disagreement 5 |
| glm-5.3 | v13 recorded | 14/15 | 11/14 | 15/15 | 8/9 | 6/15 | cache under floor 5, clean 6, disagreement 3, model conduct 1 |
| kimi-k3 | v11 recorded | 14/15 | 10/14 | 15/15 | 4/9 | 0/15 | cache under floor 7, disagreement 4, model conduct 4 |
| kimi-k3 | v11 on main | 14/15 | 10/14 | 15/15 | 9/9 | 0/15 | cache under floor 10, disagreement 4, model conduct 1 |
| kimi-k3 | v13 recorded | 12/15 | 10/12 | 13/15 | 9/9 | 2/15 | cache under floor 8, clean 2, model conduct 5 |
| deepseek-flash | v11 recorded | 12/15 | 9/12 | 15/15 | 2/9 | 5/15 | clean 5, disagreement 3, model conduct 7 |
| deepseek-flash | v11 on main | 13/15 | 10/13 | 15/15 | 6/9 | 8/15 | clean 8, disagreement 3, model conduct 4 |
| deepseek-flash | v13 recorded | 13/15 | 13/13 | 15/15 | 6/9 | 10/15 | clean 10, model conduct 5 |
| glm-5.3-flash | v11 recorded | 10/15 | 9/10 | 13/15 | 2/9 | 4/15 | clean 4, model conduct 11 |
| glm-5.3-flash | v11 on main | 12/15 | 10/12 | 13/15 | 7/9 | 9/15 | clean 9, model conduct 6 |
| glm-5.3-flash | v13 recorded | 14/15 | 13/14 | 15/15 | 7/9 | 12/15 | clean 12, disagreement 1, model conduct 2 |
| ALL | v11 recorded | 51/60 | 37/51 | 58/60 | 11/36 | 14/60 | cache under floor 8, clean 14, disagreement 13, model conduct 25 |
| ALL | v11 on main | 54/60 | 40/54 | 58/60 | 28/36 | 25/60 | cache under floor 12, clean 25, disagreement 12, model conduct 11 |
| ALL | v13 recorded | 53/60 | 47/53 | 58/60 | 30/36 | 30/60 | cache under floor 13, clean 30, disagreement 4, model conduct 13 |
```

### Every compose script under each builder (script)

`d_compose_rows.rb`

```ruby
# SECTION D: every compose call in the 60 v11 workflow traces, its script re-evaluated by ONE
# tree's shipped evaluator (nexus/lib/nexus/compose/builder.js) with the round's declared names —
# so a builder change between v11 and main (v12's race reference, S1's race_member refusal)
# shows up on scripts the readers never re-read (only barrier-free re-reads its scripts).
# Prints one line per compose row: task, model, run, row key, built?/refusal, bucket (main's
# Buckets.loud, applied to every tree's refusal so the words are comparable).
#   cd e2e && BUNDLE_FROZEN=true bundle exec ruby <this> old|v12|v13pre|head
require "json"
REPO = "/Users/jasl/Workspaces/cybros-ai.alt2".freeze
READOUT = "/private/tmp/claude-501/-Users-jasl-Workspaces-cybros-ai-alt2/fe6d4094-2f85-4b52-abfc-78043a70e275/scratchpad/v13/readout".freeze
TREES = { "old" => "fc76e859", "v12" => "bf6e5af0", "v13pre" => "a8623359" }.freeze
mode = ARGV.fetch(0)
root = TREES.key?(mode) ? File.join(READOUT, "old-tree-#{TREES.fetch(mode)}") : REPO
require File.join(root, "e2e/support/evals")
BUCKET_PATTERNS = [
  ["race_member", /a member of (?:the race on line \d+|an earlier race); a race stops the members it did not select/],
  ["race_unwrapped", /takes a list; write (?:after|results): \[race\] to name the race/],
  ["group_reference", /names an "all" group, which is not one step/],
  ["reference_value", /accepts leaf handles and races, not result values or string keys/],
].freeze
LABEL = "2026-09-24-v11-workflow".freeze
ARTIFACTS = File.join(REPO, "e2e/artifacts/evals").freeze
records = E2E::Evals::Records.read(File.join(REPO, "e2e/evals/runs", LABEL)).sort_by { |r| [r["task"], r["model"], r["run"]] }
rows = 0
refused = Hash.new(0)
records.each do |record|
  trace = E2E::Evals::Rescore.trace_of(record, E2E::Evals::Rescore.artifact_of(record, ARTIFACTS, LABEL))
  names = E2E::Evals::Predicates.declared_names(trace)
  trace.compose_rows.each do |row|
    rows += 1
    input = trace.input_of(row)
    built = Nexus::Compose::Evaluator.call(script: input["script"].to_s, params: Hash(input["params"]), tool_names: names)
    text = "#{built.refusal}: #{built.detail.to_s.lines.first.to_s.strip}"
    bucket = built.built? ? "-" : (BUCKET_PATTERNS.find { |_, pattern| text.match?(pattern) }&.first || "other")
    refused[bucket] += 1 unless built.built?
    puts "#{record["task"]} #{record["model"].split("/").last} ##{record["run"]} #{row["key"]} row_status=#{row["status"]} " \
         "built=#{built.built?} refusal=#{built.refusal.inspect} bucket=#{bucket} detail=#{built.detail.to_s.lines.first.to_s.strip[0, 100].inspect}"
  end
end
puts "#{mode}: #{rows} compose rows over #{records.size} records; refused by bucket #{refused.inspect}"
```

### Every compose script under main's builder (output)

`d_compose_rows_head.out`

```text
workflow-barrier-free-pipeline deepseek-flash #3 r6t0 row_status=completed built=false refusal=:script_error bucket=other detail="Error: g.tool: results: is not an option; a tool reads nothing. To wait for a step, write after: [st"
workflow-barrier-free-pipeline deepseek-flash #3 r7t0 row_status=completed built=true refusal=nil bucket=- detail=""
workflow-barrier-free-pipeline kimi-k3 #1 r3t0 row_status=completed built=true refusal=nil bucket=- detail=""
workflow-barrier-free-pipeline kimi-k3 #3 r4t0 row_status=completed built=true refusal=nil bucket=- detail=""
workflow-barrier-free-pipeline glm-5.3 #1 r3t0 row_status=completed built=true refusal=nil bucket=- detail=""
workflow-barrier-free-pipeline glm-5.3 #2 r3t0 row_status=completed built=true refusal=nil bucket=- detail=""
workflow-barrier-free-pipeline glm-5.3 #3 r4t0 row_status=completed built=true refusal=nil bucket=- detail=""
workflow-barrier-free-pipeline glm-5.3-flash #3 r6t0 row_status=completed built=true refusal=nil bucket=- detail=""
workflow-judge-panel deepseek-flash #1 r4t0 row_status=completed built=true refusal=nil bucket=- detail=""
workflow-judge-panel deepseek-flash #2 r4t0 row_status=completed built=false refusal=:script_error bucket=other detail="Error: g.parallel: every member must be a step built for this group, e.g. g.parallel([g.tool({...}),"
workflow-judge-panel deepseek-flash #2 r5t0 row_status=completed built=true refusal=nil bucket=- detail=""
workflow-judge-panel deepseek-flash #3 r4t0 row_status=completed built=true refusal=nil bucket=- detail=""
workflow-judge-panel deepseek-flash #3 r5t0 row_status=completed built=true refusal=nil bucket=- detail=""
workflow-judge-panel deepseek-flash #3 r6t0 row_status=completed built=true refusal=nil bucket=- detail=""
workflow-judge-panel glm-5.3 #3 r2t2 row_status=completed built=true refusal=nil bucket=- detail=""
workflow-judge-panel glm-5.3-flash #3 r4t0 row_status=completed built=true refusal=nil bucket=- detail=""
head: 16 compose rows over 60 records; refused by bucket {"other" => 2}
```

### Builder comparison across the four trees (output)

`d_compose_rows_diff.out`

```text
== old vs v12 (built/refusal/bucket per compose row; detail text left out):
identical
== old vs v13pre (built/refusal/bucket per compose row; detail text left out):
identical
== old vs head (built/refusal/bucket per compose row; detail text left out):
identical
```

### The draft script as run, read-only (its output)

`d_draft_run.out`

```text
2026-09-24-v11-workflow workflow-fan-out-finders: 12 records; old pass 2, new pass 12; flipped to pass 10
2026-09-24-v11-workflow workflow-adversarial-verify: 12 records; old pass 0, new pass 5; flipped to pass 5
2026-09-23-v10-workflow workflow-fan-out-finders: 12 records; old pass 4, new pass 12; flipped to pass 8
2026-09-23-v10-workflow workflow-adversarial-verify: 12 records; old pass 0, new pass 8; flipped to pass 8
-glm-pack-workflow/openrouter_z-ai_glm-5.3.pack.1.json: old r=true c=true | new r=true c=true 
-glm-pack-workflow/openrouter_z-ai_glm-5.3.pack.2.json: old r=true c=false | new r=true c=true 
-glm-pack-workflow/openrouter_z-ai_glm-5.3.pack.3.json: old r=true c=false | new r=true c=true 
-glm-wfword-workflow/openrouter_z-ai_glm-5.3.pack.1.json: old r=false c=false | new r=true c=one bash call handles several items: "ls queue done results 2>&1; echo 
-glm-wfword-workflow/openrouter_z-ai_glm-5.3.pack.2.json: old r=true c=true | new r=true c=true 
-glm-wfword-workflow/openrouter_z-ai_glm-5.3.pack.3.json: old r=true c=true | new r=true c=true 
-kimi-pack-workflow/openrouter_moonshotai_kimi-k3.pack.1.json: old r=true c=true | new r=true c=true 
-kimi-pack-workflow/openrouter_moonshotai_kimi-k3.pack.2.json: old r=true c=true | new r=true c=true 
-kimi-pack-workflow/openrouter_moonshotai_kimi-k3.pack.3.json: old r=true c=true | new r=true c=true 
-workflow/deepseek_deepseek-flash.nexus.1.json: old r=true c=false | new r=true c=true 
-workflow/deepseek_deepseek-flash.nexus.2.json: old r=true c=true | new r=true c=true 
-workflow/deepseek_deepseek-flash.nexus.3.json: old r=false c=false | new r=true c=one bash call handles 6 items: "cat queue/item-01.txt; echo \"===\"; c 
-workflow/openrouter_moonshotai_kimi-k3.nexus.1.json: old r=true c=true | new r=true c=true 
-workflow/openrouter_moonshotai_kimi-k3.nexus.2.json: old r=true c=true | new r=true c=true 
-workflow/openrouter_moonshotai_kimi-k3.nexus.3.json: old r=true c=true | new r=true c=true 
-workflow/openrouter_z-ai_glm-5.3-flash.nexus.1.json: old r=false c=true | new r=true c=true 
-workflow/openrouter_z-ai_glm-5.3-flash.nexus.2.json: old r=true c=true | new r=true c=true 
-workflow/openrouter_z-ai_glm-5.3-flash.nexus.3.json: old r=false c=false | new r=true c=true 
-workflow/openrouter_z-ai_glm-5.3.nexus.1.json: old r=true c=true | new r=true c=true 
-workflow/openrouter_z-ai_glm-5.3.nexus.2.json: old r=true c=true | new r=true c=true 
-workflow/openrouter_z-ai_glm-5.3.nexus.3.json: old r=true c=true | new r=true c=true 
deepseek_deepseek-flash.nexus.1.json: old r=true s=true | new r=true s=true
deepseek_deepseek-flash.nexus.2.json: old r=true s=true | new r=true s=true
deepseek_deepseek-flash.nexus.3.json: old r=true s=true | new r=true s=true
openrouter_moonshotai_kimi-k3.nexus.1.json: old r=true s=true | new r=true s=true
openrouter_moonshotai_kimi-k3.nexus.2.json: old r=false s= | new r=true s=true
openrouter_moonshotai_kimi-k3.nexus.3.json: old r=true s=true | new r=true s=true
openrouter_z-ai_glm-5.3-flash.nexus.1.json: old r=true s=true | new r=true s=true
openrouter_z-ai_glm-5.3-flash.nexus.2.json: old r=true s=true | new r=true s=true
openrouter_z-ai_glm-5.3-flash.nexus.3.json: old r=true s=true | new r=true s=true
openrouter_z-ai_glm-5.3.nexus.1.json: old r=true s=true | new r=true s=true
openrouter_z-ai_glm-5.3.nexus.2.json: old r=true s=true | new r=true s=true
openrouter_z-ai_glm-5.3.nexus.3.json: old r=true s=true | new r=true s=true
Run options: --seed 18498

# Running:



Finished in 0.000193s, 0.0000 runs/s, 0.0000 assertions/s.

0 runs, 0 assertions, 0 failures, 0 errors, 0 skips
e2e ledgers: device-flow slept 0.0 s, sign-in slept 0.0 s; terminate: 0 calls 0.0 s
```

### Repo status after the run (output; empty = nothing written in the repo)

`d_repo_status.out`

```text
```
