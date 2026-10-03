# workflow-scout-then-fan

**Measures.** The scout, then the fan: the work-list is not in the
text, so the right door lists first and hands out one review per LISTED
file — five fresh agents at once, merged into one list. The fixture
hides five files that define a class with a `call` method among eleven
under lib/, whose names share no stem with the finders' fixture and
cannot be guessed from the text; two of the six others hold a
`def call` inside a module, the near-miss a grep for the method lists.
The door the model takes — a listing round then a `task` fan or a
compose over the list, one delegating `task` that discovers and
reviews, or a compose that lists with `g.tool` and fans in a stage — is
recorded, never a pass condition; a fan over names the model never
listed is the red.

**Converts.** The door design's D6 (`docs/plans/2026-09-27-door-choice-design.md:272`,
the text and the fixture's shape; `:281`, the rule: right =
`fan_over_guessed_names` false, wrong = "a `task` or compose fan over
names not in the listing"), run in vivo as a workflow cell
(`:327`); the v17 in-vivo design's item D
(`docs/plans/2026-10-01-v17-in-vivo-design.md` §2 D).

**Dimensions.** reach = a delegation (any `task` or `compose` row);
success = no name guessed AND `per_file <= 1` over the five AND every
loop on the feed completed; conduct = `did_not_review_itself` (the
spine's own `read` of lib/ in a round after the dispatch round —
adversarial-verify's rule; with nothing handed out, every such read);
task pass = review.md names exactly the five and none of the six.
`fan_over_guessed_names`, `names_guessed`, `names_not_on_disk` (a
guessed name the fixture does not hold — beside, never the rule),
`guessed_after_a_delegate`, `per_file`, `loop_style`, `door` and the
door facts (`door_kind`, `door_read`, `dispatch_round`,
`scout_then_door`, `door_calls`) are facts, and so are `dispatch_door`
(the dispatch round's own door, which the right-door read takes: a
listing the look rule reads as a door — an `echo` beside it, a todo
beside it, three look rounds — still came before the fan) and
`dispatch_names` (the lib/ files the dispatch round's briefs name: a
single `task` that discovers names none; one handed the list is one
agent, not one per file).

**A guessed name.** A lib/ source a SPINE delegation's brief names —
a `task` prompt, a compose script or its params — that no read-class
call (`read`, `ls`, `find`, `grep`, `glob`, `bash`) of an EARLIER spine
round returned. The listing is the call's own text, which the trace
read joins onto the spine's read-class rows (`output`), matched by the
file's own name, since `ls lib` and rho's `grep` print names relative
to the path they read. A listing in the delegation's own round briefs
nothing (the briefs were written in that turn); one in any earlier
round does, the dispatch round's or a later delegation's. What the
model named is never a listing: a `read` of lib/slug.rb lists no file.
A branch's own delegations are the branch's, briefed off what the
branch listed. A compose whose script builds its names at run time
names none; a single discovering `task` whose prompt names no file
guesses nothing.

**What the record cannot see.** The listing is read off the spine's
own calls alone: a discovering `task` whose RESULT lists the files,
followed by a spine fan over them, reads that fan as guessed (a
delegate's result text is not joined). `guessed_after_a_delegate`
names those guesses — a delegation round some earlier `task` call
preceded — and the v17 readout lists them for a hand read.

## Reading a red

- **lane bug** — `error`, or `stopped: deadline` before a round settled
  ("the receipts never went quiet" past 900 s with rounds settled is
  conduct: the loop kept waking).
- **model conduct** — "fanned over guessed names: lib/zeta.rb" (it fanned
  before, or without, a listing that returned the name — read
  `names_not_on_disk` beside: an invented file, or a real one it never
  listed); "no delegation: the spine reviewed lib/ itself"; "a file was
  handed to two delegates: lib/csv_out.rb"; `did_not_review_itself:
  false` — "the spine read lib/csv_out.rb itself" after the reviews went
  out; `task_pass: false` with the names review.md missed or added (a
  module's `def call` read as a class's).
- **kernel finding** — "loop <id> never completed on the feed" with the
  reviews done (a woken turn that never settled); a round `failed` with a
  kernel error key.
