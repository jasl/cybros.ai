# Repository Rules

**Applies to:** every project, including shared Ruby style.

## Scope And Naming

This repository (`cybros-ai.alt2`) is a ground-up rewrite of `~/Workspaces/cybros-ai.alt`. Treat
each top-level project directory as an independent project unless a change is explicitly shared.

- `Cybros` is the formal product/brand name; `cybros.ai` is the planned primary product domain.
  The default installation display name is `Nexus` (owner decision 2026-07-19, `Setup::DEFAULT_ACCOUNT_NAME`).
- `Nexus`/`nexus` is the kernel: component, project, module, directory, and namespace identifier
  (the old repo's `CoreMatrix`, renamed). Agent-facing protocol text calls Nexus the `platform`
  unless a concrete resource name is clearer. The Cybros/Nexus naming theme is StarCraft II
  Purifier lore — naming context, not architecture.
- Credential token prefixes use the `cybros` tag (`sk-cybros-api-v1`, `sk-cybros-session-v1`;
  `nexus/app/models/access_token.rb`, `session.rb`) and digest salts the `cybros/<model>/<field>`
  form. Tool names have three spellings on the wire, none a brand prefix: a kernel tool's
  canonical `source.category.name` (`nexus.memory.read`) beside its short wire alias
  (`memory_read`; `nexus/lib/nexus/tool_registry.rb`), an executor tool's short name (`bash`,
  `read`), and an MCP tool's `mcp__<server>__<tool>` (`rho-mcp`'s `naming.rb`); a name resolves
  to one providing authority (`.ai/boundaries.md`, *Product Boundaries*, the four-sources rule).
- `cybros_agent` (`CybrosAgent::`) is the single Ruby gem merging the old SDK and rho-core agent
  runtime. `httpx` is its one runtime dependency (the DeviceFlow transport); the WebSocket realtime
  channel is an optional module that runs inside an `async` reactor and requires the consumer to
  supply `async-websocket` (`sdks/ruby/lib/cybros_agent/realtime.rb`).
- Plan and phase labels such as `Foundation`, `F1`, or a roadmap stage are planning metadata only.
  They never appear in application constants, migration names, tables/columns, routes, jobs, logs,
  or public contracts. Permanent names describe the concrete domain purpose they serve.
- Public technical manuals and source comments must stand on their own. Do not cite internal
  specs, plans, phase labels, decision numbers, or dated owner rulings there; state the applicable
  behavior, invariant, reason, or limitation in place. External protocols, library documentation,
  and other external sources may be cited. Ordinary navigation between public manual pages and
  references to concrete code symbols remain useful; neither substitutes for explaining a rule.
  Historical development records stay separate until the owner retires them after feature
  completion (owner direction, 2026-09-20).
- `task` names one unit of work owned by a loop (or another kernel owner); an inbox row is that
  task delivered to an executor, never a second noun — no `Task` delivery plane, no `Assignment`
  (owner ruling R1, 2026-09-05; supersedes the 2026-08-30 R1 naming reservation).

## Active Projects

- `nexus`: the kernel and the gateway (`.ai/boundaries.md`, `.ai/nexus.md`) — a Rails service
  (Rails main branch, Ruby 4.0.7, PostgreSQL multi-DB with the solid trifecta) and current rewrite
  focus. Licensed O'Saasy (`nexus/LICENSE.md`); the rest of the repository defaults to MIT.
- `sdks/ruby`: the `cybros_agent` gem — API client plane plus agent-framework plane under one
  `CybrosAgent::` namespace. **Stateless**: it owns protocols, not storage — no files, no
  directories, no logs. Anything that must persist is reached through a port the application
  implements (spec 40 Non-goals, D5).
