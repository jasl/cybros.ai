# Approvals and rules

Approval is a kernel stage between "ready" and "runs": every tool call crosses it, under every mode, never skipped. What decides the crossing is the **mode** and the **rule list** frozen on the run, and the row's **origin** — who wrote it.

## Modes

For a model-composed tool call:

| Mode | Deny rule matches | Allow rule matches | Ask rule matches | Unmatched |
| --- | --- | --- | --- | --- |
| `bypass` | Fails `approval_denied` with the rule's reason | Granted | Granted | Granted |
| `ask` | Fails `approval_denied` | Granted | Parks | Parks |
| `rules` | Fails `approval_denied` | Granted | Parks | Fails `approval_denied`: "no approval rule allows NAME" |

Deny binds everywhere, for every origin. `ask` parks every model call unless an allow rule names it. `rules` is the policy itself: what it does not name is refused as data the model reads — a typo in a tool name is a refusal, never a grant and never a 24-hour park. An agent that wants "unmatched allow" authors `{ "tool": "*", "verdict": "allow" }` last, explicitly.

## Origin

- A row a model composed is a `model` row: the mode and rules govern it.
- A row appended through the tasks door is an `author` row; a row the kernel planted (a continuation, a summarizer, the `ask` await) is a `kernel` row. Both are pre-approved by their origin — the appender could approve, the kernel asks nobody — unless a rule naming their `origin` opts them back in. A person's own command line is never re-prompted.

## The park

A parked call rests at `needs_approval`, addressed to the host's agent, with the effect profile the approver reads frozen on it and a 24-hour clock armed. It appears on that application's inbox as kind `approval`, the run announces `approval_required` and stays `running`, and the addressee is nudged `work_available`. It ends by `approve` or `deny`, by the clock (`timed_out approval_expired` under the row's own failure policy; the next round reads that nobody approved it), or by a stop.

Stopping cancels parked calls with the rest of the unstarted work. Revoking an executor clears a held row's addressee instead of failing it; the person's door still answers.

## Rule grammar

`approval_rules` is a JSON array; each rule is an object of at most these six keys:

```json
[
  { "tool": "bash|start_process", "path": "command", "match": "*git push*--force*",
    "verdict": "deny", "reason": "force push rewrites history others may hold; a person can run it" },
  { "tool": "write|edit", "path": "path", "match": "*.env", "verdict": "deny" },
  { "tool": "memory_*|ask|delegate_task|code|skill", "verdict": "allow" },
  { "tool": "bash|start_process", "path": "command", "match": "ls*", "verdict": "allow" },
  { "tool": "bash", "verdict": "ask", "origin": "author" }
]
```

| Key | Meaning |
| --- | --- |
| `tool` (required) | `\|`-separated anchored globs. Kernel aliases match the resolved execution name. Runner routes match either their served name or captured callable name: `bash` covers all routed `bash` tools, while `bash__0123456789ab` selects one callable and target. Nexus MCP routes match only their captured callable name. A served-name deny or ask still takes precedence over a callable-name allow. |
| `verdict` (required) | `allow`, `ask` or `deny` |
| `path` | A dotted key path into `tool_input` — `command`, `edits.0.path`. Absent, the rule matches the tool as a whole; present without `match`, it matches when there is text at the path. |
| `match` (needs `path`) | An anchored glob over the text at the path. Only `*` (anything, newlines included) and `?` (one byte) are special; a fragment needs a leading `*`. A string matches as-is; an array of scalars is joined by one space (`["rm", "-rf", "/"]` reads `rm -rf /`); anything else never matches. |
| `reason` | The denial's `error.detail`, first 256 bytes |
| `origin` | `model` (default), `author` or `kernel` |

Evaluation collects every matching rule: deny wins, then ask, then allow — an agent's deny is never overturned by a later allow. Glob only, no regex. The kernel interprets no tool argument: the path is the agent's, and the evaluator reads `tool_input` as opaque JSON through it. The list is validated at declaration under a 64 KiB bound.

## Tightening per request

An input may narrow `tool_names` and set a stricter `approval_mode` for that request; it can never widen the declaration. Kernel mail replies must keep approval at least as strict as the profile's current settings.

## Questions

`ask` is a kernel tool that parks a question for a person with a prompt, optional options and a 24-hour deadline. The run stays `running` and announces `awaiting_human`; the task sits in `awaiting_input`. An ask a client authored through the tasks door carries its `resolution_token` in the append receipt, so the client answers it directly and nobody else is nagged. An expired question leaves a hold for a person's decision rather than a success.

## Resolve decisions

One rule covers every decision a person makes: **machines claim and commit on the executor plane; people decide on the member plane.** A question and an approval are both *decisions* — they differ only in payload and in the verb that ends them.

| Decision | How you learn about it | How you end it |
| --- | --- | --- |
| A question (`ask`) | `attention_required` with `reason: awaiting_human` on the run's lifecycle feed; the task reads `awaiting_input` with its `prompt`, `options` and `multi` | `POST …/runs/{id}/tasks/{key}/resolution` with `content` (and `outcome: failed` to decline); no token for a model's own ask, the receipt's `resolution_token` for one your application authored |
| An approval | `attention_required` with `reason: approval_required`; the task reads `needs_approval` with its `tool_name`, `tool_input` and frozen `effect_profile` | `POST …/tasks/{key}/approve` or `…/deny` with an optional reason |

Both need your application's **member** credential: the deciding principal is recorded on the settle (`resolved_by`, or the approval's origin), which is why a transport credential cannot do it. If your application also runs an executor, its inbox lists the same questions and approvals as `ask` and `approval` rows and its cable receives `work_available` for them — a low-latency notice, never something to claim or commit; the claim and commit doors answer `409 not_claimable_kind`.

A simple loop: subscribe to the conversation's `lifecycle` feed (or poll the run), read each task named in `attention_required.blocked_task_keys`, show the question or the call to a person, and call the matching member-plane verb. Nothing needs to be done quickly: a hold has no clock except the 24-hour park on the decision itself, after which the task expires and the run waits for `retry` or `abandon`.

The Ruby SDK packages that loop as `run_context.decisions`: one `Decision` per task resting on a person, with the question (`prompt`, `options`, `multi`) or the call (`tool_name`, `tool_input`) and the verb that ends it — `answer(content:)`, `approve`, `deny(reason:)`.

```ruby
client.workspace(workspace_id).runs.run(run_id).decisions.each do |decision|
  decision.ask? ? decision.answer(content: "Now") : decision.approve
end
```

rho's `GET /asks` control route is exactly this loop over its own inbox; its browser page, Telegram and editor integrations all end decisions through the member plane.

For MCP tools, a rule's `tool` pattern matches the captured callable name, such as
`work_search`, even when the remote tool is named `search`. This lets applications
apply different policies to separate external accounts. Approval shows the
connection name, non-secret account label, remote tool and parameters. It does not
grant connection use or restore revoked access, and `ask` uses the existing Run
write permission rather than a separate Human-only role.
