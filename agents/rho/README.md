# rho

rho is the reference agent application for Cybros/Nexus: a Cowork agent that pairs an
Agent identity (and an optional private Runner) to a Nexus server over OAuth device
flow, then works through Nexus's conversation, task inbox and tool-call protocols.
Nexus owns the mechanisms (prompt assembly, execution, memory, approvals,
persistence); rho owns the product policy (prompts, model selection, tool
declarations, channels, UI).

This directory is a Ruby monorepo. Each top-level folder is an independently
packaged gem; the container itself has no build of its own.

## Layout

### Core

- **rho/** — the core gem and flagship application. Carries the daemon
  (`rho server`), the credential vault, the Nexus connection, the local control
  API, the extension manager, the shared application core (`Rho::Core`) that every
  surface consumes, and the single `exe/rho` CLI entry point. Runs in three modes:
  `full` (agent + private runner), `agent` (conversations only), and `runner`
  (tools only, headless).

- **rho-runner/** — the passive tool executor. Executes filesystem/process tools,
  checkpoints and capture/restore where the files actually live, dialing out to
  Nexus and never listening for inbound connections. A separate gem so a runner
  can run standalone (`RHO_MODE=runner`) without the daemon. Most tool extensions
  depend on this gem rather than on `rho`.

### Surfaces (peer interfaces over `Rho::Core`)

- **rho-webui/** (`rho.webui`) — the browser interface: conversations, streamed
  answers, tool activity, artifacts, schedules, plugin management and settings.
  Plain ES modules with no JS build step, registered through
  `Api#register_webui`; other extensions can inject browser modules into the same
  page. Enabled by default in full/agent modes.

- **rho-acp/** — rho as an ACP (Agent Client Protocol) agent: the JSON-RPC/ndjson
  wire protocol plus the `rho-acp` executable an editor (Zed, JetBrains) spawns on
  stdio. Each ACP session is a conversation driven through `Rho::Core`. Not an
  extension — a peer surface gem beside CLI/WebUI.

- **rho-ingress-telegram/** (`rho.ingress_telegram`) — Telegram ingress: a
  long-polling Bot API client inside the daemon (no webhook server). Models
  Connections (one physical bot token) and Bots (one fixed chat/topic target bound
  to a Nexus Bot identity), with routing, allowlists and a quiet debounce window.
  Disabled by default.

### Tool extensions (runner-side)

- **rho-codemode/** (`rho.codemode`) — the `code` tool: a sandboxed JavaScript VM
  (embedded V8 via `mini_racer`, no Node required) that orchestrates frozen tool
  declarations and task-scoped helpers (`nexus.model`, `nexus.steps`,
  `nexus.background`, …). Default-enabled in every mode.

- **rho-web-tools/** (`rho.web_tools`) — a minimal web reader: the
  `web_fetch {url}` tool (GET only, SSRF-filtered, HTML rendered to markdown under
  bounded size/time) plus the `rho web fetch URL` CLI verb. Enabled by default in
  runner-capable modes.

- **rho-browser/** (`rho.browser`) — real browser control via Playwright
  (`browser_snapshot/navigate/click/type/screenshot/evaluate`), with a shared
  browser context and per-agent-loop tabs. Requires an external Node Playwright
  driver and Chromium. Disabled by default.

- **rho-mcp/** (`rho.mcp`) — the MCP client extension: runs operator-named MCP
  servers (stdio children or streamable-HTTP with OAuth login) and announces their
  tools as `mcp__<server>__<tool>`. Adds the `rho mcp`, `probe`, `login` and
  `logout` management verbs. Disabled by default.

### Agent delegation

- **rho-t3/** (`rho.t3`) — optional delegation to native coding harnesses (Codex,
  Claude Code) through a T3 service over authenticated Effect RPC. rho keeps the
  Nexus task, questions, Stop and artifacts; the harness owns its native session.
  Disabled by default.

- **rho-acp-client/** (`rho.acp-client`) — the reverse ACP direction: rho as an
  ACP *client*, delegating work to other ACP agents (`codex-acp`, `opencode acp`,
  Gemini CLI, …) through the `delegate_agent` runner tool. Child permission
  requests are answered by rho's own approval floor. Disabled by default.

### Development

- **rho-dev/** (`rho.dev`) — development/debug extension: the terminal verbs that
  operate conversations beyond `rho run` (`do`, `say`, `stop`, `watch`, `follow`,
  `result`, `transcript`, `graph`, `rewind`, `regenerate`, approval decisions).
  Never shipped in the distribution; enabled only via an explicit path source for
  orchestrator/E2E/agent testing.

## Dependency shape

```
cybros_agent (external SDK)
  └── rho-runner ──────────────┐
        └── rho                │
              ├── rho-webui    ├── rho-browser
              │                ├── rho-codemode
              ├── rho-ingress-telegram
              ├── rho-acp ──► rho-acp-client
              ├── rho-t3       ├── rho-mcp
              └── rho-dev      └── rho-web-tools
```

- `rho` hard-depends on `rho-runner`; everything else loads through the extension
  plane (`rho-extension.json` static descriptors plus a `register(api)` module),
  so optional gems contribute tools, CLI verbs, control routes and web modules
  without changing the core.
- Tool extensions depend only on `rho-runner`; surface gems depend on `rho`;
  `rho-t3` and `rho-acp-client` depend on both, and `rho-acp-client` also depends
  on `rho-acp` for the wire protocol.

## Working in this monorepo

Each gem has its own `Gemfile`, `Rakefile` and `test/` tree. Run commands from
the target gem's directory and keep changes scoped to one gem whenever possible.
