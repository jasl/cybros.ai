# compaction-wall-kernel

**Measures.** B51 — the KERNEL-mode summary arm on a wall a prune cannot
satisfy: the last unobserved compaction path (L-49's surviving half),
made runnable as a task. The arm chooses once per wall
(`nexus/app/services/conversations/compaction/arm.rb:163-166`): prune
when `history.prunable_bytes >= overshoot.bytes`, else append a `kN`
summarizer under the round. `prunable_bytes` (`serialize.rb:49-54`)
sums tool RESULT bytes of the entries before the keep-recent tail, and
the tail (`tail_index`, `serialize.rb:79-93`) is `min(Σ × 0.25, 80 KiB)`
of the RENDERED entries of `loop_history` — a 46 KiB read renders as a
pointer line, a write's content is cut to its arguments head — so the
tail is a count of ROUNDS (≈ 16 at wall 1 in run 1, r42–r57 ≈ 380 KiB
of bodies), never "the last 80 KiB of bodies"; tool INPUTS are never
prunable. So a wall arrives with little to prune only when the composed
request is mostly the model's own bytes — here, `write` calls carrying
each file back — and when the reads outside the tail are few.

**The arithmetic, against the rendered-tail rule** (18 files of ≈ 46 KiB
low-entropy rows, each read whole — a ≈ 46 KiB result — then written
back with line numbers — a ≈ 49 KiB input; ≈ 95 KiB of composed bytes
per file plus the INDEX rewrite; the wall `MAX_COMPOSED_BYTES` = 1 MiB =
1 024 KiB, a KERNEL constant; the numbers below are run 1's, n = 1, on
glm-5.3 at 5–6 rounds a file: 63 rounds, 590 804 input tokens at the
wall, $8.17, 4 404 s to file 10 — the cost and the time, not the walls,
are what the re-cut moves):

- **Wall 1 at file ≈ 10** (run 1: r58 = file 10 + 2 INDEX rewrites, as
  the first cut's ≈ 11 said). The tail spans ≈ 16 rounds ≈ 3–4 files'
  reads, so prunable = the reads BEFORE those ≈ 5–6 × 46 ≈ 230–280 KiB
  ≥ the overshoot (a few KiB) → PRUNE (run 1: 5 reads, ≈ 233 KiB,
  cleared; the writes stay; the mark on r58, the round being composed;
  r58 re-sent from rows, the licensed cache bust, $0.55 for that round).
  The slack after the prune ≈ 230 KiB ≈ 2.4 files.
- **Wall 2 at file ≈ 13**: prunable = the reads since wall 1 that have
  left the tail ≈ 3 × 46 ≈ 135 KiB ≥ a few KiB → PRUNE; slack ≈ 135 KiB
  ≈ 1.4 files.
- **Wall 3 at file ≈ 14–15**: prunable ≈ 1 read ≈ 46 KiB against an
  overshoot ≈ 20–50 KiB → prune, MARGINAL (the first wall the
  arithmetic cannot call from here); slack ≈ 0–25 KiB.
- **Wall 4 at file ≈ 15–16**: 1 read ≈ 46 KiB < an overshoot of ≈ 50–90
  KiB → SUMMARIZE — B51's observation, at wall 3 or 4, file ≈ 15–16,
  ≈ r 84–90, on ANY envelope-legal corpus at read:write ≈ 1. With 24
  files the run then copied 8 more files past the observation (≈ 45
  rounds, ≈ $4, ≈ 40 min for nothing); 18 ends ≈ 2 files after the
  summary wall, and the work-survived verification still reads copies
  made after it.

**The sizing, and why the levers are these** (readout F-1). The wall is
fixed at 1 MiB: the bytes to each wall are invariant, rounds to a wall
∝ files, cost ∝ rounds × the history's tokens. SMALLER files therefore
RAISE the cost (22.5 KiB → ≈ 20 files and ≈ 110 rounds to wall 1,
≈ $16), and LARGER files are impossible — rho's whole read caps at
50 KiB / 2 000 lines (`rho-runner/lib/rho/runner/truncation.rb:14-15`);
46 KiB plus the tail line is at the cap. The levers that move the
number: (a) TOKEN DENSITY — run 1's random alphanumerics tokenized at
≈ 0.56 tok/B; six words from a fixed 256-word list per row (still
≈ 64 B a row, the `tail-<hex>` line untouched) at ≈ 0.25–0.30 tok/B put
the history at the wall at ≈ 270–315k tokens instead of 590k, so the
cache-read integral AND the write outputs (≈ 27k → ≈ 13k tokens a
file; the run is output-bound, ≈ 320k output tokens of run 1's 4 404 s)
both halve; (b) the FILE COUNT, 18 (above). Projection for 18 × 46 KiB
low-entropy rows on glm-5.3 at observed conduct: ≈ 100 rounds; wall 3
at ≈ $5.5–6 / ≈ 3 400–3 600 s; the SUMMARY wall at ≈ $6–7.5 /
≈ 3 700–4 100 s; the run's end ≈ $7–8 / ≈ 4 200 s (± 20 %). Under
`cost_stop_usd: 8.0` with thin margin (the bench's `cost_stop_usd_by_task`
lifts this task to 12.0 since 2026-09-11, so the check ladder completes
inside the run), and NOT under 3 600 s — so this
task's own `deadline_seconds` (its front-matter; the bench's default is
the lane's patience, a task overrides) is 5 400: at 3 600 the
observation is unreachable on glm-5.3 by this task. The numbers are
the reader's to check against the trace's `columns.compactions` and
`summary_keys` and the world's log; every run corrects them.

**Observed (run 2, 2026-09-11, glm-5.3, the re-cut corpus, n = 1):** four
walls in 3 704 s — prune at r46, r61 and r69, then the KERNEL SUMMARY at
r71 (`k1`, 5 144 B; summary_keys [k1]) with the copy at part-14 — the
projection's shape (prune, prune, prune, summarize at wall 4) a file
earlier than its numbers; the summary wall arrived at ≈ 2 600 s and
$5–6; the run then finished every copy (18/18 exact, INDEX complete,
`pointers_never_values` true, the summary naming only `read`, `write`,
`edit`, `ls`, `memory_edit`) and was cost-stopped at $8.007 in the
check ladder (102 mainline rounds, 111 calls, 16.9 M cache-priced input
tokens, reread_rate 0.167 over the 12 reads after wall 1, induced_rounds
56 = the mainline from r46 on). At 3 600 s it would have died with the
observation in hand; at $8 the margin was $0.007 — the deadline is right,
the cost stop is the bench's to raise if the check ladder must finish.

**Converts.** The gallery's `compaction_kernel` shape (`shapes.rb:480`,
the manual door) for the summary's structure; `live_long_session`'s
ladder and index for the work surviving; a NEW corpus (this task's
`environment.rb`).

**Dimensions.** reach = a fact-triggered `context_compacted`; success =
a kernel summary on a fact trigger (a completed `kN` model_task) with no
fallback, every round completed, the loop completed; conduct =
`pointers_never_values` (each file's last line `tail-<hex> of part-NN.txt`
in no summary); task pass = every `out/` copy exact and INDEX.md complete;
`columns`, `checks` are facts.

## Reading a red

- **lane bug** — `error`; or `stopped: cost_stop` or `stopped: deadline`
  with `rounds_settled: 0` — nothing was read: the daemon, the key, the
  world (the runbook's §6.1, one sentence for both stops).
- **model conduct** — `stopped: cost_stop` or `stopped: deadline` WITH
  rounds settled: it did not finish (the runbook's §6.2; a cost stop past
  this task's $12 (`cost_stop_usd_by_task`) with the copy under way says the projection above was
  wrong for this model's conduct — `efficiency.input_tokens` against the
  ≈ 0.25–0.30 tok/B the corpus assumes is the first thing to read);
  "the context never overflowed on a fact" (it copied with bash `nl` —
  the conduct the instruction forbids and the reach then misses;
  `called` says `bash`); `task_pass: false` with "12/18 copies exact"
  (it stopped, or its copies drifted after the arm).
- **kernel finding / sizing finding** — "no kernel summary on a fact
  trigger: every wall pruned ({prune/wall: 4})": either the arm pruned
  a wall the arithmetic says it could not (read `columns.compactions`
  against the composed sizes in the world's log — a kernel finding), or
  the corpus is undersized (`E2E_WALL_KERNEL_FILES=24` re-cuts it — a
  lane finding, recorded before any number is read); "a round did not
  complete" with `already_compacted` on a wall the prune could not clear
  (the arm armed once and the round still did not fit: the kernel's
  once-per-wall rule meeting a prune that was not enough — B51's real
  question); `conduct.pointers_never_values: false`.
