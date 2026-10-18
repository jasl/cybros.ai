# Build an Agent with HTTP MCP tools

Nexus can run a conversation using a model, kernel tools and HTTP MCP services
without a Runner or a permanent application claim loop. Start with the connection
and Workspace steps in [Quickstart](quickstart.md). Keep the member credential
bundle and refresh it through the application's existing credential storage.

## 1. Prepare the service account

In Nexus Settings → MCP connections, the Human creates a connection and chooses
its authentication method. For OAuth, choose **Authorize service**, finish the
service's browser consent and return to Nexus. For Bearer authentication, supply
a token for the same external account. Then choose **Discover tools**. Save the
connection UUID. The owner's Main Agent and named Agents can use it through
their current steward relationship, without separate grants. See [Manage MCP connections](../reference/platform-api/mcp-connections.md).

## 2. Declare exact tools

The following Ruby code uses a connected `client`, a `model_ref` selected from
`client.models.list`, and the owner's connection UUID. It replaces the complete
Agent configuration. The application owns the prompt and model selection.
`default_model` supplies the Agent's addressed and delegated replies. Direct
input below selects its model explicitly.

```ruby
connection_id = "01900000-0000-7000-8000-000000000091"
connection = client.mcp_connections.fetch(connection_id)
raise "Connection unavailable" unless connection.available
raise "Search is unavailable" unless connection.tools.any? { |tool| tool.fetch("name") == "search" }

client.profile.declare_configuration(
  default_model: model_ref, fallback_models: [],
  tool_definitions: [], kernel_tools: [],
  runner_executor_public_ids: [], runner_tool_names: [],
  mcp_tools: [{ "connection_public_id" => connection.public_id,
    "tool_name" => "search", "name" => "work_search" }],
  approval_mode: "ask", approval_rules: nil,
  prompt_mechanism: "default", prompt_template: nil,
  compaction_policy: { "mode" => "kernel" }, lifecycle_hooks: nil,
  memory_context_limit: nil, conversation_reach: nil, delegation_catalog: nil,
  prompt_documents: {
    "system_prompt" => { "content" => "Use work_search to find relevant documents and cite the returned evidence." },
    "summarizer" => nil
  }
)
```

Omitting `mcp_tools` or sending `[]` imports none in the Agent API. Applications
resolve their own selection policy into this exact list. rho defaults to all
available connections and tools, minus the Preset's exclusions. Tool assembly freezes
the saved schema and exact connection route. It does not contact the service.
`default` includes the usual persona, memory and history blocks; applications
needing a different prompt composition choose it explicitly.

## 3. Submit once and save the input UUID

Using a `chat` obtained from `client.workspace(workspace_id).conversation(conversation_id)`:

```ruby
operation_key = SecureRandom.uuid
# Persist operation_key before sending. Recover this operation with that same key.
accepted = chat.inputs.create(
  kind: "direct_reply", delivery_mode: "queue",
  text: "Find the documents about the next release.",
  model: { model: model_ref },
  idempotency_key: operation_key
)
input_id = accepted.public_id
# Persist input_id beside the Workspace and Conversation UUIDs.
```

A disconnected client resumes observation of `input_id`. It does not submit a
second prompt. Receipt replay has the documented retention window; when that
window has elapsed, recover known resources before repeating an uncertain write.

## 4. Follow the exact execution

This bounded HTTP observer follows the input's original candidate and its
automatic fallback lineage. Manual regeneration or another active candidate is
a different execution. It returns pending decisions for the application's UI.

```ruby
def observe_reply(chat, workspace, input_id, seconds: 120)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
  loop do
    binding = chat.inputs.materialization(input_id)
    if binding
      variants = chat.turns.variants(binding.turn_public_id).items
      variant = variants.find { |row| row.public_id == binding.variant_public_id }
      raise "The original candidate is unavailable" unless variant
      while (successor = variants.find { |row| row.source == "fallback" && row.origin_variant_public_id == variant.public_id })
        variant = successor
      end

      return { state: "completed", input_id: input_id, variant: variant } if variant.status == "completed"
      if %w[failed canceled].include?(variant.status)
        return { state: variant.status, input_id: input_id, variant: variant }
      end
      if variant.run_public_id
        decisions = workspace.runs.run(variant.run_public_id).decisions
        return { state: "decision_required", input_id: input_id, decisions: decisions } unless decisions.empty?
      end
    end
    return { state: "waiting", input_id: input_id } if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

    sleep 1
  end
end

result = observe_reply(chat, client.workspace(workspace_id), input_id)
puts result[:variant].content if result[:state] == "completed"
```

A `waiting` result ends this wait only; it does not Stop the execution. Keep the
same input UUID and call the observer again. A blocked input remains in the
input queue with its `blocked_reason` and requires correction. A completed
variant provides `content` and `attachments`; its reply may be complete while
explicit background work continues. For push updates, use the existing
`InputMaterialization`, `KernelFeed` and `TranscriptAccumulator` machinery in
[Events and streaming](events-and-streaming.md).

For `decision_required`, show each approval's `tool_alias || tool_name`, `target`
(connection name, account label and remote tool), `tool_input` and `effect_profile`.
Submit the person's choice with `decision.approve` or `decision.deny(reason: ...)`,
then resume the same observer. Questions use `decision.answer(content: ...)`.
These member-plane operations need no executor claim loop. An unattended `ask`
still waits and expires normally; applications that permit unattended actions
supply explicit callable-name rules through the existing approval policy.

## Next

- [MCP connections reference](../reference/agent-api/mcp-connections.md)
- [Approvals and rules](approvals-and-rules.md)
- [Errors and recovery](errors-and-recovery.md)
