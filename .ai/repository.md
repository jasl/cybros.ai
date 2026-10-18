# Repository Rules

**Applies to:** every project, including shared Ruby style.

## Scope And Naming

Treat each top-level project directory in this monorepo as an independent project unless a
change is explicitly shared.

- `Cybros` is the formal product/brand name; `cybros.ai` is the planned primary product domain.
  The default installation display name is `Nexus` (`Setup.default_account_name`, from I18n).
- `Nexus`/`nexus` is the kernel: component, project, module, directory, and namespace identifier.
  Agent-facing protocol text calls Nexus the `platform`
  unless a concrete resource name is clearer. The Cybros/Nexus naming theme is StarCraft II
  Purifier lore — naming context, not architecture.
- Credential token prefixes use the `cybros` tag (`sk-cybros-api-v1`, `sk-cybros-session-v1`;
  `nexus/app/models/access_token.rb`, `session.rb`) and digest salts the `cybros/<model>/<field>`
  form. Tool names include a kernel tool's
  canonical `source.category.name` (`nexus.memory.read`) beside its short wire alias
  (`memory_read`; `nexus/lib/nexus/tool_registry.rb`), an executor tool's short name (`bash`,
  `read`), and rho-mcp's `mcp__<server>__<tool>` (`rho-mcp`'s `naming.rb`). A Nexus-managed
  MCP import declares its callable name explicitly and binds the remote name to one connection; a name resolves
  to one providing authority (`.ai/boundaries.md`, *Product Boundaries*, the five-sources rule).
- `cybros_agent` (`CybrosAgent::`) is the Ruby gem containing the API client and agent framework. `httpx` is its one runtime dependency (the DeviceFlow transport); the WebSocket realtime
  channel is an optional module that runs inside an `async` reactor and requires the consumer to
  supply `async-websocket` (`sdks/ruby/lib/cybros_agent/realtime.rb`).
- Plan and phase labels such as `Foundation`, `F1`, or a roadmap stage are planning metadata only.
  They never appear in application constants, migration names, tables/columns, routes, jobs, logs,
  or public contracts. Permanent names describe the concrete domain purpose they serve.
- Public technical manuals and source comments must stand on their own. Do not cite internal
  specs, plans, phase labels, decision numbers, dated owner rulings, or the internal manual under
  `docs/` there; state the applicable behavior, invariant, reason, or limitation in place. External protocols, library documentation,
  and other external sources may be cited. Ordinary navigation between public manual pages and
  references to concrete code symbols remain useful; neither substitutes for explaining a rule.
- `Run` is the execution resource; `InferenceRequest` is a
  bounded sealed model request. A model invocation is an attempt, and a model round is one
  model Task within a Run. `task` names one unit of work owned by a Run or another kernel owner; an inbox row is that
  task delivered to an executor, never a second noun — no `Task` delivery plane, no `Assignment`.
- Use the same nouns in models, storage and client APIs: `Conversation`, `Input`, `Turn`,
  `Variant`, `Run`, `Task`, `Executor` and the shared `Event` family. An `AgentConfiguration`
  is a captured configuration value, while an Agent is a persistent User-backed identity.
  A named Agent has that same identity ownership; a Subagent is a temporary execution,
  never an alias for a named Agent or Bot. `Profile` is the caller's self-view API, not an
  identity or configuration entity. `Session` names authentication; SDK Human login lives
  under `Platform::Sessions`. External protocols retain their own session vocabulary.

## Active Projects

- `nexus`: the Rails kernel and gateway. Kernel and product ownership live in `boundaries.md`
  and `nexus.md`; stack/toolchain versions live in the project's manifests. Nexus is licensed
  O'Saasy (`nexus/LICENSE.md`); the rest of the repository defaults to MIT.
- `sdks/ruby`: the `cybros_agent` gem, containing the API client and agent framework under
  `CybrosAgent::`. It owns protocols, not storage: no files, directories or logs. Applications
  implement ports for persistence. The synchronous client remains loadable independently of
  the optional realtime reactor (`boundaries.md`, Package Boundaries).
