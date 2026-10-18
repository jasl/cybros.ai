# Tools and announcements

A runner tells Nexus what it serves. Nexus then addresses calls to it by that announcement and lets an agent import the exact schemas into its declaration.

## Announce

```http
PUT /agent_api/v1/executor/announcement
```

Executor plane. A whole replacement of the tools this address serves, the environment they are bound to, and the documents it can load for a model:

```json
{
  "tools": [
    { "name": "bash", "effect_profile": { "kind": "write", "destructive": true, "effect_scope": "open", "idempotency": "none", "reconciliation": "none" },
      "timeout_ms": 120000, "description": "…", "input_schema": { "type": "object", "…": "…" } },
    { "name": "read", "effect_profile": { "kind": "read_only", "destructive": false, "effect_scope": "closed", "idempotency": "intrinsic", "reconciliation": "none" },
      "description": "…", "input_schema": { "…": "…" } },
    { "name": "files_bytes", "effect_profile": { "kind": "read_only", "destructive": false, "effect_scope": "closed", "idempotency": "intrinsic", "reconciliation": "none" } }
  ],
  "environment": { "os": "linux", "working_directory": "/home/runner", "…": "…" },
  "documents": [ { "name": "workspace-tools", "description": "Tools installed in this image" } ]
}
```

- `effect_profile` is required on every entry and uses exactly the kernel's closed effect vocabulary: `kind` (`pure`, `read_only`, `write`), `destructive` (boolean), `effect_scope` (`closed` — the runner's own files; `open` — the outside world), `idempotency` (`intrinsic`, `keyed`, `none`) and `reconciliation` (`none`, `lookup`). The approval stage reads it when a person decides, and the expiry sweep reads it to settle an abandoned claim.
- `timeout_ms` is the deadline when the authored call names none.
- `description` and `input_schema` make a tool model-visible. An entry without them — `files_bytes`, `process_log` — is an operator capability: announced so a person's client can call it through the kernel, hidden by name from model declarations.
- `mcp: {server_key, tool_name}` identifies an MCP source on this executor. These tools require explicit declarations and are excluded from automatic default-Runner imports; the application owns its MCP selection policy. The metadata adds no execution authority.
- `environment` is an opaque snapshot of environment facts (operating system, working directory, installed toolchains) that discovery and the `runners_list` kernel tool show to agents.
- `documents` are skills the `skill` tool can load from this runner.
- `tools: []` clears the list.

Replacing an announcement affects future addressing. Work already accepted keeps its frozen declaration; a removed tool follows the ordinary failed-tool path if a later call cannot be served.

## Discover and import

An agent reads the runners it may address on the member plane:

```http
GET /agent_api/v1/executors?kind=runner
GET /agent_api/v1/executors/{public_id}
```

Each row shows `served_tools` whole, `environment`, `served_documents`, `assignment_scope`, `presence` and `last_seen_at`. Discovery requires an active, credential-ready Runner that is not shutting down and whose [assignment scope](deploy.md#identity-and-scope) admits the Agent. The same scope governs tool assembly and execution: knowing a Runner UUID does not grant use of it. Presence does not determine eligibility.

The tool assembly endpoint returns the declarations an agent should put into its configuration for a selected runner: each callable name, the served name, the schema and the `route`:

```json
{
  "type": "function",
  "function": { "name": "remote_read", "parameters": { "type": "object" } },
  "route": { "kind": "runner", "runner_executor_public_id": "<runner UUID>", "tool_name": "read" }
}
```

The model's provider receives the callable schema; Nexus keeps the routing metadata and lowers the call to the served tool at the named runner. Continuation children inherit these declarations and cannot replace their targets.

## Where a call goes

- A runner route names a concrete runner. An authored step may omit the UUID and resolve the conversation's default runner once at acceptance; an absent default refuses `runner_target_required`. A missing or ineligible target fails explicitly — another runner never takes it.
- Without a runner route, kernel tools run in the kernel; other names go to the declaring application's announced address, then to an eligible tool-provider pool. Runner announcements never create a fallback by bare name.
- The park's deadline uses the authored `timeout_ms`, then the announcement's value, then the kernel default.

## Effects and restore

Every claimed write is recorded per runner as effect evidence: `untouched`, `touched` or `unavailable`. A runner may supply an opaque checkpoint with a result so a later rewind can restore that runner independently; the projection is evidence that an effect may have happened, never proof that a write completed. After retention prunes a run's detail, its effects read `unavailable` with `execution_details_pruned`.

The complete announcement contract is in the [Executor reference](../reference/agent-api/executor.md#announce-what-this-executor-serves); the import request and response are in [Tool assembly](../reference/agent-api/tool-assembly.md); routing rules are in [Executor](../reference/agent-api/executor.md#where-a-tool-call-goes).
