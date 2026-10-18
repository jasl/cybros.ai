# Plugins and code mode

rho's capabilities are plugins: tool extensions, the browser page, Telegram, lifecycle hooks and code mode. All of them are configured in one place.

## Manage plugins

**Plugins** lists installed plugins, including disabled ones, with their saved choices, effective defaults and current readiness. Edit a form or its JSON view, then **Save**. Invalid interactive edits stay in the draft and leave the saved file unchanged. **Restore default** removes an override; an explicit value equal to today's default remains a saved choice. Secret fields offer keep, replace and clear without returning the value.

The CLI uses the same owner:

```sh
rho extensions list
rho extensions enable rho.mcp
rho extensions disable rho.mcp
rho extensions configure rho.coding '[{"op":"set","path":["bash_timeout_seconds"],"value":90}]'
rho extensions configure rho.coding '[{"op":"unset","path":["bash_timeout_seconds"]}]'
```

Configuration lives in `<RHO_HOME>/settings.json`. Ordinary changes apply immediately and affect future work; a plugin with exclusive process state keeps its old instance until rho restarts and reports that in the save result. Even with every optional plugin disabled, authenticated management stays available. `rho extensions enable rho.webui` restores the browser page; the page itself never offers to switch off the plugin that serves it.

Edit the JSON file directly only while rho is stopped.

## Bundled plugins

| Plugin | Provides | Default |
| --- | --- | --- |
| `rho.coding` | File, shell and process tools on the runner | On |
| `rho.webui` | The browser page | On in full and agent modes |
| `rho.codemode` | The `code` tool: JavaScript orchestration of tools and model calls | On |
| `rho.web_tools` | `web_fetch`: read a public URL as markdown, text or a saved file | On in full and runner modes |
| `rho.mcp` | Tools from configured MCP servers (stdio and streamable HTTP), with OAuth login from the CLI | Configure servers to use |
| `rho.browser` | Playwright browser tools, when the driver and Chromium are installed | Add `rho/browser` to the extensions list |
| `rho.ingress_telegram` | [Telegram](telegram.md) | Off |
| `rho.acp-client` | `delegate_agent`: delegate to another configured ACP agent | Off |
| `rho.t3` | Delegate coding assignments to Codex, Claude Code or other configured coding agents through the T3 service | Off |
| `rho.lifecycle_hooks` | Executor tools at turn start, compaction and stop | `{}` |
| `rho.compaction` | Model and prompt settings for Nexus context compaction | On |
| `rho.schedules` | Enables the Nexus schedule tools | On |
| `rho.images` | Enables the Nexus image tool with a chosen image model | Configure a model to use |

Web fetching reaches only public addresses unless the operator sets `allow_private_network: true`. MCP tools keep source-qualified callable names; `rho mcp`, `rho mcp probe`, `login` and `logout` manage servers.

Those commands manage the `rho.mcp` plugin's local connections. Their tools are
on by default for Main Agent and Bots; **Settings › Agent Presets › MCP connections
and tools** can turn off whole connections or individual tools. Subagents inherit
their parent's selection and can narrow it further in the role Preset. Nexus-managed
HTTP MCP connections appear in the same
[Agent Preset picker](agent-presets.md#connect-nexus-mcp-tools) and run in Nexus.
rho resolves stable callable names for each source when it captures an execution.
Both sources can be used together.

## Code mode

Code mode lets the model coordinate tools and model calls with JavaScript instead of one tool call per model round. The `code` tool runs a bounded program in a fresh VM with no filesystem, network, module loader, clock or randomness; the program calls declared tools and `nexus.model`, awaits real results and selects what returns to the model.

The VM runs in rho. rho must remain online while the program waits for child
results and continues executing JavaScript. Nexus retains the child tasks and
their results, but does not resume that VM after rho exits.

It is on by default. Change the global default in **Plugins → Code mode** or:

```sh
rho extensions configure rho.codemode '[{"op":"set","path":["default"],"value":"off"}]'
rho run "Compare these files" --code-mode
rho run "Summarize this project" --no-code-mode
```

The Main conversation composer has separate **Code mode** and **Subagent** buttons. Each saves the
current conversation's on/off choice immediately. Global defaults supply the initial
state of new Main conversations only; changing a default never changes existing
conversations. Side and fork copy the source conversation's choices. ACP exposes
`code_mode`. Bots always keep Code mode off; Telegram `/codemode` explains this policy.
Each Bot has its own **Subagent** switch in its settings, on by default. Turning it
off makes that Bot complete work directly in its main conversation and wait for
the result. This applies to future inputs, including its existing conversation,
and does not change already accepted workers or their captured tools.

Code mode off removes the code tool and its usage hint from new rho-authored turns;
ordinary tools remain. Subagent off removes role spawning and bounded task delegation
from new inputs. It does not cancel workers already accepted: they can still finish,
report results, and be managed through their existing conversation. Explicit native
coding harness tools retain their own configuration. The Subagent default is in rho's
settings and starts on. Human-authored schedules capture the conversation's choices;
later mode edits do not rewrite them. Regeneration replays the original request with
its original tools.

## Until mode

`rho run --until` (also `rho do --until` when rho-dev is enabled) uses rho's
observer to evaluate the stopping condition,
resolve its continuation hold and submit another attempt when needed. Keep that
process online. Work already accepted by Nexus can finish while it is absent,
but the next until attempt does not start until rho resumes the continuation.
