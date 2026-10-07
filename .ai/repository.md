# Repository Rules

**Applies to:** every project, including shared Ruby style.

## Scope And Naming

Treat each top-level project directory in this monorepo as an independent project unless a
change is explicitly shared.

- `Cybros` is the formal product/brand name; `cybros.ai` is the planned primary product domain.
  The default installation display name is `Nexus` (`Setup::DEFAULT_ACCOUNT_NAME`).
- `Nexus`/`nexus` is the kernel: component, project, module, directory, and namespace identifier.
  Agent-facing protocol text calls Nexus the `platform`
  unless a concrete resource name is clearer. The Cybros/Nexus naming theme is StarCraft II
  Purifier lore — naming context, not architecture.
- Credential token prefixes use the `cybros` tag (`sk-cybros-api-v1`, `sk-cybros-session-v1`;
  `nexus/app/models/access_token.rb`, `session.rb`) and digest salts the `cybros/<model>/<field>`
  form. Tool names have three spellings on the wire, none a brand prefix: a kernel tool's
  canonical `source.category.name` (`nexus.memory.read`) beside its short wire alias
  (`memory_read`; `nexus/lib/nexus/tool_registry.rb`), an executor tool's short name (`bash`,
  `read`), and an MCP tool's `mcp__<server>__<tool>` (`rho-mcp`'s `naming.rb`); a name resolves
  to one providing authority (`.ai/boundaries.md`, *Product Boundaries*, the four-sources rule).
- `cybros_agent` (`CybrosAgent::`) is the Ruby gem containing the API client and agent framework. `httpx` is its one runtime dependency (the DeviceFlow transport); the WebSocket realtime
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
- `Run` is the public execution resource (`AgentRun` internally); `InferenceRequest` is a
  bounded sealed model request. A model invocation is an attempt, and a model round is one
  model Task within a Run. `task` names one unit of work owned by a Run or another kernel owner; an inbox row is that
  task delivered to an executor, never a second noun — no `Task` delivery plane, no `Assignment`.

## Active Projects

- `nexus`: the Rails kernel and gateway. Kernel and product ownership live in `boundaries.md`
  and `nexus.md`; stack/toolchain versions live in the project's manifests. Nexus is licensed
  O'Saasy (`nexus/LICENSE.md`); the rest of the repository defaults to MIT.
- `sdks/ruby`: the `cybros_agent` gem, containing the API client and agent framework under
  `CybrosAgent::`. It owns protocols, not storage: no files, directories or logs. Applications
  implement ports for persistence. The synchronous client remains loadable independently of
  the optional realtime reactor (`boundaries.md`, Package Boundaries).
- `e2e`: cross-project acceptance through public contracts.
- `cmctl`: the Human operator CLI over the SDK Platform client. It manages Human sessions,
  provider/model configuration, subscription authorization, model visibility and Account cost
  units through the same commands as Nexus settings. Its re-runnable setup wizard serves
  terminal onboarding with a process-local Human session, revoked on exit without replacing
  the saved cmctl session. It owns its local session file and duplicates no transport/OAuth
  implementation. Model execution remains on the member plane. The deployment catalog is the
  base; `ModelProviderConfig` owns the persistent overlay. Pricing estimates are optional and
  independent of recorded usage.

  The Platform admin User-removal endpoint (`POST /api/v1/admin/users/{user_public_id}/removal`)
  is deliberately absent from the SDK's typed resources. E2E uses a test-local JSON helper;
  cmctl is the intended operator consumer. This narrow client-surface exception neither grants
  authority nor determines the owner of unrelated future Platform APIs.

### rho Application And Packages

`agents/rho` is a Cowork agent and must meet the coding capability standard of Codex, Claude Code
and OpenCode. Its application-specific rules live here; `boundaries.md` owns the shared
persistence, credential, runner, console and settings contracts.

