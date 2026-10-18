# Agents and configuration

An agent is a member of the account. Its application declares, in one atomic write, the standing configuration: tools, approval policy, prompt mechanism, compaction policy, models, lifecycle hooks and the agent's own prompt documents. Nexus validates these values and captures them for execution. The Human console [inspects the declaration](../operate/configure-an-agent.md); configuration editors and Presets belong to the agent application. An input may supply a complete inline declaration.

```http
PUT /agent_api/v1/profile/configuration
```

```json
{
  "configuration": {
    "tool_definitions": [
      { "type": "function", "function": { "name": "bash", "description": "…", "parameters": { "…": "…" } } }
    ],
    "approval_mode": "rules",
    "approval_rules": [
      { "tool": "bash|start_process", "path": "command", "match": "*rm -rf /*", "verdict": "deny" }
    ],
    "prompt_mechanism": "default",
    "prompt_template": null,
    "compaction_policy": { "mode": "kernel" },
    "lifecycle_hooks": {
      "stop": { "tool": "review_completion", "timeout_ms": 30000, "max_continuations": 2 }
    },
    "default_model": "openrouter/z-ai/glm-5.3",
    "fallback_models": ["openrouter/moonshotai/kimi-k3"]
  },
  "prompt_documents": {
    "system_prompt": { "content": "You are {{agent}}.", "role": "developer" },
    "summarizer": { "content": "Preserve decisions and pointers to results." }
  }
}
```

## Replacement, not merge

`PUT` replaces the whole configuration. A field omitted from the body clears. The `prompt_documents` root replaces the agent's two owned slots: an omitted or null root clears both, an omitted or null slot clears that slot. Configuration and documents validate together and commit atomically; a refused write changes nothing, including document versions. Repeating the same declaration converges on the same content, though a rewritten document still advances its version.

Named Agents (`PUT /profile/agents/{name}`) are separate declarations and are not part of this transaction.

## Freezing

An input with `agent_configuration` captures that complete identity-free configuration at admission. Materialization assembles and freezes the execution’s tools, prompt documents, approval, memory and environment. A later Preset or profile edit does not rewrite that queued declaration.

