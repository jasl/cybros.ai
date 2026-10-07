# compaction-wall-long

**Measures.** A session long enough to overflow its context on a real
model — the wall trigger, the arm's choice (prune when the prunable
bytes cover the overshoot, else summarize), and the WORK surviving it:
every file indexed, each first line one only reading could produce. The
family's columns ride as facts (`reread_rate` after the first arm,
`induced_rounds` = the mainline rounds from the compacted round on — the
stated minimum is two per file still unindexed, read off the index in
the artifact —, `summary_bytes`, mode × trigger). Strong tier only, on
glm-5.3 alone.

**Converts.** `e2e/test/live_long_session_test.rb:56-133` (the task
`:78-87`, the ladder `:88-89`, the vocabularies `:107-112`, the index
`:116-132`, the corpus `:160-168`) with the `until` driver; the delegate
half (`:142-156`) is `compaction-delegate-manual`'s and the delegate
configuration of this task is a RUN-half question (the same task under
`daemon.compaction: delegate` is one front-matter line).

**Dimensions.** reach = a fact-triggered `context_compacted`; success =
the vocabularies, a repair naming its round, no fallback, every round
completed, the loop completed; conduct = `pointers_never_values` (each
file's second line `body-<hex> of doc-NNN.txt` appears in no summary);
task pass = the index complete and exact; `columns`, `checks` are facts.

## Reading a red

- **lane bug** — `error`, or `stopped: deadline` (3600 s) or
  `stopped: cost_stop` with `rounds_settled: 0` — nothing was read
  (the runbook's §6.1, one sentence for both stops).
- **model conduct** — either stop WITH rounds settled: it did not finish
  (a `cost_stop` past this task's $12 — `cost_stop_usd_by_task` — has two
  readings, and the record says which: the model RE-READ the corpus
  (`facts.columns.reread_rate` says how much), OR it read once and the
  ROUNDS did it — the round count against 2 × the corpus's files beside
  `request_bytes` against the 1 MiB wall, each round carrying the whole
  window (glm-5.3's run step cell: `reread_rate 0.0`, 106 rounds, $12);
  the rounds the stop canceled carry `creator_requested` or
  `loop_canceled`, the harness's words); "the context never overflowed on a fact" (it
  windowed the reads: 70-byte results, never near the wall);
  `task_pass: false` with "missing 12" (it stopped early past six
  attempts) or "wrong 3" with a first line that is a paraphrase (read
  the wrong lines: an INVENTED line after a compaction is the summary's
  defect and a kernel finding, not conduct).
- **kernel finding** — "a fallback fired"; "a round did not complete:
  {content_items_too_many …}";
  `conduct.pointers_never_values: false`; invented first lines after the
  arm.
