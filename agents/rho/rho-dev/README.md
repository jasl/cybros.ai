# rho-dev

rho's development extension: the verbs that operate a conversation from a
terminal — for the orchestrator, e2e and other agents to test and debug
through. Never in the distribution.

## One sentence, and what it rules out

A product install of rho carries the management verbs — the install's
(`version`, `doctor`, `update`, `uninstall`), the connection's (`connect`,
`disconnect`, `status`), the daemon (`server`) — and ONE conversation verb,
`run`, which opens a conversation, follows its turn to the end, denies
what nobody there can approve, prints the answer and exits by outcome.
Everything else that operates a conversation from a terminal — open one and
return its ids (`do`), a second turn (`say`), the end (`stop`), a loop
watched, followed, read, repaired, decided, paused and deleted — is this gem. It is not in rho's bundle, the installer's manifest, the images or `rho doctor`; a product home
lists none of its verbs, and typing one there is an unknown verb.

Every verb is a thin formatter over `Rho::Core`'s primitives through the
terminal it is handed (`cli.core.*`, `cli.out`, the shared renderers) —
never a second client. The daemon's routes it calls are `rho.ops`'s, which
ships everywhere; only the terminal spellings live here.

## Loading it

```json
{ "extensions": ["rho/dev"] }
```

The gem is loaded through the same extension door as any operator gem
(`rho-dev.gemspec` carries `rho_extensions = "rho/dev"`, the loader's
contract): a home names it in `settings.json`, and the rho process must
find `lib/rho/dev.rb` on its load path. rho's bundle never carries it, so
the checkout's `lib` is handed over directly:

```sh
# a developer's shell, from agents/rho/rho
RUBYLIB=$PWD/../rho-dev/lib bundle exec exe/rho do "fix the failing test" --model dev/mock-text
```

The e2e harness does the same for every rho child it spawns
(`E2E::RhoDaemon::CHILD_DEV_ENV`), and writes `{"extensions": ["rho/dev"]}`
into a home that wrote no settings of its own — so the mock journeys type
`rho do`, `rho watch` and `rho say` with no line per lane, while the
product-shaped lanes (`rho_run`, `rho_core_only`, `rho_runner_mode`,
`executor_plane`, the install lanes) write `[]` and drive `run` alone.

A daemon whose home names `rho/dev` without the lib on its load path
records the load as a failure (`rho runner` lists it) and serves everything
else; only the verbs are missing.

## The verbs

`rho help` under a dev home lists them under `Extension rho.dev:`.