- Evolve by incubation: a running rho does not edit its own installation or protected state and
  configuration members. Its work root remains writable, including the default `<RHO_HOME>/work`.
  It develops and verifies a successor as a separately registered instance, then upgrades. This
  is removable application policy expressed by `Rho::RunDeclaration.self_modification_rules` through
  the kernel's approval rules, never a kernel ban on self-modification.
- Personal extension development uses the writable work root and the managed package operation.
  That operation copies local source/tests, explicitly checks a candidate, then prepares and
  selects an owned instance. It is the narrow allowance for changing installed extensions;
  ordinary file/shell tools still cannot edit protected installation/configuration members.
  Source, installed versions and assembly choices remain local and operator-backed-up. User
  documents, conversation records and business state retain their existing Nexus owners.
  Installed packages share the process Ruby dependencies; incompatible dependency versions or
  exclusive process-wide integrations report a restart requirement.
- The distributed Docker image preinstalls project language toolchains, Chromium and document
  processing tools. Versions belong to the installation manifest and dependency locks. This
  convenience adds no Node or Python boot requirement to bare-metal rho; optional tools report
  missing dependencies when invoked.

rho keeps core deployment settings and all plugin overrides in
`<RHO_HOME>/settings.json`, with static schemas and versions owned by each plugin.
New plugin private data uses `<RHO_HOME>/plugins/<id>/`; existing credential
stores retain their owned directories in the same home. The core plugin manager,
authentication, configuration migration and CLI recovery remain available when all
optional plugins are disabled. Disabled metadata discovery never evaluates a factory.
Current-file fallback is field-scoped; old formats use one forward migration before
normal loading. Runtime code consumes only current plugin configurations through
`Api#configuration`; it carries no previous-key aliases or parallel settings writer.

rho consists of these independently packaged surfaces:

- `rho`: the connected daemon and `exe/rho` CLI. Identity combines the program constant and a
  per-home instance id (`rho.<instance_id>`). The core wraps the SDK, loads extensions and
  supplies a small set of verbs; other routes, commands, background tasks and tools register
  through `Api#register_route`, `register_command`, and `background`. Extensions do not read
  process-global state; the process table is `ToolEnv#processes`, nil for a standalone runner.
  `nexus` / `claude` / `codex` tool-style presets are SDK declaration aliases applied by
  `Rho::Adaptations`. They change tool spellings through the kernel's macros, never kernel text.
  Side is rho's single conversation branch feature; there is no separate BTW product entry.
  Side defaults to ordinary writable tools and accepts a read-only narrowing, with normal
  approvals. Core exposes the capability independently of ingress so CLI and WebUI can share
  the same complete application surface. Reference snapshots are readable context, never
  newly produced replies or recoverable execution.
- `rho-runner`: filesystem/process tools, checkout skill loading, checkpoints and capture/restore
  capabilities executed where the files live. It runs separately in `RHO_MODE=runner` through
  the same executable, or in full mode as a second runner-kind executor beside rho's application
  address. Its credential is transport-only. Each accepted Runner call records its explicit
  target; a host's nullable default applies only to future authored calls with an omitted target.
  A Runner may serve multiple Agents within its assignment scope. Operator-facing capabilities are
  announced without model descriptions or schemas and hidden from model declarations.
- `rho-webui`: plain browser ES modules and CSS, with no build step or Node/Deno server dependency.
  It registers its page through `Api#register_webui`; full/agent modes select it by default,
  runner mode stays headless, and `api_only` disables serving. rho owns static serving,
  authentication and control APIs.
- `rho-ingress-telegram`: bot configuration, long polling, allowlists, chat/topic routing and
  delivery through the shared rho Core. Nexus owns accepted input attribution, history and
  execution. It is disabled by default; static configuration remains available through
  the core plugin manager. Polling and group-profile contributions require explicit enablement.
  GUI and CLI share the configuration owner and apply changes immediately.
  An IM chat/topic uses its selected Agent conversation for dialogue and task scheduling;
  Side and BTW are unavailable on this ingress. Telegram-specific restrictions do not remove
  Core capabilities from the future complete WebUI.
