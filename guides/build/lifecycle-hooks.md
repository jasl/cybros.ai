# Lifecycle hooks

An agent can declare executor tools that run at four execution boundaries. Nexus owns when those boundaries occur and how work progresses; the agent owns the hook's meaning. Hooks are ordinary tasks delivered through the executor inbox — no plugin loader and no shell-command configuration format.

## Declare

Include `lifecycle_hooks` in the whole configuration declaration (`PUT /agent_api/v1/profile/configuration`):

```json
{
  "turn_start": { "tool": "execution_check", "timeout_ms": 30000 },
  "pre_compact": { "tool": "execution_check", "timeout_ms": 30000 },
  "post_compact": { "tool": "execution_check", "timeout_ms": 30000 },
  "stop": { "tool": "execution_check", "timeout_ms": 30000, "max_continuations": 2 }
}
```

- Omit events that are not needed; `null` or `{}` enables none.
- `tool` names an external executor tool, served through the ordinary tool task channel. It need not be visible to the model.
- `timeout_ms` is 1 through 300000. `stop` also requires `max_continuations` (0 through 20): the agent's bound on hook-requested continuations.
- Declaring hooks makes an ordinary reply run-backed even with no tools, and a profile with hooks declares an approval mode.
- The selection is frozen onto each execution. New inputs capture the current profile; regeneration reuses the run's hooks.

| Event | Boundary | Allowed result |
| --- | --- | --- |
| `turn_start` | Before the execution's first foreground model request, including regeneration and an automatic mail reply | Acknowledge |
| `pre_compact` | Before the applicable compaction work | Acknowledge |
| `post_compact` | After compaction, before execution proceeds | Acknowledge |
| `stop` | A normal final answer is ready and outstanding obligations permit delivery | Accept, or request another model round with feedback |

Creating an empty conversation does not invoke `turn_start`; parallel and background branches do not trigger it. Compaction hooks follow actual compaction operations, not every size check.

## Handle the task

The tool input carries `event`, `task_key`, `run_public_id` and `conversation_public_id` (null for a standalone execution). Hooks observing an answer also receive a bounded `output_preview` and `output_size_bytes`. A mid-turn `pre_compact` carries `compaction_trigger` and `overshoot_bytes` (and `overshoot_tokens` when a token limit triggered it).

Return the decision in the result's `structured_content`:

```json
{ "continue": false }
```

For `stop` only, a successful result may ask for continuation:

```json
{ "continue": true, "feedback": "Run the pending verification before finishing." }
```

Feedback must be nonblank, at most 16 KiB and contain no NUL. The other three events acknowledge with `continue: false`; they cannot inject feedback, veto completion or alter compaction. Additional result fields are refused. The same object returned from an ordinary model-invoked tool has no lifecycle meaning.

Stop continuation stays in the same execution and reply. It requires an existing model round to inherit; a tool-only execution can acknowledge Stop but a continuation request fails with `hook_requires_model`. The next candidate answer passes through Stop again. Each event and source pair has one durable hook task, so scheduling retries reuse it.

## Failures and forced stop

Hooks use ordinary approval evaluation, dispatch, claims, deadlines and repair. A tool failure, timeout, invalid decision or exceeded continuation allowance leaves a visible failed task and attention hold; it never silently accepts an ending. Force stop bypasses Stop and cancels pending hook work; a hook cannot keep a forcibly stopped execution alive.

## In rho

rho accepts the same object at `plugins["rho.lifecycle_hooks"].configuration` (default `{}`), through **Plugins → Lifecycle Hooks** or `rho extensions configure rho.lifecycle_hooks`. Supply the handler as an extension or a tool provider. The Ruby SDK exposes the field through `profile.declare_configuration(lifecycle_hooks: ...)`.