```sh
rho do "…"                 # open a conversation and print its ids (conversation:, turn:, loop:, compose:)
                           # --model M --dir PATH --runner ID --agent @handle --attach FILE --instructions TEXT
                           # --compose/--no-compose --restricted --approval ask|rules --no-stream
                           # --until CMD --attempts N (the acceptance check; `rho say` lands with the next check)
rho say <id> "..."         # say something to a loop or conversation this daemon follows
                           # (--mode steer lands at the running turn's next model boundary,
                           # the default; --mode queue waits for the turn boundary;
                           # --to @handle|<id> names who answers this turn — group chat;
                           # --in DURATION | --at TIME schedules it)
rho stop <conversation> [TASK]  # cancel the conversation's unfinished work; a task key cancels one branch
rho stop <loop> [TASK] --host-type agent_loop  # exact loop/task, including an older candidate (--graceful: let steps finish)
rho adaptations [--model M] # the adaptation row a model resolves to, and the kernel's facts
rho loops                  # which loops is this daemon following
rho loops --server --attention any   # …and which of the workspace's need a person
rho loops --side           # the side conversations this daemon opened (hidden by default)
rho providers              # the account's provider lanes, with each lane's `unavailable_until`
                           # (the provider's own Retry-After clock) when one stands
rho attach <id>            # start following one this machine did not place
rho watch <id>             # follow one loop's tasks until it finishes (polls; prints what moved,
                           # and the reply as it accumulates; --reasoning, --no-stream);
                           # `mailed`/`sent` rows print `from: @handle (kind) <sender>` under them,
                           # each spawned child prints `spawned … — replying|idle`, a settled park
                           # says who resolved it
rho follow <id>            # …or read its events as they land, the reply word by word
                           # (the stream a console reads; --reasoning, --no-stream)
rho result <id>            # what did it answer
rho transcript <id>        # the thread: the spine's rounds, the calls each read, the branches under them
                           # (--prefix <call> expands one branch; --follow keeps reading the spine as it settles)
rho task <id> <key>        # one task whole: its question, its arguments, its output
rho graph <id>             # the whole run as a Mermaid flowchart (--json: nodes and edges)
rho fetch <upload-id>      # an upload's bytes whole to stdout (a capture a task's resource_link named, an
                           # attachment this daemon may read; redirect it); --thumbnail | --preview prints the
                           # kernel's named representation of it instead (a PNG; none → representation_unavailable)
rho request <id> <key>     # the bytes a round was sent (entries + request options, JSON)
rho request <conv> <turn>  # the same for a turn's active variant
rho prompt preview <conv>  # the bytes a send would seal, before sending: the block evidence,
                           # the storage line, then the entries as JSON — under --to @handle
                           # (whose template and identity compile), --var name=value… for
                           # the template's variables, --template FILE for a trial order (never
                           # stored), --prompt TEXT, --model M; --json prints the document;
                           # writes nothing; refused whole when the addressee's standing word
                           # is `raw` (the kernel's `estimate_unavailable_under_raw`)
rho prompt show [SLOT]     # this profile's own prompt documents, or one slot whole
rho relay <runner> <tool> [INPUT_JSON]  # ask one runner to run a tool it announced and print the answer
rho btw "…" [--on <id>]    # ask beside the work: the side conversation answers from context; a call it makes is denied
rho side [<id>]            # open/resume the side conversation (read-only tools); `rho say <side-id>` talks in it
rho inputs <id>            # the queued and parked inputs of a host this daemon follows
rho inputs rm <id> <input>          # drop one
rho inputs edit <id> <input> "…"    # rewrite one (the unblock path for a parked head)
rho inputs edit <id> <input> --in 20m   # reschedule a timed row (--at TIME | --in DURATION | --now clears)
rho answer <id> <key> "…"  # answer a question a loop is waiting on
rho variant <id> <turn> [<variant> --conceal|--restore]  # a turn's candidates (active starred); hide one sample, or bring it back
rho activate <id> <turn> <variant>  # choose a settled candidate as the turn's answer (swipe)
rho pause|resume <id>      # hold it, let it go on
rho retry <id> [TASK]      # a round failed and the loop is holding: run it again
                           # (--model provider/model [--effort E]: on another model)
rho abandon <id> [TASK]    # give up on that one so the loop moves past it
rho compact <id> [TASK]    # compact it now: a conversation's running reply on its next
                           # round (idle, its history); a loop needs the round's key
rho approve <id> <key>     # let a held tool call run (--always: and grant its shape for the
                           # session; --match PREFIX: its family — `npm` → `npm *`)
rho deny <id> <key> ["why"] # refuse it; the reason is what the model reads next
rho rules                  # the approval grants this daemon holds for the session
rho append <id> -f FILE    # grow a loop: place steps after its answer, from a JSON file
rho phases <id>            # how far a loop has come: its phases, the one in flight, background work and spend (per model once a step re-ran on another)
rho delete <id>            # remove a finished loop from every surface
rho rewind <conv> <turn>   # branch a conversation at a turn and put the files back (--keep-world forks alone)
rho regenerate <conv> <turn>  # re-do the tail turn's reply, restoring the world first (--keep-world: as it is)
rho skills                 # the skills the kernel holds for this person and this workspace
rho skills push DIR | show NAME | rm NAME   # (--scope user|workspace)
rho conversation participants <id> [add PRINCIPAL LEVEL | rm PRINCIPAL | default LEVEL]  # who may see it
```

`rho skills push` replaces the whole remote skill with the local `SKILL.md`. It reads
the current remote version once when the command starts; an absent skill is created
only if it remains absent. `rho skills rm` deletes only the version it just observed.
If another writer changes the skill, either command stops with `stale_object` instead
of retrying. Compare the remote skill with your intended change before running again.

