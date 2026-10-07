# rho-acp

rho as an ACP agent: the Agent Client Protocol's wire and the `rho-acp`
process an editor, the registry or harbor spawns on stdio — a peer surface
over `Rho::Core` beside the CLI and the WebUI.

## One sentence, and what it rules out

An editor that speaks ACP spawns one program and talks JSON-RPC over its
stdin and stdout; `rho-acp` is that program for rho. It opens conversations,
says turns, follows them and relays the parks through the same `Rho::Core`
primitives every surface uses, and never a second client: the daemon owns
the conversation, and this process only speaks for it. Nothing here
changes Nexus or the SDK.

It is NOT an extension. `rho-acp.gemspec` carries no `rho_extensions`
metadata and the module answers no `register(api)`; rho's `settings.json`
never names it, and rho's own bundle never names it back — a surface gem
depends on the body, not the other way round. The client half of the
protocol (the `delegate_agent` tool, the `rho.acp-client` plugin's `agents` configuration, the management
verbs) is `rho-acp-client`, an extension gem in rho-mcp's shape that depends
on this one for the wire.

## The exe

```
rho-acp [--mode bypass|ask|rules] [--model MODEL] [--runner EXECUTOR_ID]
rho-acp connect
```

`rho-acp` serves the protocol on stdio (`Rho::Acp::Agent`,
`lib/rho/acp/agent/`) until EOF or a signal; the flags are the DEFAULTS for
new sessions — the mode (`bypass`, rho's own posture; an editor that wants
prompts passes `--mode ask`), the model (else the home's `default_model`),
the runner-kind executor an agent-mode rho names for the session's tools.
`--flag value` and `--flag=value` both parse. `rho-acp connect` runs the
connect ceremony on plain stdio (the terminal auth method's word): the
code and the identity printed, exit 0 when connected; a home the daemon
already reports connected exits 0 at once with one stderr sentence (the
daemon would refuse a second ceremony 409). The home is `RHO_NEXUS_URL`
when set, else the bound home's address, else the product's — the sources
`exe/rho` reads, in its order.

Exit codes: `0` on stdin EOF, SIGTERM and SIGINT (the sessions' live
members released best-effort, the kernel's turns keep running — a
conversation outlives its reader) and on a `connect` that connected or was
already connected; `1` on a usage error (an unknown word or flag, a bad
mode, a flag without its value — the usage on stderr; never 0, since an
editor would wait for `initialize`, and never 2), on a refused connect, and
on a `Rho::Error` at serve time; every sentence of this process's own
starts `rho-acp:` on stderr (the usage block under a usage error and the
ceremony's code lines are the CLI's, unprefixed).

## The initialize document

`initialize` makes no kernel call, remembers the client's capabilities and
answers, whatever `protocolVersion` was asked:

```json
{"protocolVersion": 1,
 "agentInfo": {"name": "rho", "title": "rho", "version": "<Rho::VERSION>"},
 "agentCapabilities": {
   "loadSession": true,
   "promptCapabilities": {"image": true, "audio": false, "embeddedContext": true},
   "mcpCapabilities": {"http": true, "sse": false},
   "sessionCapabilities": {"resume": {}, "close": {}, "additionalDirectories": {}}},
 "authMethods": [{"id": "nexus", "name": "Connect this machine to Nexus", "description": "opens the device page"}]}
```

`authMethods` is never empty (the registry's `--auth-check`); when the
client advertised `clientCapabilities.auth.terminal` a second method rides —
`{"id": "connect", "type": "terminal", "name": "Connect from the terminal",
"args": ["connect"]}` — the client runs the configured program with the
word appended and re-initializes. `authenticate {methodId: "nexus"}` on a
home not connected starts the daemon's ceremony and shows the code as an
`elicitation/create {mode: "url"}` card when the client advertised
`elicitation.url`, else answers -32000 whose message and `data {url, code}`
carry it; already connected → `{}`. A start that joined another client's
ceremony before its code was issued reads the code off the daemon status;
one already past its code answers `{}` once connected, with no card.

### The registry entry

`registry/rho/agent.json` is this agent's entry in the ACP registry's own
layout (`<id>/agent.json`, its draft-07 schema): `id` and `name` `rho`, the
`version` rho's own (`Rho::VERSION` — the gem is rho-acp, the agent is
rho), the description, the repository, the license and its URL, the
authors, and a `local` distribution, `{"cmd": "rho-acp", "args": []}` —
the shape harbor reads. It is the entry read TODAY: harbor's `--agent-kwarg
registry_entry_path=` (the evals cell overlays the `local` block with its
launcher and env; everything else is the file's) and an editor entry placed
by hand. This entry describes a local installation. Public registry
submission requires a supported public package distribution; this repository
currently supplies a checkout-based installation instead.

## What a client can rely on

- **Supported methods**: `initialize`,
  `authenticate`, `session/new|load|resume|close|set_mode|
  set_config_option|prompt`, the `session/cancel` notification and
  `$/cancel_request` both ways; everything else -32601, unknown
  notifications ignored. Every request runs on a thread of its own, so a
  `session/new` waiting on the kernel never delays another session's
  cancel; ONE prompt per session at a time (a second while one runs is
  -32600) — a form re-armed by `session/load` onto a held ask holds that
  slot too, from before its card is sent until the card is answered
  (accepted, or declined — the ask failed) and the turn followed to its
  end, or cancelled (on the card, or by `session/cancel`), so a
  `session/prompt` meanwhile is the same -32600;
  a fresh `Rho::Core` per method.
- **A session is a conversation.** `session/new {cwd, additionalDirectories?,
  mcpServers?}` — `cwd` absolute, the root set at most 4 KiB — opens one on
  the daemon (`Core#open_conversation`), answers `{sessionId, modes,
  configOptions}` and THEN sends `available_commands_update`; `session/load`
  attaches to an existing conversation, replays it (below) and answers;
  `session/resume` attaches without the replay; `session/close` drops the
  in-process session (the daemon keeps following). Not connected: -32000
  naming the auth methods; a runner-mode home: -32603 ("this rho runs in
  mode runner: it opens no conversations"); a `cwd` the daemon refuses
  (not a directory, under a protected root): -32602 with its sentence; an
  unknown session, or one whose conversation ended: -32002.
- **The file-system port.** When the client advertised `fs.readTextFile` /
  `fs.writeTextFile`, the daemon's reads and writes under the session's root
  set reach the editor as `fs/read_text_file` / `fs/write_text_file` —
  unsaved buffers included — through a loopback port this process serves
  (registered at `session/new`/`load`, re-asserted every prompt; a
  loopback-only bearer); a client that advertised neither is never asked.
- **`mcpServers` per session**, verbatim: stdio entries (`{name, command,
  args, env: [{name, value}]}`) and http entries (`{type: "http", name,
  url, headers}`) become the conversation's tool sources; an sse entry is
  listed down; a daemon without `rho/mcp` says so on stderr and the session
  continues without them.
- **Modes and config options.** `modes` names
  `bypass`, `ask`, `rules`; `configOptions` carries the same mode as a
  select and the MODEL as a second select whose options are the refs this
  surface knows (the session's, the home's default, `--model`'s, and every
  ref the picker learned). `set_mode` takes effect on the NEXT prompt;
  `set_config_option model` with a ref outside the options asks the
  kernel: a known ref is learned and set, an unknown one is -32602 with
  the kernel's word. The `code_mode` select offers `default`, `on` and `off`.
  Changing it saves the conversation's Code Mode override through rho; `default`
  clears that override and follows the global setting. Loading or resuming the
  conversation reads the saved choice. It affects subsequent requests, while
  existing work keeps its captured tools. Conversations answered by another
  agent application omit this option.
- **Slash commands**: `retry` (the holding turn re-followed), `abandon`,
  `compact`, then the checkout's skills; a `/skill-name …` prompt is posted
  verbatim, the model holds the `skill` tool. Loading or resuming an existing
  held turn restores its retry/abandon target from the daemon's current row.
  If a fresh follower has not caught up, load uses its existing durable
  history replay; resume reads that history only when a command needs the
  missing target, without emitting replayed content.
- **The prompt turn** (`session/prompt`): text and content blocks in, the
  frames of the daemon's stream out as `session/update` — `agent_message_chunk`
  (messageId `"<turn>:<n>"`), `agent_thought_chunk`, `tool_call` /
  `tool_call_update` (toolCallId `"<loop>:<key>"`, the kind from the tool's
  name: read, search, edit, execute, fetch, think, else other; `rawInput`,
  `locations`, `diffs` for a write), `plan` from `todo_write`. The response
  is `{stopReason: "end_turn"}` on completion, `"cancelled"` after a
  `session/cancel` (whatever settled — never an error), -32603 with the
  failure reason and `data` on a failed turn (a hold carries `{hold: true,
  retry, abandon}` and the session keeps the conversation); `refusal`,
  `max_tokens` and `max_turn_requests` are never produced.
  Rejoining after an ask or retry reconciles the bounded snapshot against
  the text already sent. A replacement changes `messageId`, including when
  the reset happened while this surface was not following; continuation
  emits only the new bytes.
  A queued prompt waits for its own input's durable materialization event,
  polling from the receipt's pre-submission position once per second. Another
  sender's turn or a compaction summary cannot answer it; the editor can cancel
  while it waits. When that event has expired, the existing input materialization
  read recovers its original turn and candidate. A reply with no loop still
  follows that candidate to completion; a later regeneration never replaces it.
  If that receipt arrives before the daemon's follower catches up, a stream
  closed on an earlier turn is rejoined while the requested turn's durable
  status is still active. The earlier turn cannot complete the prompt or
  supply its permissions.
- **The park** (`ask` mode; `rules` refuses as data): `session/request_permission
  {toolCall, options}` with `allow` (once), `always` (a session grant, listed
  by `rho rules`) and `reject`. For `web_fetch`, the option reads “Allow
  this site until rho restarts”: Core grants the held URL's literal
  `scheme://authority/*`, retaining any explicit port and refusing URL
  credentials. The [exact grant and redirect semantics](../rho-web-tools/README.md#approval)
  distinguish matching the initial URL from following same-site redirects.
  Other tools retain their
  command/path or whole-tool scope. A `cancelled` outcome → nothing (the
  cancel's own cascade stops the turn); a client gone (-32800 with no
  cancel, or the wire closed) → a deny; no `reject_always`. **The ask**: with `elicitation.form`, `elicitation/create
  {mode: "form", requestedSchema {answer}}` — accept answers and the same
  turn continues, decline fails it, cancel holds it; without the form the
  question streams, the prompt answers `end_turn` and the NEXT prompt is the
  answer (the escape is `session/cancel`).
- **The replay** on `session/load`: nothing of ACP's is stored — the
  conversation is read back off the kernel, one exchange per turn (the
  person's words as `user_message_chunk`, each settled call as a
  `tool_call`, the reply as `agent_message_chunk`; messageId `"<turn>:0"`);
  a Side's frozen parent reference is one explicitly labelled
  `user_message_chunk` of context with messageId `"<turn>:reference"`, without
  a second prompt, agent answer or tool replay. Inherited history stays readable;
  neither inherited turns nor reference snapshots become retry/abandon targets.
  A held ask is re-armed after the response; `$/cancel_request` aborts it
  (-32800).

Codes: -32700 (not JSON), -32600 (not a message, or a second prompt),
-32601, -32602, -32603, -32002, -32000 (auth required), -32800 (cancelled).

## Hygiene

At entry the ORIGINAL fd 1 becomes the wire — a fresh IO on a dup'd
descriptor — and STDOUT is reopened onto stderr with `$stdout` pointed there
too, so `puts`, `warn`, the log and every child spawned with an inherited
stdout land on stderr: nothing but JSON lines ever reaches the editor (the
hygiene test spawns a child with an inherited stdout and asserts the wire
stays JSON). A line that is not JSON is answered -32700 and the next line
read; a line that is no message -32600; the wire never writes two lines for
one message and serializes every write under one lock.

## In the distribution

The gem is one of the trees `install/manifest.json` names, copied by the
installer and the two images beside rho's own, and a path gem of rho's own
bundle. The installer writes no `rho-acp` wrapper (its `bin/` holds `rho`,
and `rho-playwright` under the dev profile): under a prefix the exe is
`$RHO_PREFIX/current/agents/rho/rho-acp/exe/rho-acp`, run the way `bin/rho`
runs the CLI — the prefix's Ruby with `-rbundler/setup` under the app's
Gemfile (`e2e/evals/docker/rho-acp-launch` spells that line for the harbor
cell); from a checkout, `bundle exec rho-acp` under this gem's own bundle.
The editor's `agent_servers` row names it with the flags above.

## The suite

```sh
cd agents/rho/rho-acp && bundle exec rake        # test, rubocop, rbs
```

`test/test_helper.rb` requires rho's test support tree by relative path
and this gem's own doubles (`test/support/core_double.rb`, a scripted
`Rho::Core`; `test/support/agent_harness.rb`, the surface on a pipe pair
with a client `Connection` playing the editor): the surface's cases run
against the double, never a daemon — the e2e lane is the real witness.
The exe is spawned under this gem's own bundle (all three Bundler names,
frozen). CI runs it as `agent_rho_acp`.