Without an inline declaration, an ordinary input resolves the answering User’s current standing declaration at materialization, then freezes it. Regeneration without a new declaration reuses the originating candidate’s capture. Context estimate accepts the same declaration for a write-free preview. See [Inline agent configuration](../reference/agent-api/profile-configuration.md#inline-agent-configuration).

## Fields

| Field | Meaning |
| --- | --- |
| `tool_definitions` | The tools a model may call: function declarations in nested or flat form, kernel tools declared in the exact bytes the [kernel tool catalog](../reference/kernel-tools.md) serves (or through the compact alias grammar), and runner declarations carrying a `route`. Stored canonically by name under a 1 MiB bound. |
| `approval_mode`, `approval_rules` | `bypass`, `ask` or `rules`, and the rule list. See [Approvals and rules](approvals-and-rules.md). |
| `prompt_mechanism` | `default`, `assembly` or `raw`; see below. |
| `prompt_template` | The block order for `assembly`. |
| `memory_context_limit` | Optional cap on natural memory roots and their access; it narrows inherited bindings. |
| `conversation_reach` | `subtree` limits conversation tools and history to the current conversation and descendants. |
| `compaction_policy` | `{ "mode": "kernel" }` for the kernel summarizer, or a delegated policy naming your own summarizer tool. |
| `lifecycle_hooks` | Executor tools at `turn_start`, `pre_compact`, `post_compact` and `stop`. See [Lifecycle hooks](lifecycle-hooks.md). |
| `default_model` | A complete `provider/model` reference. A changed reference uses the text-generation model resolver; temporary unavailability does not reject the save. Execution checks live availability. See [Configuration validation](../reference/agent-api/profile-configuration.md). |
| `image_model` | Optional complete `provider/model` reference for the kernel's image tool, captured with the execution and validated for `image_generation`. |
| `fallback_models` | Ordered recovery candidates captured for the execution. `[]` disables automatic fallback. The initial model is not added implicitly. |

## Prompt mechanisms

- **`default`** assembles the agent's system prompt, the workspace character, the human persona, memory, skills, history and the new input in the kernel's order.
- **`assembly`** uses your `prompt_template` to order the same blocks explicitly.
- **`raw`** lets the application supply the complete request and own its context; an input then carries its message list.

Prompt documents — `system_prompt` and `summarizer` on the agent, `persona` on the human, a workspace's character — are durable, versioned texts read and edited individually through their own endpoints. Templates use `{{variable}}` placeholders validated against the declaration.

## Tool declarations

Five tool sources share one provenance model, and each name resolves to one providing authority:

| Source | How it is declared | Where a call goes |
| --- | --- | --- |
| Kernel (`delegate_task`, `ask`, `memory_*`, `tool_search`, `skill`, …) | Byte-identical to the catalog, or by alias | Runs in the kernel |
| Runner | `route: { "kind": "runner", "runner_executor_public_id": "<uuid>", "tool_name": "read" }` beside the callable schema | That runner's inbox |
| The application's own tools | A function declaration, plus an announcement on the application's executor | The application's inbox |
| Tool provider | A function declaration; the provider announces the name | A pool shared by eligible providers |
| MCP connection | Exact `mcp_tools` selections, frozen as a connection UUID and remote tool name | Nexus makes the HTTP MCP call |

A runner declaration separates the callable name and schema the model sees from the served name at a concrete runner, so two runners can expose incompatible `read` schemas under different callable names. An application may declare an alias and parameter map for a kernel tool; the call arrives under the alias and runs under the canonical name. `defer_loading: true` hides a schema from the provider's tool list when `tool_search` and `tool_call` are declared, letting the model discover it on demand; deferral is presentation, not permission.

An MCP connection must belong to the answering Agent's current Human steward. The application selects exact remote tools and callable names to import; no separate Agent grant is required. See [MCP connections](../reference/agent-api/mcp-connections.md).

A shared application can preview its own active named Agent's sources by passing
that Agent's UUID as `agent_public_id` to the MCP directory and tool assembly
reads. The selected Agent supplies its current steward and Runner eligibility.
For rho, each Main Agent or Bot uses its [Agent Preset's MCP selection](../use/agent-presets.md#connect-nexus-mcp-tools):
available connections and tools are enabled by default, with explicit exclusions.

Read a selected runner's announced declarations and environment through the tool assembly endpoint instead of transcribing them by hand. Tool arguments remain the executor's payload; Nexus never interprets them.

## Models and reasoning

An input or schedule may select a model and the independent `reasoning_enabled` and `reasoning_effort` controls. A missing selection uses the configuration’s `default_model`. Inputs also accept `model_selection` to record default, inherited or explicit intent and model/provider constraints, independently of the initial route. An ordered `fallback_models` override replaces the inherited list; `[]` forbids automatic switches.

Only eligible, available candidates may be tried, with bounded retries and no renewal of a spent route. Kernel result mail retains its source execution’s list and constraints; it has no hidden switch to the recipient’s current default. See [Model selection and recovery](../reference/agent-api/models.md#model-selection-and-recovery).

## Named Agent identities

`PUT /profile/agents/{name}` creates a named Agent identity with its own configuration. It can answer conversations and retain its own memory. Its declaring application serves selected application tools through its existing executor address; Runner declarations retain their concrete targets and exact schemas. rho uses named identities for Bots, while reusable Presets and published Subagent roles are configuration without a separate User. Import and export operate on Presets; see [Agents and bots](../use/sub-agents.md).

The complete field reference is in the [Agent configuration reference](../reference/agent-api/profile-configuration.md); the kernel tool catalog and import rules are in [Run tools](../reference/agent-api/run-tools.md#the-kernel-tool-catalog).

To let accepted work finish after the application exits, see
[Run an Agent while its application is offline](offline-agents.md).
