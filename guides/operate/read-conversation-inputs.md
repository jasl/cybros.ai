# Read and cancel Conversation inputs

Open a Conversation under **Workspaces → Work → Conversations** to read its
accepted inputs and retained results. New requests and text or attachment edits
are submitted from the application or SDK through the
[inputs API](../reference/agent-api/conversation-inputs.md).

## Review pending inputs

Open **Pending inputs**. The paginated list shows queued and blocked inputs,
their authors, answering Agents, delivery times and blocked reasons.
Future-dated inputs wait until their delivery time. Messages directed to an
active execution appear with that execution.

Open an input to follow its state and download retained attachments. Once
materialized, the page follows its original Turn and answer candidate, even if
another candidate is selected later. An answer can exist without a Run.

## Cancel an input

Choose **Cancel pending input** on an eligible pending or blocked input. This
cancels that input; its Schedule and already started work keep their own state.
If materialization wins first, the page follows the original result without
claiming cancellation. Use [**Stop conversation work**](work-console.md#stop-conversation-work)
to stop existing execution, or **Stop** on a Run for that execution and the work it owns.

Archived Workspaces permit reading only. An archived Conversation's pending
inputs remain readable, but cancellation requires restoring the Conversation.
Kernel-created inputs cannot be canceled through this action. Full Conversation
access is required; read access and administrator status grant no extra command authority.

## Next

- [Organize a Conversation](organize-conversation.md)
- [Inspect running corrections](inspect-running-corrections.md)
- [Schedules and results](schedules.md)
