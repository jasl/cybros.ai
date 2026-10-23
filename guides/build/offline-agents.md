# Run an Agent while its application is offline

Nexus can finish an accepted conversation after the submitting application
exits. It owns model rounds, tool waits, approvals, context compaction, image
generation and scheduled work. Use this path when the application is a client
that submits and observes work rather than an executor needed by that work.

## 1. Select independent execution services

Declare the tools your Agent needs through its
[configuration](agents-and-configuration.md). Each selected capability determines
what must remain available:

| Capability | Required service |
| --- | --- |
| Model rounds, kernel tools and kernel compaction | Nexus, its workers and the selected model provider |
| File, shell and other Runner tools | The selected Runner |
| Nexus-managed HTTP MCP tools | The steward-owned MCP connection and remote service |
| Application-served tools or lifecycle hooks | The application serving that executor |
| rho code mode | rho's JavaScript VM for the entire call |
| `rho run --until` | rho's continuation observer |

An independent Runner can use the rho-runner package without starting the rho
application. It holds its own executor credential; it does not need the
application's member credential. An offline application is still an active
Agent identity with ordinary Workspace access and grants.

## 2. Capture execution settings

Use `compaction_policy: {mode: "kernel"}`. The policy can select a summarizer
model, and the `summarizer` prompt document can customize the summary. Nexus
executes that summary; no summarizer tool callback is required. Omitting the
document uses the kernel's default instructions.

To generate images, declare `nexus.image.generate` and an `image_model`.
To let the model schedule future work, declare `nexus.schedules.read` and
`nexus.schedules.manage`. These [kernel tools](../reference/kernel-tools.md)
reuse the execution's captured authority and persist their results in Nexus.

Use an inline `agent_configuration` when admission must freeze the complete
configuration immediately. Without one, an ordinary input captures the
answering Agent's standing declaration at materialization. Scheduled jobs keep
their own captured declaration for later occurrences.

## 3. Submit once and retain the receipt

Submit through the ordinary SDK or HTTP input door with a durable idempotency
key. Save the returned input UUID with its Workspace and Conversation UUIDs.
The submitting process may then exit, even before a tool or model call finishes.

[Build an Agent with HTTP MCP tools](http-mcp-agent.md#3-submit-once-and-save-the-input-uuid)
shows the submission and exact-input observer. The same observer works for
Runner and kernel tools. After reconnecting, resolve that input's materialization
and follow its original candidate and automatic fallback lineage. Do not submit
another input merely because observation disconnected.

## 4. Handle decisions and results

An approval or human question remains a durable wait while the application is
absent. A separate authorized UI can answer through the member-plane decision
doors. Resume observing the same execution afterward; the observer does not
append model rounds or tool results.

A [Conversation cost limit](usage-and-cost.md#limit-one-conversations-cost)
can also hold a priced task while the application is offline. An authorized
member adjusts the limit and explicitly retries that task. Rejoin the original
execution; completed tools are not repeated.

An application-owned coordination point may use an explicitly
[indefinite authored ask](../reference/agent-api/run-steps.md). rho uses this for
Until: completed checks stay recorded while its continuation observer is offline.
Recovery advances the original wait without rerunning those checks. Stop remains
effective, and later tool work still needs its ordinary authorization and approvals.

Read final content and attachments from the retained result. Image generation
produces upload links without an application download-and-reupload step.
Schedules dispatch their own child executions and return the original answers
through kernel result mail.

This behavior does not move rho's local integrations into Nexus. rho-served
extensions, delegated compaction callbacks and lifecycle hooks still need their
executor. Background memory review is also application work. Choose those
features when that online dependency is appropriate.

## Next

- [Approvals and rules](approvals-and-rules.md)
- [Schedules](schedules.md)
- [Events and streaming](events-and-streaming.md)
