# B — Every red on the three new models (bench v15)

Scope: the 180 v15 records (`e2e/evals/runs/2026-09-26-v15-{task,compose,workflow}`, digest `772186a893d5`, one line
per key, kernel `cbff8f42`), their traces and world logs, read against v14's records and readout
(`docs/plans/2026-09-26-v14-bench-readout.md` §3, §7, §8, §9, §10). Nothing was rescored or appended. No paid call,
no world, no test suite ran. The Ruby re-reads load the harness under the e2e bundle, in memory only. Every number
below comes from a script in `B/` beside its `.out` (§B.8). "Green" means class nil.

## Headline

**35 reds on 180 records**: Opus 5.5 has 8, GPT-6 Sol 15 and GPT-6 Luna 12 (b1). Green counts out of 60 are Opus 52,
Sol 45 and Luna 48. For comparison, v14's glm-5.3 had 40, kimi-k3 43, deepseek-flash 46 and glm-5.3-flash 45 (b14).

**No red is a kernel or wire fault.** Across the 1,901 billed invocations, every usage record succeeded with no error
code and every attempt completed. No record has a `round_errors` or `attention_reasons` entry, no model node failed,
and `reasoning_extraction` never appears (b2, b16). Looking hard still turned up three things that do not cause any
red:

- **Anthropic refused 9 compose model steps.** The category was `cyber`. All 9 are Opus steps on the three
  compose-three-stage-pairing runs, and all three records are green.
- **The kernel hands a refused step on as `(task completed with no output)`.** The harness reads that as completed.
- **Anthropic dropped earlier thinking on 17 of the 547 Opus invocations.** The reason was
  `prefix_binding_mismatch`.

| model | 1 plain model conduct | 2 a rule the v14 readout left to the owner | 3 reader flaw | 4 kernel/wire | reds |
|---|---|---|---|---|---|
| claude-opus-5-5 | 1 | 7 | 0 | 0 | 8 |
| gpt-6-sol | 7 | 6 | 2 | 0 | 15 |
| gpt-6-luna | 11 | 1 | 0 | 0 | 12 |
| all | 19 | 14 | 2 | 0 | 35 |