- `e2e`: product-level E2E harness for cross-project public-contract flows.
- `agents/`: agent applications. `agents/rho` is rho, the first Nexus consumer: a Cowork-type
  agent, which must be a strong coding agent by the standard of codex, claude-code and opencode
  (owner mandate 2026-09-04) — across these gems:
  Agent business persistence belongs in Nexus's storage infrastructure wherever possible
  (owner clarification 2026-10-01): database memory, opaque scoped stores for program state,
  and uploads for artifacts. File-style memory tools address database rows, never memory
  files. Local filesystem operations are the Runner's role for coding and Cowork work;
  an Agent may also play that role, as rho does in full mode. Connection bootstrap,
  credentials and disposable local caches are distinct from durable business state.
  - `rho`: the agent application — a connected-identity daemon plus its CLI (`exe/rho`, the
    single entry point). Its member bearer is reached by the same-host CLI and, through the console-code
    handoff, by rho's own webui — the conversation-level UI the owner kept (2026-09-05); the daemon
    proxies no account administration (model/provider configuration and credentials belong on Nexus;
    read-only discovery of available models remains on the Agent API). The terminal
    `rho setup` may use cmctl's separate Human/admin session for first-run settings;
    that session never becomes a daemon/member credential (owner OOBE request, 2026-09-29).
    The daemon reads its in-process runner's surface locally; a separate runner's it reaches through
    Nexus's relay (S-E2, 2026-09-13: `Ops.relay` / `Processes.list` / `Processes.log` dispatch on
    `own_runner?`; the verbs `rho relay`, `rho fetch`, `rho ps` / `rho logs`;
    `.ai/boundaries.md`, *The Human Console And The Gateway*). Its identity is the program constant plus a per-home instance id
    (`rho.<instance_id>`, derived once at `prepare` and read by `Connection#instance_id`,
    `lib/rho/connection.rb`), and it
    ships the tool-style presets `nexus` / `claude` / `codex` as declaration aliases over the
    kernel's `task`/`ask` (the SDK pack `sdks/ruby/lib/cybros_agent/model_adaptations/presets.yml`
    applied by `Rho::Adaptations` — capabilities II §3.6; the former `lib/rho/tool_style.rb` of S-N
    step 3 is gone) — the kernel's texts carry
    tool-name macros, so a preset re-spells names and never the kernel's bytes.
    Shape (owner 2026-09-05, idiom audit): rho's core is the SDK wrapper, the extension loader
    and a handful of verbs; every other route, operator verb, background task or tool registers
    from an extension through `Api#register_route`/`register_command`/`background`, and no
    extension reads a process-global (the process table rides `ToolEnv#processes`, `nil` for a
    standalone runner).
  - `rho-runner`: the runner — eleven tools under `lib/rho/runner/tools/`: the seven
    environment-bound tools (`bash`, `read`, `write`, `edit`, `ls`, `find`, `grep`) executed where
    the files are, `skill` (a checkout's skill load), and the runner's own capabilities as TOOLS a
    person requests through Nexus's relay (S-E2, 2026-09-13) — announced without a description or
    a schema and hidden by name from every model, the shape `.ai/boundaries.md` (*Product
    Boundaries*, "The runner's capabilities are TOOLS") explains: `checkpoints` and
    `world_restore` (the world record and its restore) and `files_bytes` (`Rho::Runner::Files`,
    moved down from rho — the same bytes and classification the daemon's `/files/bytes` door
    serves locally; always a capture, uploaded by `TaskRun`'s one upload site and linked in the
    commit) beside rho's `process_log`, both announced without a description or a schema, both
    hidden by name from every model on the agent side. It is deployable on its own —
    the same gem in `RHO_MODE=runner` through the one `exe/rho`, in a container or the cloud, on
    a runner credential (`rho-runner.<instance_id>`) — and in full mode rho pairs a runner-kind
    row on the device flow's combined A+B grant (`rho.<instance_id>` for the runner half) and
    names it on every host it opens (S-D step 2, cb415c44): the runner row announces the
    environment tools and follows the executor inbox on its transport credential, never by
    lending rho's member bearer;
    switching runner is an explicit handoff (owner mandate 2026-09-04, ruling R2 2026-09-05;
    `.ai/boundaries.md` Product Boundaries).
  - `rho-webui`: the independently packaged browser page (owner 2026-09-28). It registers
    its static root through `Api#register_webui`; full/agent modes select it by default,
    while runner mode stays headless and `api_only` disables serving. The daemon owns
    static serving, authentication and control APIs. The shipped page needs only Ruby
    on the server; browser JavaScript has no Node/Deno runtime dependency.
  - `rho-ingress-telegram`: the Telegram channel beside the WebUI. It owns its bot token,
    long polling, allowed users/groups, chat/topic routing, control commands and message
    delivery through the shared rho Core. Nexus owns accepted inputs, ingress speaker
    attribution, conversation history and execution; the plugin adds no gateway or model
    execution path. It runs when explicitly enabled in full/agent modes.
  - `rho-browser`: a real browser for the model — six Playwright tools (`navigate`, `snapshot`,
    `click`, `type`, `evaluate`, `screenshot`) loaded as a runner extension.
  - `rho-mcp`: the MCP client — the official `mcp` gem's `MCP::Client` over stdio (a server's
    tools ride the runner row) or the gem's streamable-HTTP transport (an http server's ride the
    agent row), OAuth login from the CLI process (`rho mcp login|logout NAME`, the loopback
    listener inside it), each tool announced VERBATIM under `mcp__<server>__<tool>`
    (`naming.rb`), prompts and resources curated into documents through rho-runner's plane seam
    (the address's `skill` row), `rho mcp` / `rho mcp probe NAME` beside them; loaded as a runner
    extension (capabilities II §3.4, 2026-09-15; the OAuth half capabilities III A, 2026-09-16).
  - `rho-web-tools`: a web reader — one tool, `web_fetch {url}`: httpx with its SSRF filter behind
    `UrlRule` and same-site redirects, the nokogiri/reverse_markdown render cut at 1 MiB
    (`RENDER_INPUT_BYTES`), private hosts refused unless rho's opaque `web` settings key sets
    `allow_private_network: true`; `rho web fetch URL` beside it; loaded as a runner extension
    (capabilities III B, 2026-09-16).
  - `rho-acp`: rho as an ACP agent — the Agent Client Protocol's wire (ndjson framing, JSON-RPC
    ids and `$/cancel_request` both directions, the method names) and `rho-acp`, the process an
    editor, the registry or harbor spawns on stdio: a PEER SURFACE over `Rho::Core` beside the
    CLI and the WebUI, never an extension (no `rho_extensions`, no `register(api)`), with its own
    exe. The implemented surface serves session creation, load/resume/close, prompt, mode and
    configuration changes, authentication and cancellation; the shared wire lives in this gem
    (`rho-acp/lib/rho/acp/`, ACP design r2; the mandate's 2026-09-17 packaging ruling).
  - `rho-acp-client`: rho as an ACP client — `delegate_agent`, one child per (conversation,
    agent) from the `acp_agents` rows, its permission requests relayed to rho's own floor and
    never proxied, the management verbs and `GET /acp`; an extension gem in rho-mcp's shape
    (`rho/acp-client` → `Rho::AcpClient`, its own top-level name) that depends on rho-acp for the
    wire and on rho-runner. `register(api)` installs `delegate_agent` when enabled, the management
    routes and command, and child cleanup on host end and daemon shutdown (ACP design r2 §4).
- `cmctl`: a thin Human operator CLI over `cybros_agent`'s Platform client (owner-approved
  model-management slice, 2026-09-29). API Session login, provider/model discovery, API-key
  installation/removal, provider subscription authorization, lane enablement, individual model visibility
  and configure-once Account cost unit; no duplicated
  transport/OAuth code. Its re-runnable setup wizard also serves rho's terminal onboarding,
  using a process-local Human login and revoking it on exit without replacing the saved cmctl session.
  It owns its local session file; model execution stays on the member
  plane, and every Agent can discover the Account's currently available models there. rho exposes
  that read-only discovery. Human operators can also author provider connections and model
  definitions through the same Platform API, browser settings and terminal setup (owner-approved
  2026-09-30). The deployment catalog remains the base; ModelProviderPolicy owns the persistent
  overlay. Pricing is optional spending-estimate configuration, independent of recorded usage.
  Narrow owner-approved exception (2026-07-30): the Platform
  admin removal endpoint (`POST /api/v1/admin/users/{user_public_id}/removal`) is deliberately not
  surfaced by the `CybrosAgent` gem, so Agent applications gain no ergonomic or typed path to
  Platform administration. E2E drives it with a test-local JSON helper; `cmctl` is the other
  intended consumer (a command-local adapter versus a future operator-only client boundary stays
  deliberately undecided). This exception does not decide client ownership for unrelated future
  Platform APIs.

