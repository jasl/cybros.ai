# shape-halt-retry

**Measures.** The halt-and-repair shape, and the ONE task of the corpus
whose loop `rho do` cannot open: a loop shaped to HALT is authored over
the member plane (`author_halting_loop!`, live_repair's shape), then
repaired from the terminal — `rho abandon gate-1`, `rho retry`, `rho
answer gate-2 --token`. It measures the kernel's halt/retry path and
rho's repair verbs; the model's part is one round that says DONE.

**Converts.** The gallery's `halt_retry` shape
(`e2e/support/gallery/shapes.rb:472`, predicate `Gallery.halt_retry?`
`:164-181`) with the gallery's `halting_loop` driver (`live_gallery_test.rb:172-183`).
The exception to "rho do is the door" is recorded here, as decision 6 says.

**Dimensions.** reach = the authored gates on the graph; success =
`Gallery.halt_retry?`. No instruction, no verification.

## Reading a red

- **lane bug** — `error`: authoring refused (a 4xx on the POST), the
  retry verb needing a key it was not given, the deadline before the halt.
- **model conduct** — "work did not run once the gates were resolved:
  failed" when the round's own reply failed (rare: the prompt is one word).
- **kernel finding** — "gate-1 carries no error: it was not abandoned
  after timing out"; "work does not wait on both gates"; a `halt_failure`
  that never surfaced (the driver's await_halt hit the deadline: read the
  loop row in the artifact).
