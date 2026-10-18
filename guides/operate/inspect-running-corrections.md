# Inspect running corrections

Open a Conversation Run's **Text corrections** page to inspect waiting text
fixed to that execution. Applications and SDKs submit corrections and choose or
advance their timing through the [inputs API](../reference/agent-api/conversation-inputs.md).
The Nexus page provides reading and cancellation. Standalone and Side Runs do
not offer this browser correction list.

## Manage waiting corrections

The paginated list includes only corrections fixed to this Run, not all queued
inputs or unpinned steers. Open an item to read its text and timing. Choose
**Cancel correction** to remove it while waiting. If processing wins first, the
page shows the available evidence instead of claiming cancellation succeeded.

Cancellation requires write access to the Conversation and a writable Workspace.
Members with full access can cancel another member's correction. An archived
Conversation permits reading but not cancellation.

An already sent model request remains unchanged. Earlier processing chosen by
an application does not resume a paused Run, retry a failed Task or approve a
held operation. Tools retain their original execution ownership.

## Follow the evidence

| Page state | What it proves |
| --- | --- |
| Waiting | The exact-target Input is still waiting for this Run |
| Added to a model request | A retained event identifies the Input, Run and consuming Task |
| Canceled | A retained cancellation event identifies the Input and target Run |
| Processing result unknown | Current rows and retained events do not establish the result |

An acceptance record proves only acceptance. The waiting row disappears on
consumption or cancellation, so absence alone does not distinguish them.
Cancellation evidence does not identify an actor or reason; ending a Run can
also cancel an unconsumed correction.

**Added to a model request** does not prove that the model followed the text,
that the request succeeded or that an answer was delivered. Open its consuming
Task, original Run or answer candidate when available. These links retain the
original execution after another candidate is selected. Candidate-level
additional text is an aggregate, not a permanent per-input receipt.

Event items expire after 30 days. Missing evidence stays unknown; the page does
not resend text. Collected execution details are unavailable while the Run's
retained overview remains readable. See [Retention, usage and budgets](retention-usage-budgets.md).

## Next

- [Inspect and recover work](work-console.md)
- [Read and cancel Conversation inputs](read-conversation-inputs.md)
- [Conversation event evidence](../reference/agent-api/conversation-feeds.md)
