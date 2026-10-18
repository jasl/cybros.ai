# Stored conversation reasoning

```text
GET /agent_api/v1/workspaces/{workspace}/conversations/{conversation}/turns/{turn}/variants/{variant}/reasoning
```

This route reads the displayable reasoning retained for one candidate answer. It requires
conversation read standing, including for an inherited turn reached through a
fork. A concealed conversation, turn, or variant is `404`; a hidden turn remains
readable by its known identity, as on the variant deck. An unrelated turn or
variant is `404`. Executor transport credentials cannot use this member route.

```json
{
  "items": [
    {
      "task_key": "r2",
      "model": {"provider_id": "example", "model_ref": "reasoning-model"},
      "available": true,
      "text": "The provider's displayable reasoning text."
    }
  ],
  "pagination": {"next_before": null, "has_older": false}
}
```

For a run-backed candidate, each item names a visible model task's selected
invocation, including branch tasks. `model` identifies the invocation that
produced this reasoning, including its effective `reasoning_enabled` and
`reasoning_effort` when set; it is not
the conversation's current model. Native signatures, encrypted reasoning,
provider request/response documents and superseded invocation attempts are
never returned. A selected invocation without displayable text has
`available: false` and no `text`. Unstarted model tasks and hidden internal
tasks are absent. A direct reply returns at most one item, without `task_key`;
a manual candidate without reasoning returns an empty list.

The default page contains the newest 20 selected model tasks, returned in
creation order. `limit` must be between 1 and 100; an invalid limit or cursor
returns `400 parameter_invalid`. Echo the opaque `next_before` as
`before` to read older tasks; clients must not parse it. Pagination counts
tasks, including those without displayable reasoning, so a page's work is
bounded independently of the conversation's history. Reads acquire no locks
and do not drive execution. Newly completed work appears on a fresh first page.
This route does not change the lightweight timeline or transcript feed.

Reasoning follows [execution-detail retention](execution-retention.md), not
retained conversation text. Once detail has been collected the route returns
`410 execution_details_pruned`, distinct from an available execution with no
displayable reasoning. Increasing retention cannot recover deleted reasoning.

The Ruby SDK exposes the same window through
`conversation.turns.reasoning(turn_id, variant_id, before: nil, limit: nil)`.
