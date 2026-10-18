# exit-long

**Measures.** A long coding task measured by its verification result, in one loop: a
port of a ~300-line JS module against a shipped, frozen Ruby suite; a
vector corpus read whole that crosses the byte wall twice; a background
dev server the model starts and reads (the token arrives AFTER the ready
line so `read_process` is necessary); an approval park under `ask` with
a scripted person (`ExitLongPump`: approve everything but a shell read of
the corpus — "use the read tool"); the `--until` ladder on `sh check.sh`.
Task pass is the acceptance: the suite's exit, the specification
untouched, the index real, the token in the port.

**Converts.** `e2e/test/live_exit_long_test.rb:113-225` (the acceptance
`:152-160`, the server `:162-176`, the ladder `:178-187`, the parks
`:189-202`, the rounds `:204-210`; the fixture `:265-372` is now this
task's `environment/` + `environment.rb`, read by the lane too — one
fixture source; the pump `:396-439` is the `pump` driver with the
`exit_long` policy; `vector_reads` `:487-500` is the `whole_vector_reads`
fact). The lane's own text passes the port on the command line; this
instruction has the server read `server/PORT`, so the text is static.

**Dimensions.** reach = a whole vector read, `start_process` and
`read_process` completed, the port written; success = the ladder,
the parks' origin, no check parked, every round completed, no attention
outside the park, the loop completed; task pass = the acceptance;
`compactions` (mode/trigger — the compaction family's column on this
run), `parks`, `denied`, `checks`, `whole_vector_reads` are facts. The
two-compaction property is a property of the corpus only when the files
are read whole — recorded, never asserted here (the lane keeps its own
assertion).

## Reading a red

- **lane bug** — `error` from the pump ("the loop holds for something the
  pump cannot answer"), or `stopped: deadline` (5000 s) with
  `rounds_settled: 0`.
- **model conduct** — `stopped: cost_stop` past this task's $20
  (`cost_stop_usd_by_task`; the historical strong-tier passes cost $10–20
  with pruning). The pump handles approval parks under the spend watch,
  so the cost stop can fire during a park; "no whole-file read of a vector" with
  `whole_vector_reads: 0` (windowed reads: the index then fails on the
  marker line); "lib/frame_codec.rb was never written"; `task_pass:
  false` with "index missing 3 wrong 12" (invented lines — see the
  compaction family's pointer rule) or "token differs" (it guessed);
  `denied > 3` (it kept trying shell reads of the corpus).
- **kernel finding** — "a round did not complete: {content_items_too_many
  …}" (a regression of the historical long-session failure; the first
  thing to look for); "an author's check was not pre-approved"; "the
  feed called for a person outside the approval park"; a compaction
  `fallback` in the facts.
