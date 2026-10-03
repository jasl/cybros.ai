# shape-linear

**Measures.** The plainest loop shape on a real model: a coding turn
(write a file, run it, read what it printed) as a CHAIN — `rN → rNtM → rN+1`,
every tool fanned by one round and read by the next, no join, nobody asked.
It is the corpus's seed task: the one that proves the pipe end to end
(`rho do` → the kernel's trace → the predicate → the verification → the
record) before any family is measured on it.

**Converts.** The gallery's `linear` shape (`e2e/support/gallery/shapes.rb:452`,
predicate `Gallery.linear?` `:73-95`) with the task text of
`e2e/support/coding_task.rb:8-16` (`E2E::CODING_TASK`, read byte for byte by
`live_agent_loop` and `live_rho_runner`; the corpus test pins this
instruction to it) and the gallery's `plain` driver (`live_gallery_test.rb:152-159`).
The verification is the program's own output, as `live_agent_loop` judges it.

**Dimensions.** reach = any tool row (a text-only answer reaches nothing);
success = `Gallery.linear?` over the trace — structure only, the round count
and the fan width are facts on the record; task pass = `ruby fizzbuzz.rb`
prints the fifteen lines; conduct = `ran_the_file` (a bash row runs
`ruby fizzbuzz.rb`) and `wrote_before_running` (the write precedes the run in
row order).

## Reading a red

- **lane bug** — the record carries `error` (the driver raised: `rho do`
  refused, the route read failed) or `stopped: deadline` with
  `facts.rounds_settled: 0` (nothing moved: the daemon, the provider key,
  the world). Fix the harness; never re-tune the task.
- **model conduct** — `reason` in the trace's words: "no tool call" (reach),
  "a node outside the spine: r1t0-model-1" (the model delegated a one-file
  task — `success` red), "a join_task on a linear loop" (it composed),
  `conduct.wrote_before_running: false` (it ran before it wrote),
  `verdict.task_pass: false` with the verification's output (wrong lines).
  A record, never a prompt patch on the floor.
- **kernel finding** — a round `failed` with a kernel error key
  (`facts.round_errors`), an `attention_required` this driver never scripts
  (`facts.attention_reasons`), a `fallback` compaction on a five-round loop,
  or `task_pass: true` beside a red predicate (the chain completed but the
  graph route drew something else). Stop and write it into the ledger with
  the artifact path.