**A step a provider declined.** A round whose provider's classifier declined
it re-runs once on the answerer's `fallback_model` (rho's setting); `rho watch`
prints the move on the status that moved, `waiting  r2  — switched from
anthropic/claude-opus-5-5 to openai_api/gpt-6.1-sol (model_refused: cyber)`. A
step that STOOD — no fallback declared, the fallback declined too, or content
`blocked` — prints the category, who declined and the way on: `failed  r2
(model_refused: cyber — declined by anthropic/claude-opus-5-5; `rho retry
al-9 r2 --model provider/model` re-runs it on another model)`; for `blocked`
content, `rho abandon` and a rephrase, since it is re-sent to no model.
`rho retry --model` is the kernel's `retry(model:)` through the daemon (an
`--effort` needs `--model`; `abandon` takes no model). A retry re-arms no
fallback: a step switches once by its own history.

**`rho retry` re-arms the clock.** A retried `await` step runs again with its
AUTHORED timeout, so a sub-second gate (a 1 000 ms `until`, say) expires again
before your `rho answer --token` lands — the loop halts twice and the token
still resolves the timed-out-then-retried await; retrying such a gate is a race
with your own hand, not a repair. The picture keeps only each node's final word;
the feed keeps the history.

## How the conversation verbs behave

`rho do` opens a CONVERSATION in the connected workspace and says the prompt
on it — `rho run`'s first step, printed and RETURNED: three ids
(`conversation:`, `turn:`, `loop:`), then `compose:`, the tier the
conversation runs in and its source, then the `rho watch` line that follows
it. Every loop-grain verb above (`watch`, `task`, `retry`, …) takes either
the conversation's id or the loop's. `--model`, `--dir`, `--runner`,
`--agent`, `--attach` and `--instructions` are `run`'s, with the same
meanings (rho's README, "Starting work"); the four `run` does not carry:
`--approval ask` holds every command this turn for `rho approve`/`rho deny`,
`--approval rules` refuses every command (kernel tools only) — a per-turn
tightening of rho's own bypass, the next `rho say` turn is bypass again;
`--no-stream` opens a conversation the daemon holds no transcript
subscription for (no live text — `rho result` and `rho transcript` still
read what the turn said); `--compose`/`--no-compose` grants or withholds
the `compose` tool for this conversation ahead of the `compose` setting and
the model's row; `--restricted` opens it with default access `none` — only
you (your steward, at full), rho, and whom `rho conversation participants
add` names can see it. A turn
the kernel has not materialized within the daemon's 30 s bound prints
`pending` (exit 0; `rho watch` follows it); an input the kernel BLOCKS at
materialization is a refusal in one line, `rho do: the kernel blocked the
input (unknown_model) …`, exit 1. `--until CMD --attempts N` is the same
acceptance check `run` carries, through the same fold (`Rho::Until.fold`):
the command runs on the conversation's runner when the model ends its turn,
exit 0 closes the turn with a summary, anything else hands the model the
output and another attempt, and `rho say` lands with the next check.

`rho say <id> "…"` says the next thing on it — it is the PERSON's `send`:
the same input door a model's `send` uses, the row stamped `origin:
person` and bare in the model's history, where a peer's is wrapped
`<message from=… kind=…>`. `steer`, the default, lands at the running
turn's next model boundary; with nothing running it simply starts the
next turn. `--mode queue` waits for the turn boundary. `--attach shot.png`
QUEUES the turn: a picture never rides a steer (`--mode steer --attach` is
refused with the kernel's word); the daemon stages the bytes on its member
plane as rho's own user and prints `attached: shot.png (image/png, 184
KiB)`, and `rho inputs` shows the picture on a waiting row. `--to
@handle|<id>` names who answers ONE turn (group chat): the
workspace's principals listing, the same door word
(`answering_user_public_id`, the SDK's `to:`), the addressee printed back
as `to: @handle (id)`; the bare rule follows the ADDRESSEE, never the row —
a turn for another profile carries the words alone, a turn for rho itself
its tier's names (and, on a conversation another profile answers by
default, the lead the bare open withheld, once). Without `--to` the kernel
addresses a steer to whoever is replying and a queued word to the
conversation's own answerer; a `--to` naming someone other than the
running answerer queues for its own turn. `rho watch` prints `sent` with
`from:` under a peer's row. A loop has one answerer and refuses `--to`.
`--in DURATION` (`90s`, `20m`, `2h`, `1d`) or `--at TIME` (ISO 8601; a
time with no offset is read in this terminal's zone) says NOT BEFORE a
time: it implies `--mode queue`, is refused on a loop, prints `queued:
<id> (pending, scheduled for <time>)`, and `rho watch` prints `scheduled:
<input> for <time>` when the row is accepted. `rho say` on a conversation
this daemon only attached rides `default_model`, else the addressed turn's
model off the loop projection, and refuses only when neither states one;
`rho do`/`rho say` print a `runner:` line when none is bound or the bound
one is not online.

`rho stop <id>` addresses a conversation by default and cancels its unfinished
work through the kernel, including background work; the conversation stands. `rho
stop <id> r3t1` cancels ONE branch the model started (the `task` call's
key) and the turn runs on. On a conversation this daemon never followed
(one the model spawned) it cancels through the kernel and says so. The kernel
follows originating requests into derived work; an independent later request
in the same child conversation is not owned by the earlier stopped execution.

Use `rho stop <loop> --host-type agent_loop` to stop exactly that loop, even
after its conversation has moved to a new turn or candidate. Adding a task key
targets that loop's task. The explicit type prevents the current followed row
from redirecting an old loop command to the conversation. `--graceful` applies
only to loop stopping; conversation cancellation remains immediate.

`rho activate <conversation> <turn> <variant>` uses the kernel's activation door.
It chooses an existing settled candidate and cancels unfinished work owned by the
replaced candidate. Completed answers and results remain readable; selecting an
old candidate does not restart its canceled work. This is separate from
`rho variant --conceal|--restore`, which controls whether a candidate is shown.

The whole spawn surface is driven through these verbs by two lanes:
`e2e/test/rho_spawn_test.rb` on the mock (group 1 of the gate: the detached child's mail, `wait: true`, `send` three ways, `rho stop CHILD`, and two rho homes in one room under `RHO_WORKSPACE` — `rho do --agent @handle`, a peer spawn, the ask answered on the other home) and the paid
`cd e2e && E2E_LIVE=1 rake live_spawn` (both floor models, no compose; its
GROUP variant is the group's paid case). The group's mock lane is
`e2e/test/group_chat_test.rb` (group 4: rho A and a differently-declared
SDK peer B in one room — `rho do --agent @b`, `rho say --to @a`, A's
`send` reaching B, each agent reading the other wrapped and the person
bare, the two-instant "B not woken" read, the unnamed steer reaching the
running answerer, `principal_unknown` and `answerer_not_eligible`).

`rho adaptations [--model M]` prints the row M resolves to from the files
alone — its entries and the one that matched M, spellings, recut anchors,
summarizer, hints and compose rung, the boot row when M's differs — then
the kernel's facts for M (`tool_calls true (catalog)`) through the daemon,
`(no daemon)` without one (the pack, the knob and the boot-row rule are
rho's README, "Starting work").

## Side conversations

A SIDE CONVERSATION is a question beside the work. `rho btw "…"`
asks it on a side of the newest conversation this daemon follows (`--on
<id>` names another) and prints the answer alone. The btw turn DECLARES
THE PARENT'S WHOLE TOOL SET and runs none of it: the provider's prefix
cache needs the parent's tool block ahead of the messages (a tool-less
btw read 0 cached tokens against the parent's 5,632 on identical
entries), so the turn is tightened to `ask` and the daemon denies every
call it makes with one sentence the model reads next — tools present,
blocked by permission, Claude Code's own shape. `rho side [<id>]` opens
the same side with rho's read-only tools (`read`, `grep`, `ls`, `find`,
`read_process`, `memory_read` — never `bash`, `write`, `edit` or `task`)
for a person to keep talking in with `rho say <side-id> "…"`. The kernel
forks the side at the live head from the conversation's last SETTLED turn
even while a later turn runs, renders the inherited history behind one
boundary item and shares the parent's prefix bytes (the provider's cache
is hit); the side's turns never write into the parent's history —
bringing a conclusion back is your own `rho say <id> "…" --mode queue`.
The rest is rho's bookkeeping, not the kernel's: ONE open side per
conversation (both verbs reuse it), the sentence the model reads riding
each side turn as one user-role tail entry (never a lead, which would
change the shared prefix), and a side nobody spoke in for 24 h swept by
the daemon (deleted through the kernel: tombstone and reap at once).
`rho loops` hides sides; `rho loops --side` lists them with their parent.

## The input queue

`rho inputs <id>` lists what is queued or parked on a conversation (the
kernel blocks a head it cannot materialize — an unknown model, say — and
the queue waits behind it); `rho inputs rm <id> <input>` drops a row and
`rho inputs edit <id> <input> "…"` rewrites it, which is the unblock path.
`edit … --at TIME | --in DURATION | --now` reschedules or clears a timed
row; `rm` cancels it; the listing shows `at <time>`.

## Watching a reply arrive

`rho watch` and `rho follow` print the model's words in their own block
behind a `│` gutter, as `rho run` does, and every structured line (`loop:`,
`status:`, `  check 1/3:`) still starts where it always did — a status line
breaks the block first. `rho follow` renders each delta as it lands and
flushes per delta, so a long answer scrolls; `rho watch` renders at its
one-second poll and so coalesces by construction — that, or `rho follow |
tee`, is the answer for a model that streams fast. A retry prints one
`(restarted — the text above was discarded)` line and starts over, and when
the turn settles only the part that was not already shown is printed.
`--reasoning` adds the model's thinking on a second, dimmed channel (off by
default; a captured pipe gets no escape codes), and `--no-stream` leaves
only the once-per-change table. Both print the todo checklist as it
changes, `background:` while a detached `task`/`compose` runs and `mailed`
when its result lands, `ASKING approval_required — key` and the call's
line once, with the approve/deny tail.

A follower is DELTA-FREE BY DESIGN in two cases, and both are silent rather
than broken: `rho do --no-stream` opens a conversation the daemon holds no
transcript subscription for, and a daemon following without a socket
(`rho attach --no-live`) has nothing to stream. What the turn said is still
the transcript: `rho result` and `rho transcript` read it back.

## Approvals and grants

`rho status` (shipped) lists the calls held under `approvals:`; here
`rho approve <id> <key>` lets one run and `rho deny <id> <key> ["why"]`
refuses it with the reason the model reads next.

> `rho approve <id> <key> --always` also grants the call's shape for the rest of this daemon's life: the exact text the
> model sent, byte for byte — the `command` of `bash`/`start_process`, the `path` of `write`/`edit` — or `--match
> PREFIX` for every command starting with that word (`npm` → `npm *`) or every path under that directory; any other
> tool is granted whole. A prefix is raw text with no shell in it: `npm *` also covers `npm test; …`, so grant the
> exact text unless you mean the family. The grant is an allow rule rho appends to its own declared `approval_rules`
> and re-declares; it governs turns opened after it by `rho do --approval ask` (the call runs) and `rho do --approval
> rules` (the call runs there too — the grants are the allowlist that mode reads), never the turn whose call parked
> (that list is frozen) and never a plain `rho do`/`rho say`/`rho run` turn (bypass). It is gone once the daemon is
> stopped and started again, or at `rho stop`. `rho rules` lists the grants. Nothing is written to `settings.json`.

## The hints

The shared renderers in rho (`Rho::Cli::Reporting`) print a line's fact and
leave its hint to a hook: the shipped terminal names the capability (a
product home has no `retry`, `answer` or `approve`), and this gem's
`Rho::Dev::Hints`, extended onto the same terminal a verb receives, answers
those hooks with its verbs — so `rho watch` prints
`answer:    rho answer <loop> <key> "…"` under an ask and
`→ rho approve … | rho deny …` after a park, exactly as before.

## The suite

```sh
cd agents/rho/rho-dev && bundle exec rake        # test, rubocop, rbs
```

`test/test_helper.rb` requires rho's test support tree by relative path
(`RhoTest::CliHarness`, the scripted daemons, `NexusDoubles`), so the
seventy command cases and the watch cases run over the same doubles rho's
own suite uses; `test/dev_cli_test.rb` drives the shipped binary under a
dev home (`RUBYLIB` + `{"extensions": ["rho/dev"]}`): the listing, the
usage-line law, the flags folded into the one POST, and — since a verb
collision is a `RegistrationError` that kills every non-core verb — that
`rho help` succeeds at all. CI runs it as `agent_rho_dev`.
