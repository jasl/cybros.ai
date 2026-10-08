# rho-t3

An optional rho extension for delegating coding assignments to Codex, Claude Code
and other configured coding agents. Users choose the coding agent and, when
needed, a model for that assignment. T3 is the internal service adapter; it owns
the native session, checkout, subagents and browser tools. rho owns the Nexus
task, conversation, questions, cancellation and returned artifacts. This adds
no forwarding model invocation.

The configured T3 service is an independent coding delegate. Nexus evaluates the
delegation tool call and owns its task lifecycle; native operations follow T3's
and the provider's execution and permission policies. Some operations have no
identifiable approval callback. This integration supports that native behavior
and applies rho's callback checks wherever the native adapter exposes enough
information. It does not provide per-operation Nexus approval-rule parity.

The package adopts the authenticated Effect RPC interface inspected at
[T3 revision 3dfe373](https://github.com/pingdotgg/t3code/tree/3dfe373fddb966101371805b0b102ae5af75b15b),
whose server package reports `0.0.45`. The T3 contracts package is private, so the
Ruby bridge adopts provider discovery, five work request shapes and the finite unary Effect RPC wire
format. It requires **orchestration protocol 2**, checks that version on each
connection before any business request, and refuses incompatible servers. The
published stable `0.0.45` uses protocol 1 despite the matching package version.
The official `0.0.46-nightly.20261006.2752` build uses protocol 2 and the same
adopted contracts as the inspected revision. No reference checkout or JavaScript
dependency is loaded at runtime. Later protocol changes may require an update.

## Installation and configuration

The repository distribution bundles `rho-t3`. Its image's `toolchains` and
`browser` targets also install exact manifest-pinned versions of T3, Codex and
Claude Code. The smaller `rho` target and bare-metal installation need the native
programs installed separately. For example, with Node 24:

```sh
npm install --global t3@0.0.46-nightly.20261006.2752 @openai/codex@0.160.1 @anthropic-ai/claude-code@2.1.292
```

The plugin is disabled by default and its descriptor is visible in rho Settings
without starting native programs. Configuration has one owner, `RHO_HOME/settings.json`:

```json
{
  "plugins": {
    "rho.t3": {
      "enabled": true,
      "configuration_version": 1,
      "configuration": {
        "server": "local",
        "listen_port": 3773,
        "token_env": "RHO_T3_TOKEN",
        "project_id": "PROJECT_ID_FROM_T3",
        "default_agent": "Codex",
        "workspace": { "type": "root" }
      }
    }
  }
}
```

Use `server: "local"` to start an owned foreground T3 process in rho's execution
environment, or `server: "host"` with `url` to connect to an independently managed
service. Local mode derives `http://127.0.0.1:LISTEN_PORT`; `url` has no effect there.
Local startup must launch the configured service successfully before its tools
become available. A missing runtime, occupied port, or failed startup leaves the
plugin inactive with repair guidance; core settings remain available for a retry.
Host mode never starts a native program or copies provider credentials. Its URL
must be an HTTP service origin without credentials, path, query or fragment.
A container can use `http://host.docker.internal:3773` for a reachable host service;
the host service must listen on an interface reachable from that container.

Local mode keeps native files under `RHO_HOME/plugins/rho.t3/`: `server` is T3's
base directory, `codex` is `CODEX_HOME`, and `claude` is `CLAUDE_CONFIG_DIR`.
Anthropic profiles use `claude/anthropic`. rho's own `HOME` remains unchanged.
The native provider configuration is seeded once; subsequent native edits and
login rotation remain the native programs' responsibility. The owned service
starts without a project or bearer, so setup can finish. Coding tools remain
unpublished until URL, bearer and project are configured. Status describes
configuration/process readiness; it does not establish a successful model call.

Local configuration changes, disable and removal require a daemon restart.
The active service and accepted work retain their old configuration until then.
The configuration API returns a successful save with `saved: true`,
`applied: false`, `published: false` and `restart_required: true`; this means
the edit is persisted and waiting for restart. Ordinary CLI commands print that
result. The stack's `t3` setup and project commands then restart rho automatically.
Host changes use the normal extension replacement path. Stopping one coding
assignment never stops the shared local T3 service.

## Docker setup

In an installed stack:

```sh
./cybros t3 local
./cybros t3 login codex
# Alternatively: ./cybros t3 login claude
./cybros t3 create /home/runner
./cybros t3 check
```

`local` enables the plugin, issues a dedicated bearer using native
`t3 auth session issue --base-dir ... --token-only`, saves it privately, and
restarts rho. Repeating it preserves the existing bearer. `create` first lists
native projects and reuses an exact path match; after an uncertain response it
lists again before considering another create. Paths refer to T3's execution
environment. To select an existing project instead:

```sh
./cybros t3 projects
./cybros t3 project PROJECT_ID
```

Project selection saves through the same plugin configuration API and the stack
wrapper restarts rho to apply local settings. Host mode accepts the explicit URL
and prompts for a bearer issued on the host; it leaves that host's native state alone:

```sh
./cybros t3 host http://host.docker.internal:3773
```

Docker keeps native environment credentials in the single private file
`RHO_HOME/plugins/rho.t3/rho.env` (mode `0600`). The container entrypoint reads its
literal `KEY=value` lines without executing them. Both bind-mounted and named
rho home volumes retain it across container recreation; include the entire rho
home in backups. Supported names are `RHO_T3_TOKEN`, `OPENAI_API_KEY`,
`CODEX_API_KEY`, `ANTHROPIC_API_KEY` and `CLAUDE_CODE_OAUTH_TOKEN`.
Reading or replacing this file refuses another owner or any group/other access;
stricter owner-only modes remain valid. If permissions were widened, inspect the
exposure and explicitly restore `chmod 600` before retrying; setup never hides it
by silently repairing the file or rotating its bearer.
`./cybros t3 secret NAME` reads a value privately from the terminal or stdin and
restarts rho. Secrets are absent from the plugin schema and ordinary status.

Codex login uses its [native device authorization flow](https://developers.openai.com/codex/auth/)
and file-backed credentials under the same `CODEX_HOME` as T3. For API-key login,
pipe the key to `./cybros t3 login codex --api-key`; the wrapper never places it
in argv. Claude uses [`claude auth login`](https://code.claude.com/docs/en/cli-reference)
in the same configuration directory; over SSH or in a container, open the printed
URL in your local browser and paste the returned code when asked.
[Claude API-key authentication](https://code.claude.com/docs/en/authentication)
can instead use `./cybros t3 secret ANTHROPIC_API_KEY`.

For standalone Compose, run `/opt/rho/libexec/t3-setup local` using `compose exec`
as the image's default UID, then `compose restart` that rho service. Run later
commands through `/opt/rho/libexec/docker-entrypoint t3 ...` so they read the same
private environment file. For bare metal, use `rho extensions configure rho.t3
'[{"op":"set","path":["server"],"value":"local"}]'`, then `rho extensions enable
rho.t3`, `rho t3 token`, and provide that bearer to the daemon environment before
restarting. Native login/project/check commands are the same `rho t3` verbs.

`rho t3 status` is offline. `rho t3 check` verifies authenticated protocol-2
service access, project availability and the reported provider directory; it
does not invoke a model. Provider authentication and a real coding assignment
are separate checks. Expired or revoked bearers require a new operator credential;
failed mutations are never retried automatically.

`workspace` accepts native `root`, `existing_worktree` with `worktreePath`, or
`worktree` with `baseRef` and optional `branch`. Accepted work captures its
provider/model and workspace. Continuation refuses changed connection settings,
native model/provider, branch, worktree or permission mode. `default_agent` only
applies after rho chooses to delegate and does not force delegation.

## Choosing a coding agent and model

`coding_work {action: "agents"}` reads the service's current provider directory.
It returns human-readable agent names, readiness, model IDs, names, aliases and
the native default model. The directory is read on demand and is not copied into
rho settings. Listing it does not start a coding assignment or refresh native
model discovery. A provider marked ready by the service is selectable; this is
not proof that every listed model can successfully run a request.

An explicit `agent` selects that coding agent, and `model` must match a model ID,
name or alias in that agent's directory. The adapter rejects unavailable or
ambiguous choices before creating a native thread. It never sends an arbitrary
Nexus model reference to a different harness. Configure custom models in the
native service so they appear in its directory. When several instances of one
agent exist, give them distinct display names, such as `Personal Codex` and
`Work Codex`, and choose that name.

Without `agent`, delegation uses `default_agent` when configured, or the sole
ready agent. Otherwise rho must choose from the discovered list. Without
`model`, it uses the native directory's standard default, first standard model,
or first listed model; an empty directory is refused. These are defaults for a
delegation already chosen by rho. For an unspecified user request, rho can use
its own tools or choose a suitable coding agent. The parent remains responsible
for coordinating the work and checking its result.

Selections are local to the new work. They do not change settings, the parent
conversation's model or another assignment. Continuing a `work_id` keeps its
original agent, model and workspace even after the configured preference changes.
Omit `agent` and `model` when continuing; supplied values must match its saved
agent name and exact model ID. Use new work for a different selection.

## Work and ownership

`delegate_coding {prompt, agent?, model?, title?, work_id?}` starts an assignment, or continues a
settled assignment in its original T3 thread. It waits for the latest native run
and active native subagents to settle. Use the existing `code` background-work
operation when the main conversation must stay available:

```javascript
const work = tools.delegate_coding({agent: "Codex", prompt: "Fix the parser and run its tests.", title: "Parser repair"});
await nexus.background({operation_key: work.operation_key, lifetime: "conversation", wake: "auto"});
text("The coding result will arrive when ready.");
```

Use the callable tool name in the current declaration if an adaptation supplies
another spelling. Background work uses the existing Nexus ownership transfer and
result delivery. The extension requires a conversation-owned task on an agent
address; standalone tasks and runner-only mode are refused.

Delegation uses an ordinary tool claim with a one-hour renewable window. Waiting
for a native result or a Human answer keeps the same live execution and claim;
the runner renews its deadline independently of progress output. Process loss
does not restart that execution automatically. Reconcile the saved work ID before
deciding whether to continue or stop the native work.

`coding_work` supplies these conversation-scoped actions:

| Action | Input | Behavior |
| --- | --- | --- |
| `agents` | none | Discover coding agents, readiness and supported model choices. |
| `list` | none | List retained work IDs, titles and accepted agent/model selections. |
| `observe` | `work_id` | Read current native state, workers, questions and reported checks. |
| `steer` | `work_id`, `prompt` | Send input to its active native run while the original Nexus task is live. |
| `stop` | `work_id` | Interrupt the native run with queue holding and cancel its exact owning Nexus task, including pending questions. Observe separately to confirm settlement. |
| `forget` | `work_id` | Release a settled continuation after its owning Nexus task has ended. |

One bounded `rho.t3` conversation-store entry retains thread/message command
coordinates, the task owner and accepted environment. It is a continuation, not
a second result database or a mirror of native execution status. The existing
Nexus store limit applies across the host's namespaces; forget old settled work
when slots are needed. Unknown or unreachable native work cannot be forgotten
through this tool. Forked conversations cannot control copied source handles.

A lost launch response is reconciled by its preallocated thread and message IDs.
A created thread without the accepted initial message remains uncertain; rho
does not launch a replacement. Continue and steer similarly retain their message
coordinate before sending. Never retry by starting another work item merely
because a transport response was missing.

## Questions, permissions and Stop

Native questions become ordinary durable Nexus questions owned by the delegating
task. The task keeps its claim while waiting so its existing cancellation path
still owns the native work. Single-choice answers retain the provider's option
value; multiple-choice questions request a JSON array of labels. After the Human
answers, rho re-reads the callback's current native resumability before sending
the answer. Reading an old projection after a T3 restart does not establish that
a live callback survived.

The bridge requests `approval-required`. Its approval responses never select
`acceptForSession` or `acceptAlways`. Command and edit requests must identify the owning native action;
rho applies its existing dangerous-command and protected-installation Guard
before asking for a one-shot decision. Missing command/edit identity and requests
explicitly tagged as `permission` or `mcp-elicitation` are declined. A Human answer
cannot override a Guard refusal. Approval prompts include the identified native action.
Codex can also surface consent as a generic user-input question without the
original action or consent type. The bridge cannot distinguish those questions
from ordinary questions, so it does not guarantee refusal of every MCP consent request.

These checks apply to callbacks that T3 exposes. `approval-required` selects the
native mode; it does not ensure that every native operation reaches rho's Guard.
Nexus approval rules for the enclosing task are not translated into the native
provider's policy. Native work may complete without any approval callback, and
rho returns its reported result without claiming that each operation was
individually approved. The same independent-delegate boundary applies to native
subagents, browser tools and MCP integrations.

Cancellation checks run during native polling, RPCs and question waits. Stop
targets the retained thread and native run. `coding_work stop` also cancels the
saved Nexus owner task so an unanswered Human question cannot keep the delegation
waiting. It can still interrupt orphaned native work after that owner has ended.
A failed Stop reports that it could
not be confirmed and preserves the handle for reconciliation; it does not claim
remote work ended. The ordinary Nexus task/claim rules still fence late commits.

## Results and verification

Completion returns the coding agent, model, work ID, native assistant text,
command exit codes/output and worker results. The model is the selection reported
by the current native run, not independent provider attestation of an underlying
model. Native thread, project, provider-instance and callback identifiers remain
inside the adapter's records and diagnostics. It fetches command output omitted from a projection and captures a JSON
report plus the native thread diff through the existing tool-result upload path.
Unfetchable command logs retain `outputOmitted`; an unavailable diff is an
explicit report limitation. Text shown inline is truncated by rho-runner, while
captures retain the fetched content. These are the native agent's reported
checks, not an independent correctness verdict. The projection endpoint returns
a bounded native history window, so older conversation text may be absent.

Each Ruby RPC exchanges the configured bearer for a WebSocket ticket and opens
a fresh socket using Effect Request/Exit frames with `orchestrationProtocol=2`.
It reads `server.getConfig` on that socket and confirms protocol 2 before sending
the business request. The waiter reads a projection, handles exposed callbacks,
then sleeps one second before the next read. There is no shared socket or event
subscription. Credentials stay in process memory and authenticated transport,
never process arguments or saved continuations. Ticket redirects and transport
retries are disabled. Ticket bodies are bounded to 64 KiB, individual WebSocket
frames and complete fragmented messages to 4 MiB, ticket requests and socket
opening to 10 seconds each, the RPC exchange to 20 seconds, and the entire call
to 30 seconds. Compression is disabled; the framing library checks frame lengths
before reading their payloads. Cancellation closes the current HTTP or WebSocket
exchange while preserving the retained work handle for reconciliation.

From this package directory, local verification is:

```sh
bundle install
bundle exec rake
bundle exec rake build
```

The gate runs Ruby lifecycle/ownership regressions, RuboCop, RBS validation, and
auth/Effect-wire tests against a real loopback HTTP/WebSocket server, including
an ordinary runner worker thread, both cancellation waits, incompatible protocol
preflight, failed mutations without retries, heartbeat frames and bounded
responses. Selection tests cover available combinations, explicit unsupported
choices before launch, per-assignment overrides and unchanged accepted work after
default changes. Ruby fixtures cover ordinary questions,
identified one-shot approvals, Guard refusals, callback expiry and completion
without an approval callback. They prove the adapter's behavior for those
inputs, not which callbacks a real provider emits. The runner package separately
tests question receipt reconciliation and cancellation under the original claim.

The repository's `e2e/test/rho_t3_test.rb` separately exercises real Nexus and rho
against an authored external T3 wire server. It covers background delegation,
an ordinary question held open for 35 seconds while the main conversation and
`coding_work` list/observe/steer remain available, identified approvals and
readable result/diff captures. It also covers daemon restart, explicit continuation
in the original environment, and both task Stop and `coding_work stop` canceling
the exact pending question and native workers. The first wait retains its original live task, native run and
daemon process. That test establishes the complete integration path for the
scripted native behavior. Native reported checks remain separate from independent
verification of the resulting code.

A focused real-provider check on 2026-10-07 used T3
`0.0.46-nightly.20261006.2752` through Nexus and rho, with Codex and the per-call
model selection `gpt-6.1-sol`. The native run reported that same selection,
completed a small Ruby repair, and exposed five reviewed one-shot approval
callbacks. The original three tests passed independently, and the resulting
checkout contained only the intended unstaged `slugify.rb` change, with no
staged or untracked files. The JSON report and actual diff were fetched through
Nexus captures. Native settlement was checked and the temporary session revoked
afterward. This check establishes that assignment's integration and result; it
does not establish performance, parity across providers, or approval coverage
for native actions that expose no callback.
