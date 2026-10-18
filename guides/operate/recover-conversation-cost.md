# Recover work after a Conversation cost limit

When a Conversation reaches its cost limit, Nexus refuses new priced model work.
Increase or clear the limit, then explicitly recover the failed work. Saving a
new limit does not resume execution.

## Review and change the limit

1. Open the Conversation or the Task that reports the cost limit failure.
2. Open the cost limit editor. Review the known cumulative cost and its coverage,
   the current limit, and the Account's cost unit.
3. Enter a higher limit, or leave the field empty to remove it. Zero is a valid
   limit. Save, then return to the original Task or reply.

You need full Conversation access and write access to its Workspace. A
Conversation can be archived while you change only its cost limit; an archived
Workspace cannot be changed. If another edit changes the Conversation, the form
preserves your amount and shows the current value. Review it before explicitly
retrying the save.

The limit covers that Conversation's known cumulative cost. It is not a
reservation or a strict maximum bill: already admitted calls can finish, and
unknown cost remains unknown. Children, forks and Sides have independent totals
and limits. See [Usage and cost](../build/usage-and-cost.md).

## Retry a failed Task

1. Return to the original failed Task, including a compaction Task when that is
   the work that reached the limit.
2. Review its error and choose **Retry** when the Task offers it.
3. Follow the same Run to its result.

Retry preserves completed tools, their results and pending dependents. It does
not replay the entire Conversation. **Resume** controls a paused Run and does
not repair a failed Task. Raising a limit alone does not clear the failure.

Already accepted work may be retried after its Conversation is archived.
Stopped, replaced or collected work retains its existing recovery restrictions.

## Regenerate a direct reply

For a direct reply without a held Run to repair, adjust its limit in Nexus, then
regenerate or continue in the application or SDK. The browser retains the failed
candidate and explains this next step; it does not create another candidate.
Raising the limit alone does not start any work.

Regeneration uses the selected reply's captured configuration at acceptance and
can incur new model or tool cost. A held Run should be repaired through its
original Task. See the [Turn contract](../reference/agent-api/conversation-turns.md)
for eligibility and replay behavior.

## Next

- [Organize a Conversation](organize-conversation.md)
- [Inspect and recover work](work-console.md)
- [Errors and recovery](../build/errors-and-recovery.md)
- [Conversation cost limits](../reference/agent-api/conversations.md#cost-limits)