- `rho-browser`: Playwright browser tools loaded as a runner extension.
- `rho-mcp`: the official `mcp` gem client. Stdio tools ride the runner address; streamable-HTTP
  tools ride the agent address. OAuth login and its loopback listener belong to the CLI process.
  Tools retain `mcp__<server>__<tool>` names verbatim; curated prompts/resources become documents
  through rho-runner's skill plane. `rho mcp`, `probe`, `login` and `logout` expose management.
- `rho-web-tools`: `web_fetch {url}` and `rho web fetch URL`, using httpx, `UrlRule` SSRF filtering,
  same-site redirects and HTML rendering bounded to 1 MiB of input. Private hosts require the operator's explicit
  `allow_private_network: true` setting. It is a runner extension.
- `rho-codemode`: the `code` tool, JavaScript authoring instructions and a live VM
  that retains its state across recorded child observations. It serves every available agent and
  runner address through the runner's claim-scoped orchestration bridge; Nexus owns task
  acceptance and scheduling. All rho modes load it by default, including headless deployments.
  rho owns the `code_mode` request/conversation choice: an explicit request overrides the
  conversation's saved choice, which otherwise inherits `rho.codemode`'s configured
  `default` (`on`). Disabling the plugin withdraws its contributions. Off omits `code` and its
  authoring hints from new rho-authored turns; executor registration remains available for
  already accepted work. Nexus has no code-mode setting or product-specific admission branch.
  Named agents retain the same eligible Runner declarations, with a concrete target and exact
  schema for each callable. Their `code` invocation inherits that frozen tool authority.
- `rho-t3`: an optional external coding harness integration. Its Ruby client implements the
  finite T3 Effect RPC/WebSocket calls used for native sessions and callbacks.
  The enclosing Nexus task owns delegation, questions, cancellation and result capture; native
  thread references are bounded continuation data in its conversation store. rho boot does not
  require a running T3 service. Nexus authorizes delegation to the configured native harness; that harness
  owns its internal action policy. rho applies its Guard and one-shot Human decisions to the
  identified approval callbacks it receives. Native actions without callbacks and consent
  exposed as ordinary questions are an accepted integration limit, not arbitrary Nexus
  per-action rule parity. This does not change rho's own tools or the ACP client's approval floor.
- `rho-acp`: an ACP peer surface over `Rho::Core` beside CLI/WebUI, with its own stdio executable,
  not an extension. It owns shared JSON-RPC/ndjson framing, bidirectional cancellation and session,
  prompt, mode, configuration and authentication handling.
- `rho-acp-client`: an extension depending on rho-acp's wire and rho-runner. It owns
  `delegate_agent`, one child per conversation/agent from its `agents` configuration, management routes/verbs,
  and cleanup at host end and daemon shutdown. Child permission requests are relayed to rho's
  approval floor, never proxied as independent authority.

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
- Normalize wire input once at its parse boundary (`to_s`/`to_h`/`fetch`), apply one loud
  guard, and trust the result downstream in every project — no `is_a?`/`respond_to?` probes on values the code itself
  produced, options are keyword arguments rather than an `options = {}` bag with a key allowlist,
  and a value the code constructed is never discriminated by class (`event.dig("response",
  "error") || {}` after one `parse_json_object`, not `x.is_a?(Hash) ? x : {}` at each layer).
- Where a constructed value's class IS the question — a refusal handed
  up in place of the row it stands for, a tagged tuple's arm — the spelling is pattern matching,
  `return policy if policy in Rho::Daemon::Refusal` for the one-arm guard and `case answer in
  Veto … in Rewrite(arguments:)` for the tuple, never `is_a?` and never `case … when Class`.
