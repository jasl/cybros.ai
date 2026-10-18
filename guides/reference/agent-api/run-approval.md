---
title: Run approval
description: The kernel's approval stage — the modes, the origin rule, the park, the rule grammar — and the lifecycle hooks a declaration schedules around a turn.
---

# Run approval

Every tool call crosses one kernel stage between ready and runs. This
page is what decides that crossing, and the hooks a declaration
schedules around the turn it happens in. The doors that end a held call
are `approve` and `deny` on [Runs](runs.md).

## The stage

Approval is a kernel stage between "ready" and "runs": every tool call crosses it, under every mode,
never skipped. What decides the crossing is the **mode** and the **rule list**
frozen on the run row — from the create shell on a standalone run, from
the declaring profile's `configuration` (or the input's tightening,
[Conversations](conversations.md)) on a run-backed turn — and the row's
own **origin**: who wrote it.

## The origin rule

A row a model composed (a round's fan, a task operation or
`delegate_task` graph) is a `model` row: the mode and the rules govern it. A row
appended through the tasks door is an `author` row and a row the kernel
planted (a continuation, a summarizer, the `ask` await) a `kernel` row:
both are pre-approved by their origin — the appender is a principal who
could approve, the kernel asks nobody — unless a rule that names their
`origin` opts them back in. This is what every reference does (a person's
own command line is never re-prompted), and it is why a person's `rho
append` or `--until` check never parks.

## The modes

For a model-composed tool call:

| mode | deny rule matches | allow rule matches | ask rule matches | unmatched |
| --- | --- | --- | --- | --- |
| `bypass` | `failed approval_denied` + the rule's reason | granted, `origin: mode` | granted, `origin: mode` | granted, `origin: mode` |
| `ask` | `failed approval_denied` | granted, `origin: rule` | PARKS | PARKS |
| `rules` | `failed approval_denied` | granted, `origin: rule` | PARKS | `failed approval_denied` — "no approval rule allows NAME" |

Deny binds everywhere, for every origin. `ask` parks every model call
unless an allow rule names it (the rules are an allowlist refinement);
`rules` is the policy itself, and what it does not name is refused AS
data — a typo in a tool name is a refusal the model reads, never a grant
and never a 24 h park for nobody; an agent wanting "unmatched allow"
authors `{"tool": "*", "verdict": "allow"}` last, explicitly. An `author`
or `kernel` row is granted by its origin under every mode, parks only on
an `ask` rule naming its origin, and is refused by a deny rule naming it.

## The park

A parked row rests at `needs_approval` addressed to the host's
agent application (nobody on a Human's own standalone run — the member
door alone), with the effect profile the approver reads frozen on it and
the 24 h park clock armed; it lists on that inbox as kind `approval`
([Executor inbox](executor-inbox.md)), the run announces `approval_required` naming
it and stays `running`, and the addressee is nudged `work_available`
(kind `approval`). It ends by `approve` or `deny` (the routes above), by
the clock — `timed_out approval_expired` under the row's own
`on_failure`, the next round reading "Nobody approved this tool call
before it expired." — or by a stop. Explicit executor revocation clears a
held row's addressee (`task_readdressed` with its own detail) instead of failing
it: the person's door still answers. Agent removal separately fences
that application's credentials and asynchronously force-stops related runs;
their held rows are canceled through the ordinary stop path.

## The rule grammar

`approval_rules` is a JSON array; each rule
is an object of at most these six keys:

```json
[{"tool": "bash|start_process", "path": "command", "match": "*git push*--force*",
  "verdict": "deny", "reason": "force push rewrites history others may hold; a person can run it"},
 {"tool": "write|edit", "path": "path", "match": "*.env", "verdict": "deny"},
 {"tool": "memory_*|ask|delegate_task|code|skill", "verdict": "allow"},
 {"tool": "bash|start_process", "path": "command", "match": "ls*", "verdict": "allow"},
 {"tool": "bash", "verdict": "ask", "origin": "author"}]
```

- `tool` (required): `|`-separated globs, each ANCHORED — `bash` names
  `bash` alone, `memory_*` every memory tool. Kernel aliases match the resolved
  execution name. Runner routes match either the served name or the captured
  callable name: `bash` covers every routed `bash`, while `bash__0123456789ab`
  selects that exact callable and target. Nexus MCP routes match only the
  captured callable name. Each rule is evaluated once, in its original order;
  a served-name deny or ask still takes precedence over a callable-name allow.
  Argument paths use the resolved input keys.
- `verdict` (required): `allow | ask | deny`.
- `path` (optional): a dotted key path into `tool_input` — `command`,
  `edits.0.path` — an object walked by key, an array by integer index;
  anything else walks nowhere. Absent, the rule matches the tool as a
  whole; present without `match`, the rule matches when there is text at
  the path.
- `match` (optional, needs `path`): an ANCHORED glob over the text at the
  path — only `*` (anything, newlines included) and `?` (one byte) are
  special, every other byte is literal; so a fragment needs a leading
  `*`. The text at the path: a string as-is; an array of scalars joined
  by ONE space (`["rm", "-rf", "/"]` reads `rm -rf /`); anything else —
  absent, an object, a nested array, a number alone — never matches, and
  under `bypass` a non-match is a grant.
- `reason` (optional, text): the denial's `error.detail`, the first 256 bytes.
- `origin` (optional, `model | author | kernel`, default `model`): whose
  rows the rule addresses.

Evaluation collects every matching rule: deny wins, then ask, then allow
(codex/claude-code strictness — an agent's deny is never overturned by a
later allow), the first deny's `reason` riding; unmatched is the mode's
word. Glob only, no regex. The kernel interprets no tool argument: the
path is the agent's, and the evaluator reads `tool_input` as opaque JSON
through it. The list is validated at declaration — a seventh key, a
missing tool, a verdict outside the three, an origin outside the three, a
`match` without a `path`, an empty path segment, a glob that does not
compile — under the 64 KiB envelope bound and with no length limits.


## Lifecycle hooks

An Agent may declare `lifecycle_hooks` through its
[configuration](profile-configuration.md). Nexus freezes the
declaration onto each execution and schedules its named executor tools as
ordinary tasks at `turn_start`, `pre_compact`, `post_compact`, and `stop`.
Hooks are independent of the model's declared tool list. Turn-start and
compaction hooks acknowledge their event; a Stop hook can accept the candidate
final answer or request a bounded model continuation with feedback. Hook
failure follows the existing attention, retry, and abandon flow. Explicit
force-stop cancels hook work and never asks it for permission.

See [Lifecycle hooks](../../build/lifecycle-hooks.md) for event ordering and
[Executor](executor-inbox.md#lifecycle-hook-tasks) for the input and result protocol.

MCP tool rules match the frozen callable name. Their task `target` contains
`kind: "mcp"`, `connection_public_id`, `display_name`, `account_label` and
`tool_name`; the last is the remote name. Show this target with parameters and
`effect_profile` when requesting a decision. The conservative MCP effect is
`write`, destructive, open-scope, non-idempotent and without reconciliation.
Remote read-only/idempotency annotations do not change that profile.
