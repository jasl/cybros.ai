# shape-ask-human

**Measures.** The ask shape: the model's `ask` becomes an `await_task`
under the call, the person answers (the driver, with the seed's secret),
the round that reads the answer completes, the feed carried
`attention_required`. Structure only; `ask-codeword` is the same turn
judged on the disk.

**Converts.** The gallery's `ask_human` shape
(`e2e/support/gallery/shapes.rb:466`, predicate `Gallery.ask_human?`
`:145-158`) with the gallery's `answer_ask` driver (`live_gallery_test.rb:158-168`).

**Dimensions.** reach = an `ask` row; success = `Gallery.ask_human?`; the
asked prompt and key are facts (`asked_key`, `asked_prompt`).

## Reading a red

- **lane bug** — `error` ("the model never asked" is the driver's flunk
  after 300 s — read it with the reach column: a model that wrote the file
  without asking is conduct, a daemon that never surfaced the ask is a bug).
- **model conduct** — "no ask: the model called {write: 1}"; "no
  completed round reads the answer of r1t0-ask-1".
- **kernel finding** — "the ask r1t0-ask-1 was not answered: running"
  after `rho answer` succeeded (the executor-plane answer did not land);
  "the feed never called for a person" with the ask answered (the
  attention item is missing).
