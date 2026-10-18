# Organize a Conversation

Use the Nexus browser console to rename or archive a Conversation and read its
saved candidates and branches. Open it under **Workspaces → Work → Conversations**.
Management actions require full Conversation access and a writable Workspace.

## Change the title

Choose **Edit title**, enter a title, and save. Leave the title empty to use
the unnamed display. Titles can contain up to 255 characters.

If another change wins while the form is open, Nexus preserves your draft and
shows the current title and version. Review that value and check the confirmation
before saving again. Another intervening change requires another review. Restore
an archived Conversation before changing its title.

## Archive and restore

Choose **Archive conversation** and review the confirmation. Archiving includes
the Conversation's Subagent tree and discards its Sides, stopping their unfinished
work. Ordinary branches keep
their own archive state. Subagent Conversations and Sides cannot be archived
independently through this action.

Archiving does not stop already accepted ordinary work. Runs, queued inputs,
approvals, questions and necessary result delivery can continue. The Conversation
remains readable and exportable, but it does not accept new inputs.
[**Stop conversation work**](work-console.md#stop-conversation-work) remains
available in an archived Conversation while its Workspace is writable. Review
that separate action's confirmation when you want to stop existing execution.

Find the Conversation using the archive filter, then choose **Restore
conversation**. Restoration reopens its Subagent tree. It does not bring back
discarded Sides. The Conversation retains the return link to the filtered list
you used to open it.

## Read candidates and branches

Open a Turn's candidate list and choose **Open this candidate** to read its exact
answer. Browsing does not change the selection. Related links show readable
children, branches and Sides, with current access checked for each resource.

Regeneration, selecting an active candidate and creating branches are application
or SDK operations. The [Conversation](../reference/agent-api/conversations.md)
and [Turn](../reference/agent-api/conversation-turns.md) contracts define their
snapshots, eligibility, idempotency and execution consequences. Nexus retains
these mechanisms without providing browser authoring forms.

## Next

- [Read and cancel Conversation inputs](read-conversation-inputs.md)
- [Inspect and recover work](work-console.md)
- [Recover a Conversation cost limit](recover-conversation-cost.md)
