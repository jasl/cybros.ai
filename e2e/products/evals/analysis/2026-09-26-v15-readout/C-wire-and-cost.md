# Section C — wire and cost facts of the new models (bench v15)

Scope: the 180 v15 runs (task 54, compose 81, workflow 45; `anthropic/claude-opus-5-5`, `openai_api/gpt-6-sol`,
`openai_api/gpt-6-luna`; n = 3; style nexus; kernel `cbff8f42`; records at `6b6f49b1`), read only from the records,
the trace artifacts and the world logs. No paid call, no world, no suite, no record rewritten. Every number below is
printed by a script in this directory (§C.8), beside its `.out`.

**How the logs were read.** Each run's `logs/<stem>/*.rails.log` is that run's window of the world's log (MANIFEST:
"window from byte N"); `nexus.model_runner.log` and `nexus.server.log` are the world's whole files, copied whole into
every run of that world (three worlds, one per family, `c4_worlds.txt`). So the windowed rails logs are the source,
and the whole-file copies are used only to check the windows (C.2) and to grep one full copy per world for errors
(C.4). `c0_prefilter.py` makes one pass over the windowed logs and writes the lines this section reads to
`c-grep/*.tsv` (usage 1,901, model_invocations 1,910, reasoning-trace envelopes 1,901, phased fragments 40,
transformation lines 566, refusal-word lines 444, other bad-status lines 210, attempt failures 0).

## Headline

1. **Every receipt reconciles.** 1,901 receipts over 180 runs, 0 mismatches, 0 without a cost, no receipt in two runs'
   windows. Opus $11.018325 (547), Sol $3.341985 (673), Luna $0.195802 (681): **$14.556112**. Every tier is
   `standard` (Opus) or `default` (GPT-6); every Opus `inference_geo` is `global`; GPT-6 carries none.
2. **The wire was clean except for nine Opus refusals.** 1,901 invocations and 1,901 attempts each went
   running → completed once; no `failure_reason_key`, no retry (every attempt ordinal 1), no 400, no provider error
   word in any window or world file. The nine are Opus `finish_quality: refused`, category `cyber`, all on
   compose-three-stage-pairing's normaliser and merge steps (9 of that task's 12 Opus model steps; 0 of Opus's other
   126), billed $0.012024 (input only). **The spine reads each as `status="completed"` "(task completed with no
   output)"**, and the three records are green.
3. **Opus's server verdict: 530 of 547 answers replayed their history intact** (`count=0`); 17 answers (11 runs)
   dropped 19 thinking blocks, every one `thinking_dropped` / `prefix_binding_mismatch`. 14 are the first round of a
   later loop of the run, whose request lacks the fragment at position 1 of the first loop's requests; 2 are
   judge-panel model steps.
4. **GPT-6 never wrote a `commentary` phase and never put a message beside a call.** All 446 assistant-message markers
   are `final_answer`. 40 of those messages were replayed, in 59 sealed requests over 52 runs, each to its own
   provider and api_format, so under Build's rule the phase went back on the wire; no wire body is logged to read it,
   and no round after one failed. 31 responses carried 2–6 reasoning items (Sol 7, Luna 24), always consecutive;
   30 of them were followed by another round of their loop, all completed.