## Global Ruby Style

These rules apply to Ruby code in every top-level project. Framework-specific Ruby and Rails rules
belong to the owning project's instruction modules.

- Prefer expanded conditionals over guard clauses. An early return is appropriate only at the
  beginning of a method when the main body is nontrivial.
- Every `case ... when` includes an `else` with an explicit default, rejection, or programmer-error
  fallback; first-party project RuboCop configurations enforce this without requiring `else` on
  ordinary `if` expressions.
- Order class methods first, then public methods with `initialize` first, then private methods.
- Within each visibility section, order methods vertically by invocation flow so the file reads
  top-down from an entrypoint to the methods it calls.
- Use `!` only when a corresponding non-bang method exists; never use it merely to mark a
  destructive action.
- Comments complement code and public documentation in every project: explain a non-obvious
  reason, invariant, ownership boundary, or consequence near the implementation. Keep executable
  rules in predicates and tests; put development history in commit messages. Expand an internal
  specification's relevant clause instead of citing its number, and check the explanation against
  current writers and readers rather than copying the old wording.
- (idiom audit 2026-09-05) Wire input is normalized once at its parse boundary and trusted
  downstream in every project — no `is_a?`/`respond_to?` probes on values the code itself
  produced, options are keyword arguments rather than an `options = {}` bag with a key allowlist,
  and a value the code constructed is never discriminated by class (`event.dig("response",
  "error") || {}` after one `parse_json_object`, not `x.is_a?(Hash) ? x : {}` at each layer).
