# Section C: the brake, the kernel changes in use, and the harness's own readings

Bench version 13: 240 records (task 72, compose 108, workflow 60), kernel c576fe9c, records commit
0649b3dd, digest ab836ee0d8be. This section was read only. Nothing in the repo was written, and no
record was rescored in place: the one full re-read (C7.0) ran in memory, and `git status` stayed
clean afterwards. Every number below comes from a script in `scripts/`, next to this file. The
Appendix has each script's text and its captured output. Paths inside the scripts are absolute.

## Headline

- **The repeat brake did not fire on any v13 record.** No record, trace or world log names
  `repeat_call_loop` or `agent_loop_repeat_refused`. No v13 chain came close either. Across every
  chain of every primary loop, the most consecutive fans whose calls were already seen is 1. The
  brake needs 8 such fans in a row plus a ninth that repeats. The same metric on v11 finds the one
  cell the brake replay predicted, judge-panel glm-5.3-flash #2 (a 399-round spine with a streak
  of 392). That cell ran green on v13.
- **Both `lane bug` records were the model deliberating.** Each loop was streaming reasoning up to
  the cancel: 1,679 frames over 580 s, and 4,060 frames over 602 s. The watcher's figure of 582
  counts only the log lines that Rails did not truncate, not the frames. In the flash run a
  provider error cut the first attempt after 408 s, and the kernel retried it. Both records
  should read as model conduct. The scorer rule that would tell this apart from a dead lane is
  proposed in C2.
- **The receipt sentence blames the kernel for the model's choice** in 5 v13 records and 12 v11
  records. In every one of them, every `task` call waited. Only the sentence needs to change; no
  verdict or class moves.
- **No model chose a passive wake on v13** (0 of 24 records, 0 task rows). **No tool timed out**,
  so the timeout-budget sentence never appeared. **One content-named capture appeared**, from a
  single call, so whether a repeat keeps the same name went untested.
- **Nine v13 records are read wrongly or on a questionable rule** (C7):
  - task-fan-five glm-5.3-flash #1 is red because the scorer read turn 1's reply. The merged list
    is in a turn a receipt woke. v11 has the same miss on kimi-k3 #2.
  - compose-rendezvous glm-5.3-flash #1 is red on the first-call rule. Its second call passes the
    floor's usable bar.
  - Three strong compose-background-suite reds read `suite_waited_on` for a suite launched with
    `start_process`, which returns after 0 to 15 s.
  - Four green-and-passed adversarial-verify records are `model conduct` only because the spine
    read lib/ before it dispatched any refuter.
  - Some wording also needs fixing: the grep-then-edit glm-5.3 #1 reason and the barrier-free
    RATIONALE.

---

## C1. The repeat brake

**The brake as it ships** (`nexus/app/services/agent_loops/repeat_brake.rb`, from
`ExpandRound.call`). A round is stale when every element it brought was already seen in the 16
rounds before it on its chain. An element is a call together with its result. A round is refused
with `round_expansion_refused` / `repeat_call_loop` only when the 8 rounds up to the reader are
all stale and the new fan asks only for calls seen in those 16 rounds. Two other rules matter
here:
- Rounds that only poll (`read_process`) are skipped: they neither extend a run of stale rounds
  nor break it.
- A round whose maker made no call ends the segment.

Each refusal logs `event=agent_loop_repeat_refused` in the jobs process.

**Surfaces searched** (script `c1_brake.py`):

