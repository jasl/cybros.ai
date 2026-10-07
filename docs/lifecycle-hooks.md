# Execution lifecycle hooks

An Agent can declare tools that run at four execution boundaries. Nexus owns
when these boundaries occur and how work progresses; the Agent owns the hook's
meaning. This is a task-backed API, without a plugin loader or shell-command
configuration format.

## Declare a hook

Include `lifecycle_hooks` in the Agent's whole configuration declaration:

```json
{
  "turn_start": { "tool": "execution_check", "timeout_ms": 30000 },
  "pre_compact": { "tool": "execution_check", "timeout_ms": 30000 },
  "post_compact": { "tool": "execution_check", "timeout_ms": 30000 },
  "stop": {
    "tool": "execution_check",
    "timeout_ms": 30000,
    "max_continuations": 2
  }
}
```

The profile API field is described in [Agent configuration](agent-api/v1/profile.md).
Send it inside `{"configuration": {"lifecycle_hooks": ...}}` to
`PUT /agent_api/v1/profile/configuration`, alongside the rest of the application’s
declaration. That PUT replaces the whole configuration and the Profile's
`prompt_documents` root atomically; include the complete owned prompt set or
omission clears its slots. Omitting a configuration field clears its prior
value. Declaring hooks makes an ordinary conversation reply loop-backed
even when `tool_definitions` is empty.
Omit events that are not needed; `null` or an empty object enables none. The
selection is frozen onto each execution. New inputs capture the current profile;
regeneration of a loop-backed reply reuses that loop's hooks and approval policy.
Regenerating an older reply backed only by a direct model invocation does not
convert it into a hook-enabled loop. `tool` names an external executor tool, not
a kernel tool. It need not be exposed to the language model. An executor must serve that name through
the ordinary tool task channel. A profile with hooks declares an approval mode
even if its model has no tools.

Timeouts are required integers from 1 through 300000 milliseconds. Stop also
requires `max_continuations`, an integer from 0 through 20. This is the Agent's
bound on hook-requested continuations, not a general cap on model rounds.

| Event | Boundary | Allowed result |
| --- | --- | --- |
| `turn_start` | Before the execution's first foreground model request, including regeneration and an automatic mail reply. | Acknowledge. |
| `pre_compact` | Before the applicable compaction work. | Acknowledge. |
| `post_compact` | After compaction, before execution proceeds. | Acknowledge. |
| `stop` | A normal final answer is ready and outstanding completion obligations permit delivery. | Accept, or request another model round with feedback. |

Creating an empty Conversation does not invoke `turn_start`. Parallel/background
model branches do not trigger it; a standalone graph with only such branches
can run without a `turn_start` hook. The compaction hooks follow actual
compaction operations, including mid-turn compaction and a
between-turn summary. They do not run for every context-size check.

## Handle the task

The tool input carries `event`, `task_key`, `run_public_id`, and
`conversation_public_id` (null for a standalone execution). The task key names
the source task at that boundary. Hooks observing an answer can also receive
its bounded `output_preview` and `output_size_bytes`; full content remains
available through the normal authorized task reads.
For mid-turn `pre_compact`, `compaction_trigger` identifies the accepted trigger
and `overshoot_bytes` carries its size estimate when available. A token limit
also supplies `overshoot_tokens`, preserving the original unit so resuming the
repair checks token savings rather than assuming a fixed byte-to-token ratio.
The same task retains these facts while the hook runs, so acknowledgement resumes the
requested compaction even if scheduling no longer encounters the original wall.

Return the decision in the executor result's `structured_content`:

```json
{ "continue": false }
```

For `stop` only, a successful result may instead ask for continuation:

```json
{ "continue": true, "feedback": "Run the pending verification before finishing." }
```

Feedback must be nonblank when continuing, at most 16 KiB, and contain no NUL.
The other three events acknowledge with `continue: false`; they cannot inject
feedback into the model, veto completion, or alter compaction policy. Additional
result fields are refused. The ordinary text `content` remains the tool's
readable result; only the kernel-marked hook task gives this structure lifecycle
meaning. Returning the same object from an ordinary model-invoked tool does
not grant it control over the execution.

Stop continuation stays in the same execution and reply, preserving prior work.
It requires an existing model round to inherit. A tool-only execution can
acknowledge Stop, but requesting continuation fails with `hook_requires_model`;
the hook does not select a new model from the profile.
The next candidate answer passes through Stop again. Each event/source pair
has one durable hook task, so retries of scheduling reuse that task rather than
running the hook again. Executor transport retries still require the handler's
normal idempotence discipline.

## Failures and forced stop

Hooks use ordinary approval evaluation, task dispatch, claims, deadlines, and
task repair. Kernel-origin approval behavior still applies, including explicit
deny rules. A tool failure, timeout, invalid decision, or exceeded continuation
allowance leaves a visible failed task and attention hold. It does not silently
accept an ending. An operator can use the existing task repair operations.

Force stop always wins: it bypasses Stop and cancels pending hook work. A hook
cannot prevent account/Agent shutdown or keep a forcibly stopped execution alive.

## rho configuration

rho accepts the same object at
`plugins["rho.lifecycle_hooks"].configuration` in `<RHO_HOME>/settings.json`.
The default is `{}`. Configure it through **Settings → Plugins → Lifecycle Hooks**
or `rho extensions configure rho.lifecycle_hooks` with a field-operation batch.
Each event is a complete group: supply its tool, timeout and, for Stop, continuation
limit together. Saved changes refresh future declarations; disabling the plugin
withdraws future hooks. Accepted executions retain their captured hooks. Supply
the handler as an ordinary extension or tool provider. The Ruby SDK exposes the field through
`profile.declare_configuration(lifecycle_hooks: ...)`.
