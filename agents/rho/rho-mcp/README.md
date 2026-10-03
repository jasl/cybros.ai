# rho-mcp

The MCP client for rho's agent loop, as an extension: runs the servers an
operator names, curates what they named, announces each tool VERBATIM under
its own prefix with the worst-case effect profile — and the kernel, which
never speaks MCP, addresses, judges and settles the call exactly as it does
`bash`.

## One sentence, and what it rules out

An MCP server is a tool source behind an executor. rho runs the client; the
kernel merges the announcement once and routes a call to its announcer.
Nothing here changes Nexus or the SDK: the whole gem is one settings key,
two registry seams in rho-runner (per-address entries; document loaders),
two verbs. The client is the official `mcp` gem's `MCP::Client` on its own
two transports — never a hand-rolled JSON-RPC layer, initialize or
`tools/list`; rho-mcp is the seams only.

## Wanted, not merely installed

```json
{ "extensions": ["rho/mcp"] }
```

The gem is in rho's bundle; nothing loads it until `settings.json` names it
(`rho-mcp.gemspec` carries `rho_extensions = "rho/mcp"`, the loader's
contract). It loads under either host — a full-mode daemon, a runner-mode
one — and its daemon-only verbs answer `unavailable` elsewhere.

## Where a server is declared

One key, opaque to rho's `Config` (an object of objects and nothing more;
everything inside is this gem's to judge at load):

```json
{
  "extensions": ["rho/mcp"],
  "mcp_servers": {
    "fx": {
      "transport": "stdio",
      "command": "ruby", "args": ["/opt/fx/server.rb"], "cwd": "/opt/fx",
      "env": { "FX_TOKEN": "${FX_TOKEN}" },
      "tools": ["echo", "lookup"],
      "timeout_ms": 60000,
      "effect_profiles": { "lookup": { "kind": "read_only", "destructive": false, "world": "open",
                                       "idempotency": "intrinsic", "reconciliation": "none" } }
    },
    "remote": {
      "transport": "http",
      "url": "https://mcp.example.com/mcp",
      "headers": { "Authorization": "Bearer ${REMOTE_TOKEN}" },
      "tools": "*",
      "serves": "agent"
    }
  }
}
```

- `transport` — `stdio | http`, required.
- `command`, `args`, `env`, `cwd` — stdio; `command` required, `cwd` the
  daemon's home by default.
- `url`, `headers` — http; `url` required.
- `oauth` — http only; optional, an object `{client_id, callback_port}`, both
  optional. A server that answers 401 with an OAuth challenge is logged in
  to with `rho mcp login NAME` (authorization code + PKCE in your browser;
  rho registers itself dynamically as a public client unless `client_id`
  names one you registered by hand). `callback_port` fixes the loopback
  redirect's port for an authorization server that refuses an ephemeral one
  (`http://127.0.0.1:PORT/callback`). A row with an `Authorization` header
  is the static-bearer door and takes no `oauth`; a row on plain `http://`
  off loopback takes none either.
- `tools` — REQUIRED: the server's raw tool names, or `"*"` for every one.
  A row with no list is `down: config:` at boot with a sentence naming
  `rho mcp probe NAME`, and nothing is spawned to count.
- `timeout_ms` — the announced park of every tool of this server and the
  tool's own clamp; absent, the kernel's default park for stdio (10 min),
  60 000 for http, where it is also the HTTP read timeout.
- `startup_timeout_ms` — the connect + list bound (30 000): a server that
  spawns and never speaks costs its bound once and is `down`.
