# shape-repeat-brake

**Measures.** The kernel's repeat brake on a real model told to repeat:
after the kernel's window of rounds that brought nothing new (the tenth
identical `cat status.txt`, `RepeatBrake::NOVELTY_WINDOW`) the round is
refused `round_expansion_refused / repeat_call_loop` and the loop holds
`halt_failure`. The driver reads the trace held, then stops
the conversation so the next run starts clean; a model that varies its
call never trips it and never ends — the deadline is that finding.

**Converts.** The gallery's `repeat_brake` shape
(`e2e/support/gallery/shapes.rb:509`, predicate `Gallery.repeat_brake?`
`:311-338`) with the gallery's `brake` driver and `after_brake`
(`live_gallery_test.rb:228-244`).

**Dimensions.** reach = a bash row; success = `Gallery.repeat_brake?`;
`identical_rounds` (how many spine rounds fanned exactly `cat status.txt`)
is a fact. The brake's error key is the model's CONDUCT on the record
(`Scorecard::CONDUCT_ERROR_KEYS`), never a kernel finding.

## Reading a red

- **lane bug** — `error` other than the deadline; `stopped: deadline`
  with `rounds_settled: 0`.
- **model conduct** — "no round was refused repeat_call_loop: the model
  varied its call (bash:{"command":"cat status.txt; true"}×2 …)"; the
  deadline with rounds still moving (it obeyed "do not give up" by
  varying — `identical_rounds` says how close it came).
- **kernel finding** — ten identical fans on the record and no refusal
  (the brake did not fire: `identical_rounds >= 10`, `round_errors: {}`;
  a braked run shows `identical_rounds: 9`); "the loop never held for a
  person on halt_failure" after the refusal.