- `sdks/typescript`: the `@cybros/agent` server SDK for Node.js, with native fetch,
  strict TypeScript types and ESM output. Realtime has a separate entry point. Package commands
  use pnpm, TypeScript and Vitest on Node.js; native Node tests also exercise the built package.
- `sdks/rust`: the async `cybros-agent` crate (`cybros_agent`) using Tokio and reqwest, with
  optional realtime support. It owns its Cargo toolchain requirements and local verification.
  Both new SDKs share the Ruby SDK's protocol/storage boundary and three credential planes;
  language conventions do not change wire keys, execution ownership or recovery semantics.
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
- `guides`: the public documentation site — VitePress, built and served with Bun. Its Markdown
  is the public manual and the normative public contract (`.ai/README.md`, Current Rules):
  task-oriented pages for people using rho, operating an installation, building an agent
  application and running executors, plus the reference pages that own every wire fact. It
  follows the self-contained documentation rule above and never links into `docs/`, the
  internal development manual.

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
  convenience adds no Node or Python boot requirement to bare-metal rho. Enabled plugins
  that require external runtimes check their prerequisites before becoming active. A failed
  plugin reports actionable repair guidance while core management remains available. Browser
  checks its configured Playwright driver and Chromium during plugin startup.

rho keeps core deployment settings and all plugin overrides in
`<RHO_HOME>/settings.json`, with static schemas and versions owned by each plugin.
An environment variable only seeds a setting the file does not have; a saved
value — a saved `null` included — wins, and a launch flag wins for that start.
Only what a process needs before it can read its settings stays a launch
parameter: the home, the Nexus it is bound to, mode, bind, port and the serving
switches. A credential a plugin needs at runtime is a saved write-only field
(`rho.t3`'s and Telegram's `token`); a value the settings can hold needs no
environment variable beside it.
New plugin private data uses `<RHO_HOME>/plugins/<id>/`; existing credential
stores retain their owned directories in the same home. The core plugin manager,
authentication, configuration migration and CLI recovery remain available when all
optional plugins are disabled. Disabled metadata discovery never evaluates a factory.
Current-file fallback is field-scoped; old formats use one forward migration before
normal loading. Runtime code consumes only current plugin configurations through
`Api#configuration`; it carries no previous-key aliases or parallel settings writer.
Settings editors offer what the daemon can list instead of typed names: the kernel
tool catalog (`GET /kernel_tools`), adaptation rows (`GET /adaptations/rows`), models,
runners and workspaces; a plugin schema's string field names its model catalog with
`x-rho-choices` (`source: models`, `workload`), an editor annotation that constrains
no value.

Localization is an accepted design, not yet implemented; it binds every rho surface and every
plugin, including third-party plugins whose authors may write in any language:

- Catalogs are optional, as Rails I18n is. A gem — the core or a plugin — that wants
  translation ships its human-facing strings as static catalogs, `locales/<tag>.json` (BCP 47
  tags: `en`, `zh-CN`), flat key → string, keys namespaced by the plugin id
  (`rho.ingress_telegram.setup.token_prompt`). Catalogs are static metadata, read without
  executing the plugin, like its descriptor. A plugin with no catalog shows whatever its code
  writes; a plain string in code is a supported way to write a single-language plugin.
  Model-facing text (prompts, tool descriptions, protocol identifiers) is never in a catalog
  and never translated.
- A plugin that ships one catalog needs no declaration: that language is its fallback, whatever
  the person prefers. A plugin that ships several ships `en` among them, because English is the
  automatic fallback between languages: lookup walks the person's tag → its language (`zh-CN`
  → `zh`) → `en` → the caller's `default:` text → the key itself. A multi-catalog plugin
  without `en` is reported by `rho extensions list` as a diagnostic.
