# shape-fan-join

**Measures.** The fan-and-merge shape on a real model, told the verb:
one compose call, five model members in one parallel, one merge step
reading all five, the merge completed. Structure only — the gallery's
rule (`shapes.rb:13-16`): fan width and round count are printed.

**Converts.** The gallery's `fan_join` shape (`e2e/support/gallery/shapes.rb:459`,
predicate `Gallery.fan_join?` `:101-115`, the fixture `fan_files` `:360`)
with the gallery's `plain` driver and its 900 s deadline.

**Dimensions.** reach = a `compose` row; success = `Gallery.fan_join?`;
conduct = `no_task_tool`, `reply_names_all_five`; `orphans_named` (how
many of the five `orphan_<f>` methods the merged list names) is a fact.

## Reading a red

- **lane bug** — `error`, or the deadline before a round settled.
- **model conduct** — "no compose call: the model fanned without compose
  (5 task calls)"; "r1t0 composed 6 tasks and no step reads two model
  members" (a chain, not a fan); `conduct.no_task_tool: false`.
- **kernel finding** — "the merge step r1t0-model-6 did not complete:
  failed"; a round `failed` with a kernel error key; a `fallback`
  compaction on a short loop.