- `serves` — `runner | agent`, defaulted by transport (below).
- `effect_profiles` — a full five-key profile per raw tool name, its
  VALUES checked at parse (`kind`, `world`, `idempotency`, `reconciliation`
  each against the kernel's vocabulary); a typo is that row's fault, never
  a blanked announcement.
- `enabled` — the switch; absent is on. `false` parks the row: listed by
  `rho mcp` as `disabled — \`rho mcp enable NAME\``, never connected, never
  announced. `rho mcp enable NAME` / `rho mcp disable NAME` write it (below).
  Not a boolean is the row's fault.

The server KEY is your short word (`[a-z0-9]` with single hyphens, ≤ 32) and
never the remote `serverInfo.name`: it has to fit both `mcp__<key>__<tool>`
and `<key>-<document>`.

## Shipped, disabled: Context7

One example row rides in the gem, present in every rho and OFF until you say
so — `context7`, the documentation server at `https://mcp.context7.com/mcp`
(http, every tool, the agent address):

```
$ rho mcp
server:    context7  http  https://mcp.context7.com/mcp  serves agent  disabled — `rho mcp enable context7`
  auth:    oauth — needs login (no tokens)
$ rho mcp enable context7
enabled context7
$ rho mcp login context7      # optional: Context7 answers anonymously too; a login adds your account's token
```

The row lives in the gem (`Rho::Mcp::Builtin::ROWS`), not in rho's `Config`,
which reads nothing inside `mcp_servers`; it is merged UNDER your table the
way `checkpoints` merges its defaults under your object — your rows first, in
your order, the shipped row after. A row you write under the same key
OVERLAYS it member by member: `rho mcp enable context7` writes exactly
`"context7": {"enabled": true}` into `settings.json`, and
`"context7": {"tools": ["get-library-docs"]}` narrows it while the URL and
the rest stand. `rho mcp disable context7` writes `false` back; a name that is
neither shipped nor in your file is refused by name. A running daemon applies
the new table immediately through the shared settings operation; without a
daemon the table is saved for its next start. `rho mcp probe context7` and
`rho mcp login context7` reach the row by name whether or not it is enabled.
One row, no registry of examples.

Saving MCP settings reuses unchanged live connections and their tool classes.
Changed or removed rows close their previous connections; new or changed rows
connect with the new settings. Servers supplied by an editor for a conversation
keep their own lifetime and remain connected. Removing the extension closes all
its connections; adding it again starts it normally.

**Faults are per server.** A malformed table (not an object of objects, a
key outside the grammar) refuses the extension; everything else — an
unknown transport, a missing `command`/`url`, a `${NAME}` naming an unset
variable, a bad profile value, any header over plain `http://` off loopback
(every header value is a secret), no `tools`, a server that cannot be
spawned, listed or handshaken
within its bound, a `tools` list naming a tool the server no longer lists —
is THAT row, listed `down: <reason>` on `rho mcp`, logged
(`mcp.server_config_invalid` / `mcp.server_unavailable`), contributing no
tool; the other servers are announced.

## What is announced

For each allowed tool, one class at load:

- `NAME` — `mcp__<server>__<tool>` verbatim when it fits the runner's
  `[A-Za-z0-9_-]{1,64}`; else every other byte becomes `_`, the name is cut
  and `_` + 12 hex of `SHA256("<server>\0<raw>")` appended, so two raw names
  that normalize alike never collapse. The raw name goes on the wire.
- `DESCRIPTION` — the server's, every byte, no cut, no sentence of ours. A
  tool with no description is never announced (the door refuses it; an
  invented sentence would be ours in the server's mouth).
- `SCHEMA` — `inputSchema` verbatim, compiled at load and validated on every
  call; a schema the runner cannot compile costs that tool, never the row.
- `EFFECT_PROFILE` — the WORST CASE: `write`, `destructive`, `open`, no
  idempotency, no reconciliation. A server's `annotations` are untrusted by
  MCP's own text and are NEVER read; an operator's `effect_profiles` row
  replaces the profile for one tool — the operator's act, in the operator's
  file.
- `TIMEOUT_MS` — the row's; `INTERNAL_CLAMP = true` always: the announced
  park (or the kernel's default) is the wall, never extended.

Judged like `bash`: under `--approval ask` the worst-case profile PARKS on
rho's inbox and `rho approve` releases it; under `rules` it is denied as
data; rho's incubation denies reach every `mcp__` tool through the same
kernel rule grammar — from the tool's own schema, one deny per text-shaped
top-level property per protected root (a property whose name is not one
valid path segment, `file.path`, is skipped and listed on `rho mcp`).

The list is read ONCE at boot and never re-synced (`list_changed` is not
subscribed: every list move rewrites the front of every cached prefix). A
re-list is the next boot; stopping and starting the daemon re-lists, `rho env` re-announces the
same registry. Every boot logs `mcp.announced {server, tools, bytes}` — at
WARN past 4,971 bytes, rho's whole toolset (ADR-0040's byte case); `"*"` is
your written choice. The one wall is the kernel's: an address's announcement
is one PUT under `envelope_bound` (65,536 canonical bytes), refused whole
above it, so each server's tools are measured as the kernel measures them —
cumulatively in settings order, on top of rho's own tools — and a server
that would cross the bound is listed `down:` naming its bytes, the total and
the bound; nothing of it is announced, and rho's tools and every other
server announce.

## Which address

`serves` is the address: stdio → the RUNNER row, beside Coding's tools;
http → the AGENT row, beside the delegate summarizer, addressed by the
kernel as `agent_application`. Override per row (`"serves": "runner"` for a
localhost http server this machine owns). A mode that does not serve the
row's address lists that row `down: config:` with the sentence saying which
setting to change; in `mode: full` both serve. An http tool on the agent row
runs on that slot's one worker and delays a compaction for as long as it
runs — `timeout_ms` bounds it; a heavy server this machine owns is
`serves: runner`.

## The stdio child

Spawned through the runner's `OwnedProcess` in its own process GROUP; the
environment is REPLACED, not merged (`unsetenv_others: true`): the runner's
`ChildEnv` minus credential-shaped names (`KEY`, `PASSWORD`, `SECRET`,
`TOKEN`, `CREDENTIAL`) and rho's own (`RHO_*`), plus the row's `env`. A
4 KiB stderr tail is kept for the log; the model-facing sentences carry at
most its last 3 lines / 512 bytes. ONE REQUEST IN FLIGHT per stdio
connection (a mutex — the SDK's reader discards frames that are not its
own); HTTP rows with OAuth credentials also serialize calls. Close is the
spec's ladder — stdin, TERM, KILL — sent to the group, each stage bounded,
and `close!` closes every server in
parallel outside the lock so N servers cost one ladder.

Closing a connection is final. If a conversation ends or replaces its MCP
servers while a reconnect is in progress, the late transport is closed and
cannot be published into the retired set.

## Errors, by the two-axis law

| the server said | the call answers | the kernel settles |
|---|---|---|
| a result, `isError: false` | `Result.ok(text, structured)` | completed |
| a result, `isError: true` | `Result.error(text, structured)` | completed, `is_error` — the model self-corrects |
| JSON-RPC `-32602` (unknown tool or invalid params) | `Result.error("The server refused the call: …")` | completed, `is_error` — with the server's words |
| any other JSON-RPC error; `input_required` | `CallRefused` | `outcome: failed` |
| the transport died under the call | `ServerGone` — "mcp server fx exited (status 3) during mcp__fx__lookup; its stderr ended: …; the next call restarts it" | `outcome: failed` |
| a legacy http session expired | reconnect, resend ONCE, `note: … session had expired and was re-established for this call` | completed with the notice |
| cancelled / timed out | nothing (the runner already answered) — and a stdio connection is TORN DOWN | timed out / interrupted |

A cancelled or timed-out stdio call poisons the pipe (the SDK's abandoned
reader eats the next frame whether the server honours the cancel or ignores
it), so the group is killed and reaped under the ladder's bound, the exit
recorded (`mcp.server_killed`), and the NEXT call restarts it. A server
known dead at call time — exited, or killed by us — is restarted ONCE for
that call and the result opens with one line the model reads: `note: mcp
server fx had exited (status 1 at …) and was restarted for this call; any
state it held is gone`. The lost call is never replayed: a worst-case-profile
write may have partially run. No supervisor, no backoff, no `down` state
that needs a boot to clear.

Results: `text` blocks joined by newlines; an `image` (or an image `blob`)
decoded to a capture under the artifacts dir and named in `Result#files`, so
the runner uploads it and links a `resource_link` beside the text; `audio`
one placeholder line, never a file (ruled); a `resource_link` one text line
naming the URI; `structuredContent` carried verbatim, and serialized into
the text when the server sent no text.

## Prompts and resources are documents

Beside `tools`, each server's `prompts` and `resources` are listed once at
load and curated into the plane's `{name, description}` documents on the
SERVER's row: `<server>-<name>` (lowercased, non-alphanumerics folded to
`-`; the same hash rule when that changed the name or overran 64). A prompt
with a required argument, a listing with no description or one over 1024
bytes, a resource whose listing names a non-text non-image `mimeType`, or a
name a sibling already took is not announced and is listed `skipped:` with
its reason; a resource with no listing `mimeType` is announced and the read
decides. The load is the address's `skill` tool (`skill {name}`): a prompt's
messages as text (an `assistant:` line where a message has that role), a
text resource verbatim, a binary image resource as a capture, a name the
server no longer holds `skill_unknown`, a load that asks for input
`skill_unavailable`. Documents ride the runner address for a stdio server
and the agent address for an http one; on the agent address this gem
registers the plane's `skill` itself.

## The CLI

```
rho mcp              # every server: state, pid/pgid, protocol, identity; each tool with its
                     # lowered bytes and profile; skips with reasons; documents; env/header NAMES
rho mcp probe NAME   # connect from the CLI (no daemon) and print what NAME would announce: every
                     # tool, prompt, resource and template with its bytes, non-printables ESCAPED,
                     # $ref/$defs/allOf/anyOf/oneOf flagged, the config sentence the daemon would
                     # list it down with; torn down before the verb returns
rho mcp enable NAME  # write the row's switch on into settings.json (`"enabled": true` — the shipped context7's
                     # partial row, or one more member of yours); apply to a running daemon immediately
rho mcp disable NAME # the switch off: listed `disabled — rho mcp enable NAME`, never connected, never announced
rho mcp login NAME [--no-browser]   # authorize rho with NAME's authorization server: the URL is printed,
                                    # then your browser opens it (a browser that did not open is said; open
                                    # the URL by hand — rho keeps waiting); --no-browser: print only, paste
                                    # the redirected URL back; a server that answers anonymously but
                                    # publishes its authorization server is logged in to as optional;
                                    # tokens land in RHO_HOME/mcp/credentials/NAME.json (0600)
rho mcp logout NAME                 # forget NAME's tokens and registration
```

The daemon's route is `GET /mcp`; its document carries each row's `auth`
(a kind, a state, a reason, an issuer, a scope, a clock, whether a refresh
token is held, whether the authorization is optional — never a value), and
`rho mcp` prints an OAuth row's `auth:` line from it — or, with NO daemon,
from the settings rows and the credential files alone: the one place a
person checks logins before a boot. A login made through the
optional-authorization shape (a server that answered anonymously but
publishes its authorization server — Context7's) is marked in the
credential file, and the line says so: `oauth — logged in (…; refresh token
held; optional: the server answers anonymously too)`. There is no `rho mcp
sync`.

## Secrets

`${NAME}` in `env` and `headers` is expanded once at load from the daemon's
environment — the door that keeps a token out of the file. Values are never
logged or printed: log lines name keys, `rho mcp` prints `FX_TOKEN=•••` and
every header as `Name: •••`. Redaction is BY VALUE: every expansion, every
header value, and a literal typed under a credential-shaped `env` key
(`KEY`, `PASSWORD`, `SECRET`, `TOKEN`, `CREDENTIAL`) is a secret, each
replaced with `•••` (longest first; values under 8 bytes excepted) on the
stderr tail, every transport error, every failure sentence and notice, every
`mcp.*` log line and the probe's output — then the SDK's own family
redaction on top. The residual: a secret the server read from its own
config and echoed on stderr rides the capped tail.

OAuth tokens live in `RHO_HOME/mcp/credentials/<server>.json` — one file
per server, 0600 under 0700, refused if wider — and never in settings, a
log line, `rho mcp` or a result: the current and every previous access and
refresh token this process saw join the by-value redaction of every surface
a model or a log reads. The daemon never logs in: a server with no tokens
is listed `down: needs login` and every call to it fails naming `rho mcp
login NAME`; a renewal that fails is retried at the next call, not a login.
Authorization flows remain serialized after a caller is canceled, including
across a reconnect of that connection. The bounded HTTP worker may finish
later; a sibling cannot spend the same in-flight refresh token and clear a
valid rotated pair.

## Not built, on purpose

Resource subscriptions and every `list_changed` (the cache bomb by another
door); sampling and roots (deprecated by the spec, and a model caller behind
the kernel's back); elicitation and `input_required` handlers (the kernel's
`ask` is the one human door); a server's `instructions` in any model's
context (the probe prints it); a reconnect supervisor, a demultiplexing
stdio reader, a sanitizer, a transport of ours; a proactive token refresh
(the gem refreshes on the 401); Client ID Metadata Documents (rho serves no
HTTPS document); token revocation on logout; a login performed by the
daemon (it has no person to ask); a confidential client (`client_secret`),
a configured `scope` and a `resource` override (no reference carries them
in config; each returns with a server's evidence). The HTTP client runs on
Faraday's DEFAULT `net_http` adapter: httpx's Faraday adapter hands the
SDK's `on_data` no `env` and degrades its SSE path.

## Tests

```sh
bundle exec rake            # minitest + rubocop + rbs validate
```

An in-process `MCP::Server` behind a fake transport carries the naming,
settings, curation, mapping, redaction, restart and document tables; one
REAL child (the gem's fixture server under this gem's own bundle) proves the
group, the replaced environment, the watcher, the ladder, two concurrent
calls serialized and a cancelled call torn down and restarted; one loopback
streamable-HTTP server under puma proves the SDK's SSE path on `net_http`,
including a handler that holds the stream open after its final response and
a legacy session that answers 404 once; one mock authorization server +
resource server under puma (`test/support/oauth_fixture.rb`, the e2e
fixture's `oauth` entry mounts the same app) carries the store, the
classifier, both provider halves, the loopback listener, the login verb
and the daemon's refresh, renewal-failure, refusal, step-up and recovery
paths against rho's real `Rho::StateFile` (loaded from the sibling
checkout). The world journeys are `e2e/test/mcp_tools_test.rb` (the stdio
and http halves, the documents) and `e2e/test/mcp_oauth_test.rb` (the OAuth
path through `exe/rho`: the same mock authorization server under the e2e
fixture's `oauth PORT TTL` entry, the browser stubbed by `$BROWSER`, the
login, the refresh, the renewal failure, the refusal, the step-up, the
paste, no daemon, the negatives); the paid lanes against real public
servers are `e2e/test/live_mcp_test.rb` and the MANUAL
`e2e/test/live_mcp_oauth_test.rb` (`E2E_LIVE=1 E2E_MCP_OAUTH_URL=<url> rake
live_mcp_oauth`: you click consent in your browser).