- (delta audit 2026-09-16) Where a constructed value's class IS the question — a refusal handed
  up in place of the row it stands for, a tagged tuple's arm — the spelling is pattern matching,
  `return policy if policy in Rho::Daemon::Refusal` for the one-arm guard and `case answer in
  Veto … in Rewrite(arguments:)` for the tuple, never `is_a?` and never `case … when Class`.
- (idiom audit 2026-09-05) A closed value is a `Data.define` — not a `Struct`, an `attr_reader` +
  `freeze` class or a hash-of-hashes — and its codec is written once as keyword `new`, `to_h` and
  `with` (`Envelope = Data.define(:status, :headers, :body) { def success? =
  (200..299).cover?(status) }`); a value's `from_h` (`new(**hash.transform_keys(&:to_sym))`) is
  the one-time ingestion normalizer .ai/backend-rails.md sanctions, and internal callers pass the
  Data, never the Hash. The one exception (architecture audit 2026-09-15, doctrine-13): a MUTABLE
  IN-PROCESS HANDLE — a row one fiber or thread stamps as it runs (`ModelRunner::Host::InFlight`'s
  `settled`, a pump's cursor, a queue slot) — is a `Struct.new(..., keyword_init: true)`, never a
  `Data` rebuilt with `with` on every stamp; it never crosses a boundary (no wire, no job argument,
  no result), and a value that does is a `Data`.

## Rewrite Direction

- The old repo (`~/Workspaces/cybros-ai.alt`) is a behavior oracle — what the predecessor did,
  consulted when a claim about past behavior needs checking — never the design baseline (owner
  mandate 2026-09-04; supersedes the 2026-08-17 "parity with the predecessor" default). The design
  baseline is the agent references (Reference Research), summarised and distilled into ONE
  semantically and functionally orthogonal capability set under the method in
  `docs/plans/2026-09-04-product-mandate.md`; the distilled set is
  `docs/plans/2026-09-05-capability-basis.md`. A difference from the references that is neither
  justified nor recorded is drift, and drift is a defect. Never re-derive the node-local execution
  era from git history.
- The goal is to solve the old repo's deferral-ledger problems from a whole-product perspective,
  not to port patches. Key pivots: no tenant layer — one Fizzy-shaped `Account` (founding specs);
  one task inbox — a distributed asynchronous task queue between Nexus and every executor role
  (agent application, runner, tools provider), the HTTP API the authority and Action Cable the
  push, claim then commit, its kinds not limited to tool calls (owner ruling R1, 2026-09-05;
  `.ai/boundaries.md`) — retiring the founding specs' directed task-delivery abstraction
  (publish, lease/renew, epoch fencing), which was never built; shared Ruby reading rules and
  Fizzy-first Rails style inside Nexus.
- All projects may take destructive changes: choose the correct design and the simpler maintainable
  system over compatibility with copied code, old APIs, old fixtures, or old local data. No
  compatibility aliases, fallback parameters, or adapter layers for old names.
- Product direction to hold in mind (owner mandate 2026-09-04): Nexus is a fat, complete,
  orthogonal kernel for building every kind of agent — coding/Cowork, personal, chat, role-play —
  an agent plugs in to get an agent's general capabilities from three primitives (Conversation,
  the bare-metal Agent loop, OneShot; `.ai/nexus.md`). Conversation is the unit a person has and
  the Agent loop is the engine inside a turn. Nexus is the gateway that relays every message among
  the components; three executor roles stand beside it, each a separate abstraction — agent
  application, runner, tools provider; Nexus sits on the public internet or a LAN and every other
  component polls it from the intranet. rho is the first consumer: a Cowork-type agent that must
  be a strong coding agent by the standard of codex, claude-code and opencode.