- One lookup API per runtime: `api.t(key, default: nil, **vars)` in Ruby, `ui.t(key, vars)` in
  a WebUI module, `%{var}` interpolation in both; plural forms are separate keys the caller
  selects (`…_one`, `…_other`). No plural-rule library. The lookup never raises: a missing
  catalog, an unknown locale, a missing key or a malformed catalog degrades to the `default:`
  text, else the key, with one log line per key — neither a plugin nor rho fails over
  translation.
- The locale is the person's, not the daemon's: the core `locale` setting (seeded from the
  environment) is the default; the browser may choose its own in the page settings, Telegram
  follows the sender's `language_code`, the CLI follows the setting. Nexus error codes and event
  names reach a person as rho catalog entries keyed by the code, never as Nexus's English
  message translated. Nexus's own pages use Rails I18n (`config/locales`), locale from the
  human's setting.

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
  address. Its credential is transport-only. The current runner reserves local worker-pool
  admission capacity before claiming a task. Extensions can declare a shared local resource
  and concurrency limit at registration. A desktop resource admits one task at a time;
  ordinary CLI and filesystem tools retain independent startup capacity. Resource permits
  last until the handler and result hooks exit, including after cancellation or pool replacement.
  That policy belongs to the runner, never a kernel lock (`.ai/nexus.md`, The Task Inbox).
  Each accepted Runner call records its explicit
  target; a host's nullable default applies only to future authored calls with an omitted target.
  Full mode's Runner is private to its application Agent lineage: this rho's Main,
  Bots and their Subagents use it; another rho under the same Human cannot. New combined
  connections bind both together; adding a missing Runner names the existing Agent by public
  UUID without replacing its credentials. Standalone Runner mode retains the chosen
  Human-private or account-wide assignment. A Runner may serve multiple Agents within its
  assignment scope. Operator-facing capabilities are
  announced without model descriptions or schemas and hidden from model declarations.
