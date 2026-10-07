# compaction-delegate-manual

**Measures.** rho's own summarizer (`summarize_history`, a InferenceRequest under rho's prompt) on a real model, forced through the
manual door on a round queued while its predecessor's `sleep 20` runs
(prune answers every byte wall on a read-heavy loop, so a SUMMARY is only
observable this way on a short loop). The family's columns ride as facts:
`reread_rate`, `induced_rounds` (beyond the two rounds the task states
after the arm), `summary_bytes`, mode × trigger; `pointers_never_values`
is the conduct fact — the fixture's body-only token (`brief-<hex>`, the
file's last line) must not appear in k1's summary; `work_survived` is the
verification (`done.txt`).

**Converts.** The gallery's `compaction_delegate` shape
(`e2e/support/gallery/shapes.rb:487`, predicate `Gallery.compaction?`
`:189-217`, the driver `compact_queued_round` `live_gallery_test.rb:185-190,257-288`,
k1's summary read `:358-370`) with one read step added so the summary has
a pointer to carry.

**Dimensions.** reach = a manual `context_compacted`; success =
`Gallery.compaction?(mode: "delegate")`; conduct = `pointers_never_values`;
task pass = `done.txt == done`; `columns` is a fact.

## Reading a red

- **lane bug** — `error` ("the door never armed within 600 s": the model
  combined the sleeps and no round was queued — read `rounds_settled`;
  with rounds moving it is conduct), or the deadline before a round settled.
- **model conduct** — the door refused every round `nothing_to_compact`
  because the model never read the file first (no history behind the
  queued round); a re-read of the brief after the arm is not a red — it
  is `columns.reread_rate`, the number the family reports.
- **kernel finding** — "no edge k1 → r3: the round does not wait on its
  summary"; "the repaired round r3 did not complete"; a `fallback`
  trigger; `conduct.pointers_never_values: false` — the summary carried
  the file's value (the summary's text is in the artifact).
- **kernel finding (the delegate's)** — "k1 is not rho's summarize_history"
  (the kernel answered a wall the delegate owned); a `fallback` trigger
  with rho alive (the delegate expired at its park: rho's inbox, not the
  kernel).
