# workflow-loop-until-dry

**Measures.** Loop-until-dry: a queue processed one head at a
time until empty. The static compose grammar cannot loop, so the model
iterates across rounds, across receipts (a task per pass, each receipt
waking the next), or with a compose per pass — `loop_style` records
which approach the model used. Success is the loops
completing; the results on disk are the verification; the conduct fact
is the instruction's one rule.

**Converts.** New; the receipt reads are the gallery's; the
one-item rule and reach read what each bash command DID to `queue/`
(`QueuePass`), each operand from the folder its command runs in (the
call's `workdir`, then each `cd`): the items it took out — `mv` or `rm`
of a path under the queue, spelled, bound by a head-pick
(`head=$(ls queue | head -n1)`, then `mv "queue/$head"`) or picked inline
— the items whose contents a reader named, and whether it loops over the
queue with a shell construct, however the loop is fed. The item's file
name is never the read: a head-pick spells none, and a loop over the
results takes none. A look at every item (`cat queue/*`) takes none out,
so it never counts toward reach, but it reads every item's contents in
one call, so the conduct holds it red.

**Dimensions.** reach = ≥ 2 passes (rounds, receipts or compose passes —
never a fixed count) and ≥ 2 items taken out of `queue/` — the bash
calls that took one, and, once one did, each receipt, since the receipt
door's later passes run in woken loops whose rows the trace does not
hold; success = every loop completed; conduct = `one_item_per_pass` (no
bash call takes two items out or reads two items' contents, none loops
over the queue); task pass = six results doubled and `queue/` empty;
`door`, `loop_style` are facts.

## Reading a red

- **lane bug** — `error`, or the deadline before a round settled.
- **model conduct** — "no iteration: 1 pass(es)" (one bash did it all —
  `conduct.one_item_per_pass` then names the command); "a shell loop
  over the queue: for f in queue/*"; "one bash call handles 6 items: cat
  queue/item-01.txt; …" (a look at every item's contents in one call);
  `task_pass: false` with "4/6 results right; queue left [item-05.txt,
  item-06.txt]" (it stopped early).
- **kernel finding** — a receipt-driven loop whose woken turn never
  completed; a round `failed` with a kernel error key mid-queue.