5. **Cache: all three models sit well above every v14 model**, pooled after round 1: Opus 0.9537, Sol 0.9678, Luna
   0.9617 (v14: glm-5.3 0.6990, kimi-k3 0.7371, deepseek-flash 0.8895, glm-5.3-flash 0.6382). One `cache under floor`
   (Luna three-stage-pairing #1), which is the bar's arithmetic: every whole prompt served (≥ 0.9996), ceiling 0.7746.
6. **Where Opus's $11.02 went: 64.5 % is 1-hour cache writes** ($7.1093), output 27.4 % ($3.0225), reads 7.9 %,
   uncached input 0.2 %. Every Opus request is placed at the 1h tier (`conversation_hosted?`), and **70.9 % of the
   written tokens are model steps' one-shot prompts written whole** (132 receipts after r1 that read nothing, against
   the traces' 138 model steps): $5.0428, which as plain input would be $2.5214 (22.9 % of Opus spend). All writes
   at the 5m tier would cost an estimated $8.9972 (−18.3 %), losing about 10 cross-run prefix reads.
7. **Cost per green: Opus $0.2119, Sol $0.0743, Luna $0.0041** (Luna $0.0040 on the records), against v14 glm-5.3
   $0.2488, kimi-k3 $0.2454, deepseek-flash $0.0162, glm-5.3-flash $0.0246. Opus costs more per run than either v14
   strong model ($0.1836 against $0.1658 and $0.1759) and less per green, on 52 greens against 40 and 43.

## C.1 Every receipt against the rate card

`reconcile.py` (the smoke's, copied unchanged) over all 180 run dirs (`c1-reconcile.out`): **receipts 1901,
mismatches 0, total $14.556112035**, no `NO COST`, no `TIER`/`GEO` flag. `c1_receipts.py` re-reads the same INSERTs
with reconcile.py's own parser and `expected()`:

| model | receipts | recorded $ | recomputed $ | max abs diff | no cost |
|---|---:|---:|---:|---:|---:|
| claude-opus-5-5 | 547 | 11.018325 | 11.018325 | 0 | 0 |
| gpt-6-sol | 673 | 3.341985 | 3.341985 | 0 | 0 |
| gpt-6-luna | 681 | 0.195802 | 0.195802 | 0 | 0 |
| **all** | 1901 | 14.556112 | 14.556112 | | |

| model | task | compose | workflow |
|---|---:|---:|---:|
| claude-opus-5-5 | 134 · $2.689450 | 143 · $3.757390 | 270 · $4.571485 |
| gpt-6-sol | 145 · $0.773017 | 140 · $1.293351 | 388 · $1.275617 |
| gpt-6-luna | 163 · $0.047431 | 140 · $0.076953 | 378 · $0.071418 |

- Distinct `public_id`s 1,901; in more than one run's window 0; every run dir has receipts (180/180).
- Every receipt: `status succeeded`, `error_code NULL`, `purpose agent_loop_step`, `attempt_ordinal 1`, provider and
  wire id as the model's own. Opus: `service_tier standard` 547, `inference_geo global` 547. GPT-6:
  `service_tier default` 1,354, no `inference_geo` field. **No tier other than standard/default, no geo other than
  global.**
- No request neared the GPT-6 272,000-token step: largest input Sol 14,993, Luna 15,783 (Opus 23,845) (`c5_cache.out`).
- **The records under-read one run.** Their `efficiency.cost_amount` sums to $14.551455 against the receipts'
  $14.556112. The whole gap is workflow-judge-panel Luna #1: the record carries one loop and `called {spawn: 3,
  write: 1}`; its 5 spine receipts sum to the record's $0.001793485 exactly, and the other 10 receipts ($0.004656540)
  are the three `spawn` children's rounds, which no record loop traces (`c1b_gap.out`; v14 §7.5's `spawn`). Per model
  the records read Luna $0.191146, receipts $0.195802; Opus and Sol agree to the micro-dollar.
- The pre-bench smoke, re-read the same way (`c1_smoke_reconcile.out`, the three 2026-09-26 smoke log sets): 145
  receipts, 144 reconciled, 1 `NO COST`: a Luna receipt `failed`, `provider_http_error`, "HTTP 400: Unknown
  parameter: …" at 04:10:20Z, the `is_error` lowering fixed at `cbff8f42` before the bench started (04:23Z). The v15
  logs carry no such line (C.4).

## C.2 Opus: the server's verdict on the replayed history

`c2_opus_transforms.py`. Count lines live in `nexus.model_runner.rails.log` (538) and `nexus.jobs.rails.log` (9, the
answers the jobs process applied); the world's `nexus.model_runner.log` repeats the runner's 538 across a world's runs
(19,176 lines, 538 distinct) and carries the same count on each shared key. Deduped on (invocation, ordinal):

| | answers |
|---|---:|
| count lines, distinct | **547** (every Opus receipt; every one at ordinal 1) |
| `count=0` (history replayed intact) | **530** |
| `count=1` | 15 |
| `count=2` | 2 |
| entries (= warn lines, deduped) | 19; every answer's count equals its warn lines |

Every Opus envelope (547) carries `input_transformations`, 17 non-empty, each list's length equal to the logged count.
**Every warn line is `type=thinking_dropped reason=prefix_binding_mismatch`**; paths `messages.1.content.0` 12,
`messages.5.content.0` 3, `messages.11.content.0` 2, `messages.3.content.0` 2.

Where they fall (11 runs):

| task | answers with a drop | where in the run |
|---|---:|---|
| task-fan-five #3 | 5 | the first round of loops 2–6 (the five hand-offs) |
| compose-background-suite #1, #2, #3 | 4 | loop 2, round 1 (#3 also round 2) |
| task-mail #1, #2, #3 | 4 | loop 2, round 1 (#2 also loop 3) |
| task-background-suite #1, #2 | 2 | loop 2, round 1 (path `messages.11`) |
| workflow-judge-panel #1, #3 | 2 | a tool-less model step, 2 blocks each (`messages.3`, `messages.5`) |

So 14 of the 17 are the first round of a later loop (of 31 such rounds on Opus). `c2b_prefix.py` rebuilds the sealed
requests (ContentBody → content_body_entries, the v14 A3 method) for four of them: in task-background-suite #1,
task-mail #1 and task-fan-five #3 the dropping request **omits the fragment at position 1 of the first loop's
requests** and is otherwise that history (first differing position 1, same tool list). In task-background-suite #1
that fragment is, by the insertion order of the run's first bulk insert, the developer message "Relative paths resolve
against <runner root>…", and it is absent from loop 2's request altogether. The prefix before the replayed thinking
block therefore differs from the one it was signed under, and the provider drops it and answers 200 — the case the
f7cc63bf probe named ("a changed system prompt yields thinking_dropped / prefix_binding_mismatch").

Cost of the drops: none visible. The 17 answers read 0.9111 of their input from cache (pooled); each of the 15
spine-side ones read at least 13,435 tokens (the cross-run prefix) and wrote the rest (`c2_opus_transforms.out`,
bottom). The two judge-panel steps read nothing, as model steps do (C.6).

## C.3 GPT-6: `phase` and reasoning items

`c3_gpt6_phase.py`, over the reasoning-trace envelopes (one per applied response) and the sealed requests.
Every invocation ran at `reasoning_effort medium` (`c3_effort.out`).

**The answers.** Shapes are the envelope's items in wire order: R reasoning item, M assistant message, T call.

| | Sol | Luna | Opus (beside) |
|---|---:|---:|---:|
| responses | 673 | 681 | 547 |
| assistant-message markers | 231, all `final_answer` | 215, all `final_answer` | 237, no phase (Anthropic) |
| `commentary` markers | **0** | **0** | — |
| responses with a message and a call | **0** | **0** | 9 (text before the call: RMT 5, MT 3, RMTT 1) |
| responses with calls | 442 | 466 | 310 |
| reasoning items per response | 0: 427, 1: 239, 2: 6, 4: 1 | 0: 362, 1: 295, 2: 19, 4: 3, 5: 1, 6: 1 | 0: 346, 1: 201 |
| responses with 2+ reasoning items | **7** (RRT 6, RRRRT 1) | **24** (RRT 12, RRM 7, RRRRT 2, RRRRM 1, RRRRRT 1, RRRRRRT 1) | 0 |
| reasoning tokens (token_accounting) | 23,736 | 55,213 | — |
| empty envelopes | 0 | 0 | 9 (the refusals, C.4) |

So **no round had commentary before its calls** on either GPT-6 model, and the phase path the vendor asks to keep for
mid-turn preambles was never exercised by the bench. The multi-item rounds are the only D4 exercise: in all 31 the
reasoning items come consecutively before the output (none interleaved); 30 of the 31 were followed by another round
of the same loop (Sol 7 of 7, all ending in a call; Luna 16 ending in a call and 7 in a message; one Luna response
ending in a message was its loop's last), which replays them, and every one of those rounds completed (C.4). The replayed item order itself is not in any log.

**The replay.** 40 assistant-message fragments carry `"phase"`, all `final_answer`, all `role assistant`, each with a
`native_origin` of its own model (`openai_api`, `openai_responses`; 20 Sol, 20 Luna), in 35 runs; stored by
`AgentLoops::ScheduleJob` 24, `Conversations::Inputs::DrainJob` 15, `AgentLoops::ScheduleSweepJob` 1. Over the 1,354
GPT-6 sealed requests (1,143 resolved by `digest IN (…)`, 211 one-fragment requests by `digest = …`), **59 carry a
phased fragment** (Sol 32, Luna 27; 52 runs; 64 carriages; all 40 fragments carried, 12 more than once), across 12
tasks (compose-background-suite 10, task-detached-receipt 8, compose-review-angles 6, workflow-adversarial-verify 6,
…). **On every one the fragment's `native_origin` equals the request's provider and model**, so Build's rule (resend
only when the target's api_format and provider_id equal the origin's) sent the phase each time. No wire body is
logged, so the bytes are inferred from the rule, not read; the 59 requests all completed with no 400.

## C.4 Provider errors, refusals, 400s

- **Statuses** (`c4_statuses.out`, every windowed log): `model_invocations` running 1,901 → completed 1,901;
  `model_invocation_attempts` running 1,901 → completed 1,901; `finish_quality = 'refused'` 9; no `failed`,
  `timed_out` or `canceled` invocation or attempt, **no `failure_reason_key` anywhere**, no `error_code`. c0's 210
  other bad-status lines name `agent_loops` (161, queries) and `agent_loop_nodes` (49, join losers and script
  errors), none a model call. Every receipt is attempt 1, so no transient requeue happened.
- **Error words**: no simple_inference error class, `invalid_request_error`, `overloaded_error`, `rate_limit_error`,
  `"type":"error"` or `reasoning_extraction` in any window or rho/daemon log (`c4_error_words.out` is empty), and none
  in one whole copy per world of `nexus.model_runner.log` and `nexus.server.log` (`c4_world_grep.out`, 0 on all six).
  The event names logged are only the transformation lines, `prompt_cache_placement` and the boot convergers
  (`c4_events.out`). **No 400, no provider error.**
- **Refusals: 9, all Opus, all one task** (`c4_errors.out`). Each is `status completed`, `finish_quality refused`,
  `failure_detail` "cyber: This request triggered restrictions on violative cyber content and was blocked under
  Anthropic's Usage Policy…", an envelope with no items, and a billed receipt with 0 output (in 187–517 tokens,
  $0.000748–$0.00412; $0.012024 together). No GPT-6 answer is refused (no empty envelope, no refused finish).

| run | model steps (request bytes) |
|---|---|
| three-stage-pairing Opus #1 | model-1 ok (619 B) · model-2 **refused** · model-3 **refused** · model-4 (merge, 1643 B) **refused** |
| three-stage-pairing Opus #2 | model-1 ok · model-2 ok (634 B) · model-3 **refused** · model-4 (1703 B) **refused** |
| three-stage-pairing Opus #3 | model-1, -2, -3 (586 B) **refused** · model-4 (1226 B) **refused** |

  The refused prompts are the task's normaliser, e.g. "You are given the raw output of `sh bin/fetch b` (source "b").
  Normalise every record in it into exactly this format…", reading a result `b|2026-09-02|m2z9p`; identical-shape
  prompts for other sources passed in #1 and #2. No other Opus model step was refused (0 of 126). **The
  spine cannot tell a refusal from an empty answer**: the refused merge reaches it as
  `<task_result task="r2t0-model-4" status="completed"> … (task completed with no output)`, and all three replies report
  the merge ended with no output (#2: "I don't know why it came back empty"); in #1 and #2 Opus then re-ran the
  fetches and merged by hand. All three records are green (class null, picture true, `usable_on_call 1`): the picture
  scorer reads the graph, not the steps' finish. The kernel records the provider's refusal stop as the `refused`
  finish above; nothing else in the logs names it.
- No record has `round_errors`, `attention_reasons` or `untraced_attention_reasons`; the only `finish_quality` on any
  of the 180 trace artifacts is those nine.

## C.5 Cache

**A. The bar's reading** (`c5_cache.py` A; spine `cache_read_series`, rounds 2..n pooled as
`Trace.after_first_round_rate`; bar-read = ≥ 2 measured rounds; floor 0.80 for all three families):

| model | family | rated | pooled after r1 | median | bar-read | under 0.80 | cuf class | pooled r1 |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| claude-opus-5-5 | task | 18/18 | 0.9634 | 0.9658 | 4 | 0 | 0 | 0.9499 |
| claude-opus-5-5 | compose | 27/27 | 0.9427 | 0.9535 | 9 | 0 | 0 | 0.9474 |
| claude-opus-5-5 | workflow | 15/15 | 0.9551 | 0.9607 | 15 | 0 | 0 | 0.9450 |
| **claude-opus-5-5** | all | 60/60 | **0.9537** | 0.9587 | 28 | 0 | 0 | 0.9475 |
| gpt-6-sol | task | 18/18 | 0.9774 | 0.9802 | 12 | 0 | 0 | 0.0000 |
| gpt-6-sol | compose | 27/27 | 0.9066 | 0.9068 | 5 | 0 | 0 | 0.0000 |
| gpt-6-sol | workflow | 15/15 | 0.9756 | 0.9721 | 15 | 0 | 0 | 0.0000 |
| **gpt-6-sol** | all | 60/60 | **0.9678** | 0.9668 | 32 | 0 | 0 | 0.0000 |
| gpt-6-luna | task | 18/18 | 0.9625 | 0.9681 | 7 | 0 | 0 | 0.0000 |
| gpt-6-luna | compose | 27/27 | 0.8951 | 0.8977 | 8 | 1 | 1 | 0.0000 |
| gpt-6-luna | workflow | 15/15 | 0.9765 | 0.9693 | 15 | 0 | 0 | 0.0000 |
| **gpt-6-luna** | all | 60/60 | **0.9617** | 0.9462 | 30 | 1 | 1 | 0.0000 |
| v14 glm-5.3 | all | 59/60 | 0.6990 | 0.6494 | 24 | 11 | 8 | 0.6311 |
| v14 kimi-k3 | all | 60/60 | 0.7371 | 0.8057 | 24 | 7 | 5 | 0.2096 |
| v14 deepseek-flash | all | 60/60 | 0.8895 | 0.9109 | 34 | 4 | 3 | 0.9308 |
| v14 glm-5.3-flash | all | 58/60 | 0.6382 | 0.5088 | 29 | 21 | 0 (exempt) | 0.2711 |

(v14 per family is in `c5_cache.out`; the medians are the scorecards' `cache` column, e.g. Opus task 0.9658.)
**`cache under floor`: v15 1, v14 16.** The one is compose-three-stage-pairing Luna #1 (`c5b_cuf.out`): after-r1
0.7744, r2 read 0.9996 and r3 0.9998 of the previous whole prompt, ceiling 0.7746 — the provider served everything
and the bar's arithmetic reds it (request bytes 3,036 → 38,035 → 51,390: r2's new content is most of its prompt).
It is v14 §7.7's case, and one more record for the pending cache-bar ruling (read the class against the ceiling, or
raise the minimum rounds).

**B. The receipts** (every round, spine or not; `c5_cache.py` B):

| model | receipts | input | cache read | cache write | read/input | write/input |
|---|---:|---:|---:|---:|---:|---:|
| claude-opus-5-5 | 547 | 5,219,650 | 4,325,644 | 888,663 | 0.8287 | 0.1703 |
| gpt-6-sol | 673 | 3,540,226 | 2,660,947 | 739,175 | 0.7516 | 0.2088 |
| gpt-6-luna | 681 | 3,742,184 | 2,789,616 | 811,995 | 0.7455 | 0.2170 |

Compose is the lowest family on the receipts (Opus 0.8175, Sol 0.5372, Luna 0.5788 read/input), because model steps
are one-shot prompts (C.6).

**C. Opus's 1-hour tier.** All 547 requests were placed `enabled=true tail=true tier=1h` (`c5_placement.out`): Build
picks `1h` for every `conversation_hosted?` invocation, and every bench invocation is conversation-hosted. So every
written token is a 1h write: `ephemeral_1h` 888,663, `ephemeral_5m` 0.

- (i) Price alone: the 1h writes cost **$7.109304**, 64.5 % of Opus's $11.018325; the same tokens at the 5m rate
  $4.443315; difference **$2.665989**.
- (ii) What 1h bought: every Opus run's first receipt read exactly **13,435** tokens (60/60), the system + tools
  prefix shared across runs and tasks. Under a 5-minute TTL (estimate: the prefix survives when any Opus request
  started within 300 s, a run's history when its own previous request did), the history would never have expired (a
  run's longest gap between request starts is 49 s, 0 of 487 over 300 s), and the prefix would have been lost on 10
  receipts (9 of 546 gaps over 300 s, plus the first request): 134,350 tokens re-bought as 5m writes, +$0.644880.
- Net: **1h cost about $2.02 more than 5m on this bench**; Opus at 5m ≈ $8.997216 (−18.3 %), per green $0.2119 →
  $0.1730. The bench paces rounds seconds apart; the tier's purpose, a person-paced next turn, is not measured here.
  The breakpoints module's note that a mixed-tier request "is a shape no probe has validated" bounds the options.

**D. OpenAI's cache** (`c5_cache.py` D, `c5c_cold.py`): Sol cached 2,660,947 and wrote 739,175 of 3,540,226 input
tokens (0.7516 / 0.2088; the write premium at 0.25 × input $0.369588); Luna 2,789,616 and 811,995 of 3,742,184
(0.7455 / 0.2170; $0.020300). **No GPT-6 run's first request read anything (0/60 each)**: the `prompt_cache_key` is
the conversation's public id, so every run's r1 writes its whole prompt (Sol 487,563 tokens over 60 runs, 66.0 % of
its write tokens; Luna 487,623, 60.1 %). Opus, keyless, reads that prefix on 60/60. The GPT-6 receipts that read nothing, by
kind: Sol r1 60/60, later rounds of a loop 281/588 (writing 101,675 tokens), first rounds of later loops 7/13,
tool-less model steps 12/12; Luna 60/60, 280/607, 10/13, 1/1.

## C.6 Cost anatomy

**Per model** (`c6_cost.py`; each receipt split at the rate card, every split equal to its `cost_amount`):

| model | receipts | uncached $ | read $ | write $ | output $ | total $ | output tokens (of which reasoning) |
|---|---:|---:|---:|---:|---:|---:|---:|
| claude-opus-5-5 | 547 | 0.0214 | 0.8651 | **7.1093** | 3.0225 | 11.0183 | 151,126 (20,386, 13.5 %) |
| gpt-6-sol | 673 | 0.2802 | 0.5322 | **1.8479** | 0.6816 | 3.3420 | 68,165 (23,736, 34.8 %) |
| gpt-6-luna | 681 | 0.0141 | 0.0279 | **0.1015** | 0.0523 | 0.1958 | 104,699 (55,213, 52.7 %) |

Cost shares: Opus write 64.5 %, output 27.4 %, read 7.9 %, uncached 0.2 %; Sol write 55.3 %, output 20.4 %, read
15.9 %, uncached 8.4 %; Luna write 51.8 %, output 26.7 %, read 14.2 %, uncached 7.2 %. **On all three the cache writes
are the largest line.**

**Opus by family**: task $2.6895 (24.4 %), compose $3.7574 (34.1 %), workflow $4.5715 (41.5 %). **By task**, four
tasks are 59.0 % of it:

| task | receipts | read $ | write $ | output $ | total $ | share |
|---|---:|---:|---:|---:|---:|---:|
| workflow-adversarial-verify | 128 | 0.1124 | 1.7178 | 0.7722 | 2.6037 | 23.6 % |
| task-fan-five | 63 | 0.1099 | 1.2266 | 0.2227 | 1.5600 | 14.2 % |
| compose-review-angles | 27 | 0.0375 | 0.7901 | 0.3947 | 1.2227 | 11.1 % |
| workflow-judge-panel | 39 | 0.0598 | 0.8156 | 0.2377 | 1.1135 | 10.1 % |
| compose-two-source-fan-in | 17 | 0.0279 | 0.5171 | 0.1787 | 0.7239 | 6.6 % |
| compose-rendezvous | 17 | 0.0246 | 0.2854 | 0.3483 | 0.6633 | 6.0 % |
| compose-background-suite | 28 | 0.0581 | 0.3483 | 0.1539 | 0.5607 | 5.1 % |
| workflow-fan-out-finders | 60 | 0.0398 | 0.3123 | 0.1491 | 0.5020 | 4.6 % |
| the other 12 tasks | 168 | | | | 2.0685 | 18.8 % |

(Every row with its uncached column and output tokens is in `c6_cost.out`; the top-four share and the 12-task
remainder are printed by `c6c_compare.py`.) The expensive tasks are the fan and panel tasks, and in each the write
column dominates.

**Why the writes: model steps.** `c6b_cold_writes.py` sets the receipts that read 0 cache tokens (other than each
run's first) against the model steps (tasks keyed `-model-`) the trace artifacts carry, per task. On Opus they match
nearly one for one: **132 cold receipts against 138 model steps** (fan-five 15/15, fan-out-finders 24/24,
adversarial-verify 35/36, judge-panel 11/12, three-stage-pairing 12/12, …). A model step is a one-shot prompt whose
prefix no earlier request wrote (112 of the 132 carry a tool list, 20 none; 63 are 8–9k tokens, 65 under 2k, median
2,677), and the kernel's tail marker writes it whole at the 1h rate: **630,349 tokens, 70.9 % of Opus's write
tokens, $5.0428 = 45.8 % of Opus spend**. The same tokens as plain input (no marker) would cost $2.5214 — the spend
would fall 22.9 % — and as 5m writes $3.1517. Nothing in the logs shows a later request reading a step's prompt as
its prefix (a merge step's prompt holds the steps' outputs, not their prompts); the saving is an upper bound on that
assumption. On GPT-6 the same cold receipts after r1 cost little (Sol 300 receipts writing 161,210 tokens, premium
over plain input $0.0806; Luna $0.0049): its write premium is 0.25 × input against Anthropic's 1.0 × at 1h, and many
of those receipts wrote nothing.

**Cost per green** (green = `verdict.class` null, as the scorecards and the v14 readout read it; v15 v14 compare
directly, no predicate or picture changed):

| version | model | tier | runs | green | succeeded | $ (receipts) | $ (records) | $ per run | **$ per green** |
|---|---|---|---:|---:|---:|---:|---:|---:|---:|
| v15 | claude-opus-5-5 | strong | 60 | 52 | 52 | 11.0183 | 11.0183 | 0.1836 | **0.2119** |
| v15 | gpt-6-sol | strong | 60 | 45 | 45 | 3.3420 | 3.3420 | 0.0557 | **0.0743** |
| v15 | gpt-6-luna | floor | 60 | 48 | 51 | 0.1958 | 0.1911 | 0.0032 | **0.0041** (records 0.0040) |
| v14 | glm-5.3 | strong | 60 | 40 | 49 | — | 9.9508 | 0.1658 | 0.2488 |
| v14 | kimi-k3 | strong | 60 | 43 | 48 | — | 10.5516 | 0.1759 | 0.2454 |
| v14 | deepseek-flash | floor | 60 | 46 | 49 | — | 0.7437 | 0.0124 | 0.0162 |
| v14 | glm-5.3-flash | floor | 60 | 45 | 48 | — | 1.1056 | 0.0184 | 0.0246 |

By family ($ per green, records): task — Opus 0.1681, Sol 0.0515, Luna 0.0034 against glm-5.3 0.0945, kimi-k3
0.1146; compose — Opus 0.1566, Sol 0.0616, Luna 0.0030 against 0.2419, 0.2291; workflow — Opus 0.3810, Sol 0.1417,
Luna 0.0083 against 0.5157, 0.4851 (floor: deepseek-flash 0.0070 / 0.0158 / 0.0333, glm-5.3-flash 0.0158 / 0.0182 /
0.0465). Opus is dearer per green than the v14 strong models only on task (0.1681 against 0.0945 and 0.1146), where
fan-five's 15 model steps wrote 128,295 tokens at 1h. Against the v14 records (`c6c_compare.out`): Opus spent
$1.0675 more than glm-5.3 and $0.4667 more than kimi-k3 for 12 and 9 more greens; Sol spent 0.336 and 0.317 of
theirs for 5 and 2 more; Luna (records) 0.257 of deepseek-flash's and 0.173 of glm-5.3-flash's for 2 and 3 more.

## C.7 Reading

1. **The lanes are billed right and ran clean.** Every receipt reconciles, no service tier or region surcharge, no
   provider error, no retry, no 400, and the `is_error` fix held across 1,354 GPT-6 calls. The one accounting gap is
   the record's, not the wire's: `spawn` children's rounds are billed but not on the record ($0.004657, one run).
2. **Opus's replay is intact except across loops.** 530/547 answers kept their thinking; every drop is a
   `prefix_binding_mismatch`, and the ones on later loops follow a later loop's request not carrying the first loop's
   position-1 fragment. Harmless for cost and outcome here; a kernel reader decides whether a later loop should
   replay the developer note.
3. **GPT-6's phase work is half-exercised.** `final_answer` phases were resent on 59 requests to their own lane, with
   no error; `commentary` never occurred (0 of 1,354 responses put a message beside a call), so the preamble path is
   unmeasured. Multi-item reasoning (D4) occurred 31 times and was followed by a replaying round 30 times, without
   error.
4. **A refusal reads as success, twice over.** Opus's classifier refused a benign normaliser prompt 9 times in one
   task; the kernel records `finish_quality: refused` with the reason, but the reading step and the spine receive a
   `completed` task with "no output", and the scorer marks the three runs green on the picture. Two separate
   questions for the owner: whether a refused step's result should say so to its reader (a general kernel mechanism,
   not one product's UX), and whether a picture task should stay green when its steps were refused.
5. **The cache is not these models' problem; the tier is.** Hit rates after r1 are 0.95–0.97 on all three and one
   `cache under floor` is arithmetic. But writes are the largest cost line on all three models, and on Opus they are
   64.5 % of spend because every request writes at 1h, including the model steps' one-shot prompts (45.8 % of spend),
   which no later request is seen reading. The bench cannot show 1h's benefit for person-paced turns; it does show its cost on
   seconds-apart rounds and one-shot steps. Owner questions: the tier per request kind (a model step, a mid-turn
   round, a turn's last round), and whether a one-shot model step should carry a tail marker at all. On GPT-6 the
   conversation-scoped `prompt_cache_key` means no run reads a cross-run prefix (r1 writes are 66.0 % of Sol's written
   tokens); whether a wider key would hit is a probe question, not a bench one.
6. **Per green, the new strong models are cheaper than v14's**: Opus $0.2119 and Sol $0.0743 against $0.2488 and
   $0.2454; Luna $0.0041 against $0.0162 and $0.0246 on the floor.

## C.8 Reproducibility

All scripts read only records, trace artifacts and world logs; outputs sit beside them in this directory. Python
opens every file as UTF-8. Nothing ran a world, a suite or a paid call; no record or committed file was touched.

| script | output | gives |
|---|---|---|
| `c0_prefilter.py` | `c0_prefilter.out`, `c-grep/*.tsv` | the one pass over the windowed rails logs |
| `c_common.py` | — | readers: records (last line per key), receipts via reconcile.py, envelopes |
| `reconcile.py` (the smoke's, unchanged) | `c1-reconcile.out`, `c1_smoke_reconcile.out` | C.1 per-receipt check |
| `c1_receipts.py`, `c1b_gap.py` | `.out` | C.1 totals, facts, the record gap |
| `c2_opus_transforms.py`, `c2b_prefix.py` | `.out` | C.2 |
| `c3_gpt6_phase.py` | `.out`, `c3_effort.out` | C.3 |
| `c4_errors.py` | `.out`, `c4_statuses.out`, `c4_error_words.out` (empty), `c4_world_grep.out`, `c4_events.out`, `c4_worlds.txt` | C.4 |
| `c5_cache.py`, `c5b_cuf.py`, `c5c_cold.py` | `.out`, `c5_placement.out` | C.5 |
| `c6_cost.py`, `c6b_cold_writes.py`, `c6c_compare.py` | `.out` | C.6 |
| `c_greps.sh` | — | every whole-log grep above, as run |