## Working Rules

- Run commands from the target project directory; keep changes scoped to the requested subproject
  whenever possible.
- Touching shared root files (`AGENTS.md`, `.editorconfig`, `.gitignore`, CI workflows, `.ai/*`)
  may affect all active subprojects.
- Prefer repo-grounded changes: verify old plans and reference claims against the live checkout
  before acting. Preserve unrelated dirty work (`.ai/git.md`).

## Development And Test Placement

- Keep Nexus development-only code minimal (owner clarification 2026-09-22). Prefer the owning
  project's `test/**` tree or top-level `e2e/**` harness for development, test, benchmark and
  diagnostic code, configuration, fixtures and artifacts. This is a placement preference, not
  a blanket ban: a small Nexus-local helper may remain when that is the simplest useful home.
  Conventional development configuration and setup tooling need no relocation for its own sake.
- Environment-variable import of provider API keys is a supported operator convenience for
  bare-metal/self-managed deployments, not inherently development-only code. Keep that import
  separate from development account founding, test fixtures and development billing defaults.
  A test invocation must not import real provider credentials merely because they are available
  in the environment.
- The converse matters: production behavior does not become test-only merely because a test or
  diagnostic invokes it. Reusable domain transitions, public/application commands, and
  production catalog loading that real runtime callers require remain in their normal production
  owners. Test-only case planning, launch orchestration, fixture installation and diagnostics
  prefer their owning test/E2E tree; any retained Nexus-local support stays minimal.
  In particular, E2E fake providers live under `e2e/support/**` as separately spawned processes;
  they are never mounted as Nexus routes or parsers.
- Runtime dependencies are one-way: E2E and project tests may boot and exercise Nexus, but Nexus
  boot/runtime code must never require, locate, load, or read `e2e/**`, `test/**`, test support, or
  real-call artifacts. A developer may use a short real-Provider diagnostic to inform an ordinary
  reviewed catalog/registry edit; the diagnostic output is not a promoted production projection,
  compatibility condition, or runtime input.