- A closed value is a `Data.define` — not a `Struct`, an `attr_reader` +
  `freeze` class or a hash-of-hashes — and its codec is written once as keyword `new`, `to_h` and
  `with` (`Envelope = Data.define(:status, :headers, :body) { def success? =
  (200..299).cover?(status) }`); a value's `from_h` (`new(**hash.transform_keys(&:to_sym))`) is
  one-time ingestion normalizer; internal callers pass the Data, never the Hash. A mutable
  in-process handle is the exception: a row one fiber or thread stamps as it runs
  (`ModelRunner::Host::InFlight`'s `settled`, a pump's cursor, a queue slot) uses
  `Struct.new(..., keyword_init: true)`, never a
  `Data` rebuilt with `with` on every stamp; it never crosses a boundary (no wire, no job argument,
  no result), and a value that does is a `Data`.

## Design Direction

- Prefer convention over configuration in product behavior, implementation, and configuration.
  Define shared defaults once at the existing owner and author only differences; apply defaults
  for omitted fields while preserving meaningful explicit overrides.
- Build one semantically and functionally orthogonal capability set. Product boundaries live in
  `boundaries.md`; kernel mechanisms in `nexus.md`; application requirements in Active Projects
  above. Evaluate changes against these rules, current public contracts and the user's request.
- Solve whole-product needs through the existing owners: one Account trust domain, the Nexus
  kernel/gateway, three executor roles and one asynchronous task inbox with HTTP authority and
  Action Cable hints. External implementations may inform a decision but do not define the design.
- Before release, choose the correct, maintainable design over compatibility with previous code,
  APIs, fixtures or local data. Update writers, readers and contracts together. Follow
  `boundaries.md` for in-flight/historical state and the distinction between dead internals and
  unwired public capabilities; a lack of current callers does not erase an accepted requirement.

## Working Rules

- Run commands from the target project directory; keep changes scoped to the requested subproject
  whenever possible.
- Touching shared root files (`AGENTS.md`, `.editorconfig`, `.gitignore`, CI workflows, `.ai/*`)
  may affect all active subprojects.
- Ground changes in the live checkout and current task requirements. Verify assumptions against
  the owning code and contract before acting. Preserve unrelated dirty work (`.ai/git.md`).

## Development And Test Placement

- Keep Nexus development-only code minimal. Prefer the owning
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

- Before implementing a subsystem, compare its current task requirements and tracked owning
  contract against the live code, schema and reachable workflows. Resolve stale assumptions
  and contract conflicts before choosing the implementation shape; do not implement prose
  mechanically or require unavailable development records to establish the contract.
- Preserve product invariants while treating contract text that over-prescribes implementation
  mechanics as revisable. Revise the owning contract rather than silently ignoring that text. If
  reachable product behavior or a public/domain contract must change, revise its owning public
  documentation before or with the implementation.
- When a change lands, synchronize any contract status or verification capture that the
  implementation made stale. Incidental code structure does not belong in the contract.

## Local Development

- Supported environments: macOS and Linux (Ubuntu 24.04 or comparable).
- Shared local-only test account: `admin@example.com` / `Passw0rd!`. Never in production, staging,
  public demos, durable fixtures, or security-sensitive examples.

## Reference Research

- `references/` is an optional, untracked local cache of external source used for specific
  research tasks. Its contents change as needed; no particular repository, directory layout or
  machine path is required. Reuse it to avoid downloading the same source repeatedly.
- Research external implementations only when relevant to the task. Reuse a suitable cached
  checkout; fetch or update only the source needed when the cache is absent or insufficient.
  Do not scan or refresh a fixed list of projects before ordinary implementation work.
- Builds, tests and instructions must work without this cache. Write adopted behavior, rationale
  and constraints into the owning tracked documentation and tests. When citing an external source,
  use an accessible upstream URL and identify the version when it matters, never a private
  checkout path as the only explanation of a rule.