| surface | task | compose | workflow |
|---|---|---|---|
| record facts (`round_errors`, `attention_reasons`, `untraced_attention_reasons`, reason, loop_status) naming `repeat_call_loop` | 0 | 0 | 0 |
| trace JSONs naming it | 0 / 72 | 0 / 108 | 0 / 60 |
| world-log files naming `repeat_call_loop` or `agent_loop_repeat_refused` (every per-run Rails window, plus the largest whole copy of each world's server, model_runner and jobs log) | 0 / 219 | 0 / 327 | 0 / 183 |
| `agent_loop_round_expansion_refused` lines, by reason | none | none | `invalid_tool_input` × 1 |

The one refusal is `workflow-adversarial-verify deepseek-flash #1`, round `r14`. That round is a
refuter branch (spine false), and the kernel refused it with `invalid_tool_input`, which is not
the brake. The classifier counts it as conduct (`CONDUCT_ERROR_KEYS`). **In short, the brake did
not fire on any v13 record, so there is no refusal to judge right or wrong.**

**The longest stale runs.** The traces do not carry tool results, so the brake's exact
staleness can't be recomputed from them. Instead, the script computes a call-only upper bound:
it treats a fan as stale when every (name, canonical input) in it was already called in the 16
judged fans before it. This covers every chain of the primary loop (compose-member and
task-branch rounds included, walked through `expansion_parent`) and skips poll-only rounds the
way the brake does. Because the brake's own staleness also needs equal results and equal
delivered material, the real run of stale rounds can only be shorter than this bound.

| | v13 (240 records) | v11 control (`c1_validate_v11.py`) |
|---|---|---|
| longest call-stale run, any chain | **1** | **392** (workflow-judge-panel glm-5.3-flash #2, a 399-round spine) |
| records with a run of 4 or more / 8 or more | 0 / 0 | 2 / 2 (judge-panel flash #2: 392; loop-until-dry deepseek-flash #3: 9, not refused, so its results changed) |
| longest run of byte-identical consecutive fans (the v11 brake refused the 4th) | 1 | 3 (three records) |

The metric is sound. On v11 it finds exactly the cell the brake replay predicted, fact (e). On
v13 that cell ran **green**: judge-panel glm-5.3-flash #1/#2/#3 all succeeded, with 15, 22 and 12
rounds settled (v11 #2 settled 398 rounds in 1,420 s as model conduct).

**The cells where the brake would matter** (v13, per cell: longest call-stale run / longest
chain / spine rounds):

| cell | glm-5.3 | kimi-k3 | deepseek-flash | glm-5.3-flash |
|---|---|---|---|---|
| workflow-judge-panel | 0 / 8 / 6 | 0 / 8 / 4 | 0 / 9 / 4 | 0 / 6 / 6 |
| workflow-loop-until-dry | 1 / 27 / 27 | 1 / 26 / 26 | 1 / 22 / 22 | 1 / 26 / 26 |
| task-background-suite (the longest task spine) | 1 / 11 / 11 | 1 / 12 / 12 | 1 / 12 / 12 | 1 / 18 / 18 |

Reading: loop-until-dry is the long-spine cell (20 to 27 rounds), and even there no two fans in
a row repeated their calls. The brake had nothing to judge on v13. Its value this version is the
v11 cell it would have stopped, which the models did not reproduce.

---

## C2. The two `lane bug` records (fact (a))

Both are compose runs on the plain driver, stopped at the 600 s deadline (`seconds` 607) with
`rounds_settled` 0 and loop `canceling`. In both, the trace's only task is `r1`, a running
`model_task`. The classifier reached `LANE_BUG` through `Scorecard.classify` → `work_seen?`,
which is false when `rounds_settled` is 0.

Evidence comes from `nexus.model_runner.log`, which is a whole-world file and so is filtered by
the run's loop id (`c2_lane_bugs.py`, `c2_reasoning_text.py`). Deltas are counted from the
`solid_cable_messages` inserts, whose hex payloads are complete. The ActionCable broadcast line,
by contrast, is truncated by the logger.

| | compose-background-suite glm-5.3 #3 | compose-grep-then-edit glm-5.3-flash #1 |
|---|---|---|
| loop | 01a0d4e2-60b1-… | 01a0d51c-dd96-… |
| `round_started` for r1 | 1 (19:26:41.01) | 2 (20:30:34.08, then 20:37:34.53) |
| `reasoning_delta` frames | **1,679** (582 of the log lines are untruncated: that is the watcher's "582") | **4,060** (2,875 in attempt 1, 1,185 in attempt 2) |
| other stream frames | none (no text, no tool-call delta) | 1 `stream_reset` (reason `retry`, 20:37:24.16) |
| first → last delta | 19:26:41.8 → 19:36:21.8 (580 s), last at log line 31,715 of 32,194 ✓ | 20:30:35.6 → 20:40:37.7 (602 s) |
| deltas per minute | 393, 282, 120, 160, 150, 111, 74, 193, 97, 99 | 444, 456, 463, 424, 392, 385, 312, 398, 385, 387, 14 |
| largest silence between deltas | 28.2 s | 11.4 s |
| last delta → cancel (`model_invocations.canceled_at`, `creator_requested`) | 23.0 s (inside the stream's own 28.2 s cadence) | −0.1 s (a delta landed as the cancel did) |
| reasoning reassembled | 131,315 chars: "Hmm" ×150, "Actually" ×29, `g.parallel` ×80, `g.tool` ×99. It ends mid-sentence, still weighing whether the `all` group runs the report step. | attempt 1: 128,527 chars ending "Let me reconsider ONE more time…"; attempt 2: 66,655 chars ending "maybe simpler to NOT use parallel" |
| attempt settlement (`usage_records`) | none written (canceled) | attempt 1 `failed provider_http_error`, duration 410,171 ms, first token after 1,853 ms, tokens NULL; attempt 2 none (canceled) |

**Reading.** Fact (a) is confirmed, with two corrections:
- The first run's frame count is 1,679, not 582.
- The flash run's first attempt was ended by the provider (`provider_http_error` after 408 s of
  reasoning with no call), not by the model. The kernel queued a retry 10 s later, and attempt 2
  reasoned for 182 s until the deadline.

In both runs the model was producing reasoning continuously until the cancel and never emitted
a tool call. The lane and the kernel worked: the attempt ran, the retry fired, and the cancel
landed. **Reclass both to `model conduct`** (the model deliberated past the deadline). Record the
flash run's provider error as a fact, not as a cause. Attempt 1 had already spent 408 s without
a call, and the glm-5.3 run shows the same shape with no provider fault at all.

Two further findings:
- Both records show `cost_amount` null and 0 tokens. A canceled attempt writes no usage row, and
  the failed attempt's row carries NULL tokens. So about 10 minutes of streamed reasoning per run
  (131 KB and 195 KB of text) is **missing from the efficiency columns**.
- **Proposed scorer rule** (do not implement yet): the classifier has to tell "the deadline hit
  while the model was still streaming" apart from "the lane died". The detailed proposal follows.

**Where the rule goes.** In `e2e/support/evals/scorecard.rb`, `Scorecard.work_seen?(record)`. It
is called from `Scorecard.classify` at the `HARNESS_STOPS` line, so it covers deadline, cost_stop
and needs_person.

**The rule.** Keep the current test. Also count a stop as work when the record carries
`facts.in_flight` and all of the following hold:
- `in_flight.status == "running"`: the stop cut a model round that was running.
- `in_flight.frames > 0`: its stream carried reasoning, text or tool-call deltas for this loop.
- `in_flight.last_frame_age_s <= STREAM_LIVE_SECONDS`: the last delta arrived within that many
  seconds of the stop. 60 s is proposed, about twice the largest silence seen inside a live
  stream on v13 (28.2 s).

Everything else stays `LANE_BUG` when nothing settled:
- no running round (the round never started, or its invocation never reached the provider);
- a running round with no frames (a provider hang, or a dead runner);
- a running round whose last frame is older than the threshold (a stalled stream).

A kind `deadline (mid-round)` beside `deadline (failed)` in `Scorecard.kind_of` would make the
red line say so without opening the record.

**Where the fact comes from.** Deltas are not durable in the kernel
(`Conversations::TranscriptStream`: "Nothing here is durable"). The lane therefore records
`in_flight` at the stop. The pure option is a reader in `e2e/support/evals/world_log.rb` (the
module is "pure over paths"), for example `WorldLog.stream_at_stop(run_log_dir, loop_id,
stopped_at)`. It would run after `WorldLog.copy` for a stopped record and would:
- decode the `solid_cable_messages` inserts in the copied `nexus.model_runner.log`, filtered by
  the loop's public id, the same way `c2_lane_bugs.py` does;
- record `{task_key, status, started_at, frames, last_frame_age_s, attempts, stream_resets,
  attempt_errors}`.

`MemberPlane#caught` (`e2e/support/evals/member_plane.rb`), the `Stopped` branch, would stash it
on the facts. A cheaper stand-in reads only the trace (spine `r1` `running` and started well
before the stop), but it cannot separate a hung stream from a live one.

---

## C3. The receipt wording (fact (c))

Script `c3_receipt.py`. It lists every record whose reason contains "the kernel mailed no
receipt", then checks each `task` and `compose` row's stored `tool_input.wait`:

| label | records | every task/compose call waited | classes |
|---|---|---|---|
| v13 workflow | **5** (glm-5.3 #2, #3; kimi-k3 #1, #3; glm-5.3-flash #2) | **5 / 5** (12/12, 12/12, 12/12, 13/13, 12/12) | 3 disagreement (task_pass true), 2 model conduct (task_pass false) |
| v11 workflow | **8** | 8 / 8 | 7 disagreement, 1 model conduct |
| v11 kimi-pack / glm-pack workflow | 4 | 4 / 4 | 4 disagreement |

All of them are `workflow-adversarial-verify`. None of them had a detached call, and every one
has `receipts: 0`.

What the task wants (`expected.rb`, `RATIONALE.md`): success is `Predicates.receipt_loop`, meaning
the receipt-wake loop, "never a count". The RATIONALE already lists this exact red under **model
conduct**: "…the kernel mailed no receipt ({task: 12})" with `waited: true`, described as the
recorded shape, red by the family's rule, and read together with the fact. So the check is right
for this task: a waited fan never enters the loop the task measures. The sentence is wrong,
because a waited call owes no receipt.

**The corrected rule.** In `e2e/support/evals/predicates.rb`, `Predicates.receipt_loop`
(line 233), split the case where `trace.receipts.zero?`:
- **Every `task` row waited:** `"no input_accepted{origin: task_result}: every task call waited
  (wait: true on 12 of 12), so no receipt was owed and the receipt-wake loop never ran
  ({...called})"`. The model chose this, so it is red by the family's rule.
- **Some `task` row was detached:** `"no input_accepted{origin: task_result}: the kernel mailed no
  receipt for N detached task call(s) ({...})"`. The RATIONALE's kernel-finding bullet already
  names this case ("a detached fan with `receipts: 0` … the mail is owed"). It could also carry a
  kernel signal, but no record on file has it.

The quoted sentence in RATIONALE.md's "Reading a red" changes with it.

**Effect.** The change is to the sentence only. `succeeded` stays false, and `Scorecard.classify`
never parses the reason (only the `PREDICATE_RAISED` prefix). So all 17 records keep their class:
disagreement where task_pass is true, model conduct where it is false. No verdict moves on v11 or
v13.

---

## C4. Passive wake

Script `c4_passive.py` reads the trace facts (`wake_passive`, `receipt_woke_a_turn`, `mailed`,
`reply_final_with_background`, `mail_in_turn_2_history`) and every task, spawn, compose and send
row's stored `wake`.

| | task-detached-receipt | task-mail | rows asking `wake: "passive"` |
|---|---|---|---|
| **v13** | wake_passive **0 / 12**; receipt_woke_a_turn 12 / 12; all 12 succeeded | wake_passive **0 / 3** reached (the other 9 made no `task` call); the 3 reached runs (glm-5.3 #3, deepseek-flash #1, #2) all woke, mailed, and kept the mail in turn 2's history, all green | **0**. task family: 82 unset + 1 `auto`; workflow: 248 unset; compose: 104 unset |
| v11 (contrast) | 2 / 12 (kimi-k3 #2, #3; both red, "the receipt woke no turn: the call asked `wake: \"passive\"`") | 1 (deepseek-flash #2, red; under v11's owed-wake reading) | 3 |

No v13 cell ran spawn (`spawn-subagent-suite` and `spawn-peer-relay` are not in the three
labels), so `reply_woke_a_turn` has no reading.

**Reading.** No model chose a passive wake on v13. The version-12 revision (task-mail and spawn
read the wake as the model's choice, while detached-receipt treats a passive wake as a red that
names itself) was therefore never exercised. Fact (d) holds: v11's task-mail glm-5.3 cell was
0/3 reached (all three "no `task` call: turn 1 called {start_process, bash}"). On v13 it is 1/3
reached and green (#3).

---

## C5. The timeout-budget sentence

Script `c56_bytes.py` checks every run's Rails window (the `content_fragments` inserts that hold
a tool result's text), every `rho.log`, and the trace JSONs. Script `c56_world.py` checks the
largest whole copy of each world's `server.log` and `model_runner.log`, which together cover
every line once.

| surface | task | compose | workflow |
|---|---|---|---|
| `runner_tool_timed_out` in rho.log (the runner logs every clamp at warn) | 0 | 0 | 0 |
| traces holding "did not finish within the task" | 0 | 0 | 0 |
| the sentence in the run windows' fragment inserts | 0 | 0 | 0 |
| the sentence in the whole world logs | 0 | 0 | 0 |

**No v13 record contains it**, so byte identity across repeats cannot be read on this version.
Nothing in these families ran a tool past its `timeout_ms`.

---

## C6. Content-named captures

The same two scripts search for `(bash|web|browser)-<16 hex>`. **One capture appeared**, and the
same name shows up in 12 world-log lines:
- The capture is `bash-c88fbdcdeb64e0f7.log`, in workflow-adversarial-verify deepseek-flash #1.
- It is the spill of a refuter branch's 9,015-line filesystem search (`find / -maxdepth 8 …`,
  row `r39t0`, completed 00:25:45; the result was sealed at 00:25:45.84). It hit the 50 KB cap:
  "[Showing lines 8412-9015 of 9015 (50.0KB limit). Full output: …/bash-c88fbdcdeb64e0f7.log]".
- The runner uploaded it with that `original_filename`, and the result's `resource_link` name
  carries the same name.
- Active Storage stored the blob as `bash-c88fbdcdeb64e0f7.bin` (`application/octet-stream`).
  This is a cosmetic mismatch that the model never sees.

The branch's 47 bash calls hold 45 distinct inputs. The only repeat is `which ruby && ruby -v`
×3, whose output is short. So no over-limit output ran twice, and **the capture did not repeat**.
The "same bytes, same name" property went untested on v13. No web or browser tool ran.

---

## C7. Records whose class or reason reads wrong

**C7.0 control.** `c7_reread.rb` re-reads all 240 records through today's harness, in memory
only: it calls `Rescore.rescored` and appends nothing. HEAD is the records commit. **0 differ
from the committed line**, so the stored verdicts are what the harness says. What follows are
questions about the readers themselves, not drift. `c7_list.py` lists every red.

### Workflow `model conduct` (13) and `disagreement` (4)

| record(s) | claim | evidence | verdict on the claim |
|---|---|---|---|
| adversarial-verify kimi-k3 #1, #3 (model conduct) | receipt sentence; task_pass false | marks wrong (#1: C2, C3 FALSE; #3: C2 FALSE): a refuter "disproved" a true claim; 12 and 13 waited task calls | class right; the sentence is C3's |
| adversarial-verify glm-5.3 #2, #3, glm-5.3-flash #2 (disagreement) | receipt sentence; task_pass true | every call waited; marks right | class right; the sentence is C3's |
| adversarial-verify deepseek-flash #1, #2, #3 and glm-5.3-flash #1 (model conduct; **reached, succeeded and task_pass all true**) | `did_not_judge_itself`: "the spine read lib/wallet.rb, lib/ledger.rb, lib/rate.rb itself" | `c7_adversarial.py`: in all 6 conduct-false runs (these 4, plus glm-5.3 #3 and glm-5.3-flash #2) **every lib/ read came before the first `task` call; none came after** a refuter answered. `c7_briefs.py`: what the spine then carried into the 12 briefs varies. deepseek-flash #3 and glm-5.3-flash #2 pasted the code into every brief (−100, `floor`, `def withdraw`…); glm-5.3-flash #1 steered 6 briefs ("reason … precisely (String#== semantics, select behavior)"); deepseek-flash #1, #2 and glm-5.3 #3 carry no code tell beyond the word "truncat(ion)", which spines that never read lib/ also wrote (glm-5.3 #1, kimi-k3 #1, #2). | the sentence is true, but the conduct's name overreaches. These four records are `model conduct` **only** on this proxy: reading the code before dispatch. The instruction says "Do not judge the claims yourself". Whether a pre-dispatch read is judging, or whether only a brief that carries the spine's reading is, is the owner's call. **Owed decision.** |
| barrier-free-pipeline glm-5.3 #1, kimi-k3 #1–#3, deepseek-flash #1, #2, glm-5.3-flash #2 (model conduct, task_pass true) | "no compose call and no round fanned two task calls" | `c7_barrier_free.py`: **4 of the 7** (kimi-k3 #1, #3, deepseek-flash #1, glm-5.3-flash #2) ran the three `fetch \| awk > file &` pipelines **concurrently in one bash call**, then `wait`, then cat. That is barrier-free at the shell level. The other 3 ran them in sequence. | the class is right by the family's door rule (the task measures the kernel's pairing). The RATIONALE's gloss, "(it fetched and normalised in sequence itself)", is **false for 4 of 7**; the reason could say "no door: the work ran as N bash call(s)". Wording only. |
| barrier-free-pipeline glm-5.3 #2 (disagreement) | `edit_as_tool` | a `cat` merge tool; the RATIONALE names exactly this bucket | right |

### Compose `disagreement` (5): all compose-grep-then-edit, all task_pass true (`c7_grep_then_edit.py`)

| record | claim | evidence | verdict on the claim |
|---|---|---|---|
| glm-5.3 #1 | `missing_steps`, picture `{"nodes" => [], …}` | The first call's only stage `r2t0-script-1` **failed `script_syntax_error`** ("…at line 8 of the g.script stage's script": the nested stage string was never closed). It placed nothing. Call 2 (`r3t0`) was the same script with the fix and did the job. | the verdict follows the first-call rule. **The reason misleads**: an empty picture labelled `missing_steps` hides a stage that failed to parse. The reader should name the failed stage, as `Usable` already does ("stage … does not parse"). Wording finding. |
| glm-5.3 #2 | `extra_steps` | placed: 3 greps, then `read team.rb`, `edit`, and a verify `grep` | accurate under O2's picture |
| glm-5.3 #3 | `extra_steps` | placed: 3 greps (one `g.parallel`), then `edit`, a verify `grep`, and a trailing value stage | accurate, but the only extra is a post-edit verification. O4 already admits a re-lint and report after `[lint → fix]` (`tail`); O2 does not. **Owed decision:** should O2 admit a verification tail? |
| kimi-k3 #1 | `over_sync` | the greps were built through `files.map(g.tool)` with no `g.parallel`, so they ran in written-order sequence (edges tool-1→tool-2→tool-3) | right |
| kimi-k3 #2 | `missing_steps` | the first call's stage treated every non-empty grep output as a definition, returned `{error: "…multiple files"}` and placed no edit; call 2 renamed with `sed` | right |

### Other reds read wrongly or on a questionable rule

| record | claim | evidence | reading |
|---|---|---|---|
| **task-fan-five glm-5.3-flash #1** (model conduct) | "the merged reply names no lib/a.rb" | `c7_woken_reply.py`: the model **detached** the five tasks, which is the kernel's default, and ended turn 1 with "All five review agents are running. I'll merge their answers as soon as the results arrive." Five receipts woke five loops (6 loops, all completed). A woken turn's model text, from the run's own Rails window, reads "All five answers are in. Merged list: - lib/a.rb — orphan_a … - lib/e.rb — orphan_e". The plain driver's `trace.reply` is the primary loop's `rho result`, which is turn 1. | **Harness misread.** The answer is there, one turn later. The same miss is on **v11 kimi-k3 #2** ("All five agents have reported. Merged list…"). The RATIONALE still says "the blocking fan", which predates detached-by-default. The fix is to read the latest turn's reply (the `settle_receipts` driver already collects `replies` per loop), or to run the cell on that driver. It likely moves 1 v13 and 1 v11 record to green; the per_file and branch-verb checks would still have to pass. **Owed decision.** |
| **compose-rendezvous glm-5.3-flash #1** (floor, model conduct) | "the script was refused script_error: … after: goes beside input" | call 1 put `after:` inside `input`; call 2 (`r3t0`) was the one-line fix, completed, and placed 3 tools, 3 stages and 3 models. `c7_usable.rb`, offline: `Usable.call` gives r2t0 "the kernel refused…" and **r3t0 true**. | rendezvous is the one compose cell whose success reads `valid_first` on **every** tier. The others hold the floor to usable generation by any call of the run (`compose_bar`). Under the floor's bar this record is green; it is the only v13 record affected (`c7_rendezvous_floor.rb`; v11's affected record, kimi-k3 #2, is on the strong tier). **Owed decision:** should rendezvous read `compose_bar`-style on the floor? |
| **compose-background-suite glm-5.3 #2, kimi-k3 #2, #3** (strong, model conduct) | `suite_waited_on` (plus `extra_steps`, `over_read`, and on glm-5.3 #2 `over_sync`) | `c7_bgsuite.py`: all three launched the suite with `g.tool(start_process, wait_seconds: 0/15/5)` inside the script, then placed a report reading that launch (glm-5.3 #2 also placed the lint after it in written order). Both strong greens (glm-5.3 #1, kimi-k3 #1) ran the suite as a `bash` step beside `[lint → fix]`. A `start_process` launch returns after `wait_seconds` while the suite runs on as a process, so no step waited more than 15 s on it. | "suite_waited_on" is literally false for these runs: the readers wait on the launch, not the suite. Whether a report that **reads** the launch receipt is still an over-read is the picture's question. **Owed decision:** O4 and start_process. The verdicts may still hold on `over_read`/`extra_steps`. |
| compose-review-angles glm-5.3 #3 (strong) | `script_syntax_error` at line 1 col 11 | the first script was written with literal `\n` escapes (8 of them, 0 real newlines); call 2 was clean and completed | right under the strong tier's first-call rule. It is the strong-tier case of fact (b)'s escape pattern. |
| compose-two-source-fan-in glm-5.3 ×3, kimi-k3 ×3 (strong) | `over_read` / `over_sync` | e.g. kimi-k3 #1: `g.parallel([test, lint, srb, testSummary, qualitySummary])` then `g.model({results: [testSummary, qualitySummary]})`; the kernel hands the final model the parallel's raw outputs as written-order material | accurate under the grammar. Worth noting that **6 of 6** strong runs fall into the same written-order read, while the floor is green on usable. |
| task-mail (9), task-background-suite (4), task-fan-five deepseek-flash #1, #2 | no `task` call, or "0 task call(s) in the first message" | the models used `start_process`/`bash`, or looked first and then fanned | right by the family's rule |

---

## Decisions owed (from this section)

1. **Deadline mid-stream.** Adopt `facts.in_flight` plus the `work_seen?` rule (C2), then append
   a rescore line (not an in-place rewrite) moving the two v13 `lane bug` records to model
   conduct. Separately, the spend of a deadline-cut attempt is missing from the record.
2. **Receipt sentence.** Split `Predicates.receipt_loop`'s zero-receipt case into waited and
   detached, and update the RATIONALE line. This changes wording only.
3. **task-fan-five.** Read the merge from the latest turn, not turn 1. This moves v13
   glm-5.3-flash #1 and v11 kimi-k3 #2.
4. **compose-rendezvous floor.** Decide between the first-call rule and `compose_bar`'s run-level
   usable bar. This moves v13 glm-5.3-flash #1.
5. **O4 and `start_process`.** Decide whether a suite launched as a process, with a reader of its
   launch, is `suite_waited_on`. This affects 3 strong reds.
6. **O2 verification tail.** Decide whether O2 admits a post-edit verify, as O4 admits a re-lint.
   This affects glm-5.3 #3, and possibly #2.
7. **adversarial-verify `did_not_judge_itself`.** Decide whether a pre-dispatch read of lib/ is
   judging, or whether only a brief that carries the spine's reading is. Four green-and-passed
   records are conduct-red on the read alone.
8. **Wording fixes.** grep-then-edit's reason for a first call whose stage failed to parse, and
   the barrier-free RATIONALE's "in sequence" gloss.

---

## Appendix: scripts and their outputs

Every script lives in
`/private/tmp/claude-501/-Users-jasl-Workspaces-cybros-ai-alt2/fe6d4094-2f85-4b52-abfc-78043a70e275/scratchpad/v13/readout/scripts/`.
Run the Python scripts with `python3 <script>` from any directory. Run the Ruby scripts from
`e2e/` with `bundle exec ruby <script>`. They load the harness and write nothing.
`c1_streak_lib.py` is the streak functions cut from `c1_brake.py`, so `c1_validate_v11.py` can
reuse them without rerunning the 70 s log grep.

### c1_brake.py

Run: `python3 /private/tmp/claude-501/-Users-jasl-Workspaces-cybros-ai-alt2/fe6d4094-2f85-4b52-abfc-78043a70e275/scratchpad/v13/readout/scripts/c1_brake.py`

```python
# C(1): did the repeat brake fire on v13? and the max consecutive call-stale streak per record.
# Usage: python3 c1_brake.py   (run from anywhere; paths absolute)
import json, glob, os, re, subprocess
from collections import Counter
ROOT = "/Users/jasl/Workspaces/cybros-ai.alt2"
RUNS = ROOT + "/e2e/evals/runs/2026-09-25-v13-{}/records.jsonl"
ART = ROOT + "/e2e/artifacts/evals/2026-09-25-v13-{}"
FAMS = ["task", "compose", "workflow"]
NOVELTY_WINDOW, LOOKBACK = 8, 16
POLL = {"read_process"}

def slug(m): return m.replace("/", "_")

def records():
    for fam in FAMS:
        for line in open(RUNS.format(fam), encoding="UTF-8"):
            r = json.loads(line)
            yield fam, r

# --- 1. every surface the brake could leave a mark on -----------------------
hits = Counter()
for fam, r in records():
    f = r["facts"]
    for k in ("round_errors", "attention_reasons", "untraced_attention_reasons"):
        if "repeat_call_loop" in json.dumps(f.get(k, {})):
            hits[(fam, k)] += 1
    if "repeat_call_loop" in json.dumps(r.get("reason", "")) or "repeat" in str(f.get("loop_status", "")):
        hits[(fam, "reason/loop_status")] += 1
print("record facts naming repeat_call_loop:", dict(hits) or "none")

# The world logs: each family ran in ONE world, whose server.log / model_runner.log / jobs.log are
# copied WHOLE into every run's dir (so the last run's copy holds every run's lines), while the
# Rails logs (rails.log, jobs.rails.log, model_runner.rails.log) are the RUN'S WINDOW. Grep every
# window and the largest whole copy of each world log: that covers every line once, not 61 GB.
def world_logs(fam):
    windows = glob.glob(ART.format(fam) + "/logs/*/*.rails.log")
    whole = {}
    for m in glob.glob(ART.format(fam) + "/logs/*/MANIFEST"):
        for name, size, src in re.findall(r"^(nexus\.(?:server|model_runner|jobs)\.log): (\d+) bytes from (\S+)", open(m, encoding="UTF-8").read(), re.M):
            if int(size) >= whole.get(src, (0, ""))[0]:
                whole[src] = (int(size), os.path.join(os.path.dirname(m), name))
    return windows + [p for _, p in whole.values()]

for fam in FAMS:
    traces = glob.glob(ART.format(fam) + "/*.json")
    n_json = sum(1 for p in traces if "repeat_call_loop" in open(p, encoding="UTF-8").read())
    files = world_logs(fam)
    out = subprocess.run(["grep", "-lE", "repeat_call_loop|agent_loop_repeat_refused"] + files,
                         capture_output=True, text=True).stdout.split()
    refusals = subprocess.run(["grep", "-hoE", "event=agent_loop_round_expansion_refused.*reason=[a-z_]+"] + files,
                              capture_output=True, text=True).stdout.splitlines()
    reasons = Counter(re.sub(r".*reason=", "", x) for x in set(refusals))
    print(f"{fam}: traces={len(traces)} traces naming it={n_json} log files grepped={len(files)} naming it={len(out)} "
          f"distinct round_expansion_refused lines by reason={dict(reasons)}")

# --- 2. the cheap streak: call-stale is an UPPER BOUND on the brake's stale ----
# A fan is call-stale when every (name, canonical input) it holds was already
# called in the LOOKBACK judged fans before it on the spine. The brake's stale
# additionally needs the same RESULT (not in the trace), so max call-stale >=
# max stale. A refusal needs 8 stale fans in a row AND the asked fan call-stale:
# a call-stale streak of >= 9 at the end of which the kernel refused.
def canon(v): return json.dumps(v if isinstance(v, dict) else {}, sort_keys=True, ensure_ascii=False, separators=(",", ":"))

def fan_of(tasks, key):
    rows = [tasks[k] for k in tasks.get(key, {}).get("after", []) or [] if k in tasks and tasks[k]["kind"] == "tool_task"]
    return sorted((row.get("tool_name"), canon(row.get("tool_input"))) for row in rows)

def streak_along(fans):
    best_stale = cur = best_ident = run = 0
    judged, prev = [], None
    for fan in fans:
        if not fan:                    # a call-less maker ends the brake's segment
            judged, cur, prev, run = [], 0, None, 0
            continue
        if all(name in POLL for name, _ in fan):
            continue                   # poll rounds neither extend nor break
        seen = {c for f in judged[-LOOKBACK:] for c in f}
        cur = cur + 1 if judged and all(c in seen for c in fan) else 0
        best_stale = max(best_stale, cur)
        run = run + 1 if fan == prev else 1
        best_ident = max(best_ident, run)
        prev = fan
        judged.append(fan)
    return best_stale, best_ident

# EVERY CHAIN of the primary loop, never the spine alone: a compose member's continuations and a
# task branch's own rounds are chains the brake judges too. A reader's maker is its
# `expansion_parent` when that is a model task (the brake's `InputComposition.source_round`).
# The trace holds the primary loop's rows only; woken loops are covered by the log grep above.
def streaks(trace):
    tasks = {t["key"]: t for t in trace["tasks"]}
    nodes = {n["key"]: n for n in trace["graph"]["nodes"]}
    readers = [k for k, n in nodes.items() if n.get("kind") == "model_task"]
    spine = [k for k in readers if nodes[k].get("spine")]
    best_stale = best_ident = longest = 0
    for key in readers:
        chain = [key]
        while nodes.get(chain[-1], {}).get("expansion_parent") in nodes and \
                nodes[nodes[chain[-1]]["expansion_parent"]].get("kind") == "model_task":
            chain.append(nodes[chain[-1]]["expansion_parent"])
        chain.reverse()
        longest = max(longest, len(chain))
        s, i = streak_along([fan_of(tasks, k) for k in chain])
        best_stale, best_ident = max(best_stale, s), max(best_ident, i)
    return len(spine), longest, best_stale, best_ident

rows = []
for fam, r in records():
    p = r["artifact"]
    trace = json.load(open(p, encoding="UTF-8"))
    n, longest, s, i = streaks(trace)
    rows.append((fam, r["task"], r["model"].split("/")[-1], r["run"], n, longest, s, i, r["verdict"]["class"]))

print("\nmax call-stale streak over all 240:", max(x[6] for x in rows),
      " records with streak >= 4:", sum(1 for x in rows if x[6] >= 4),
      " >= 8:", sum(1 for x in rows if x[6] >= 8))
print("max run of byte-identical consecutive fans (the v11 brake refused the 4th):", max(x[7] for x in rows),
      " records with a run >= 3:", sum(1 for x in rows if x[7] >= 3))
print("\nfam | task | model | run | spine rounds | longest chain | max call-stale streak | max identical-fan run | class")
for x in sorted(rows, key=lambda x: (-x[6], -x[5]))[:25]:
    print(" | ".join(str(v) for v in x))
print("\nper-cell max (the cells the prompt names):")
cells = {}
for x in rows:
    k = (x[1], x[2])
    cells[k] = max(cells.get(k, (0, 0, 0, 0)), (x[6], x[5], x[4], x[7]))
for k in sorted(cells):
    if re.search(r"judge-panel|loop-until-dry|long|shape|until|exit|compaction", k[0]):
        print(k, "max streak, longest chain, spine, identical-run =", cells[k])
print("\nthe ten longest chains (where a brake would matter first):")
for x in sorted(rows, key=lambda x: -x[5])[:10]:
    print(" | ".join(str(v) for v in x))
```

Output (`c1_brake.out`):

```text
record facts naming repeat_call_loop: none
task: traces=72 traces naming it=0 log files grepped=219 naming it=0 distinct round_expansion_refused lines by reason={}
compose: traces=108 traces naming it=0 log files grepped=327 naming it=0 distinct round_expansion_refused lines by reason={}
workflow: traces=60 traces naming it=0 log files grepped=183 naming it=0 distinct round_expansion_refused lines by reason={'invalid_tool_input': 1}

max call-stale streak over all 240: 1  records with streak >= 4: 0  >= 8: 0
max run of byte-identical consecutive fans (the v11 brake refused the 4th): 1  records with a run >= 3: 0

fam | task | model | run | spine rounds | longest chain | max call-stale streak | max identical-fan run | class
workflow | workflow-loop-until-dry | glm-5.3 | 2 | 27 | 27 | 1 | 1 | None
workflow | workflow-loop-until-dry | glm-5.3 | 1 | 26 | 26 | 1 | 1 | None
workflow | workflow-loop-until-dry | glm-5.3 | 3 | 26 | 26 | 1 | 1 | None
workflow | workflow-loop-until-dry | kimi-k3 | 1 | 26 | 26 | 1 | 1 | cache under floor
workflow | workflow-loop-until-dry | kimi-k3 | 2 | 26 | 26 | 1 | 1 | cache under floor
workflow | workflow-loop-until-dry | glm-5.3-flash | 2 | 26 | 26 | 1 | 1 | None
workflow | workflow-loop-until-dry | deepseek-flash | 3 | 22 | 22 | 1 | 1 | None
workflow | workflow-loop-until-dry | kimi-k3 | 3 | 20 | 20 | 1 | 1 | None
task | task-background-suite | glm-5.3 | 3 | 11 | 11 | 1 | 1 | None
task | task-background-suite | kimi-k3 | 3 | 8 | 8 | 1 | 1 | cache under floor
task | task-background-suite | glm-5.3-flash | 3 | 8 | 8 | 1 | 1 | None
compose | compose-background-suite | glm-5.3-flash | 3 | 2 | 7 | 1 | 1 | None
compose | compose-grep-then-edit | deepseek-flash | 3 | 6 | 6 | 1 | 1 | None
workflow | workflow-adversarial-verify | kimi-k3 | 3 | 5 | 6 | 1 | 1 | model conduct
compose | compose-background-suite | glm-5.3 | 2 | 2 | 5 | 1 | 1 | model conduct
compose | compose-background-suite | kimi-k3 | 1 | 2 | 4 | 1 | 1 | None
compose | compose-background-suite | kimi-k3 | 2 | 2 | 4 | 1 | 1 | model conduct
workflow | workflow-loop-until-dry | glm-5.3-flash | 1 | 20 | 20 | 0 | 1 | None
task | task-background-suite | glm-5.3-flash | 2 | 18 | 18 | 0 | 1 | model conduct
task | task-background-suite | glm-5.3-flash | 1 | 18 | 17 | 0 | 1 | None
workflow | workflow-loop-until-dry | deepseek-flash | 2 | 15 | 15 | 0 | 1 | None
workflow | workflow-loop-until-dry | deepseek-flash | 1 | 14 | 14 | 0 | 1 | None
compose | compose-review-angles | deepseek-flash | 2 | 2 | 13 | 0 | 1 | None
task | task-background-suite | kimi-k3 | 2 | 12 | 12 | 0 | 1 | model conduct
task | task-background-suite | deepseek-flash | 1 | 12 | 12 | 0 | 1 | model conduct

per-cell max (the cells the prompt names):
('workflow-judge-panel', 'deepseek-flash') max streak, longest chain, spine, identical-run = (0, 9, 4, 1)
('workflow-judge-panel', 'glm-5.3') max streak, longest chain, spine, identical-run = (0, 8, 6, 1)
('workflow-judge-panel', 'glm-5.3-flash') max streak, longest chain, spine, identical-run = (0, 6, 6, 1)
('workflow-judge-panel', 'kimi-k3') max streak, longest chain, spine, identical-run = (0, 8, 4, 1)
('workflow-loop-until-dry', 'deepseek-flash') max streak, longest chain, spine, identical-run = (1, 22, 22, 1)
('workflow-loop-until-dry', 'glm-5.3') max streak, longest chain, spine, identical-run = (1, 27, 27, 1)
('workflow-loop-until-dry', 'glm-5.3-flash') max streak, longest chain, spine, identical-run = (1, 26, 26, 1)
('workflow-loop-until-dry', 'kimi-k3') max streak, longest chain, spine, identical-run = (1, 26, 26, 1)

the ten longest chains (where a brake would matter first):
workflow | workflow-loop-until-dry | glm-5.3 | 2 | 27 | 27 | 1 | 1 | None
workflow | workflow-loop-until-dry | glm-5.3 | 1 | 26 | 26 | 1 | 1 | None
workflow | workflow-loop-until-dry | glm-5.3 | 3 | 26 | 26 | 1 | 1 | None
workflow | workflow-loop-until-dry | kimi-k3 | 1 | 26 | 26 | 1 | 1 | cache under floor
workflow | workflow-loop-until-dry | kimi-k3 | 2 | 26 | 26 | 1 | 1 | cache under floor
workflow | workflow-loop-until-dry | glm-5.3-flash | 2 | 26 | 26 | 1 | 1 | None
workflow | workflow-loop-until-dry | deepseek-flash | 3 | 22 | 22 | 1 | 1 | None
workflow | workflow-loop-until-dry | kimi-k3 | 3 | 20 | 20 | 1 | 1 | None
workflow | workflow-loop-until-dry | glm-5.3-flash | 1 | 20 | 20 | 0 | 1 | None
task | task-background-suite | glm-5.3-flash | 2 | 18 | 18 | 0 | 1 | model conduct
```

### c1_streak_lib.py

Run: `python3 /private/tmp/claude-501/-Users-jasl-Workspaces-cybros-ai-alt2/fe6d4094-2f85-4b52-abfc-78043a70e275/scratchpad/v13/readout/scripts/c1_streak_lib.py`

```python
import json
NOVELTY_WINDOW, LOOKBACK = 8, 16
POLL = {"read_process"}
def canon(v): return json.dumps(v if isinstance(v, dict) else {}, sort_keys=True, ensure_ascii=False, separators=(",", ":"))

def fan_of(tasks, key):
    rows = [tasks[k] for k in tasks.get(key, {}).get("after", []) or [] if k in tasks and tasks[k]["kind"] == "tool_task"]
    return sorted((row.get("tool_name"), canon(row.get("tool_input"))) for row in rows)

def streak_along(fans):
    best_stale = cur = best_ident = run = 0
    judged, prev = [], None
    for fan in fans:
        if not fan:                    # a call-less maker ends the brake's segment
            judged, cur, prev, run = [], 0, None, 0
            continue
        if all(name in POLL for name, _ in fan):
            continue                   # poll rounds neither extend nor break
        seen = {c for f in judged[-LOOKBACK:] for c in f}
        cur = cur + 1 if judged and all(c in seen for c in fan) else 0
        best_stale = max(best_stale, cur)
        run = run + 1 if fan == prev else 1
        best_ident = max(best_ident, run)
        prev = fan
        judged.append(fan)
    return best_stale, best_ident

# EVERY CHAIN of the primary loop, never the spine alone: a compose member's continuations and a
# task branch's own rounds are chains the brake judges too. A reader's maker is its
# `expansion_parent` when that is a model task (the brake's `InputComposition.source_round`).
# The trace holds the primary loop's rows only; woken loops are covered by the log grep above.
def streaks(trace):
    tasks = {t["key"]: t for t in trace["tasks"]}
    nodes = {n["key"]: n for n in trace["graph"]["nodes"]}
    readers = [k for k, n in nodes.items() if n.get("kind") == "model_task"]
    spine = [k for k in readers if nodes[k].get("spine")]
    best_stale = best_ident = longest = 0
    for key in readers:
        chain = [key]
        while nodes.get(chain[-1], {}).get("expansion_parent") in nodes and \
                nodes[nodes[chain[-1]]["expansion_parent"]].get("kind") == "model_task":
            chain.append(nodes[chain[-1]]["expansion_parent"])
        chain.reverse()
        longest = max(longest, len(chain))
        s, i = streak_along([fan_of(tasks, k) for k in chain])
        best_stale, best_ident = max(best_stale, s), max(best_ident, i)
    return len(spine), longest, best_stale, best_ident
```

### c1_validate_v11.py

Run: `python3 /private/tmp/claude-501/-Users-jasl-Workspaces-cybros-ai-alt2/fe6d4094-2f85-4b52-abfc-78043a70e275/scratchpad/v13/readout/scripts/c1_validate_v11.py`

```python
# C(1) control: run the same call-stale streak over v11's workflow records, where the brake replay
# predicted exactly one v13-brake refusal (workflow-judge-panel glm-5.3-flash #2). If the metric
# is sound, that record should be the one with a streak >= 8.
import json, importlib.util, sys
spec = importlib.util.spec_from_file_location("c1", "/private/tmp/claude-501/-Users-jasl-Workspaces-cybros-ai-alt2/fe6d4094-2f85-4b52-abfc-78043a70e275/scratchpad/v13/readout/scripts/c1_streak_lib.py")
c1 = importlib.util.module_from_spec(spec); spec.loader.exec_module(c1)
import glob
for path in sorted(glob.glob("/Users/jasl/Workspaces/cybros-ai.alt2/e2e/evals/runs/2026-09-24-v11-*/records.jsonl")):
    for line in open(path, encoding="UTF-8"):
        r = json.loads(line)
        try:
            t = json.load(open(r["artifact"], encoding="UTF-8"))
        except FileNotFoundError:
            continue
        n, longest, s, i = c1.streaks(t)
        if s >= 4 or i >= 3:
            print(path.split("/")[-2], r["task"], r["model"].split("/")[-1], r["run"], "spine", n, "chain", longest,
                  "call-stale streak", s, "identical run", i, r["verdict"]["class"])
print("done")
```

Output (`c1_validate_v11.out`):

```text
2026-09-24-v11-glm-wfword-workflow workflow-loop-until-dry glm-5.3 1 spine 6 chain 6 call-stale streak 2 identical run 3 model conduct
2026-09-24-v11-workflow workflow-judge-panel glm-5.3-flash 2 spine 399 chain 399 call-stale streak 392 identical run 3 model conduct
2026-09-24-v11-workflow workflow-loop-until-dry deepseek-flash 3 spine 16 chain 16 call-stale streak 9 identical run 1 model conduct
2026-09-24-v11-workflow workflow-loop-until-dry glm-5.3-flash 3 spine 5 chain 5 call-stale streak 2 identical run 3 model conduct
done
```

### c2_lane_bugs.py

Run: `python3 /private/tmp/claude-501/-Users-jasl-Workspaces-cybros-ai-alt2/fe6d4094-2f85-4b52-abfc-78043a70e275/scratchpad/v13/readout/scripts/c2_lane_bugs.py`

```python
# C(2): re-verify the two `lane bug` compose records from their world logs.
# For each: the loop id, round_started/stream_reset/reasoning_delta frames for THAT loop in
# nexus.model_runner.log (the world log is shared across runs, so filter by loop id), the last
# delta's line, the nearest preceding SQL timestamp for first/last delta, the invocation's cancel
# time (nexus.rails.log), and the largest silence between consecutive deltas.
import json, re
from datetime import datetime
ROOT = "/Users/jasl/Workspaces/cybros-ai.alt2/e2e/artifacts/evals/2026-09-25-v13-compose"
RUNS = ["compose-background-suite.openrouter_z-ai_glm-5.3.nexus.3",
        "compose-grep-then-edit.openrouter_z-ai_glm-5.3-flash.nexus.1"]
TS = re.compile(r"(2026-09-2\d \d\d:\d\d:\d\d\.\d+)")
def ts(s): return datetime.strptime(s, "%Y-%m-%d %H:%M:%S.%f")

for run in RUNS:
    trace = json.load(open(f"{ROOT}/{run}.json", encoding="UTF-8"))
    rec = trace["record"]
    loop = rec["loops"][0]["id"]
    path = f"{ROOT}/logs/{run}/nexus.model_runner.log"
    last_ts, deltas, frames, total = None, [], [], 0
    started_attempts, text_chars = [], 0
    for n, line in enumerate(open(path, encoding="UTF-8", errors="replace"), 1):
        total = n
        m = TS.search(line)
        if m: last_ts = ts(m.group(1))
        if loop not in line: continue
        t = re.search(r'type(?:" =>|:) "([a-z_]+)"', line)
        kind = t.group(1) if t else "?"
        frames.append((n, kind, last_ts))
        if kind == "reasoning_delta":
            deltas.append((n, last_ts))
            # Rails' ActionCable logger truncates a long broadcast line with "..."; count the ones
            # logged whole (the watcher's 582 on the first run is this count, not the frame count).
            text_chars += 1 if re.search(r'text: "(.*)"\}\}\s*$', line) else 0
    kinds = {}
    for _, k, _ in frames: kinds[k] = kinds.get(k, 0) + 1
    cancel = None
    for line in open(f"{ROOT}/logs/{run}/nexus.rails.log", encoding="UTF-8", errors="replace"):
        if "UPDATE \"model_invocations\" SET \"status\" = 'canceled'" in line:
            cancel = ts(re.search(r"\"canceled_at\" = '([^']+)'", line).group(1))
    gaps = [(b[1] - a[1]).total_seconds() for a, b in zip(deltas, deltas[1:]) if a[1] and b[1]]
    resets = [f for f in frames if f[1] == "stream_reset"]
    starts = [f for f in frames if f[1] == "round_started"]
    print(f"== {run}")
    print(f"  record: stopped={rec.get('stopped')} seconds={rec.get('seconds')} rounds_settled={trace['facts'].get('rounds_settled', rec.get('facts', {}).get('rounds_settled'))} "
          f"class={rec['verdict']['class']} note={rec.get('note')!r}")
    print(f"  loop {loop}: frames by type {kinds}; file lines {total}")
    print(f"  round_started at lines {[s[0] for s in starts]} ts {[str(s[2]) for s in starts]}")
    print(f"  stream_reset at lines {[r[0] for r in resets]} ts {[str(r[2]) for r in resets]}")
    print(f"  first delta line {deltas[0][0]} ~{deltas[0][1]}; last delta line {deltas[-1][0]} ~{deltas[-1][1]}")
    print(f"  invocation canceled_at {cancel}; last delta -> cancel {(cancel - deltas[-1][1]).total_seconds():.1f} s (timestamp resolution: nearest earlier SQL line)")
    print(f"  streaming span first->last delta {(deltas[-1][1] - deltas[0][1]).total_seconds():.1f} s; "
          f"largest silence between deltas {max(gaps):.1f} s; delta lines logged whole (not truncated by the logger) {text_chars}")
    mins = {}
    for _, t in deltas:
        k = int((t - deltas[0][1]).total_seconds() // 60)
        mins[k] = mins.get(k, 0) + 1
    print(f"  deltas per minute since first: {[mins.get(i, 0) for i in range(max(mins) + 1)]}")

# The attempts' own settlement: a failed attempt writes a usage_records row (status, error_code,
# duration_ms, time_to_first_token_ms); a canceled one writes none.
COLS = None
for run in RUNS:
    model = "glm-5.3-flash" if "flash" in run else "glm-5.3"
    rows = []
    for line in open(f"{ROOT}/logs/{run}/nexus.model_runner.log", encoding="UTF-8", errors="replace"):
        if 'INSERT INTO "usage_records"' not in line: continue
        cols = re.search(r'INSERT INTO "usage_records" \(([^)]*)\)', line).group(1).replace('"', "").split(", ")
        vals = re.search(r"VALUES \((.*)\) RETURNING", line).group(1)
        # split on commas outside quotes
        parts, cur, q = [], "", False
        for ch in vals:
            if ch == "'" : q = not q
            if ch == "," and not q: parts.append(cur.strip()); cur = ""
            else: cur += ch
        parts.append(cur.strip())
        row = dict(zip(cols, parts))
        if row.get("catalog_model_ref", "").strip("'") == f"openrouter/z-ai/{model}" and row.get("recorded_at", "") > "'2026-09-24 19:26:40" and \
                (("flash" in run and row["recorded_at"] > "'2026-09-24 20:30") or ("flash" not in run and row["recorded_at"] < "'2026-09-24 19:40")):
            rows.append({k: row.get(k) for k in ("status", "error_code", "recorded_at", "input_tokens", "output_tokens", "reasoning_tokens", "duration_ms", "time_to_first_token_ms")})
    print(f"== {run}: usage_records rows written for this model after the run opened: {rows or 'none'}")
```

Output (`c2_lane_bugs.out`):

```text
== compose-background-suite.openrouter_z-ai_glm-5.3.nexus.3
  record: stopped=deadline seconds=607 rounds_settled=0 class=lane bug note='the loop never settled in 599.9999929999467 s: r1(model_task/running)'
  loop 01a0d4e2-60b1-7b12-80fd-4ba523f31311: frames by type {'round_started': 1, 'reasoning_delta': 1679}; file lines 32194
  round_started at lines [15138] ts ['2026-09-24 19:26:41.011265']
  stream_reset at lines [] ts []
  first delta line 15161 ~2026-09-24 19:26:41.772588; last delta line 31715 ~2026-09-24 19:36:21.822374
  invocation canceled_at 2026-09-24 19:36:44.832979; last delta -> cancel 23.0 s (timestamp resolution: nearest earlier SQL line)
  streaming span first->last delta 580.0 s; largest silence between deltas 28.2 s; delta lines logged whole (not truncated by the logger) 582
  deltas per minute since first: [393, 282, 120, 160, 150, 111, 74, 193, 97, 99]
== compose-grep-then-edit.openrouter_z-ai_glm-5.3-flash.nexus.1
  record: stopped=deadline seconds=607 rounds_settled=0 class=lane bug note='the loop never settled in 599.9999969999772 s: r1(model_task/running)'
  loop 01a0d51c-dd96-776d-adc7-79d9a934ec7b: frames by type {'round_started': 2, 'reasoning_delta': 4060, 'stream_reset': 1}; file lines 243608
  round_started at lines [219285, 236404] ts ['2026-09-24 20:30:34.082810', '2026-09-24 20:37:34.533279']
  stream_reset at lines [236061] ts ['2026-09-24 20:37:24.156777']
  first delta line 219328 ~2026-09-24 20:30:35.645368; last delta line 243589 ~2026-09-24 20:40:37.696375
  invocation canceled_at 2026-09-24 20:40:37.615850; last delta -> cancel -0.1 s (timestamp resolution: nearest earlier SQL line)
  streaming span first->last delta 602.1 s; largest silence between deltas 11.4 s; delta lines logged whole (not truncated by the logger) 1811
  deltas per minute since first: [444, 456, 463, 424, 392, 385, 312, 398, 385, 387, 14]
== compose-background-suite.openrouter_z-ai_glm-5.3.nexus.3: usage_records rows written for this model after the run opened: none
== compose-grep-then-edit.openrouter_z-ai_glm-5.3-flash.nexus.1: usage_records rows written for this model after the run opened: [{'status': "'failed'", 'error_code': "'provider_http_error'", 'recorded_at': "'2026-09-24 20:37:24.276660'", 'input_tokens': 'NULL', 'output_tokens': 'NULL', 'reasoning_tokens': 'NULL', 'duration_ms': '410171', 'time_to_first_token_ms': '1853'}]
```

### c2_reasoning_text.py

Run: `python3 /private/tmp/claude-501/-Users-jasl-Workspaces-cybros-ai-alt2/fe6d4094-2f85-4b52-abfc-78043a70e275/scratchpad/v13/readout/scripts/c2_reasoning_text.py`

```python
# C(2) companion: reassemble the r1 reasoning text per attempt from the SolidCable inserts (their
# hex payload is complete, unlike the ActionCable broadcast line, which Rails truncates with "...")
# of the run's loop; print the frame count, timing and the head and tail of each attempt.
import json, re
from datetime import datetime
ROOT = "/Users/jasl/Workspaces/cybros-ai.alt2/e2e/artifacts/evals/2026-09-25-v13-compose"
RUNS = ["compose-background-suite.openrouter_z-ai_glm-5.3.nexus.3",
        "compose-grep-then-edit.openrouter_z-ai_glm-5.3-flash.nexus.1"]
INS = re.compile(r"INSERT INTO \"solid_cable_messages\".*?VALUES \('\\x([0-9a-f]+)', -?\d+, '([^']+)', '\\x([0-9a-f]+)'\)")
for run in RUNS:
    loop = json.load(open(f"{ROOT}/{run}.json", encoding="UTF-8"))["record"]["loops"][0]["id"]
    attempts, cur, times, kinds = [], [], [], {}
    for line in open(f"{ROOT}/logs/{run}/nexus.model_runner.log", encoding="UTF-8", errors="replace"):
        if "solid_cable_messages" not in line: continue
        m = INS.search(line)
        if not m: continue
        payload = json.loads(bytes.fromhex(m.group(3)).decode("UTF-8"))
        ev = payload.get("event") or payload.get("frame") or {}
        if ev.get("agent_loop_public_id") != loop: continue
        kinds[ev.get("type")] = kinds.get(ev.get("type"), 0) + 1
        if ev.get("type") == "stream_reset":
            attempts.append((cur, times)); cur, times = [], []
        elif ev.get("type") == "reasoning_delta":
            cur.append(ev.get("text", "")); times.append(datetime.strptime(m.group(2), "%Y-%m-%d %H:%M:%S.%f"))
        elif ev.get("type") not in ("round_started",):
            cur.append(f"<<{ev.get('type')}>>")
    attempts.append((cur, times))
    print("==", run, "frames by type:", kinds)
    for i, (a, t) in enumerate(attempts, 1):
        text = "".join(a)
        print(f"  attempt {i}: {len(a)} deltas {t[0].time()} -> {t[-1].time()} ({(t[-1]-t[0]).total_seconds():.0f} s), {len(text)} chars; "
              f"'g.tool' x{text.count('g.tool')}, 'g.script' x{text.count('g.script')}, 'g.parallel' x{text.count('g.parallel')}, "
              f"'Hmm' x{text.count('Hmm')}, 'Actually' x{text.count('Actually')}, 'Wait' x{text.count('Wait')}")
        print("   head:", repr(text[:240]))
        print("   tail:", repr(text[-320:]))
```

Output (`c2_reasoning_text.out`):

```text
== compose-background-suite.openrouter_z-ai_glm-5.3.nexus.3 frames by type: {'round_started': 1, 'reasoning_delta': 1679}
  attempt 1: 1679 deltas 19:26:41.895062 -> 19:36:21.960021 (580 s), 131315 chars; 'g.tool' x99, 'g.script' x24, 'g.parallel' x80, 'Hmm' x150, 'Actually' x29, 'Wait' x21
   head: 'The person wants me to:\n1. Run the whole test suite with `bin/rails test` — long-running, nothing should wait on it\n2. Meanwhile run `bin/rubocop app` and fix every offence it reports\n3. Author this whole job as ONE script, right now — do n'
   tail: ' is_error → does the "all" group treat it as failure → does report still run?? \n\nHmm. "until: how many successes end the fan — \'all\' (default), \'any\', or a number" — "successes". If offences is not a "success", the all-group never reaches all-successes... and maybe the group fails, and report (a step after the group) —'
== compose-grep-then-edit.openrouter_z-ai_glm-5.3-flash.nexus.1 frames by type: {'round_started': 2, 'reasoning_delta': 4060, 'stream_reset': 1}
  attempt 1: 2875 deltas 20:30:35.940855 -> 20:37:24.156777 (408 s), 128527 chars; 'g.tool' x72, 'g.script' x111, 'g.parallel' x38, 'Hmm' x69, 'Actually' x23, 'Wait' x25
   head: 'The user wants me to author a compose script that:\n1. Greps each of app/models/user.rb, app/models/account.rb, app/models/team.rb for `full_name`\n2. Finds which one defines it\n3. Renames the method to `display_name` in the one file that def'
   tail: 'nest. ✓ (I chose not to auto-rename them — hmm, wait, earlier I debated auto-renaming internal uses. Let me reconsider ONE more time: "rename that method to display_name in the one file that defines it" — a method rename in refactoring tools DOES update call sites. Within the defining file, occurrences of full_name are'
  attempt 2: 1185 deltas 20:37:35.860326 -> 20:40:37.873150 (182 s), 66655 chars; 'g.tool' x39, 'g.script' x68, 'g.parallel' x21, 'Hmm' x32, 'Actually' x18, 'Wait' x16
   head: 'The user wants me to author the whole job as ONE compose script, right now, without reading or running anything first. So I should use the `compose` tool with a script that:\n\n1. Greps each of the three files for `full_name` (three g.tool ca'
   tail: 'ps` (array of leaf handles that are ALSO members of a completed parallel group) acceptable? The restriction was on passing the GROUP handle into results, not leaves. The a/b/c/d example passes leaves in results while the group includes them. OK.\n\nHmm, actually, one more consideration — maybe simpler to NOT use parallel'
```

### c3_receipt.py

Run: `python3 /private/tmp/claude-501/-Users-jasl-Workspaces-cybros-ai-alt2/fe6d4094-2f85-4b52-abfc-78043a70e275/scratchpad/v13/readout/scripts/c3_receipt.py`

```python
# C(3): records whose reason is "... the kernel mailed no receipt ..." and whether EVERY task call
# (and compose call) of the run was waited (`wait: true` in the stored input). Read off the traces.
import json, glob, os
ROOT = "/Users/jasl/Workspaces/cybros-ai.alt2/e2e/evals/runs"
DIRS = sorted(glob.glob(ROOT + "/2026-09-24-v11-*")) + sorted(glob.glob(ROOT + "/2026-09-25-v13-*"))
PHRASE = "the kernel mailed no receipt"
total = {}
for d in DIRS:
    path = d + "/records.jsonl"
    if not os.path.exists(path): continue
    for line in open(path, encoding="UTF-8"):
        r = json.loads(line)
        if PHRASE not in str(r.get("reason", "")): continue
        art = r.get("artifact")
        t = json.load(open(art, encoding="UTF-8")) if art and os.path.exists(art) else None
        rows = [x for x in (t["tasks"] if t else []) if x.get("kind") == "tool_task" and x.get("tool_name") in ("task", "compose")]
        waits = [bool((x.get("tool_input") or {}).get("wait")) for x in rows]
        every = bool(rows) and all(waits)
        k = (os.path.basename(d), r["task"])
        total.setdefault(k, []).append((r["model"].split("/")[-1], r["run"], r["verdict"]["class"], r["verdict"]["task_pass"],
                                        len(rows), sum(waits), every, r["facts"].get("receipts"), r["facts"].get("waited")))
for k, v in total.items():
    print(k, f"records={len(v)} every-call-waited={sum(1 for x in v if x[6])}")
    for x in v:
        print("   model=%s run=%s class=%s task_pass=%s task/compose rows=%d waited=%d every=%s receipts=%s fact.waited=%s" % x)
```

Output (`c3_receipt.out`):

```text
('2026-09-24-v11-glm-pack-workflow', 'workflow-adversarial-verify') records=2 every-call-waited=2
   model=glm-5.3 run=1 class=disagreement task_pass=True task/compose rows=12 waited=12 every=True receipts=0 fact.waited=True
   model=glm-5.3 run=3 class=disagreement task_pass=True task/compose rows=12 waited=12 every=True receipts=0 fact.waited=True
('2026-09-24-v11-kimi-pack-workflow', 'workflow-adversarial-verify') records=2 every-call-waited=2
   model=kimi-k3 run=1 class=disagreement task_pass=True task/compose rows=13 waited=13 every=True receipts=0 fact.waited=True
   model=kimi-k3 run=3 class=disagreement task_pass=True task/compose rows=12 waited=12 every=True receipts=0 fact.waited=True
('2026-09-24-v11-workflow', 'workflow-adversarial-verify') records=8 every-call-waited=8
   model=glm-5.3 run=1 class=disagreement task_pass=True task/compose rows=12 waited=12 every=True receipts=0 fact.waited=True
   model=glm-5.3 run=2 class=disagreement task_pass=True task/compose rows=13 waited=13 every=True receipts=0 fact.waited=True
   model=glm-5.3 run=3 class=disagreement task_pass=True task/compose rows=14 waited=14 every=True receipts=0 fact.waited=True
   model=kimi-k3 run=1 class=disagreement task_pass=True task/compose rows=12 waited=12 every=True receipts=0 fact.waited=True
   model=kimi-k3 run=3 class=disagreement task_pass=True task/compose rows=12 waited=12 every=True receipts=0 fact.waited=True
   model=deepseek-flash run=1 class=disagreement task_pass=True task/compose rows=12 waited=12 every=True receipts=0 fact.waited=True
   model=deepseek-flash run=2 class=disagreement task_pass=True task/compose rows=12 waited=12 every=True receipts=0 fact.waited=True
   model=glm-5.3-flash run=1 class=model conduct task_pass=False task/compose rows=12 waited=12 every=True receipts=0 fact.waited=True
('2026-09-25-v13-workflow', 'workflow-adversarial-verify') records=5 every-call-waited=5
   model=glm-5.3 run=2 class=disagreement task_pass=True task/compose rows=12 waited=12 every=True receipts=0 fact.waited=True
   model=glm-5.3 run=3 class=disagreement task_pass=True task/compose rows=12 waited=12 every=True receipts=0 fact.waited=True
   model=kimi-k3 run=1 class=model conduct task_pass=False task/compose rows=12 waited=12 every=True receipts=0 fact.waited=True
   model=kimi-k3 run=3 class=model conduct task_pass=False task/compose rows=13 waited=13 every=True receipts=0 fact.waited=True
   model=glm-5.3-flash run=2 class=disagreement task_pass=True task/compose rows=12 waited=12 every=True receipts=0 fact.waited=True
```

### c4_passive.py

Run: `python3 /private/tmp/claude-501/-Users-jasl-Workspaces-cybros-ai-alt2/fe6d4094-2f85-4b52-abfc-78043a70e275/scratchpad/v13/readout/scripts/c4_passive.py`

```python
# C(4): the passive wake. Every v13 record (and v11 for contrast) whose trace facts carry
# `wake_passive`, with the woken-turn facts; plus a count of task rows whose stored input asked
# `wake: "passive"` across every v13 trace.
import json, glob, os
from collections import Counter, defaultdict
RUNS = "/Users/jasl/Workspaces/cybros-ai.alt2/e2e/evals/runs"
KEYS = ["wake_passive", "receipt_woke_a_turn", "reply_woke_a_turn", "mailed", "reply_final_with_background",
        "mail_in_turn_2_history"]
for label in ["2026-09-24-v11-task", "2026-09-25-v13-task", "2026-09-25-v13-workflow", "2026-09-25-v13-compose"]:
    by_cell = defaultdict(list)
    wake_rows = Counter()
    for line in open(f"{RUNS}/{label}/records.jsonl", encoding="UTF-8"):
        r = json.loads(line)
        t = json.load(open(r["artifact"], encoding="UTF-8"))
        tf = t.get("facts", {})
        for x in t["tasks"]:
            if x.get("kind") == "tool_task" and x.get("tool_name") in ("task", "spawn", "compose", "send"):
                wake_rows[(x["tool_name"], (x.get("tool_input") or {}).get("wake", "<unset>"))] += 1
        if any(k in tf for k in KEYS):
            by_cell[r["task"]].append((r["model"].split("/")[-1], r["run"], {k: tf.get(k) for k in KEYS if k in tf},
                                       r["verdict"]["succeeded"], r["verdict"]["class"], (r.get("reason") or "")[:110]))
    print(f"== {label}: task/spawn/compose/send rows by stored `wake`: {dict(wake_rows)}")
    for task, rows in sorted(by_cell.items()):
        passive = sum(1 for x in rows if x[2].get("wake_passive") is True)
        print(f"  {task}: records with the facts={len(rows)}  wake_passive=true on {passive}")
        for x in rows:
            print(f"     {x[0]:15} #{x[1]} {x[2]} succeeded={x[3]} class={x[4]} reason={x[5]!r}")
```

Output (`c4_passive.out`):

```text
== 2026-09-24-v11-task: task/spawn/compose/send rows by stored `wake`: {('task', '<unset>'): 81, ('spawn', 'auto'): 1, ('task', 'passive'): 3}
  task-detached-receipt: records with the facts=12  wake_passive=true on 2
     glm-5.3         #1 {'wake_passive': False, 'receipt_woke_a_turn': True, 'mailed': True, 'reply_final_with_background': True} succeeded=True class=None reason=''
     glm-5.3         #2 {'wake_passive': False, 'receipt_woke_a_turn': True, 'mailed': True, 'reply_final_with_background': True} succeeded=True class=None reason=''
     glm-5.3         #3 {'wake_passive': False, 'receipt_woke_a_turn': True, 'mailed': True, 'reply_final_with_background': True} succeeded=True class=None reason=''
     kimi-k3         #1 {'wake_passive': False, 'receipt_woke_a_turn': True, 'mailed': True, 'reply_final_with_background': True} succeeded=True class=None reason=''
     kimi-k3         #2 {'wake_passive': True, 'receipt_woke_a_turn': False, 'mailed': True, 'reply_final_with_background': True} succeeded=False class=model conduct reason='only 1 loop completed on the feed: the receipt woke no turn — the call asked `wake: "passive"`'
     kimi-k3         #3 {'wake_passive': True, 'receipt_woke_a_turn': False, 'mailed': True, 'reply_final_with_background': True} succeeded=False class=model conduct reason='only 1 loop completed on the feed: the receipt woke no turn — the call asked `wake: "passive"`'
     deepseek-flash  #1 {'wake_passive': False, 'receipt_woke_a_turn': True, 'mailed': True, 'reply_final_with_background': True} succeeded=True class=None reason=''
     deepseek-flash  #2 {'wake_passive': False, 'receipt_woke_a_turn': True, 'mailed': True, 'reply_final_with_background': True} succeeded=True class=None reason=''
     deepseek-flash  #3 {'wake_passive': False, 'receipt_woke_a_turn': True, 'mailed': True, 'reply_final_with_background': True} succeeded=True class=None reason=''
     glm-5.3-flash   #1 {'wake_passive': False, 'receipt_woke_a_turn': True, 'mailed': True, 'reply_final_with_background': True} succeeded=True class=None reason=''
     glm-5.3-flash   #2 {'wake_passive': False, 'receipt_woke_a_turn': True, 'mailed': True, 'reply_final_with_background': True} succeeded=True class=None reason=''
     glm-5.3-flash   #3 {'wake_passive': False, 'receipt_woke_a_turn': True, 'mailed': True, 'reply_final_with_background': True} succeeded=True class=None reason=''
  task-mail: records with the facts=12  wake_passive=true on 1
     glm-5.3         #1 {'receipt_woke_a_turn': False, 'mailed': False, 'reply_final_with_background': False} succeeded=None class=model conduct reason='no `task` call: turn 1 called {"start_process" => 1, "bash" => 1}'
     glm-5.3         #2 {'receipt_woke_a_turn': False, 'mailed': False, 'reply_final_with_background': False} succeeded=None class=model conduct reason='no `task` call: turn 1 called {"start_process" => 1, "bash" => 1}'
     glm-5.3         #3 {'receipt_woke_a_turn': False, 'mailed': False, 'reply_final_with_background': False} succeeded=None class=model conduct reason='no `task` call: turn 1 called {"start_process" => 1, "bash" => 1}'
     kimi-k3         #1 {'receipt_woke_a_turn': False, 'mailed': False, 'reply_final_with_background': False} succeeded=None class=model conduct reason='no `task` call: turn 1 called {"start_process" => 1, "bash" => 1}'
     kimi-k3         #2 {'receipt_woke_a_turn': False, 'mailed': False, 'reply_final_with_background': False} succeeded=None class=model conduct reason='no `task` call: turn 1 called {"start_process" => 1, "bash" => 1}'
     kimi-k3         #3 {'wake_passive': False, 'receipt_woke_a_turn': True, 'mailed': True, 'reply_final_with_background': True, 'mail_in_turn_2_history': True} succeeded=True class=None reason=''
     deepseek-flash  #1 {'receipt_woke_a_turn': False, 'mailed': False, 'reply_final_with_background': False} succeeded=None class=model conduct reason='no `task` call: turn 1 called {"start_process" => 1, "bash" => 1}'
     deepseek-flash  #2 {'wake_passive': True, 'receipt_woke_a_turn': False, 'mailed': True, 'reply_final_with_background': True, 'mail_in_turn_2_history': False} succeeded=False class=model conduct reason='the receipt woke no turn — the call asked `wake: "passive"`'
     deepseek-flash  #3 {'wake_passive': False, 'receipt_woke_a_turn': True, 'mailed': True, 'reply_final_with_background': True, 'mail_in_turn_2_history': True} succeeded=True class=None reason=''
     glm-5.3-flash   #1 {'receipt_woke_a_turn': False, 'mailed': False, 'reply_final_with_background': False} succeeded=None class=model conduct reason='no `task` call: turn 1 called {"start_process" => 1, "bash" => 1}'
     glm-5.3-flash   #2 {'receipt_woke_a_turn': False, 'mailed': False, 'reply_final_with_background': False} succeeded=None class=model conduct reason='no `task` call: turn 1 called {"start_process" => 1, "bash" => 1}'
     glm-5.3-flash   #3 {'receipt_woke_a_turn': False, 'mailed': False, 'reply_final_with_background': False} succeeded=None class=model conduct reason='no `task` call: turn 1 called {"start_process" => 1, "bash" => 1}'
== 2026-09-25-v13-task: task/spawn/compose/send rows by stored `wake`: {('task', '<unset>'): 82, ('send', '<unset>'): 1, ('task', 'auto'): 1, ('compose', '<unset>'): 1}
  task-detached-receipt: records with the facts=12  wake_passive=true on 0
     glm-5.3         #1 {'wake_passive': False, 'receipt_woke_a_turn': True, 'mailed': True, 'reply_final_with_background': True} succeeded=True class=None reason=''
     glm-5.3         #2 {'wake_passive': False, 'receipt_woke_a_turn': True, 'mailed': True, 'reply_final_with_background': True} succeeded=True class=None reason=''
     glm-5.3         #3 {'wake_passive': False, 'receipt_woke_a_turn': True, 'mailed': True, 'reply_final_with_background': True} succeeded=True class=None reason=''
     kimi-k3         #1 {'wake_passive': False, 'receipt_woke_a_turn': True, 'mailed': True, 'reply_final_with_background': True} succeeded=True class=None reason=''
     kimi-k3         #2 {'wake_passive': False, 'receipt_woke_a_turn': True, 'mailed': True, 'reply_final_with_background': True} succeeded=True class=None reason=''
     kimi-k3         #3 {'wake_passive': False, 'receipt_woke_a_turn': True, 'mailed': True, 'reply_final_with_background': True} succeeded=True class=None reason=''
     deepseek-flash  #1 {'wake_passive': False, 'receipt_woke_a_turn': True, 'mailed': True, 'reply_final_with_background': True} succeeded=True class=None reason=''
     deepseek-flash  #2 {'wake_passive': False, 'receipt_woke_a_turn': True, 'mailed': True, 'reply_final_with_background': True} succeeded=True class=None reason=''
     deepseek-flash  #3 {'wake_passive': False, 'receipt_woke_a_turn': True, 'mailed': True, 'reply_final_with_background': True} succeeded=True class=None reason=''
     glm-5.3-flash   #1 {'wake_passive': False, 'receipt_woke_a_turn': True, 'mailed': True, 'reply_final_with_background': True} succeeded=True class=None reason=''
     glm-5.3-flash   #2 {'wake_passive': False, 'receipt_woke_a_turn': True, 'mailed': True, 'reply_final_with_background': True} succeeded=True class=None reason=''
     glm-5.3-flash   #3 {'wake_passive': False, 'receipt_woke_a_turn': True, 'mailed': True, 'reply_final_with_background': True} succeeded=True class=None reason=''
  task-mail: records with the facts=12  wake_passive=true on 0
     glm-5.3         #1 {'receipt_woke_a_turn': False, 'mailed': False, 'reply_final_with_background': False} succeeded=None class=model conduct reason='no `task` call: turn 1 called {"start_process" => 1, "bash" => 1}'
     glm-5.3         #2 {'receipt_woke_a_turn': False, 'mailed': False, 'reply_final_with_background': False} succeeded=None class=model conduct reason='no `task` call: turn 1 called {"start_process" => 1, "bash" => 1}'
     glm-5.3         #3 {'wake_passive': False, 'receipt_woke_a_turn': True, 'mailed': True, 'reply_final_with_background': True, 'mail_in_turn_2_history': True} succeeded=True class=None reason=''
     kimi-k3         #1 {'receipt_woke_a_turn': False, 'mailed': False, 'reply_final_with_background': False} succeeded=None class=model conduct reason='no `task` call: turn 1 called {"start_process" => 1, "bash" => 1}'
     kimi-k3         #2 {'receipt_woke_a_turn': False, 'mailed': False, 'reply_final_with_background': False} succeeded=None class=model conduct reason='no `task` call: turn 1 called {"bash" => 2}'
     kimi-k3         #3 {'receipt_woke_a_turn': False, 'mailed': False, 'reply_final_with_background': False} succeeded=None class=model conduct reason='no `task` call: turn 1 called {"start_process" => 1, "bash" => 1}'
     deepseek-flash  #1 {'wake_passive': False, 'receipt_woke_a_turn': True, 'mailed': True, 'reply_final_with_background': True, 'mail_in_turn_2_history': True} succeeded=True class=None reason=''
     deepseek-flash  #2 {'wake_passive': False, 'receipt_woke_a_turn': True, 'mailed': True, 'reply_final_with_background': True, 'mail_in_turn_2_history': True} succeeded=True class=None reason=''
     deepseek-flash  #3 {'receipt_woke_a_turn': False, 'mailed': False, 'reply_final_with_background': False} succeeded=None class=model conduct reason='no `task` call: turn 1 called {"bash" => 1, "start_process" => 1}'
     glm-5.3-flash   #1 {'receipt_woke_a_turn': False, 'mailed': False, 'reply_final_with_background': False} succeeded=None class=model conduct reason='no `task` call: turn 1 called {"start_process" => 1, "bash" => 1}'
     glm-5.3-flash   #2 {'receipt_woke_a_turn': False, 'mailed': False, 'reply_final_with_background': False} succeeded=None class=model conduct reason='no `task` call: turn 1 called {"start_process" => 1, "bash" => 1}'
     glm-5.3-flash   #3 {'receipt_woke_a_turn': False, 'mailed': False, 'reply_final_with_background': False} succeeded=None class=model conduct reason='no `task` call: turn 1 called {"start_process" => 1, "bash" => 1}'
== 2026-09-25-v13-workflow: task/spawn/compose/send rows by stored `wake`: {('task', '<unset>'): 248, ('compose', '<unset>'): 13}
== 2026-09-25-v13-compose: task/spawn/compose/send rows by stored `wake`: {('compose', '<unset>'): 104}
```

### c56_bytes.py

Run: `python3 /private/tmp/claude-501/-Users-jasl-Workspaces-cybros-ai-alt2/fe6d4094-2f85-4b52-abfc-78043a70e275/scratchpad/v13/readout/scripts/c56_bytes.py`

```python
# C(5) and C(6): the timeout budget sentence and content-named captures on v13.
# Where the bytes live: a tool result's text is stored as a content_fragments row, whose INSERT the
# world's Rails log prints in plain JSON. `nexus.rails.log` is the RUN'S WINDOW (WorldLog marks it
# before the turn opens), so a hit there belongs to that run. Also the trace JSON and rho.log (the
# runner logs `runner_tool_timed_out` at warn on every clamp).
import glob, os, re
from collections import Counter, defaultdict
ART = "/Users/jasl/Workspaces/cybros-ai.alt2/e2e/artifacts/evals"
SENT = re.compile(r"The tool timed out: it did not finish within the task's time budget \(timeout_ms: (\d+)\)[^\"]*")
CAP = re.compile(r"\b(bash|web|browser)-([0-9a-f]{16})(\.[a-z0-9]+)?\b")
for label in ["2026-09-25-v13-task", "2026-09-25-v13-compose", "2026-09-25-v13-workflow"]:
    sent_runs, caps_runs, timed_rho = defaultdict(list), defaultdict(Counter), 0
    full_output = 0
    runs = sorted(glob.glob(f"{ART}/{label}/logs/*/"))
    for run in runs:
        stem = os.path.basename(run.rstrip("/"))
        rho = open(run + "rho.log", encoding="UTF-8", errors="replace").read() if os.path.exists(run + "rho.log") else ""
        timed_rho += rho.count("runner_tool_timed_out")
        path = run + "nexus.rails.log"
        if not os.path.exists(path): continue
        for line in open(path, encoding="UTF-8", errors="replace"):
            if "content_fragments" not in line: continue
            full_output += line.count("Full output:")
            for m in SENT.finditer(line):
                sent_runs[stem].append(m.group(0))
            for m in CAP.finditer(line):
                caps_runs[stem][m.group(0)] += 1
    trace_hits = sum(1 for p in glob.glob(f"{ART}/{label}/*.json")
                     if "did not finish within the task" in open(p, encoding="UTF-8").read())
    print(f"== {label}: runs with a window={len(runs)}; runner_tool_timed_out in rho.log={timed_rho}; "
          f"traces holding the sentence={trace_hits}; 'Full output:' in fragment inserts={full_output}")
    print(f"   timeout sentence: runs={len(sent_runs)} occurrences={sum(len(v) for v in sent_runs.values())}")
    for stem, v in sent_runs.items():
        print(f"     {stem}: {len(v)} x, distinct byte strings {len(set(v))}: {sorted(set(s[:160] for s in v))}")
    print(f"   captures: runs={len(caps_runs)} names={sum(len(c) for c in caps_runs.values())}")
    for stem, c in caps_runs.items():
        print(f"     {stem}: {dict(c)}")
```

Output (`c56_bytes.out`):

```text
== 2026-09-25-v13-task: runs with a window=72; runner_tool_timed_out in rho.log=0; traces holding the sentence=0; 'Full output:' in fragment inserts=0
   timeout sentence: runs=0 occurrences=0
   captures: runs=0 names=0
== 2026-09-25-v13-compose: runs with a window=108; runner_tool_timed_out in rho.log=0; traces holding the sentence=0; 'Full output:' in fragment inserts=0
   timeout sentence: runs=0 occurrences=0
   captures: runs=0 names=0
== 2026-09-25-v13-workflow: runs with a window=60; runner_tool_timed_out in rho.log=0; traces holding the sentence=0; 'Full output:' in fragment inserts=1
   timeout sentence: runs=0 occurrences=0
   captures: runs=1 names=1
     workflow-adversarial-verify.deepseek_deepseek-flash.nexus.1: {'bash-c88fbdcdeb64e0f7.log': 3}
```

### c56_world.py

Run: `python3 /private/tmp/claude-501/-Users-jasl-Workspaces-cybros-ai-alt2/fe6d4094-2f85-4b52-abfc-78043a70e275/scratchpad/v13/readout/scripts/c56_world.py`

```python
# C(5)/(6) cross-check over the WHOLE world logs: each family ran in one world whose server.log and
# model_runner.log are copied whole into every run dir, so the largest copy holds every run's lines.
# Count the timeout sentence and content-named capture names there (each distinct string, and how
# many times it was written), and the stored text of every capture hit.
import glob, os, re
from collections import Counter
ART = "/Users/jasl/Workspaces/cybros-ai.alt2/e2e/artifacts/evals"
SENT = re.compile(r"The tool timed out: it did not finish within the task's time budget \(timeout_ms: \d+\)")
CAP = re.compile(r"\b(?:bash|web|browser)-[0-9a-f]{16}(?:\.[a-z0-9]+)?\b")
for fam in ["task", "compose", "workflow"]:
    largest = {}
    for m in glob.glob(f"{ART}/2026-09-25-v13-{fam}/logs/*/MANIFEST"):
        for name, size, src in re.findall(r"^(nexus\.(?:server|model_runner)\.log): (\d+) bytes from (\S+)", open(m, encoding="UTF-8").read(), re.M):
            if int(size) >= largest.get(src, (0, ""))[0]:
                largest[src] = (int(size), os.path.join(os.path.dirname(m), name))
    sent, caps, frag_caps = Counter(), Counter(), Counter()
    for _, path in largest.values():
        for line in open(path, encoding="UTF-8", errors="replace"):
            if "timed out" in line:
                for s in SENT.findall(line): sent[s] += 1
            if "-" in line:
                for c in CAP.findall(line):
                    caps[c] += 1
                    if 'INSERT INTO "content_fragments"' in line: frag_caps[c] += 1
    print(f"== {fam}: files={[os.path.basename(os.path.dirname(p)) + '/' + os.path.basename(p) for _, p in largest.values()]}")
    print(f"   timeout sentence strings={dict(sent) or 'none'}")
    print(f"   capture names (all lines)={dict(caps) or 'none'}; in content_fragments inserts={dict(frag_caps) or 'none'}")
```

Output (`c56_world.out`):

```text
== task: files=['task-two-calls.openrouter_z-ai_glm-5.3-flash.nexus.3/nexus.model_runner.log', 'task-two-calls.openrouter_z-ai_glm-5.3-flash.nexus.3/nexus.server.log']
   timeout sentence strings=none
   capture names (all lines)=none; in content_fragments inserts=none
== compose: files=['compose-two-source-fan-in.openrouter_z-ai_glm-5.3-flash.nexus.3/nexus.model_runner.log', 'compose-two-source-fan-in.openrouter_z-ai_glm-5.3-flash.nexus.3/nexus.server.log']
   timeout sentence strings=none
   capture names (all lines)=none; in content_fragments inserts=none
== workflow: files=['workflow-loop-until-dry.openrouter_z-ai_glm-5.3-flash.nexus.3/nexus.model_runner.log', 'workflow-loop-until-dry.openrouter_z-ai_glm-5.3-flash.nexus.3/nexus.server.log']
   timeout sentence strings=none
   capture names (all lines)={'bash-c88fbdcdeb64e0f7.log': 12, 'bash-c88fbdcdeb64e0f7.bin': 1}; in content_fragments inserts={'bash-c88fbdcdeb64e0f7.log': 3}
```

### c56_capture_context.py

Run: `python3 /private/tmp/claude-501/-Users-jasl-Workspaces-cybros-ai-alt2/fe6d4094-2f85-4b52-abfc-78043a70e275/scratchpad/v13/readout/scripts/c56_capture_context.py`

```python
# C(6): the one content-named capture: the lines of its run's Rails window that name it.
import glob
D = "/Users/jasl/Workspaces/cybros-ai.alt2/e2e/artifacts/evals/2026-09-25-v13-workflow/logs/workflow-adversarial-verify.deepseek_deepseek-flash.nexus.1"
for fn in sorted(glob.glob(D + "/nexus.rails.log")):
    for i, line in enumerate(open(fn, encoding="UTF-8", errors="replace"), 1):
        j = line.find("c88fbdcdeb64e0f7")
        if j >= 0: print(f"{fn.split('/')[-1]}:{i}: ...{line[max(0, j - 150):j + 40]!r}")
```

Output (`c56_capture_context.out`):

```text
nexus.rails.log:28108: ...'f5f75fb925a243a-20260925-14200-10lqcg/tmp/RackMultipart20260925-14256-97qsqr.log>, @content_type="application/octet-stream", @original_filename="bash-c88fbdcdeb64e0f7.log", @headers="Content'
nexus.rails.log:28119: ...' ("key", "filename", "content_type", "metadata", "service_name", "byte_size", "checksum", "created_at") VALUES (\'l7tbiuqauktyzy5jeijnsmow15dt\', \'bash-c88fbdcdeb64e0f7.bin\', \'application/octe'
nexus.rails.log:28143: ...'limit). Full output: /private/var/folders/_6/7vgpkxd14klg0lpvxyh5nk2h0000gn/T/rho-evals-e2e20260925-14267-zjlrfx/work/artifacts/c14ed464ad0de04e/bash-c88fbdcdeb64e0f7.log]"}, {"type" => "res'
nexus.rails.log:28152: ...'limit). Full output: /private/var/folders/_6/7vgpkxd14klg0lpvxyh5nk2h0000gn/T/rho-evals-e2e20260925-14267-zjlrfx/work/artifacts/c14ed464ad0de04e/bash-c88fbdcdeb64e0f7.log]"}, {"type" => "res'
nexus.rails.log:28189: ...'e98b7071b8e5206da5cc2f099effccd54099c064eec95b8ab2385f\', \'{"resource_link":{"uri":"nexus://uploads/01a0d5f4-323c-7ada-8f6b-ed209c218ea1","name":"bash-c88fbdcdeb64e0f7.log","mimeType":"applic'
nexus.rails.log:28802: ...'limit). Full output: /private/var/folders/_6/7vgpkxd14klg0lpvxyh5nk2h0000gn/T/rho-evals-e2e20260925-14267-zjlrfx/work/artifacts/c14ed464ad0de04e/bash-c88fbdcdeb64e0f7.log]\', "sealed_at" = \'2'
```

### c7_reread.rb

Run: `cd /Users/jasl/Workspaces/cybros-ai.alt2/e2e && bundle exec ruby /private/tmp/claude-501/-Users-jasl-Workspaces-cybros-ai-alt2/fe6d4094-2f85-4b52-abfc-78043a70e275/scratchpad/v13/readout/scripts/c7_reread.rb`

```ruby
# C(7): an OFFLINE re-read of every v13 record through today's harness (HEAD = the commit that
# holds the records), IN MEMORY: `Rescore.rescored` is called and compared, nothing is appended
# and nothing on disk changes. Prints every record whose verdict, class, reason or usable_on_call
# differs from the committed line. Run from e2e/: bundle exec ruby <this>
require "json"
require_relative "/Users/jasl/Workspaces/cybros-ai.alt2/e2e/support/evals"
bench = E2E::Evals::Bench.read
corpus = E2E::Evals::Corpus.load_all(bench: bench)
root = "/Users/jasl/Workspaces/cybros-ai.alt2/e2e"
diffs = 0
total = 0
%w[task compose workflow].each do |family|
  label = "2026-09-25-v13-#{family}"
  E2E::Evals::Records.read(File.join(bench.runs_dir, label)).each do |record|
    total += 1
    artifact = record["artifact"]
    trace = E2E::Evals::Rescore.trace_of(record, artifact)
    fresh = begin
      E2E::Evals::Rescore.rescored(record, corpus.find(record.fetch("task")), trace, Time.now.utc)
    rescue StandardError => e
      puts "RAISED #{record["task"]} #{record["model"]} ##{record["run"]}: #{e.class}: #{e.message[0, 200]}"
      next
    end
    old_v = record["verdict"].slice("reached", "succeeded", "class")
    new_v = fresh["verdict"].slice("reached", "succeeded", "class")
    old_u = record.dig("facts", "usable_on_call")
    new_u = fresh.dig("facts", "usable_on_call")
    next if old_v == new_v && record["reason"] == fresh["reason"] && old_u == new_u

    diffs += 1
    puts "#{family} #{record["task"]} #{record["model"].split("/").last} ##{record["run"]}"
    puts "   committed: #{old_v} usable_on_call=#{old_u.inspect} reason=#{record["reason"].to_s[0, 160].inspect}"
    puts "   re-read:   #{new_v} usable_on_call=#{new_u.inspect} reason=#{fresh["reason"].to_s[0, 160].inspect}"
  end
end
puts "#{total} records re-read in memory, #{diffs} differ from the committed line"
```

Output (`c7_reread.out`):

```text
240 records re-read in memory, 0 differ from the committed line
```

### c7_list.py

Run: `python3 /private/tmp/claude-501/-Users-jasl-Workspaces-cybros-ai-alt2/fe6d4094-2f85-4b52-abfc-78043a70e275/scratchpad/v13/readout/scripts/c7_list.py`

```python
# C(7): every v13 `model conduct` and `disagreement` record, its claim (reason / conduct_reasons)
# and the facts a reader checks first.
import json
from collections import Counter
for fam in ["workflow", "compose", "task"]:
    rows = [json.loads(l) for l in open(f"/Users/jasl/Workspaces/cybros-ai.alt2/e2e/evals/runs/2026-09-25-v13-{fam}/records.jsonl", encoding="UTF-8")]
    print(f"== {fam}: {dict(Counter(r['verdict']['class'] for r in rows))}")
    for r in rows:
        c = r["verdict"]["class"]
        if c not in ("model conduct", "disagreement"): continue
        f = r["facts"]
        claim = r.get("reason") or "; ".join(f"{k}: {v}" for k, v in (r.get("conduct_reasons") or {}).items())
        print(f"  {r['task']} {r['model'].split('/')[-1]} #{r['run']} | {c} | reached={r['verdict']['reached']} "
              f"succeeded={r['verdict']['succeeded']} task_pass={r['verdict']['task_pass']} conduct={r.get('conduct')}")
        print(f"      claim: {str(claim)[:150]!r}")
```

Output (`c7_list.out`):

```text
== workflow: {'cache under floor': 13, 'disagreement': 4, 'model conduct': 13, None: 30}
  workflow-adversarial-verify glm-5.3 #2 | disagreement | reached=True succeeded=False task_pass=True conduct={'did_not_judge_itself': True}
      claim: 'no input_accepted{origin: task_result}: the kernel mailed no receipt ({"read" => 35, "find" => 3, "todo_write" => 2, "task" => 12, "ls" => 7, "grep" ='
  workflow-adversarial-verify glm-5.3 #3 | disagreement | reached=True succeeded=False task_pass=True conduct={'did_not_judge_itself': False}
      claim: 'no input_accepted{origin: task_result}: the kernel mailed no receipt ({"read" => 18, "ls" => 5, "todo_write" => 2, "task" => 12, "bash" => 31, "grep" '
  workflow-adversarial-verify kimi-k3 #1 | model conduct | reached=True succeeded=False task_pass=False conduct={'did_not_judge_itself': True}
      claim: 'no input_accepted{origin: task_result}: the kernel mailed no receipt ({"read" => 13, "ls" => 2, "task" => 12, "bash" => 14, "write" => 2})'
  workflow-adversarial-verify kimi-k3 #3 | model conduct | reached=True succeeded=False task_pass=False conduct={'did_not_judge_itself': True}
      claim: 'no input_accepted{origin: task_result}: the kernel mailed no receipt ({"read" => 42, "ls" => 12, "task" => 13, "find" => 1, "bash" => 17, "grep" => 1,'
  workflow-adversarial-verify deepseek-flash #1 | model conduct | reached=True succeeded=True task_pass=True conduct={'did_not_judge_itself': False}
      claim: 'did_not_judge_itself: the spine read lib/wallet.rb, lib/ledger.rb, lib/rate.rb itself'
  workflow-adversarial-verify deepseek-flash #2 | model conduct | reached=True succeeded=True task_pass=True conduct={'did_not_judge_itself': False}
      claim: 'did_not_judge_itself: the spine read lib/wallet.rb, lib/ledger.rb, lib/rate.rb itself'
  workflow-adversarial-verify deepseek-flash #3 | model conduct | reached=True succeeded=True task_pass=True conduct={'did_not_judge_itself': False}
      claim: 'did_not_judge_itself: the spine read lib/wallet.rb, lib/ledger.rb, lib/rate.rb itself'
  workflow-adversarial-verify glm-5.3-flash #1 | model conduct | reached=True succeeded=True task_pass=True conduct={'did_not_judge_itself': False}
      claim: 'did_not_judge_itself: the spine read lib/wallet.rb, lib/ledger.rb, lib/rate.rb itself'
  workflow-adversarial-verify glm-5.3-flash #2 | disagreement | reached=True succeeded=False task_pass=True conduct={'did_not_judge_itself': False}
      claim: 'no input_accepted{origin: task_result}: the kernel mailed no receipt ({"read" => 4, "ls" => 2, "bash" => 19, "todo_write" => 3, "task" => 12, "write" '
  workflow-barrier-free-pipeline glm-5.3 #1 | model conduct | reached=False succeeded=None task_pass=True conduct={}
      claim: 'no compose call and no round fanned two task calls: {"ls" => 1, "read" => 1, "todo_write" => 3, "bash" => 4}'
  workflow-barrier-free-pipeline glm-5.3 #2 | disagreement | reached=True succeeded=False task_pass=True conduct={}
      claim: 'the picture is not the objective\'s (silent: edit_as_tool): {"nodes" => ["script-1/tool-1:tool", "script-1/tool-2:tool", "script-1/tool-3:tool", "scrip'
  workflow-barrier-free-pipeline kimi-k3 #1 | model conduct | reached=False succeeded=None task_pass=True conduct={}
      claim: 'no compose call and no round fanned two task calls: {"ls" => 1, "read" => 1, "bash" => 1}'
  workflow-barrier-free-pipeline kimi-k3 #2 | model conduct | reached=False succeeded=None task_pass=True conduct={}
      claim: 'no compose call and no round fanned two task calls: {"ls" => 1, "bash" => 5}'
  workflow-barrier-free-pipeline kimi-k3 #3 | model conduct | reached=False succeeded=None task_pass=True conduct={}
      claim: 'no compose call and no round fanned two task calls: {"ls" => 1, "read" => 1, "bash" => 1}'
  workflow-barrier-free-pipeline deepseek-flash #1 | model conduct | reached=False succeeded=None task_pass=True conduct={}
      claim: 'no compose call and no round fanned two task calls: {"bash" => 2, "ls" => 1}'
  workflow-barrier-free-pipeline deepseek-flash #2 | model conduct | reached=False succeeded=None task_pass=True conduct={}
      claim: 'no compose call and no round fanned two task calls: {"bash" => 4, "write" => 2}'
  workflow-barrier-free-pipeline glm-5.3-flash #2 | model conduct | reached=False succeeded=None task_pass=True conduct={}
      claim: 'no compose call and no round fanned two task calls: {"ls" => 1, "find" => 1, "read" => 1, "bash" => 1}'
== compose: {None: 83, 'model conduct': 14, 'lane bug': 2, 'disagreement': 5, 'cache under floor': 4}
  compose-background-suite glm-5.3 #2 | model conduct | reached=True succeeded=False task_pass=None conduct={}
      claim: 'the picture is not the objective\'s (silent: suite_waited_on, extra_steps, over_sync, over_read): {"nodes" => ["tool-1:tool", "tool-2:tool", "model-1:m'
  compose-background-suite kimi-k3 #2 | model conduct | reached=True succeeded=False task_pass=None conduct={}
      claim: 'the picture is not the objective\'s (silent: suite_waited_on, extra_steps, over_read): {"nodes" => ["tool-1:tool", "tool-2:tool", "model-1:model", "too'
  compose-background-suite kimi-k3 #3 | model conduct | reached=True succeeded=False task_pass=None conduct={}
      claim: 'the picture is not the objective\'s (silent: suite_waited_on, extra_steps, over_read): {"nodes" => ["tool-1:tool", "tool-2:tool", "model-1:model", "too'
  compose-grep-then-edit glm-5.3 #1 | disagreement | reached=True succeeded=False task_pass=True conduct={}
      claim: 'the picture is not the objective\'s (silent: missing_steps): {"nodes" => [], "edges" => [], "reads" => {}}'
  compose-grep-then-edit glm-5.3 #2 | disagreement | reached=True succeeded=False task_pass=True conduct={}
      claim: 'the picture is not the objective\'s (silent: extra_steps): {"nodes" => ["tool-1:tool", "tool-2:tool", "tool-3:tool", "script-2:script", "script-1/tool-'
  compose-grep-then-edit glm-5.3 #3 | disagreement | reached=True succeeded=False task_pass=True conduct={}
      claim: 'the picture is not the objective\'s (silent: extra_steps): {"nodes" => ["tool-1:tool", "tool-2:tool", "tool-3:tool", "script-1/tool-1:tool", "script-1/'
  compose-grep-then-edit kimi-k3 #1 | disagreement | reached=True succeeded=False task_pass=True conduct={}
      claim: 'the picture is not the objective\'s (silent: over_sync): {"nodes" => ["tool-1:tool", "tool-2:tool", "tool-3:tool", "script-1/tool-1:tool"], "edges" => '
  compose-grep-then-edit kimi-k3 #2 | disagreement | reached=True succeeded=False task_pass=True conduct={}
      claim: 'the picture is not the objective\'s (silent: missing_steps): {"nodes" => ["tool-1:tool", "tool-2:tool", "tool-3:tool", "script-1:script"], "edges" => ['
  compose-rendezvous glm-5.3-flash #1 | model conduct | reached=True succeeded=False task_pass=None conduct={}
      claim: 'the script was refused script_error: Error: g.tool: after: goes beside input, not inside it: g.tool({ name: "bash", input: { ... }, after: [step] }).'
  compose-review-angles glm-5.3 #3 | model conduct | reached=True succeeded=False task_pass=None conduct={}
      claim: 'the script was refused script_syntax_error: SyntaxError: Invalid or unexpected token at line 1, column 11: g.script({\\n  script: `\\n    const security'
  compose-three-stage-pairing glm-5.3 #2 | model conduct | reached=True succeeded=False task_pass=None conduct={}
      claim: 'the picture is not the objective\'s (silent: over_read): {"nodes" => ["tool-1:tool", "model-1:model", "tool-2:tool", "model-2:model", "tool-3:tool", "m'
  compose-three-stage-pairing kimi-k3 #1 | model conduct | reached=True succeeded=False task_pass=None conduct={}
      claim: 'the picture is not the objective\'s (silent: missing_steps): {"nodes" => ["script-1/tool-1:tool", "script-1/model-1:model", "script-1/tool-2:tool", "sc'
  compose-three-stage-pairing glm-5.3-flash #1 | model conduct | reached=False succeeded=None task_pass=None conduct={}
      claim: 'no compose call: the model called {"write" => 1, "bash" => 3, "read" => 1, "edit" => 1}'
  compose-two-source-fan-in glm-5.3 #1 | model conduct | reached=True succeeded=False task_pass=None conduct={}
      claim: 'the picture is not the objective\'s (silent: over_read): {"nodes" => ["tool-1:tool", "tool-2:tool", "tool-3:tool", "model-1:model", "model-2:model", "m'
  compose-two-source-fan-in glm-5.3 #2 | model conduct | reached=True succeeded=False task_pass=None conduct={}
      claim: 'the picture is not the objective\'s (silent: over_sync): {"nodes" => ["tool-1:tool", "model-1:model", "tool-2:tool", "tool-3:tool", "model-2:model", "m'
  compose-two-source-fan-in glm-5.3 #3 | model conduct | reached=True succeeded=False task_pass=None conduct={}
      claim: 'the picture is not the objective\'s (silent: over_sync, over_read): {"nodes" => ["tool-1:tool", "tool-2:tool", "tool-3:tool", "model-1:model", "model-2'
  compose-two-source-fan-in kimi-k3 #1 | model conduct | reached=True succeeded=False task_pass=None conduct={}
      claim: 'the picture is not the objective\'s (silent: over_read): {"nodes" => ["tool-1:tool", "tool-2:tool", "tool-3:tool", "model-1:model", "model-2:model", "m'
  compose-two-source-fan-in kimi-k3 #2 | model conduct | reached=True succeeded=False task_pass=None conduct={}
      claim: 'the picture is not the objective\'s (silent: over_read): {"nodes" => ["tool-1:tool", "tool-2:tool", "tool-3:tool", "model-1:model", "model-2:model", "m'
  compose-two-source-fan-in kimi-k3 #3 | model conduct | reached=True succeeded=False task_pass=None conduct={}
      claim: 'the picture is not the objective\'s (silent: over_read): {"nodes" => ["tool-1:tool", "tool-2:tool", "tool-3:tool", "model-1:model", "model-2:model", "m'
== task: {None: 54, 'cache under floor': 2, 'model conduct': 16}
  task-background-suite kimi-k3 #2 | model conduct | reached=False succeeded=None task_pass=None conduct={}
      claim: 'no `task` call: the model called {"start_process" => 2, "bash" => 9, "read" => 1, "edit" => 1}'
  task-background-suite deepseek-flash #1 | model conduct | reached=False succeeded=None task_pass=None conduct={}
      claim: 'no `task` call: the model called {"bash" => 8, "start_process" => 1, "read" => 2, "edit" => 1, "read_process" => 3, "memory_write" => 1, "send" => 1}'
  task-background-suite deepseek-flash #2 | model conduct | reached=False succeeded=None task_pass=None conduct={}
      claim: 'no `task` call: the model called {"bash" => 7, "read" => 1, "start_process" => 1, "edit" => 1}'
  task-background-suite glm-5.3-flash #2 | model conduct | reached=False succeeded=None task_pass=None conduct={}
      claim: 'no `task` call: the model called {"todo_write" => 3, "ls" => 2, "list_processes" => 1, "bash" => 11, "read" => 1, "start_process" => 1, "edit" => 1, "'
  task-fan-five deepseek-flash #1 | model conduct | reached=False succeeded=None task_pass=None conduct={}
      claim: '0 task call(s) in the first message, not five: {"bash" => 1, "read" => 1}'
  task-fan-five deepseek-flash #2 | model conduct | reached=False succeeded=None task_pass=None conduct={}
      claim: '0 task call(s) in the first message, not five: {"ls" => 1, "bash" => 1}'
  task-fan-five glm-5.3-flash #1 | model conduct | reached=True succeeded=False task_pass=None conduct={}
      claim: 'the merged reply names no lib/a.rb'
  task-mail glm-5.3 #1 | model conduct | reached=False succeeded=None task_pass=None conduct={}
      claim: 'no `task` call: turn 1 called {"start_process" => 1, "bash" => 1}'
  task-mail glm-5.3 #2 | model conduct | reached=False succeeded=None task_pass=None conduct={}
      claim: 'no `task` call: turn 1 called {"start_process" => 1, "bash" => 1}'
  task-mail kimi-k3 #1 | model conduct | reached=False succeeded=None task_pass=None conduct={}
      claim: 'no `task` call: turn 1 called {"start_process" => 1, "bash" => 1}'
  task-mail kimi-k3 #2 | model conduct | reached=False succeeded=None task_pass=None conduct={}
      claim: 'no `task` call: turn 1 called {"bash" => 2}'
  task-mail kimi-k3 #3 | model conduct | reached=False succeeded=None task_pass=None conduct={}
      claim: 'no `task` call: turn 1 called {"start_process" => 1, "bash" => 1}'
  task-mail deepseek-flash #3 | model conduct | reached=False succeeded=None task_pass=None conduct={}
      claim: 'no `task` call: turn 1 called {"bash" => 1, "start_process" => 1}'
  task-mail glm-5.3-flash #1 | model conduct | reached=False succeeded=None task_pass=None conduct={}
      claim: 'no `task` call: turn 1 called {"start_process" => 1, "bash" => 1}'
  task-mail glm-5.3-flash #2 | model conduct | reached=False succeeded=None task_pass=None conduct={}
      claim: 'no `task` call: turn 1 called {"start_process" => 1, "bash" => 1}'
  task-mail glm-5.3-flash #3 | model conduct | reached=False succeeded=None task_pass=None conduct={}
      claim: 'no `task` call: turn 1 called {"start_process" => 1, "bash" => 1}'
```

### c7_adversarial.py

Run: `python3 /private/tmp/claude-501/-Users-jasl-Workspaces-cybros-ai-alt2/fe6d4094-2f85-4b52-abfc-78043a70e275/scratchpad/v13/readout/scripts/c7_adversarial.py`

```python
# C(7) adversarial-verify: what the SPINE did with lib/ (read, bash, grep, find, ls), when (before the
# first `task` call, between, or after the last), against the recorded conduct `did_not_judge_itself`
# (which reads only `read` rows whose path includes lib/). Primary loop's spine only, as the conduct.
import json, re
RUNS = "/Users/jasl/Workspaces/cybros-ai.alt2/e2e/evals/runs/2026-09-25-v13-workflow/records.jsonl"
def touches_lib(row):
    inp = row.get("tool_input") or {}
    text = json.dumps(inp)
    return "lib/" in text or "lib\"" in text or re.search(r"\blib\b", text) is not None
for line in open(RUNS, encoding="UTF-8"):
    r = json.loads(line)
    if r["task"] != "workflow-adversarial-verify": continue
    t = json.load(open(r["artifact"], encoding="UTF-8"))
    nodes = {n["key"]: n for n in t["graph"]["nodes"]}
    spine = {k for k, n in nodes.items() if n.get("spine")}
    order = [x["key"] for x in t["tasks"]]
    calls = [x for x in t["tasks"] if x["kind"] == "tool_task" and set(x.get("after") or []) & spine]
    task_idx = [i for i, x in enumerate(calls) if x["tool_name"] == "task"]
    first, last = (task_idx[0], task_idx[-1]) if task_idx else (None, None)
    lib = []
    for i, x in enumerate(calls):
        if x["tool_name"] in ("read", "bash", "grep", "find", "ls") and touches_lib(x):
            when = "before" if first is not None and i < first else ("after" if last is not None and i > last else "between")
            inp = x.get("tool_input") or {}
            what = inp.get("path") or inp.get("command") or inp.get("pattern") or ""
            lib.append(f"{x['tool_name']}@{when}:{str(what)[:60]!r}")
    tally = {}
    for s in lib:
        k = s.split(":")[0]; tally[k] = tally.get(k, 0) + 1
    print(f"{r['model'].split('/')[-1]:15} #{r['run']} class={r['verdict']['class']} task_pass={r['verdict']['task_pass']} "
          f"conduct={r['conduct']} waited={r['facts'].get('waited')} spine calls={len(calls)} task calls={len(task_idx)}")
    print(f"     spine calls touching lib/ by tool@when: {tally}")
    for s in lib[:6]: print("       ", s)
```

Output (`c7_adversarial.out`):

```text
glm-5.3         #1 class=cache under floor task_pass=True conduct={'did_not_judge_itself': True} waited=False spine calls=16 task calls=12
     spine calls touching lib/ by tool@when: {'ls@before': 1}
        ls@before:'lib'
glm-5.3         #2 class=disagreement task_pass=True conduct={'did_not_judge_itself': True} waited=True spine calls=17 task calls=12
     spine calls touching lib/ by tool@when: {'find@before': 1}
        find@before:'lib/**/*'
glm-5.3         #3 class=disagreement task_pass=True conduct={'did_not_judge_itself': False} waited=True spine calls=21 task calls=12
     spine calls touching lib/ by tool@when: {'ls@before': 1, 'read@before': 3}
        ls@before:'lib'
        read@before:'lib/wallet.rb'
        read@before:'lib/ledger.rb'
        read@before:'lib/rate.rb'
kimi-k3         #1 class=model conduct task_pass=False conduct={'did_not_judge_itself': True} waited=True spine calls=16 task calls=12
     spine calls touching lib/ by tool@when: {'ls@before': 1}
        ls@before:'lib'
kimi-k3         #2 class=cache under floor task_pass=True conduct={'did_not_judge_itself': True} waited=False spine calls=19 task calls=12
     spine calls touching lib/ by tool@when: {}
kimi-k3         #3 class=model conduct task_pass=False conduct={'did_not_judge_itself': True} waited=True spine calls=16 task calls=13
     spine calls touching lib/ by tool@when: {'ls@before': 1}
        ls@before:'lib'
deepseek-flash  #1 class=model conduct task_pass=True conduct={'did_not_judge_itself': False} waited=False spine calls=24 task calls=13
     spine calls touching lib/ by tool@when: {'ls@before': 1, 'read@before': 3}
        ls@before:'lib'
        read@before:'lib/wallet.rb'
        read@before:'lib/ledger.rb'
        read@before:'lib/rate.rb'
deepseek-flash  #2 class=model conduct task_pass=True conduct={'did_not_judge_itself': False} waited=False spine calls=24 task calls=12
     spine calls touching lib/ by tool@when: {'bash@before': 1, 'read@before': 3}
        bash@before:'ls -la; echo "---"; find lib -type f | head -50'
        read@before:'lib/wallet.rb'
        read@before:'lib/ledger.rb'
        read@before:'lib/rate.rb'
deepseek-flash  #3 class=model conduct task_pass=True conduct={'did_not_judge_itself': False} waited=False spine calls=19 task calls=12
     spine calls touching lib/ by tool@when: {'find@before': 1, 'read@before': 3}
        find@before:'lib/**/*'
        read@before:'lib/wallet.rb'
        read@before:'lib/ledger.rb'
        read@before:'lib/rate.rb'
glm-5.3-flash   #1 class=model conduct task_pass=True conduct={'did_not_judge_itself': False} waited=False spine calls=19 task calls=12
     spine calls touching lib/ by tool@when: {'ls@before': 1, 'read@before': 3}
        ls@before:'lib'
        read@before:'lib/wallet.rb'
        read@before:'lib/ledger.rb'
        read@before:'lib/rate.rb'
glm-5.3-flash   #2 class=disagreement task_pass=True conduct={'did_not_judge_itself': False} waited=True spine calls=23 task calls=12
     spine calls touching lib/ by tool@when: {'ls@before': 1, 'read@before': 3, 'bash@before': 1}
        ls@before:'lib'
        read@before:'lib/wallet.rb'
        read@before:'lib/ledger.rb'
        read@before:'lib/rate.rb'
        bash@before:'ruby -v 2>&1; pwd; ls lib'
glm-5.3-flash   #3 class=None task_pass=True conduct={'did_not_judge_itself': True} waited=False spine calls=15 task calls=12
     spine calls touching lib/ by tool@when: {'ls@before': 1}
        ls@before:'lib'
```

### c7_briefs.py

Run: `python3 /private/tmp/claude-501/-Users-jasl-Workspaces-cybros-ai-alt2/fe6d4094-2f85-4b52-abfc-78043a70e275/scratchpad/v13/readout/scripts/c7_briefs.py`

```python
# C(7) adversarial-verify: did a spine that read lib/ carry its own reading into the refuters'
# briefs? Count, per run, the `task` briefs that quote code facts only reading lib/ yields
# (the guard `-100`, `floor`, `==`/case, `fetch`, a `.rb:` line citation, `def `), beside the
# brief's length. A brief with none is the claim alone.
import json, re
RUNS = "/Users/jasl/Workspaces/cybros-ai.alt2/e2e/evals/runs/2026-09-25-v13-workflow/records.jsonl"
TELLS = re.compile(r"-100|\bfloor\b|truncat|case-sensitive|String#==|\.rb:\d|def [a-z_]+|TABLE|\bfetch\b|< ?0\b|positive\?")
for line in open(RUNS, encoding="UTF-8"):
    r = json.loads(line)
    if r["task"] != "workflow-adversarial-verify": continue
    t = json.load(open(r["artifact"], encoding="UTF-8"))
    briefs = [x.get("tool_input") or {} for x in t["tasks"] if x.get("tool_name") == "task"]
    texts = [json.dumps(b, ensure_ascii=False) for b in briefs]
    tells = [sorted(set(TELLS.findall(s))) for s in texts]
    n_told = sum(1 for x in tells if x)
    print(f"{r['model'].split('/')[-1]:15} #{r['run']} conduct={r['conduct'].get('did_not_judge_itself')} briefs={len(briefs)} "
          f"median len={sorted(len(s) for s in texts)[len(texts)//2] if texts else 0} briefs with a code tell={n_told} "
          f"tells={sorted({w for x in tells for w in x})}")
```

Output (`c7_briefs.out`):

```text
glm-5.3         #1 conduct=True briefs=12 median len=1151 briefs with a code tell=2 tells=['floor', 'truncat']
glm-5.3         #2 conduct=True briefs=12 median len=975 briefs with a code tell=2 tells=['truncat']
glm-5.3         #3 conduct=False briefs=12 median len=1381 briefs with a code tell=0 tells=[]
kimi-k3         #1 conduct=True briefs=12 median len=757 briefs with a code tell=2 tells=['truncat']
kimi-k3         #2 conduct=True briefs=12 median len=649 briefs with a code tell=2 tells=['truncat']
kimi-k3         #3 conduct=True briefs=13 median len=588 briefs with a code tell=0 tells=[]
deepseek-flash  #1 conduct=False briefs=13 median len=1100 briefs with a code tell=0 tells=[]
deepseek-flash  #2 conduct=False briefs=12 median len=814 briefs with a code tell=2 tells=['truncat']
deepseek-flash  #3 conduct=False briefs=12 median len=1195 briefs with a code tell=12 tells=['-100', 'TABLE', 'def deposit', 'def entries_for', 'def initialize', 'def post', 'def self', 'def total', 'def withdraw', 'fetch', 'floor', 'positive?', 'truncat']
glm-5.3-flash   #1 conduct=False briefs=12 median len=871 briefs with a code tell=6 tells=['String#==', 'fetch', 'floor']
glm-5.3-flash   #2 conduct=False briefs=12 median len=1546 briefs with a code tell=12 tells=['-100', 'TABLE', 'def deposit', 'def entries_for', 'def initialize', 'def post', 'def self', 'def total', 'def withdraw', 'fetch', 'floor', 'positive?', 'truncat']
glm-5.3-flash   #3 conduct=True briefs=12 median len=776 briefs with a code tell=0 tells=[]
```

### c7_barrier_free.py

Run: `python3 /private/tmp/claude-501/-Users-jasl-Workspaces-cybros-ai-alt2/fe6d4094-2f85-4b52-abfc-78043a70e275/scratchpad/v13/readout/scripts/c7_barrier_free.py`

```python
# C(7) workflow-barrier-free-pipeline, the seven `no compose call and no round fanned two task
# calls` reds: did the one bash command run the three fetch->normalise pipelines concurrently
# (a background `&` that is not `&&`, then `wait`)? The RATIONALE reads this red as "it fetched and
# normalised in sequence itself".
import json, re
RUNS = "/Users/jasl/Workspaces/cybros-ai.alt2/e2e/evals/runs/2026-09-25-v13-workflow/records.jsonl"
BG = re.compile(r"(?<![&|])&(?![&>])")
for line in open(RUNS, encoding="UTF-8"):
    r = json.loads(line)
    if r["task"] != "workflow-barrier-free-pipeline" or r["verdict"]["class"] not in ("model conduct", "disagreement"): continue
    t = json.load(open(r["artifact"], encoding="UTF-8"))
    cmds = [(x.get("tool_input") or {}).get("command", "") for x in t["tasks"] if x.get("tool_name") == "bash"]
    conc = [c for c in cmds if BG.search(c) and re.search(r"\bwait\b", c) and "fetch" in c]
    print(f"{r['model'].split('/')[-1]:15} #{r['run']} class={r['verdict']['class']} task_pass={r['verdict']['task_pass']} "
          f"bash calls={len(cmds)} concurrent fetch pipelines in one bash call={bool(conc)} door={r['facts'].get('door')}")
```

Output (`c7_barrier_free.out`):

```text
glm-5.3         #1 class=model conduct task_pass=True bash calls=4 concurrent fetch pipelines in one bash call=False door=None
glm-5.3         #2 class=disagreement task_pass=True bash calls=8 concurrent fetch pipelines in one bash call=False door=compose
kimi-k3         #1 class=model conduct task_pass=True bash calls=1 concurrent fetch pipelines in one bash call=True door=None
kimi-k3         #2 class=model conduct task_pass=True bash calls=5 concurrent fetch pipelines in one bash call=False door=None
kimi-k3         #3 class=model conduct task_pass=True bash calls=1 concurrent fetch pipelines in one bash call=True door=None
deepseek-flash  #1 class=model conduct task_pass=True bash calls=2 concurrent fetch pipelines in one bash call=True door=None
deepseek-flash  #2 class=model conduct task_pass=True bash calls=4 concurrent fetch pipelines in one bash call=False door=None
glm-5.3-flash   #2 class=model conduct task_pass=True bash calls=1 concurrent fetch pipelines in one bash call=True door=None
```

### c7_grep_then_edit.py

Run: `python3 /private/tmp/claude-501/-Users-jasl-Workspaces-cybros-ai-alt2/fe6d4094-2f85-4b52-abfc-78043a70e275/scratchpad/v13/readout/scripts/c7_grep_then_edit.py`

```python
# C(7) compose-grep-then-edit, the five `disagreement` records: every compose call's status, what its
# stages did (a failed stage and its error), the tool rows its stages placed, and the bucket the
# strong tier's picture read on the FIRST call (the call `Predicates.compose_call` scores).
import json, re
RUNS = "/Users/jasl/Workspaces/cybros-ai.alt2/e2e/evals/runs/2026-09-25-v13-compose/records.jsonl"
for line in open(RUNS, encoding="UTF-8"):
    r = json.loads(line)
    if r["task"] != "compose-grep-then-edit" or r["verdict"]["class"] != "disagreement": continue
    t = json.load(open(r["artifact"], encoding="UTF-8"))
    nodes = {n["key"]: n for n in t["graph"]["nodes"]}
    def under(key):
        out = [k for k, n in nodes.items() if n.get("expansion_parent") == key]
        return out + [x for k in out for x in under(k)]
    b = re.search(r"silent: ([a-z_, ]+)\)", r["reason"])
    print(f"{r['model'].split('/')[-1]} #{r['run']} bucket={b.group(1)} verification={r['facts'].get('verification_output')!r}")
    for c in [x for x in t["tasks"] if x.get("tool_name") == "compose"]:
        placed = [x for x in t["tasks"] if x["key"] in under(c["key"])]
        failed = [(x["key"], (x.get("error") or {}).get("key"), (x.get("error") or {}).get("detail", "")[:90]) for x in placed if x["status"] == "failed"]
        tools = [(x["tool_name"], (x.get("tool_input") or {}).get("path") or (x.get("tool_input") or {}).get("command", "")[:40]) for x in placed if x["kind"] == "tool_task"]
        seq = len(re.findall(r"g\.parallel", c["tool_input"].get("script", "")))
        print(f"   {c['key']} result={c.get('result')} g.parallel x{seq} placed tools={tools}")
        if failed: print(f"      failed stages: {failed}")
```

Output (`c7_grep_then_edit.out`):

```text
glm-5.3 #1 bucket=missing_steps verification='team.rb renamed; changed elsewhere: []'
   r2t0 result={'resolved': True} g.parallel x1 placed tools=[]
      failed stages: [('r2t0-script-1', 'script_syntax_error', "SyntaxError: Invalid or unexpected token at line 8 of the g.script stage's script, column ")]
   r3t0 result={'resolved': True} g.parallel x1 placed tools=[('grep', 'app/models/user.rb'), ('grep', 'app/models/account.rb'), ('grep', 'app/models/team.rb'), ('edit', 'app/models/team.rb'), ('grep', 'app/models/team.rb')]
glm-5.3 #2 bucket=extra_steps verification='team.rb renamed; changed elsewhere: []'
   r2t0 result={'resolved': True} g.parallel x1 placed tools=[('grep', 'app/models/user.rb'), ('grep', 'app/models/account.rb'), ('grep', 'app/models/team.rb'), ('read', 'app/models/team.rb'), ('edit', 'app/models/team.rb'), ('grep', 'app/models/team.rb')]
glm-5.3 #3 bucket=extra_steps verification='team.rb renamed; changed elsewhere: []'
   r2t0 result={'resolved': True} g.parallel x1 placed tools=[('grep', 'app/models/user.rb'), ('grep', 'app/models/account.rb'), ('grep', 'app/models/team.rb'), ('edit', 'app/models/team.rb'), ('grep', 'app/models/team.rb')]
kimi-k3 #1 bucket=over_sync verification='team.rb renamed; changed elsewhere: []'
   r2t0 result={'resolved': True} g.parallel x0 placed tools=[('grep', 'app/models/user.rb'), ('grep', 'app/models/account.rb'), ('grep', 'app/models/team.rb'), ('edit', 'app/models/team.rb')]
kimi-k3 #2 bucket=missing_steps verification='team.rb renamed; changed elsewhere: []'
   r2t0 result={'resolved': True} g.parallel x1 placed tools=[('grep', 'app/models/user.rb'), ('grep', 'app/models/account.rb'), ('grep', 'app/models/team.rb')]
   r3t0 result={'resolved': True} g.parallel x0 placed tools=[('bash', "sed -i '' 's/\\bfull_name\\b/display_name/"), ('grep', 'app/models/team.rb')]
```

### c7_woken_reply.py

Run: `python3 /private/tmp/claude-501/-Users-jasl-Workspaces-cybros-ai-alt2/fe6d4094-2f85-4b52-abfc-78043a70e275/scratchpad/v13/readout/scripts/c7_woken_reply.py`

```python
# C(7): plain-driver records whose red reads the REPLY while more than one loop ran (a receipt woke
# later turns): the reply the predicate read is the primary loop's `rho result` (turn 1), so an
# answer given in a woken turn is invisible to it. For each, look in the run's own Rails windows for
# a model text (content_fragments insert) that satisfies the claim the red says is missing.
import json, re, glob, os
RUNS = "/Users/jasl/Workspaces/cybros-ai.alt2/e2e/evals/runs"
def texts(logdir):
    seen = set()
    for fn in glob.glob(logdir + "/*.rails.log"):
        for line in open(fn, encoding="UTF-8", errors="replace"):
            if 'INSERT INTO "content_fragments"' not in line: continue
            m = re.search(r"VALUES \(\d+, CURRENT_TIMESTAMP, '([0-9a-f]+)', '(.*?)', CURRENT_TIMESTAMP\)", line)
            if not m or m.group(1) in seen: continue
            seen.add(m.group(1))
            try: yield json.loads(m.group(2).replace("''", "'")).get("text", "")
            except Exception: pass
for label in ["2026-09-24-v11-task", "2026-09-25-v13-task"]:
    for line in open(f"{RUNS}/{label}/records.jsonl", encoding="UTF-8"):
        r = json.loads(line)
        reason = str(r.get("reason") or "")
        if r.get("driver") != "plain" or "reply" not in reason or len(r.get("loops", [])) < 2: continue
        art = r["artifact"]
        logdir = os.path.join(os.path.dirname(art), "logs", os.path.basename(art)[:-5])
        merged = [t for t in texts(logdir) if all(f"lib/{f}.rb" in t and f"orphan_{f}" in t for f in "abcde")
                  and not t.lstrip().startswith("===")] if os.path.isdir(logdir) else None
        print(f"{label} {r['task']} {r['model'].split('/')[-1]} #{r['run']} loops={len(r['loops'])} receipts={r['facts'].get('receipts')} "
              f"class={r['verdict']['class']} reason={reason[:70]!r}")
        print(f"    turn-1 reply: {r['facts'].get('reply','')[:110]!r}")
        print(f"    model texts in the run's window naming all five files with their orphan: "
              f"{'no logs' if merged is None else len(merged)}; first: {(merged or [''])[0][:120]!r}")
```

Output (`c7_woken_reply.out`):

```text
2026-09-24-v11-task task-fan-five kimi-k3 #2 loops=6 receipts=5 class=model conduct reason='the merged reply names no lib/a.rb'
    turn-1 reply: "status:    completed\nAll five review agents are now running in parallel. I'll merge their answers into the sin"
    model texts in the run's window naming all five files with their orphan: 2; first: 'module A\n  def self.used_a(x) = x * 2\n  def self.orphan_a(x) = x * 3\n  def self.call(x) = used_a(x)\nend\nmodule B\n  def s'
2026-09-25-v13-task task-fan-five glm-5.3-flash #1 loops=6 receipts=5 class=model conduct reason='the merged reply names no lib/a.rb'
    turn-1 reply: "status:    completed\nAll five review agents are running. I'll merge their answers as soon as the results arriv"
    model texts in the run's window naming all five files with their orphan: 2; first: 'All five answers are in. Merged list:\n\n- lib/a.rb — orphan_a\n- lib/b.rb — orphan_b\n- lib/c.rb — orphan_c\n- lib/d.rb — or'
```

### c7_usable.rb

Run: `cd /Users/jasl/Workspaces/cybros-ai.alt2/e2e && bundle exec ruby /private/tmp/claude-501/-Users-jasl-Workspaces-cybros-ai-alt2/fe6d4094-2f85-4b52-abfc-78043a70e275/scratchpad/v13/readout/scripts/c7_usable.rb /Users/jasl/Workspaces/cybros-ai.alt2/e2e/artifacts/evals/2026-09-25-v13-compose/compose-rendezvous.openrouter_z-ai_glm-5.3-flash.nexus.1.json`

```ruby
# C(7): re-read the floor's usable bar on each compose call of one record, OFFLINE, from the saved
# trace (nothing written, nothing rescored). Run from e2e/: bundle exec ruby <this> <record-artifact>
require "json"
require_relative "/Users/jasl/Workspaces/cybros-ai.alt2/e2e/support/evals"
path = ARGV.fetch(0)
stored = JSON.parse(File.read(path, encoding: Encoding::UTF_8))
record = stored.fetch("record")
trace = E2E::Evals::Trace.new(loops: Array(record["loops"]), graph: Hash(stored["graph"]), tasks: Array(stored["tasks"]),
  events: Array(stored["events"]), spend: stored["spend"], sealed: stored["sealed_request"],
  facts: Hash(stored["facts"]).merge("summaries" => Hash(stored["summaries"])))
names = E2E::Evals::Predicates.declared_names(trace)
trace.compose_rows.each do |row|
  verdict = begin
    E2E::Evals::Usable.call(trace, row, tool_names: names)
  rescue StandardError => e
    "RAISED #{e.class}: #{e.message[0, 300]}"
  end
  puts "#{row["key"]}: #{verdict.inspect[0, 400]}"
end
```

Output (`c7_usable.out`):

```text
r2t0: "the kernel refused the compose call r2t0: its result is an error"
r3t0: true
```

### c7_rendezvous_floor.rb

Run: `cd /Users/jasl/Workspaces/cybros-ai.alt2/e2e && bundle exec ruby /private/tmp/claude-501/-Users-jasl-Workspaces-cybros-ai-alt2/fe6d4094-2f85-4b52-abfc-78043a70e275/scratchpad/v13/readout/scripts/c7_rendezvous_floor.rb`

```ruby
# C(7): compose-rendezvous is the one compose picture-less cell whose success reads the FIRST call
# (`valid_first` + the branch) on every tier, while the other compose cells hold the floor to usable
# generation by ANY call of the run. Re-read, offline and in memory, the floor's usable bar on each
# compose call of every v13 and v11 rendezvous record. Run from e2e/: bundle exec ruby <this>
require "json"
require_relative "/Users/jasl/Workspaces/cybros-ai.alt2/e2e/support/evals"
bench = E2E::Evals::Bench.read
%w[2026-09-24-v11-compose 2026-09-25-v13-compose].each do |label|
  E2E::Evals::Records.read(File.join(bench.runs_dir, label)).each do |record|
    next unless record["task"] == "compose-rendezvous"

    path = record["artifact"]
    next puts("#{label} #{record["model"]} ##{record["run"]}: no artifact") unless File.exist?(path)

    trace = E2E::Evals::Rescore.trace_of(record, path)
    names = E2E::Evals::Predicates.declared_names(trace)
    calls = trace.compose_rows.map { |row| [row["key"], E2E::Evals::Usable.call(trace, row, tool_names: names) == true] }
    first = calls.index { |_key, ok| ok }&.succ
    puts "#{label} #{record["model"].split("/").last.ljust(15)} ##{record["run"]} tier=#{record.dig("facts", "tier")} " \
         "succeeded=#{record.dig("verdict", "succeeded").inspect} class=#{record.dig("verdict", "class").inspect} " \
         "usable per call=#{calls.inspect} first usable call=#{first.inspect}"
  end
end
```

Output (`c7_rendezvous_floor.out`):

```text
2026-09-24-v11-compose glm-5.3         #1 tier=strong succeeded=true class=nil usable per call=[["r2t0", true]] first usable call=1
2026-09-24-v11-compose glm-5.3         #2 tier=strong succeeded=true class=nil usable per call=[["r2t0", true]] first usable call=1
2026-09-24-v11-compose glm-5.3         #3 tier=strong succeeded=true class=nil usable per call=[["r2t0", true]] first usable call=1
2026-09-24-v11-compose kimi-k3         #1 tier=strong succeeded=true class=nil usable per call=[["r2t0", true]] first usable call=1
2026-09-24-v11-compose kimi-k3         #2 tier=strong succeeded=false class="model conduct" usable per call=[["r2t0", false], ["r3t0", true]] first usable call=2
2026-09-24-v11-compose kimi-k3         #3 tier=strong succeeded=true class=nil usable per call=[["r2t0", true]] first usable call=1
2026-09-24-v11-compose deepseek-flash  #1 tier=floor succeeded=true class=nil usable per call=[["r2t0", true]] first usable call=1
2026-09-24-v11-compose deepseek-flash  #2 tier=floor succeeded=true class=nil usable per call=[["r2t0", true]] first usable call=1
2026-09-24-v11-compose deepseek-flash  #3 tier=floor succeeded=true class=nil usable per call=[["r2t0", true]] first usable call=1
2026-09-24-v11-compose glm-5.3-flash   #1 tier=floor succeeded=true class=nil usable per call=[["r2t0", true]] first usable call=1
2026-09-24-v11-compose glm-5.3-flash   #2 tier=floor succeeded=false class="model conduct" usable per call=[["r2t0", true]] first usable call=1
2026-09-24-v11-compose glm-5.3-flash   #3 tier=floor succeeded=nil class="model conduct" usable per call=[] first usable call=nil
2026-09-25-v13-compose glm-5.3         #1 tier=strong succeeded=true class=nil usable per call=[["r2t0", true]] first usable call=1
2026-09-25-v13-compose glm-5.3         #2 tier=strong succeeded=true class=nil usable per call=[["r2t0", true]] first usable call=1
2026-09-25-v13-compose glm-5.3         #3 tier=strong succeeded=true class=nil usable per call=[["r2t0", true]] first usable call=1
2026-09-25-v13-compose kimi-k3         #1 tier=strong succeeded=true class=nil usable per call=[["r2t0", true]] first usable call=1
2026-09-25-v13-compose kimi-k3         #2 tier=strong succeeded=true class=nil usable per call=[["r2t0", true]] first usable call=1
2026-09-25-v13-compose kimi-k3         #3 tier=strong succeeded=true class=nil usable per call=[["r2t0", true]] first usable call=1
2026-09-25-v13-compose deepseek-flash  #1 tier=floor succeeded=true class=nil usable per call=[["r2t0", true]] first usable call=1
2026-09-25-v13-compose deepseek-flash  #2 tier=floor succeeded=true class="cache under floor" usable per call=[["r2t0", true]] first usable call=1
2026-09-25-v13-compose deepseek-flash  #3 tier=floor succeeded=true class=nil usable per call=[["r2t0", true]] first usable call=1
2026-09-25-v13-compose glm-5.3-flash   #1 tier=floor succeeded=false class="model conduct" usable per call=[["r2t0", false], ["r3t0", true]] first usable call=2
2026-09-25-v13-compose glm-5.3-flash   #2 tier=floor succeeded=true class=nil usable per call=[["r2t0", true]] first usable call=1
2026-09-25-v13-compose glm-5.3-flash   #3 tier=floor succeeded=true class=nil usable per call=[["r2t0", true]] first usable call=1
```

### c7_bgsuite.py

Run: `python3 /private/tmp/claude-501/-Users-jasl-Workspaces-cybros-ai-alt2/fe6d4094-2f85-4b52-abfc-78043a70e275/scratchpad/v13/readout/scripts/c7_bgsuite.py`

```python
# C(7) compose-background-suite: how each v13 run launched the suite inside its FIRST compose script
# (bash `bin/rails test` = a step that runs the suite to completion; start_process = a launch that
# returns after `wait_seconds` while the suite runs on as a process), against the verdict and the
# picture's buckets.
import json, re
RUNS = "/Users/jasl/Workspaces/cybros-ai.alt2/e2e/evals/runs/2026-09-25-v13-compose/records.jsonl"
for line in open(RUNS, encoding="UTF-8"):
    r = json.loads(line)
    if r["task"] != "compose-background-suite": continue
    t = json.load(open(r["artifact"], encoding="UTF-8"))
    comp = [x for x in t["tasks"] if x.get("tool_name") == "compose"]
    script = comp[0]["tool_input"].get("script", "") if comp else ""
    via = "start_process" if re.search(r'name:\s*"start_process"', script) else ("bash" if "rails test" in script else "-")
    ws = re.search(r"wait_seconds:\s*(\d+)", script)
    b = re.search(r"silent: ([a-z_, ]+)\)", str(r.get("reason") or r["facts"].get("picture") or ""))
    print(f"{r['model'].split('/')[-1]:15} #{r['run']} tier={r['facts'].get('tier'):6} class={r['verdict']['class']!s:18} "
          f"succeeded={r['verdict']['succeeded']!s:5} suite via={via:13} wait_seconds={ws.group(1) if ws else '-':3} "
          f"picture buckets={b.group(1) if b else ('exact' if r['facts'].get('picture') is True else '-')}")
```

Output (`c7_bgsuite.out`):

```text
glm-5.3         #1 tier=strong class=None               succeeded=True  suite via=bash          wait_seconds=-   picture buckets=exact
glm-5.3         #2 tier=strong class=model conduct      succeeded=False suite via=start_process wait_seconds=0   picture buckets=suite_waited_on, extra_steps, over_sync, over_read
glm-5.3         #3 tier=strong class=lane bug           succeeded=None  suite via=-             wait_seconds=-   picture buckets=-
kimi-k3         #1 tier=strong class=None               succeeded=True  suite via=bash          wait_seconds=-   picture buckets=exact
kimi-k3         #2 tier=strong class=model conduct      succeeded=False suite via=start_process wait_seconds=15  picture buckets=suite_waited_on, extra_steps, over_read
kimi-k3         #3 tier=strong class=model conduct      succeeded=False suite via=start_process wait_seconds=5   picture buckets=suite_waited_on, extra_steps, over_read
deepseek-flash  #1 tier=floor  class=None               succeeded=True  suite via=start_process wait_seconds=0   picture buckets=-
deepseek-flash  #2 tier=floor  class=None               succeeded=True  suite via=start_process wait_seconds=5   picture buckets=suite_waited_on, extra_steps, over_read
deepseek-flash  #3 tier=floor  class=None               succeeded=True  suite via=start_process wait_seconds=5   picture buckets=suite_waited_on, extra_steps, over_sync, over_read
glm-5.3-flash   #1 tier=floor  class=None               succeeded=True  suite via=bash          wait_seconds=-   picture buckets=exact
glm-5.3-flash   #2 tier=floor  class=None               succeeded=True  suite via=bash          wait_seconds=-   picture buckets=extra_steps, over_read
glm-5.3-flash   #3 tier=floor  class=None               succeeded=True  suite via=start_process wait_seconds=30  picture buckets=suite_waited_on, extra_steps, over_read
```