- `rho-webui`: plain browser ES modules and CSS, with no build step or Node/Deno server dependency.
  It registers its page through `Api#register_webui`; full/agent modes select it by default,
  runner mode stays headless, and `api_only` disables serving. rho owns static serving,
  authentication and control APIs. The page is a shell with a closed slot catalog: its own
  features and the browser modules of running extensions register into the same slots through
  one `register(ui)` contract. A running extension contributes its module through
  `Api#register_webui_module(root:)`; the page discovers modules as `capabilities.webui` on
  `GET /extensions` rows and loads or disposes them without navigation when plugins change. The
  page never offers to switch off the plugin that serves it (`capabilities.page` on its row) or
  what that plugin requires; the CLI keeps that authority. The
  shell carries no plugin-specific interface; a plugin's configuration page, and its sidebar
  entry with its own main page when people need to find it, are the plugin's own module
  (`rho-ingress-telegram`'s `webui/`). The page's gate is `webui_access` (`open` / `nexus` /
  `password`, by bind when unset); pairing with Nexus is separate and happens once
  (`.ai/boundaries.md`). The page's address is its path, spelled as resources
  (`/workspaces/<id>/conversations/<id>`, `/plugins/<id>`, `/panels/<key>` for a plugin's main
  page; `webui/kernel/address.js`); the query string is never routing, so it stays free for the
  OAuth callback and debugging switches. The daemon answers an exact control route before the
  page, so page paths keep to those shapes. The sidebar's workspace switcher is the page's
  current workspace — browser-local, carried as the address's `/workspaces/<id>` when it is
  not rho's default — which scopes the conversation list and new conversations; rho's default
  workspace (settings) remains the CLI default. Each Bot starts new conversations in its
  Home Workspace. The composer defaults to the next model boundary's
  `steer`, offers `queue` for a later turn, and uses `steer_now` for Send now. Promoting a
  held steer changes its timing through the existing input, without resubmitting its words.
- `rho-ingress-telegram`: bot configuration, long polling, allowlists, chat/topic routing and
  delivery through the shared rho Core. Nexus owns accepted input attribution, history and
  execution. It is disabled by default; static configuration remains available through
  the core plugin manager. Polling requires explicit enablement.
  GUI and CLI share the configuration owner and apply changes immediately.
  Ordinary dialogue uses a sliding quiet window (`input_debounce_seconds`, 0–10 seconds,
  default 2; 0 submits immediately) before one queued input. Only compatible contiguous messages
  combine; commands bypass the window, and a submitted batch stays frozen across retries and restarts.
  An IM chat/topic uses its selected Agent conversation for dialogue and task scheduling;
  Side and BTW are unavailable on this ingress. Telegram-specific restrictions do not remove
  Core capabilities from the future complete WebUI.

  Under the product model below, connections own credentials, polling and transport recovery,
  while each Bot answers one concrete destination. Admission precedes media IO and conversation
  creation. A physical Telegram identity has one polling worker, which can route to several
  Bots without copying its token or update offset. Token renewal for that same identity
  preserves connection state; a different physical identity cannot reuse its persisted binding.
  Channel transport, allowlists, the quiet window and routing stay rho's; the kernel's Speaker
  and input door carry attribution. Additional IM platforms remain unimplemented. A kernel
  inbound ingress endpoint is considered only when a transport requires a public URL.
- `rho-browser`: Playwright browser tools loaded as a runner extension.
- `rho-mcp`: the official `mcp` gem client. Stdio tools ride the runner address; streamable-HTTP
  tools ride the agent address. OAuth login and its loopback listener belong to the CLI process.
  Served tools retain `mcp__<server>__<tool>` names; explicit Runner imports receive stable,
  source-qualified callable aliases. Curated prompts/resources become documents
  through rho-runner's skill plane. `rho mcp`, `probe`, `login` and `logout` expose management.
- `rho-web-tools`: `web_fetch {url}` and `rho web fetch URL`, using httpx, `UrlRule` SSRF filtering,
  same-site redirects and HTML rendering bounded to 1 MiB of input. Private hosts require the operator's explicit
  `allow_private_network: true` setting. It is enabled by default in runner-capable modes;
  an explicit saved disable remains effective.
- `rho-codemode`: the `code` tool, JavaScript authoring instructions and a live VM
  that retains its state across recorded child observations. It serves every available agent and
  runner address through the runner's claim-scoped orchestration bridge; Nexus owns task
  acceptance and scheduling. All rho modes load it by default, including headless deployments.
  rho owns the `code_mode` and `subagent` conversation choices. A new Main root
  Conversation captures `rho.codemode`'s configured `default` (`on`) and core
  `subagent_default` (`true`) once; later settings edits do not change that Conversation.
  Explicit request choices are booleans and persist on the Conversation; Side and fork copy
  their parent's choices. Historical unset choices read as the fixed initial value `true`.
  Subagent off withholds rho's role spawn and bounded task delegation from future inputs,
  including explicit tool selections, while accepted work, its replies and lifecycle controls
  continue. Explicit native coding harness tools and Bot-to-Bot send retain their own policies.
  Disabling the code plugin withdraws its contributions. Code mode off omits `code` and its
  authoring hints from new rho-authored turns; executor registration remains available for
  already accepted work. Nexus has no code-mode setting or product-specific admission branch.
  Each accepted execution carries only its eligible Runner declarations, with a concrete target
  and exact schema for each callable. Its `code` invocation retains that frozen tool authority.
- `rho-t3`: an optional external coding harness integration. Its Ruby client implements the
  finite T3 Effect RPC/WebSocket calls used for native sessions and callbacks. Its bearer is
  the saved write-only `token` and nothing else (`rho t3 token` issues a local service's and
  saves it, reads a host service's hidden from stdin; the page's Options do the same); status
  says whether one is saved, never what it is.
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

### Agent Presets, Main Agent, Bots And Subagents

Preset ownership, persistent identity and captured execution configuration are separate.
Role execution uses captured declarations and conversation-only child memory. Shared ingress
Connections own transport, and target-bound Bots own their current Conversation and history.
These product distinctions belong to rho; Nexus supplies generic identity, conversation,
execution, memory and permission mechanisms.

- An **Agent Preset** is reusable configuration for every form: model, instructions, tools and
  execution policy. It has no conversational identity, Conversation or memory. Main Agent, Bots
  and Subagent roles reference the Preset rather than maintaining independently editable copies
  of its configuration. Accepted executions retain the configuration they captured. Preset
  import, export and duplication carry configuration, never identities, conversation history, memory,
  credentials or ingress bindings; an imported file is not a second live configuration authority.
- The **Main Agent** is the persistent identity that talks directly with the user in the WebUI.
  rho presents one Main Agent as a soft product limit, not a kernel uniqueness constraint. It uses a
  Preset and can own many Conversations. Its identity and memory persist across those
  Conversations.
- A **Bot** is a separate persistent identity that talks directly with users through ingress.
  There may be many Bots. Each has a name, welcome message, Preset, Home Workspace and
  Subagent setting (on by default), and is
  fixed to one concrete ingress destination: a private chat, group, or topic. It has one current
  Conversation and retains its previous Conversations. Several Bots may share a channel
  connection; a connection or transport token is not a Bot. Sharing a Preset or connection does
  not share identities or private memory. Speaker notes belong to the answering persistent
  identity and the person together. Bot settings own the live Subagent choice for future
  inputs across current, new, resumed and forked Conversations; Main's global and
  per-Conversation modes do not control Bots. Bot main Conversations always use Code Mode
  off as soft product policy, and Subagent off makes them do the work directly and wait
  for its result. Accepted executions and captured child declarations retain their policy;
  published workers may still use their own Code Mode tools. These choices add no Nexus
  admission rule or product-specific kernel branch.
- The Main Agent and Bots may spawn **Subagents**, but neither is itself a spawn target.
  A **Subagent role** publishes a Preset in the delegation directory with a name and description
  that explain when to choose it. Roles may be built in or user defined; publication references
  the Preset and creates no second configuration authority. Ordinary workers use the default
  role with a task supplied at delegation time; a new task needs no permanent role definition.
- A **Subagent instance** is temporary execution under a role. It has no standing conversational
  identity or long-term memory across tasks. Its child Conversation and execution records remain
  durable. Its memory is confined to that child Conversation: it does not automatically inherit
  the parent's memory or read notes from another task using the same role. The delegator supplies
  the task and the context needed for it explicitly. Temporary lifetime does not delete history.
- `/new` immediately creates and selects a new Conversation for the Bot. New and Resume archive
  the replaced Conversation unless its Workspace is already archived; in that case the switch
  leaves the previous Conversation unchanged. Restoring that Workspace does not reselect the
  old Conversation: new input still requires Resume. Other archive failures refuse the switch.
  Switching does not imply Stop or wait for old work to finish. Accepted work and late
  results retain their original Conversation and execution ownership; they are not silently
  redirected into the new current Conversation. Explicit Stop remains a separate action.
- The sidebar separates **WebUI Conversations** from **Bots**. Settings contains **Agent Presets**
  and **Subagent roles**; the delegation directory is not a list of direct-conversation Bots.

The initial Presets include **Probius** for Cowork and **Adjutant** for the Bot assistant.
These are editable display names, not reserved identities or kernel types. Ship prepared
**worker**, **reviewer**, **planner** and **explorer** roles with suitable Preset instructions
and parent-facing selection descriptions. The worker handles ordinary tasks; the others supply
specialist defaults. Each role references a Preset, with no role User or copied configuration.
Nexus does not branch on any of these names.

rho configures its initial default model and an ordered `fallback_models` list independently;
the list replaces the old scalar fallback setting. Instance settings own the initially empty
base list. A Preset with no override or a null override inherits it; a supplied list replaces it
whole, and `[]` disables fallback. Main Agent, Bot and role settings reference that configuration without separately editable
copies or implicit list concatenation. The default model is not implicitly added to the list.

Main Agent and Bot executions initially use their selected Preset's model, or rho's default
when none is set. Subagent model selection is part of the Preset's execution policy, with two
choices:

- **Follow the delegator:** capture the effective model of the specific round that issues spawn,
  including an applicable task override or prior recovery switch. A branch uses its own round,
  and nested delegation follows its immediate delegator. Later parent or Preset changes do not
  retarget the child.
- **Use the role Preset:** select its configured default model, using rho's single default when
  no model is set. This does not implicitly inherit the parent's model.

An explicit model for the particular task overrides either choice. Natural-language requests
such as using Sol for execution and fable for review must resolve to concrete catalog model
references and become captured execution selections, not remain instructions only in the task text.
Capture selection intent even when an explicit value equals a configured default, together
with the initial route and the effective ordered fallback candidates. Later settings edits do
not rewrite that accepted chain. Use the existing live availability and admission gates when
selecting a candidate and before sending. Skip a disabled provider, a provider missing its
required API key or OAuth authorization, or a disabled model without provider IO. A skip counts
as neither a failed attempt nor a retry and consumes no per-route or whole-chain failure/retry
budget. It does not reset the chain's deadline, enqueue a retry or spin until configuration
changes. Preserve candidate order and the user's model/provider constraints: if no eligible
available target remains, report that outcome without substituting an impermissible model or
route. Availability comes from its existing owner, not a new health registry or probe loop.
Record and expose switches and skip reasons rather than silently replacing the requested
execution.

- With no user-selected model, recovery may traverse the declared eligible candidates in order.
- A user-selected model name permits another provider only when the Catalog explicitly
  establishes that it serves the same concrete model and version. A matching string suffix,
  family name or alias is not evidence of equivalence; unknown equivalence is not permission.
  Cross-model fallback requires the user's explicit allowance.
- A user-selected `provider/model` pins that route by default. Switching provider requires
  explicit permission; permission to switch provider alone does not permit a different model.
  Permission to change the model does not implicitly release a separately pinned provider.
- An explicit prohibition on fallback has highest priority, including over otherwise eligible
  same-model provider changes. It does not prohibit the ordinary retries on the selected route.
- A user's explicit fallback order replaces the effective list for that task. Naming a concrete
  alternative authorizes the model/provider changes needed for that candidate, without releasing
  constraints for other candidates. Resolve conflicting task instructions before dispatch.

Timeouts, disconnects and classified retryable server errors can advance to the next eligible
candidate after bounded retries on the current provider are exhausted. Preserve the existing
rate-limit, cooldown and retry semantics and typed terminal failures; an arbitrary error is not
recoverable merely because another candidate exists. Each resolved provider/model route enters
the chain at most once; retries within that candidate remain bounded. The whole chain has one
finite time and attempt budget, with existing Stop and cancellation ownership throughout.
Switching candidates or recovering after restart cannot reset that budget or revive stopped
work. Fallback replaces the failed model step without replaying completed tools or discarding
their accepted results. Reuse the existing execution and retry owners for these facts.

Nexus receives generic execution selections, candidates and recovery limits. It does not learn
rho's setting names, Preset names or product policy. Use the existing Catalog to establish model
identity; do not create a parallel equivalence registry. Ordered recovery is implemented for
Runs, direct replies and InferenceRequests. Declaration-based children retain their selected
configuration, actual model and independent recovery policy for later work.

Telegram is the first implemented ingress for this model. Later channel expansion compares and
reuses applicable Hermes and dsh-im designs or implementations while keeping rho's shared Core
and channel-specific transport owners. Existing rho data structures have no compatibility
obligation for this refactor; old rho data and staging may be rebuilt during implementation.
Do not introduce migration shims merely to preserve that old shape. Implementation and
documentation changes do not by themselves deploy, rebuild staging or reset data.

MCP connections belong to the user. Main Agent and Bots, including external-purpose Bots,
start with all currently available Nexus and rho-hosted MCP tools. Presets store only
`mcp.disabled_connections` and `mcp.disabled_tools`; the ordinary application/Runner tool
pickers do not also control MCP. Nexus references use the connection UUID; rho-hosted
references use the executor UUID and server key, with exact remote names for tool exclusions.
The application resolves that choice once into explicit imports and routes. Nexus owns its
connections, credentials, schemas and HTTP calls; rho.mcp keeps its local transports and
credentials. Existing executor eligibility and conversation-local MCP scope still apply.
New connections and catalog tools become available for future work unless their connection
is disabled. Accepted executions retain their captured tools and exact targets.

Subagents inherit their direct parent's captured MCP selection and can narrow it with the
role Preset's exclusions. They cannot restore tools absent from that parent, including through
nested delegation. rho expresses this through generic delegation `inherited_tool_names`,
without making Nexus interpret rho Presets or product names. Non-MCP role tools remain
independently selected. Role publication, a shared Preset and a channel binding do not add
connection authority, data access or approval authority. Declared tools, approval rules,
memory limits and conversation reach enforce the selected execution's permissions.
Untrusted ingress content cannot widen them or import a private session grant. Credentials remain separated by
plane, and external resource references use public UUIDs. Persistent product identities do not
require separate pairings; an execution principal remains distinct from its transport address.

Existing owner/external purpose policy remains an instance constraint on the selected Preset
and published role declarations. An externally facing Bot binds writable `conversation/`
and `speaker/` plus read-only `workspace/`, never `agent/` or `user/`; its generic
`memory_context_limit` caps bindings and `conversation_reach: subtree` confines conversation
tools. It declares required kernel tools and selected MCP tools under `rules`, retaining
deny/ask rules and exact executor/connection targets. An authored `ask` mode asks for every
selected MCP call; `rules` narrows authored allows to selected MCP callables; `bypass` adds
exact MCP allows without overriding deny/ask rules. Ordinary
private Runner/custom tools, the owner's persona and private session grants remain excluded.
A delegated role cannot restore capabilities prohibited by that source instance; a Subagent's conversation-only memory limit
narrows further. This does not require every role to have exactly its parent's visible tool
list. Changing an external identity to private requires a fresh identity.
Creation is create-only when a name is absent, so a removed external identity is not silently
restored. Private Bots may use their own Agent notes alongside Conversation, Speaker and
Workspace memory. A shared group Conversation resolves Speaker memory per input/execution;
it must not pin every participant's memory to the first sender or mutate a global binding on
each message. Configuration and role publication do not grant identity-management access
to an ingress message.

Explicit Bot-to-Bot sending remains distinct from spawn eligibility. Its admitted destination
and existing durable delivery receipt own channel selection and restart recovery; an unavailable
destination cannot be replaced with front-door impersonation or a guessed chat binding.

New Conversations for a Bot read its current Home Workspace; accepted inputs, existing Conversations
and scheduled work retain their recorded Workspace and identity. WebUI conversation browsing
uses the client's selected Workspace. A bound ingress Conversation exposes its source through
`conversation_binding`; the WebUI reads it and permits Stop and attachment access, while its
other writes return `409 ingress_bound`. This cooperative surface guard grants no kernel access.

Nexus administration and rho settings remain separate. The WebUI reaches Nexus's Human personal
settings (including steward-owned Agent API keys and private Runners) and admin settings
(providers, models, members, deployment) only through the daemon's Human-platform-credential
proxy (`POST /nexus/request`), never with the Agent's runtime credential. The Nexus page presents
provider lanes with their models and configuration actions, with destructive actions in menus,
and links to authorization, members and budgets. An unlock-only proxy request returns
`403 human_login_required`, preserving the page's grant while it offers sign-in. Workspaces
management through the user plane remains accepted design.

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
  documentation under `guides/` before or with the implementation.
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