(b15; every red is assigned once, and the script asserts the set equals b1's red list.)

- **Opus's reds are almost all pending owner rulings (7 of 8).** They are two-source-fan-in's `over_read` ×3,
  barrier-free's `edit_as_tool` ×3, and a background-suite run whose suite went to a one-step detached compose
  instead of `task`.
- **Sol's reds split three ways: its conduct, the pending pictures, and one reader flaw.** Conduct means one
  delegation per message on fan-five and judge-panel, two script faults, and one no-door run. The pending pictures are
  `over_read` ×4 and `edit_as_tool` ×2. The reader flaw is two judge-panel records.
- **Luna's reds are almost all floor-typical conduct (11 of 12).** That covers `start_process` for the mail task,
  serial one-per-message delegation, bash pipelines on barrier-free, and weak refuters. The twelfth is the cache
  bar's arithmetic.

**Green counts under the pending rulings** (b13; each move comes from the script that computed it):

| model | recorded | O7 candidate | reads-only A (§8.5) | A + O7 | cache bar read vs ceiling | fan-five: five in any one message |
|---|---|---|---|---|---|---|
| claude-opus-5-5 | 52 | **54** | 52 | **54** | 52 | 52 |
| gpt-6-sol | 45 | **47** | **47** | **49** | 45 | 45 |
| gpt-6-luna | 48 | 48 | 48 | 48 | **49** | 48 |

**Why A leaves Opus flat.** Under A, Opus gains two-source-fan-in ×3 and loses three pictures that were exact only
by position (grep-then-edit #3 and three-stage-pairing #1 and #2). Sol gains 4 and loses 2. Luna is on the floor's
bar, so A moves its picture (12 → 18 of 22 re-read) but not its class.

**A reader question this bench raises, and one v14 did not have** (b10, b12). Sol hands out delegations one per
message and then gathers them with a compose that only calls `g.wait`. The family reads that gather as the compose
door, and the reading is not consistent across cells:

- adversarial-verify ×3 and fan-out-finders ×3 read green;
- judge-panel #1 and #2 read as disagreements.

Reading the gather as the task branches it gathers turns the judge-panel pair green: Sol goes to 47. Reading the
gather as no door removes six Sol greens: Sol goes to 39.

## B.1 What the reds are, per family

| family | Opus | Sol | Luna |
|---|---|---|---|
| task (18 each) | g16 · mc2 | g15 · mc3 | g14 · mc4 |
| compose (27 each) | g24 · mc3 | g21 · mc4 · dis2 | g26 · cuf1 |
| workflow (15 each) | g12 · dis3 | g9 · mc2 · dis4 | g8 · mc5 · dis2 |

(b1.) Cells with all three runs red: Opus two-source-fan-in, Opus barrier-free, Sol fan-five and Luna barrier-free.
Every other red cell has one or two reds (b14's grid in b1's list).

## B.2 Every red: reason, evidence, bucket

### Task family: 9 reds

| record | recorded reason | evidence from the trace | bucket |
|---|---|---|---|
| background-suite **Opus #3** | no `task` call; called compose ×2, bash ×5 | r2 launched the suite as a one-step detached compose, `g.tool bash "bin/rails test …"`, beside a direct rubocop call. It fixed the lint, then r6 composed `g.wait` on the suite and replied after it. Runs #1 and #2 used `task`. | **2**: §10's leniency "task-background-suite's task-only reach beside O4's `start_process` ruling". By the family's rule as written ("REACH: a `task` row") this is model conduct. Note that Opus also waited on the suite before its final reply. |
| task-mail **Opus #1** | no `task` call; turn 1 called compose ×1, bash ×2 | The same move: a one-step compose detached `ruby test/all.rb` (lifetime `conversation`), then it replied "3". Runs #2 and #3 used `task`. | **1** (the family measures the `task` receipt loop). This is the same owner question as the row above. |
| task-mail **Luna #1, #2** | no `task` call; turn 1 called start_process ×1, bash ×1 | `start_process "ruby test/all.rb"` with `wait_seconds: 0`, then it replied "3" (15 s runs). #3 used `task`. | **1**: the floor's `start_process` habit, which accounted for 13 of v14's 21 task reds (§3.2). |
| fan-five **Sol #1, #3** | 1 task call in the first message, not five | Five detached `task` calls, **one per message** (m1–m5), then a compose that only runs `g.wait` over the four open tasks. The members overlapped 3 at a time. Run #1's r17 merged all five correctly. The last woken turn wrote an empty `final_answer` (reasoning item, zero text deltas), so the recorded reply is "(none — this loop resolved no deliverable)". | **1** |
| fan-five **Sol #2** | the same | Waited `task` calls: one, one, then three in one message. | **1** |
| fan-five **Luna #2, #3** | the same | Five **waited** `task` calls, one per message. The run was fully serial (peak 1 open member, 37–39 s against Luna #1's 8 s when it put all five in one message). | **1** |

The fan-five reds are not the pending "first-message reach" case. That case (v14 deepseek-flash #1) put all five
calls in one later message. No GPT-6 red ever did: the most in one message is 3 (Sol #2) and every other red record
has 1. The candidate that admits five in any one message therefore moves 0 records (b5, b13).

### Compose family: 11 reds

| record | recorded reason | evidence | bucket |
|---|---|---|---|
| two-source-fan-in **Opus #1–#3**, **Sol #1, #3** | picture not O7b's (silent: `over_read`) | All five write `P[tests, lint, types, testSummary(results:[tests]), qualitySummary(results:[lint,types])]`, then a report **after** the group with `results: [testSummary, qualitySummary]`. The report is exactly the picture's inputs, and position adds the three raw outputs. Sol #2 is exact because it put the report inside the group. This is §8.3's placement pattern exactly. | **2** (compose `over_read`) |
| three-stage-pairing **Sol #1, #2** | picture not O7's (silent: `over_read`) | `P[a, b, c, na, nb, nc]`, then a merge after the group with `results: [na, nb, nc]`. Position adds a, b and c raw. Sol #3 wrote the pairs as sequences (`P[[a,na],[b,nb],[c,nc]]`) and is exact. | **2** (`over_read`) |
| three-stage-pairing **Luna #1** | cache under floor | Rate after r1 is 0.7744 against a ceiling of 0.7746 over 2 measured rounds, and the provider served every whole prompt. The floor's bar (usable generation on call 1) is met. Inside the plan, Luna's three normaliser scripts threw on valid rows ("Cannot normalize source a row: a\|2026-09-01\|q7f3k"). | **2** (§7.7, the cache bar's arithmetic) |
| grep-then-edit **Sol #1** | script refused: `results` names an "all" group | `results: [searches]` where `searches = g.parallel(...)`. The kernel's builder refuses this, and the compose text says `results:` is "never an "all" group". Call 2 was usable, and task pass is true. | **1** (class disagreement) |
| grep-then-edit **Sol #3** | `…(failed) did not complete under r2t0` | The plan's own verify stage failed: "New definition not verified: No matches found". The inner script is a JS template literal nested in another, so the grep pattern arrived as `(self.)?display_name` + backspace (`\b` unescaped once). The edit itself landed. Sol then fixed `to_s` by hand, and verification passed ("team.rb renamed; changed elsewhere: []"). | **1** (class disagreement) |

### Workflow family: 15 reds

| record | recorded reason | evidence | bucket |
|---|---|---|---|
| barrier-free **Opus #1–#3** | picture not O7's (silent: `edit_as_tool`) | Three [fetch → normaliser `g.script`] pairs, then a merge `g.script` stage that writes `merged.txt` with an inner `g.tool write`. Verification passes 3/3. | **2** (O7). Under the candidate, #2 and #3 become exact and green. #1 stays red: its stage-placed write tool waits on the raw fetches, so the candidate reads it as `over_read` (b7). |
| barrier-free **Sol #1, #3** | the same | An all-tool plan: `P([fetch > x.raw, awk … > x.normalized] ×3)`, then `cat a.normalized b.normalized c.normalized > merged.txt`. This is v14 glm-5.3's shape. | **2** (O7). Both are green under the candidate. |
| barrier-free **Sol #2** | no compose call and no round fanned two task calls | Three fetch→awk `bash` calls in one message, then a `cat` merge. Verification passes. | **1** (no door; Sol *does* put three calls in one message here) |
| barrier-free **Luna #1–#3** | the same | One `bash` running the three pipelines with `&` and `wait`. This is v14's kimi-k3 and deepseek-flash no-door shape. Verification passes 3/3. | **1** |
| adversarial-verify **Luna #1** | disagreement (task pass false) | Marks C3 FALSE where the oracle says STANDS. Refuter r19 answered "FALSE — `post` accepts any amount, so `post(:a, nil); total` … raises", and the spine applied "stands only if both fail" to that contrived disproof. | **1** (the weak model's judgement; the class is disagreement because the process predicate passes) |
| adversarial-verify **Luna #3** | the same | Marks C2 and C3 FALSE. The collector step reports "a custom `Numeric` can report `positive?` while coercing to −1" (C2) and "posting an entry with amount `nil` makes `total` raise" (C3). | **1** |
| judge-panel **Sol #1, #2** | `r8t0 composed 3 tasks and no step reads two model members` (disagreement; task pass true) | Three detached judges, **one per message**, each overlapping the next (peak 3 open). Then a compose of `g.wait` ×3 only, a waited chair `task`, `verdict.md` = "winner: b", and reply "winner: b". The compose row sends success to `Gallery.fan_join?`, which looks for a step that reads two model members, and a wait-only gather has none. | **3** (§B.4.1) |
| judge-panel **Sol #3**, **Luna #3** | no compose call and no round fanned two task calls | Four **waited** `task` calls (three judges, then a chair), one per message, fully serial (peak 1, 31 s and 37 s). Verification passes. | **1** |
| judge-panel **Luna #1** | the same (`spawn` ×3) | Three `spawn` judges, one per message. Verification passes. | **1**. `spawn` as a door is the owner's (§7.5), but even read as a door this run never fans two in one message. |

## B.3 Kernel and wire: nothing on any red; three findings on greens

**B.3.1 The channel is clean** (b2, b16):

- **Billing and attempts.** 1,901 billed invocations: task 442, compose 423, workflow 1,036; by model Opus 547,
  Sol 673, Luna 681. Every `usage_records` row is `succeeded` with a NULL `error_code`. Every
  `model_invocation_attempts` row ended `completed` (1,901 of 1,901).
- **Record facts.** No record has `round_errors`, `attention_reasons` or `untraced_attention_reasons`. No record
  stopped. Every `model_task` row across all 180 traces completed (task 400, compose 407, workflow 1,026).
- **Node outcomes.** The only failed nodes are 7 compose `script_task` rows, each the model's own script throwing
  `script_error`: Luna grep-then-edit #1 and #3, Luna three-stage #1 ×4, and Sol grep-then-edit #3. The only canceled
  nodes are the race losers (`join_loser_canceled`, 42).
- **Errors and refusals in the logs.** No `level=error`, no HTTP 4xx/5xx, and no `reasoning_extraction`.
- **GPT-6 requests.** Every spine request carries only `tools` and `verbosity: low`. `parallel_tool_calls` is absent,
  so the provider's default applies (b17). Sol's one-per-message delegation is therefore its own: it does put several
  calls in one message elsewhere (barrier-free #2's three `bash` calls, members' parallel reads).

**B.3.2 Anthropic refused 9 Opus compose model steps as `cyber`, and the three records read green** (b3, b3b, b16).

Every refusal is a compose-placed model step on compose-three-stage-pairing:

- **Counts.** Opus #1 refused 3 of its 4 steps, #2 refused 2 and #3 refused 4, so 9 of 12. None of Opus's other 32
  compose-placed model steps was refused, and no GPT-6 step was.
- **How the kernel records it.** Each refused invocation is `status completed`, `finish_quality refused`,
  `failure_detail "cyber: This request triggered restrictions on violative cyber content…"`. It was billed.
- **What each refused step was sent.** A ~619-byte request with `tools: []` and no system entry. It held the
  normaliser prompt ("You are given the raw output of `sh bin/fetch b` … Normalise every record …") and the envelope
  `<task_result task="r2t0-tool-2" status="completed"><call>bash {"command":"sh bin/fetch b"}</call>b|2026-09-02|m2z9p</task_result>`.
  Run #1's model-1 got the same shape and answered correctly.
- **What the kernel handed on.** The delivered envelope reads
  `<task_result task="r2t0-model-2" status="completed"> … (task completed with no output)`. The refusal is lost at
  the envelope (`AgentLoops::TaskResultEnvelope::EMPTY`). It survives only as the trace row's
  `result: {"finish_quality": "refused"}`, which no reader in `e2e/support` reads.
- **What the primaries did.** All three saw "the merge step finished with **no output**". Each re-ran the three
  fetches by hand and merged the rows itself. Their replies say plainly that the list came from the re-run and that
  they could not tell why the step came back empty.

The picture (exact edges and reads, branch completed) and usable generation both read green. **A pipeline whose
product was refused away reads green here.** Two questions go to the kernel and harness owners. Should the envelope
name a refused step, and should `branch_completed` read a refused member as completed? No v14 record carries a
`finish_quality` (b3).

**B.3.3 Opus: earlier thinking dropped on 17 of 547 invocations** (b4, b4b).

- **Coverage.** Every Opus invocation logged `event=provider_input_transformations` (547 summaries for 547 billed
  invocations). 530 read `count=0`. 17 read `count≥1`, all `type=thinking_dropped reason=prefix_binding_mismatch`.
- **Where the drops were.** 19 paths in total: 12 at `messages.1.content.0` and 7 later. The 17 invocations fall on
  11 records: task-background-suite #1 and #2; task-fan-five #3 ×5; task-mail #1, #2 ×2 and #3;
  compose-background-suite #1, #2 and #3 ×2; judge-panel #1 and #3.
- **Class.** Ten of the 11 records are green. The eleventh, task-mail #1, is red on reach, not on this.
- **Which rounds, by timing.** Traced rows only have one-second resolution, so this is inferred from times. The drops
  sit on the first round of a turn a receipt woke, or of turn 2. For example, the five drops on fan-five #3 are 2.5 s
  apart, just after its five detached members settled. The two judge-panel drops sit on the merge step, whose history
  splices the judges' rounds (`messages.3` and `messages.5`).
- **What it means.** In those rounds the kernel replays a thinking block under a prefix it was not produced under.
  The server drops it silently. No red follows from it. It goes to the kernel owner as a wire observation.

**B.3.4 Sol ends four runs with an empty final answer** (b17). The last woken turn of fan-five #1 and #3 and of
fan-out-finders #1 and #3 emitted a reasoning item plus an empty `final_answer` message, with zero `text_delta`
broadcasts (fan-five #1's w1: 23 output tokens, 17 of them reasoning). The work had already been delivered: on
fan-five by the earlier merge, on fan-out-finders by `findings.md`, whose verification passes 8/8. This is model
behaviour on a redundant woken turn, not a dropped `phase`. None of v14's four models ends a run's last reply empty.

## B.4 Reader flaws

**B.4.1 A gather compose is read three ways across the workflow family** (b10, b12, b5c, b11). Sol's idiom is to
detach N tasks one per message, then compose `g.wait` over them, sometimes with one collector `g.script` or
`g.model`. It appears on 10 v15 workflow records with at most one task call per message: Sol adversarial-verify ×3,
fan-out-finders ×3 and judge-panel #1 and #2, plus Luna adversarial-verify #1 and #3. v14 has one gather compose, on
fan-five deepseek-flash #3, and it came after a real five-call fan. The readers treat the idiom differently:

- `Predicates.door` counts **any** compose row as the compose door, so every one of these records reaches its door.
- adversarial-verify and fan-out-finders then read receipts and loops, and Sol goes green 6/6.
- judge-panel's success sends any compose row to `Gallery.fan_join?`, which wants a step reading two model members,
  and Sol #1 and #2 turn red. That contradicts the task file's own comment: "task branches that all return, whether
  waited or detached".

The two consistent readings, with the numbers from b12 and b13:

- **(i) The gather is the door, and judge-panel reads the task branches it gathers.** Every task row completed, every
  loop completed, and the reply names b. Sol judge-panel #1 and #2 turn green, and **Sol goes 45 → 47**.
- **(ii) A gather is no door.** Reach then needs a message that fans two task calls. Sol loses adversarial-verify ×3
  and fan-out-finders ×3, so **Sol goes 45 → 39**. Luna adversarial-verify #1 and #3 move from disagreement to model
  conduct and stay red.

Whether "detached one per message, then gathered" counts as a fan is the owner's question (§B.6 has the timing).
Either way, the judge-panel reading does not match its two sibling cells.

**B.4.2 The harness is blind to a refused step** (§B.3.2). No reader reads `result.finish_quality`, so three Opus
greens stand over pipelines whose model steps were refused.

**B.4.3 The v14 flaws touch no v15 record.**

- `Claims::RaceWinner` (§7.2): all 18 race and race-anon records are green.
- `Predicates.per_file` (§7.3): the five fan-five reds are reach reds, and each carries `per_file` 1 per file (b1).
- `settle_receipts` early quiet (§7.5): no verification fails on it. Luna's `spawn` judges pass verification.

## B.5 The pending rulings, read offline

**O7's candidate picture** (`"merge" => "model|tool|script"`, `computes: %w[na nb nc merge]`), run with the v14
readout's `c1_o7_merge.rb` copied verbatim (b7):

- 14 composed O7 records re-read. 5 move, all on barrier-free: Opus #2 and #3 and Sol #1 and #3 go from
  disagreement to **green**, and Opus #1 goes from `edit_as_tool` to `over_read`, still a disagreement.
- None of the 9 compose-three-stage-pairing records moves.
- The candidate's class includes the cache bar, which none of the four fails.

**The reads-only counterfactual A of §8.5**, exactly as `d5_explicit_rule.rb` defines it (b8). The helpers are
copied, with only the label and model tables extended. Every model step reads only its `results:`, and the picture
is re-scored with `Scoring.score_graph`:

- **Control.** On v14 it reproduces §8.5 exactly: `over_read` 21 → 18 gone, 14 exact; gate tasks strong 31 → 32 and
  floor 27 → 30; 4 of 61 exact pictures broken. The unchanged-plan control is 96/96 on v14 and 74/74 on v15.
- **v15 overall.** 18 `over_read` readings; 17 lose the bucket and 16 turn exact. Gate tasks: strong (Opus and Sol,
  41 built plans) 34 → 36; floor (Luna, 19 built plans) 12 → 15. 5 of 46 exact pictures break because a step named
  nothing: grep-then-edit Opus #3 and Sol #2 `blind_model`, review-angles Sol #3 `reads_mismatch`, three-stage-pairing
  Opus #1 and #2 `blind_model`. The last two are Opus's merge written as "Above are three normalised record sets…"
  with no `results:`.
- **Classes.** On the strong tier each record's class is recomputed with `Scorecard.classify`, using succeeded := A
  exact ∧ `branch_completed`. Rendezvous is recorded-only (T5) and keeps its class.
  - **Opus:** +3 (two-source #1–#3) and −3 (grep-then-edit #3 → disagreement; three-stage #1 and #2 → model conduct),
    so 52 → 52.
  - **Sol:** +4 (two-source #1 and #3; three-stage #1 and #2) and −2 (grep-then-edit #2 → disagreement; review-angles
    #3 → model conduct), so 45 → 47.
  - **Luna:** the floor's bar is unchanged, so 48 stays 48. Its picture goes 12 → 18 of 22 re-read.
- **B**, which also lets a step read the round it continues, gives the same exact-or-miss verdict as A on every
  reading: 0 of 74 on v15 and 0 of 96 on v14. Only two buckets differ: Opus three-stage #1 and #2 read
  `reads_mismatch` under B instead of `blind_model`.

**Both together** (b8 with `O7_CANDIDATE=1`): the barrier-free plans hold 0 model steps, so the two rulings add.
Opus 54, Sol 49, Luna 48.

**The other v14 pending rulings:**

- **Cache bar read against each record's ceiling** (§7.7). v15 has one record under 0.80, Luna three-stage #1 at
  0.7744 against a ceiling of 0.7746, with the provider serving every whole prompt. It turns green, so **Luna 48 → 49**.
  Opus, Sol and Luna leave 28, 32 and 30 records for the bar to read, and none other is under (b9). v14 had 16
  cache-under-floor records.
- **Fan-five reach on five in any one message.** 0 moves (§B.2).
- **`spawn` as a door.** Luna judge-panel #1 spawned one per message, so a door that reads `spawn` like `task` (two in
  one round) moves nothing.
- **Task-only reach beside O4** (Opus background-suite #3 and task-mail #1, Luna task-mail #1 and #2). Not
  computable offline: no candidate reader is defined, and task-mail's success needs a mailed receipt that a
  `start_process` or compose launch does not produce.

## B.6 GPT-6 on fan-five and judge-panel, against glm-5.3 and kimi-k3

How each model delegated (b5, b5b, b11). A message is one model response; "(d)" means detached and "(w)" waited.

| | fan-five | judge-panel |
|---|---|---|
| **glm-5.3, kimi-k3 (v14)** | 6/6 put five **waited** `task` calls in **one** message (peak 5 members at once, 16–54 s). Green glm 1 (2 cache under floor), kimi 3 | 4/6 put three waited judges in one message, then a chair (peak 3); 2/6 composed a fan/join (glm #2, kimi #3). Green glm 0 (3 cache under floor), kimi 3 |
| **Opus 5.5** | 3/3 put five **detached** `task` calls in the first message (peak 5, 13–14 s). Green 3 | 3/3 composed a fan/join in its first message and never called `task`. Green 3 |
| **GPT-6 Sol** | 0/3 fanned. #1 and #3: five detached, one per message, then a gather compose (peak 3, 19 s). #2: one, one, then three waited (peak 3, 31 s). Green 0 | 0/3 fanned. #1 and #2: three detached judges one per message, a gather, then a waited chair (peak 3, 17–19 s). #3: four waited one per message, serial (peak 1, 31 s). Green 0 |
| **GPT-6 Luna** | #1: five waited in one message (peak 5, 8 s), green. #2 and #3: five waited one per message, fully serial (peak 1, 37–39 s). Green 1 | #1: three `spawn` one per message. #2: one then two waited in one message, green. #3: four waited one per message, serial. Green 1 |

**Sol almost never puts two delegations in one message.** Across every v15 record, Sol's spine made 94 messages that
carried a delegation (`task` or `spawn`), and 1 of them carried two or more (fan-five #2's three). For comparison:

- Luna: 6 of 57.
- Opus: 3 of 10. Opus usually delegates through compose.
- v14: glm-5.3 11 of 21, kimi-k3 11 of 20, deepseek-flash 10 of 18, glm-5.3-flash 12 of 19.

Sol puts two or more calls of any kind in one message in 6% of its call-making messages (17 of 266), Luna in 9%
(22 of 255), Opus in 15% (19 of 124), and v14's four models in 23–39% (b5b).

**GPT-6 still gets concurrency by detaching.** It detaches each task and gathers them afterwards (Sol), or it waits
each one in turn and runs serially (Luna #2 and #3, Sol judge-panel #3). glm and kimi instead put three or five waited
calls in one message.

**The door rule decides whether that concurrency counts.** Detached one per message, Sol's members still overlap. On
fan-five 3 of the 5 run at once, because each call comes about 2–3 s after the last. On judge-panel all three judges
overlap. On fan-five and judge-panel the door is "N in one message", so it reads red there. It reads green on adversarial-verify and
fan-out-finders, where the gather compose opens the door (§B.4.1). This is a model habit with no wire cause:
`parallel_tool_calls` is never sent, and Sol fans three `bash` calls in one message on barrier-free #2 (§B.3.1).

## B.7 What it says

1. **All 35 reds are the models' conduct or rules already pending with the owner, plus one new reader question.** No
   provider error, round error, attention stop or failed attempt occurs on any of the 1,901 invocations (§B.3.1).
2. **Opus 5.5 is the strongest model the bench has run: 52/60.** 7 of its 8 reds sit on pending pictures, and under
   O7's candidate it reads 54. Its compose picture is 18/21 on the gate tasks, against 16 for glm-5.3 and 15 for
   kimi-k3 (b14). It shows the same `over_read` placement habit as v14's strong models on two-source-fan-in ×3.
3. **Sol reads 45/60, and its distinctive miss is serial delegation.** One task call per message: 1 of its 94
   delegation messages fanned. That costs fan-five 3/3 and judge-panel 3/3. The same idiom passes adversarial-verify
   and fan-out-finders only through a gather compose that the family reads inconsistently (§B.4.1).
4. **Luna reads 48/60, above both v14 floors (46 and 45).** Its reds are floor-typical: `start_process` on task-mail,
   serial delegation, bash pipelines instead of a door, and weak refuters accepting contrived disproofs.
5. **One thing to raise beside the rulings.** Anthropic's `cyber` classifier refused 9 of 12 Opus model steps on
   compose-three-stage-pairing. The kernel delivers a refusal as "(task completed with no output)", and the harness
   reads the branch as completed. Three green records hide a lost pipeline product that the model itself reported.

## B.8 Scripts and outputs (all under `B/`)

Every script is read-only, and every one ran on this machine. `bundle exec ruby` ran from `e2e/` under `nice -n 10`.

| script | gives |
|---|---|
| `b1_reds.py` | per-model classes and cost per family, and every red with its recorded reason |
| `b2_statuses.py` | per-trace errors, attention, stops, and every non-completed row |
| `b3_finish_quality.py`, `b3b_member_steps.py` | rows carrying `result.finish_quality` (v15 and v14), and compose-placed model steps per model |
| `b4_transformations.py`, `b4b_rows.py` | Opus `input_transformations` from the world logs, mapped to records and (by time) rows |
| `b5_fans.py`, `b5b_calls_per_message.py`, `b5c_other_fans.py` | delegation per message on fan-five and judge-panel (v14 and v15), calls per message for every record, and the passing workflow fans |
| `b6_refuters.py` | Luna adversarial-verify: prompts per claim and `verdict.md` |
| `b7_o7_merge.rb` | the v14 readout's `c1_o7_merge.rb` verbatim, run with `O7_LABELS` on the v15 labels |
| `b8_common.rb`, `b8_harness.rb`, `b8_explicit_rule.rb` | §8.5's counterfactual A and B with the v14 control and per-record classes. `.out` is A alone; `.o7cand.out` is A with O7's candidate |
| `b9_cache.py` | rate after r1, ceiling and short-served rounds for every v15 record under the floor |
| `b10_gather_door.py`, `b12_judge_gather.rb` | the gather compose across v14 and v15, and judge-panel under readings (i) and (ii) |
| `b11_member_overlap.py` | peak concurrent members and wall time on fan-five and judge-panel |
| `b13_green_counts.py` | the green-count table, assembled from b5, b7, b8, b9, b10 and b12's outputs |
| `b14_context.py` | green per family and model, v15 against v14, and the gate-task compose picture |
| `b15_buckets.py` | the bucket per red, asserted against b1's red set, counted per model |
| `b16_channels.py` | per world: billed invocations and status, attempt terminal statuses, `finish_quality`, failed and canceled nodes, error words |
| `b17_replies_and_options.py` | empty final answers (v15 and v14), and the sealed request options per model |
| `b_show.py` | helper that prints one trace's rows and compose scripts, used for the evidence quotes in §B.2 |
