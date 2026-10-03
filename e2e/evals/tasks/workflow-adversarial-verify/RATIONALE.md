# workflow-adversarial-verify

**Measures.** Adversarial verification with N refuters: six claims,
two independent refuters each, a claim stands only if both fail. The
iterative shape the receipt-wake loop has to carry: refuters answer as
receipts, each waking a turn, the verdict written when the last is in.
Success asserts the LOOP (a receipt accepted, every woken loop completed),
never a count of refuters or rounds — those are facts.

**Converts.** New; the receipt reads are
`Gallery.detached_receipt?`'s (`shapes.rb:272-278`); the fixture has
three false claims (C1 overdraft, C4 exact match, C5 truncation).

**Dimensions.** reach = a door; success = ≥ 1 `input_accepted{origin:
task_result}` AND every loop completed on the `task` door — on the
COMPOSE door (no `task` row) the branch completed under its call AND
every loop completed (the kernel mails a `task_result`
receipt for a detached task's result only, and a compose branch of N
members is not a detached fan, so the door owes no receipt — the door
is on the record); conduct = `did_not_judge_itself`; task pass =
`verdict.md` marks C1, C4, C5 FALSE and the rest STANDS; `door`,
`loop_style`, `waited` (a `wait: true` on any task OR compose row),
`refuters`, `read_before_dispatch` are facts.

**Judging is a read after dispatch.** The instruction forbids judging
the claims, not reading the code: a brief needs the code's shape, and
every reference orchestrator reads before it delegates. So
`did_not_judge_itself` reads the spine's own `read` of `lib/` (the
kernel's spine mark, never a key's shape) made by a round LATER, in the
spine's order, than the round that made the first `task` or `compose`
call — the spine checking what it handed out. A read by an earlier round
is briefing. A read beside the dispatch, in that round, is not briefing:
the briefs were written in the same turn, so it cannot have informed
them. It is still not read as judging, because no refuter could have
answered yet. Both count as `read_before_dispatch`, the reads made no
later than the dispatch. With nothing handed out, every such read is the
spine's own verdict. The rule is deliberately lenient — the models were
not adapted to this shape — and here is what that costs. A brief that
carries the spine's own judgment (naming the mechanism behind a false
claim) reads green, since no mechanical reader grades what a brief says
without a keyword heuristic. A spine that reads the code beside its
dispatch reads green too. On v11 and v13 the check caught no run: every
read of `lib/` came before or beside the first dispatch, and one v11 run
read all three files beside it. The fault it keeps apart from a style
difference is reading the code after the refuting was handed out.

## Reading a red

- **lane bug** — `error`, or "the receipts never went quiet" before a
  round settled.
- **model conduct** — "no compose call and no round fanned two task
  calls"; "no input_accepted{origin: task_result}: every task call waited
  (wait: true on 12 of 12), so no receipt was owed and the receipt-wake
  loop never ran ({task: 12})" with `waited: true` — it fanned with
  `wait: true` (the recorded shape; red by the family's rule, read with
  the fact);
  "the compose door mails no task_result receipt, and … did not complete
  under r1t0" (a member that failed); `task_pass: false` with the marks
  (a refuter that believed a claim); `did_not_judge_itself: false` — "the
  spine read lib/… itself" in a round after its first dispatch.
- **the compose door** (`door: compose`, no `task` row) — GREEN when its
  branch completed with the marks: a data point on which shapes the
  grammar carries, never a miss; `refuters` counts its
  model members.
- **disagreement** — `task_pass: true` beside a red predicate (the
  waited fan whose marks are right), or the reverse: read both, never a
  stop.
- **kernel finding** — receipts on the feed and "loop <id> never
  completed on the feed" (a woken turn stuck); "no
  input_accepted{origin: task_result}: the kernel mailed no receipt for 12
  detached task call(s) ({task: 12})" — a detached fan with `receipts: 0`
  after the reply went final (the mail is owed).