- Development/E2E tools optimize for fast, truthful feedback. Keep the smallest single-project
  implementation that exercises the current behavior; do not add environment attestation, source
  pins, artifact promotion/currentness protocols, dependency/hardware matrices, or generalized
  maintenance APIs unless the tool itself has become an explicitly approved product.

## Implementation Entry And Contract Delta

- Before implementing a subsystem, perform a scoped delta review of its owning contract — the
  capability-basis row (`docs/plans/2026-09-05-capability-basis.md`), `docs/agent-api/**` as the
  living contract of what is built, and the owning round plan — against the live code, schema,
  public contracts, and reachable workflows. Resolve stale assumptions and contract conflicts
  before choosing the implementation shape; do not implement prose mechanically.
- Preserve product invariants while treating contract text that over-prescribes implementation
  mechanics as revisable. Revise the owning contract rather than silently ignoring that text. If
  reachable product behavior or a public/domain contract must change, revise `docs/agent-api/**`
  before or with the implementation.
- When a change lands, synchronize any contract status or verification capture that the
  implementation made stale. Incidental code structure does not belong in the contract.

## Local Development

- Supported environments: macOS and Linux (Ubuntu 24.04 or comparable).
- Shared local-only test account: `admin@example.com` / `Passw0rd!`. Never in production, staging,
  public demos, durable fixtures, or security-sensitive examples.

## Reference Research

Reference checkouts hold reference-only material; consult them deliberately, never by default.
There are two trees, and one name collides: the old repo's `~/Workspaces/cybros-ai.alt/references/`
holds every reference below except `pi-web`, which is this repo's
`~/Workspaces/cybros-ai.alt2/references/pi-web`. Name the absolute path in any prompt that
mentions a reference; `/references/` is gitignored in both trees (`.gitignore:40`) and no workflow
under `.github/workflows` reads one.

The agent references — the design baseline (Rewrite Direction), each consulted for what it is
strongest at:

- `codex`, `claude-code`, `opencode`: coding agents — the loop, tools, approval, checkpoints.
  Where they agree the agreement is taken; where they conflict the conflict is analysed and the
  choice recorded (owner ruling 2026-09-02).
- `pi` (the agent, old tree): personal agent, and the minimalism Nexus is defined against
  (owner mandate 2026-09-04) — read for the loop's mechanics, never for its scope; `pi-web` (this
  repo's `references/pi-web`, `@jmfederico/pi-web`; owner ruling 2026-09-04): the web console.
  The old tree's same-named `pi-web` is a different project and is never read.
- `hermes-agent`: personal agent — terminal backends as runner prior art.
- `cherry-studio`: ChatGPT-style chat — message parts, providers.
- `SillyTavern`, `Risuai`: role-play chat — persona/character layering, lorebook, branch tree.

The Rails references (old tree):

- `references/fizzy`: the primary Ruby and Nexus Rails style reference (`AGENTS.md`, `STYLE.md`, and
  codebase). Account/Identity/User shape, concerns discipline, Eventable/Notifier pipeline, storage
  ledger, saas/ overlay.
- `references/once-campfire`: a small Rails-native reference for first-run Account creation,
  authentication/session flows, model-sized behavior, and database uniqueness as the final race
  winner.
- `references/discourse`: recipes for complex business logic — Reviewable queue, RateLimiter,
  Guardian, serializer hierarchy, MessageBus discipline, plugin registries.
- `references/gitlab`: recipes for scheduler/executor machinery — CI state machines, runner
  registration, job pickup, per-state reapers, partitioning, loose FKs. Engineering-principle
  research only; adapt discipline, never copy scale machinery or enterprise process.
- Old repo `docs/specs/*`, `docs/agent-api/v1/*`, `docs/superpowers/parity/*`: behavior oracle —
  what the predecessor did — never the design baseline; restate contracts in `docs/agent-api/**`
  and tests before porting implementation structure.
