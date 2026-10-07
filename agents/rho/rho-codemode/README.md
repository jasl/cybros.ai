# rho-codemode

`rho-codemode` supplies rho's `code` tool. Every rho mode loads `rho/codemode`
by default, including `api_only`. The extension serves each available agent and
runner address; a standalone runner can load the same extension. Named agents
use an eligible Runner’s target-qualified `code` declaration, because they have no
application executor address of their own. The package embeds V8 through `mini_racer` and
requires no Node, Bun or Deno runtime.

rho controls model access with `plugins["rho.codemode"].configuration.default`
(`on` by default, or `off`). Change the running daemon's default with
`rho extensions configure rho.codemode '[{"op":"set","path":["default"],"value":"off"}]'`.
Use `rho run --code-mode` or `--no-code-mode` to override it for a
conversation. Control clients pass the boolean `code_mode` field when opening or
replying; a saved conversation choice is inherited by later requests and forks.
Omitting that field uses the saved choice, then the current global default.
An explicit `null` clears the conversation override back to that default.

Off removes the `code` tool and its authoring hint from new rho-authored turns,
including when the caller supplies an explicit tool list. The executor keeps the
extension registered so already accepted programs can finish.
Changing the switch does not change an existing turn's frozen tools or cancel work.
Other Agents using Nexus's task-operation API keep their own enablement policy.

The extension owns JavaScript execution, tool metadata and authoring instructions.
The runner's claim-scoped orchestration bridge owns transport and live waits. Nexus
owns accepted task operations, recorded observations and task settlement. The VM
does not receive clients, credentials, filesystem handles or Ruby callbacks.

## Authoring

Call `code` with `{ "code": "...", "params": { ... } }`. `code` is the body of an
async function; top-level `await`, expressions, loops and branching work without a
wrapper, Markdown fences or TypeScript compilation. `params` contains frozen JSON.

```javascript
const results = await Promise.all([
  tools.read({ path: "README.md" }),
  tools.read({ path: "Gemfile" }),
]);
for (const result of results) {
  if (result.is_error) text(JSON.stringify(result));
  else for (const block of result.content || []) {
    if (block.type === "text") text(block.text);
  }
}
```

Only the task's frozen declarations are callable. Use `tools[name](input)` for a
name that is not a JavaScript identifier. The `code` tool itself is omitted; nested
tool steps and child model declarations use that same allowed catalog. Child model
defaults keep their configured tool subset after that restriction. Each call returns a Promise with a readonly
`operation_key`, available before settlement. Tool calls preserve their complete
outcome envelope: `status`, `is_error`, `content`, `output`, `structured_content` and
`error` retain their recorded presence and values. A tool's `is_error: true` resolves;
a recorded bridge refusal rejects with `error.refusal`. An uncertain task outcome is
a value and never authorizes replaying the effect.

`Promise.all` returns input order. `Promise.race` observes the earliest recorded
settlement and does not cancel the other calls. Keep references and settle those calls
before returning. `Promise.allSettled` keeps refusal errors as JavaScript Error
objects; select `reason.message` or `reason.refusal` when returning JSON.

Use `text(string)` for model-visible final text, `value(json)` for structured output,
and `resource({uri, name, mimeType?})` for a reference authorized by its owning resource
surface. A returned JSON value replaces `value()`; an absent return leaves it alone.
`null`, `false` and `0` are values. Structured output alone is not model-visible text.
All output is buffered until successful finalization. Intermediate outcomes stay out of the final result unless selected.

To forward an image or PDF already captured by a child tool, pass its
`resource_link` block to `resource(block)`. Nexus retains that observed capture and
carries supported media into the next model request using the existing attachment
policy. This does not accept raw image bytes or arbitrary external URLs.

`nexus.model(input)`, `nexus.ask(input)`, `nexus.steps(input)`,
`nexus.replace(input)`, `nexus.cancel(input)`, `nexus.join(input)` and
`nexus.background(input)` emit their named host operation with the supplied JSON
input. The kernel validates the operation and owns its task references. These calls
use the same Promise and observation rules as tools; source cannot write scheduler
edges or mutate task state directly.

| Helper | Input |
| --- | --- |
| `nexus.model` | `{prompt, model?, tools?, ...modelStepFields}`; model is `"provider/model"` or `{model, reasoning_effort?}` |
| `nexus.ask` | `{prompt, options?: string[], multi?: boolean}` |
| `nexus.steps` | An array of public step objects, or `{steps: [...]}` |
| `nexus.replace` | `{operation_key, tasks: [authoredFutureKey], steps: [...]}` |
| `nexus.cancel` | `{operation_key, tasks?: [authoredKey]}` |
| `nexus.join` | `{operations: [operationKey], until: "all" | "any" | number, losers?: "cancel" | "run_out"}` |
| `nexus.background` | `{steps: [...], lifetime: "conversation" | "turn", wake: "auto" | "passive"}`, or `{operation_key, lifetime?, wake?}` to transfer existing work |

For example, a batch can declare a read and a model step consuming it:

```javascript
const plan = nexus.steps([
  {tool: {key: "readme", name: "read", input: {path: "README.md"}}},
  {model: {key: "summary", prompt: "Summarize the project.", after: ["readme"], results: ["readme"]}},
]);
const outcome = await plan;
text(JSON.stringify(outcome));
```

The same interface authors a durable DAG with parallel agents and a synthesis
node. Written order creates scheduling dependencies; `after` adds waits, while
`results` both waits and selects the result envelopes the model reads:

```javascript
const outcome = await nexus.steps([
  {parallel: [
    {model: {key: "design", prompt: "Review the proposed design."}},
    {model: {key: "tests", prompt: "Identify the tests the design needs."}},
  ]},
  {model: {key: "synthesis", prompt: "Combine the two reviews.", results: ["design", "tests"]}},
]);
text(JSON.stringify(outcome));
```

A parallel member may itself be a sequence. `until: "any"` or a positive quorum
and `losers: "cancel" | "run_out"` select a race; the default is to wait for all.
The kernel persists these tasks and their dependencies. The run's public
`GET /agent_api/v1/workspaces/{workspace}/runs/{run}/graph` read returns nodes,
scheduling edges, result sources and Mermaid. See the
[step grammar](../../../docs/agent-api/v1/runs.md#the-step-grammar).
There is no arbitrary edge-mutation API or persisted JavaScript VM: the code tool
authors work through the kernel, and a lost VM still follows ordinary task failure.

`plan.operation_key` is available immediately for a replacement of an unstarted
authored key. The kernel accepts a replacement wholly or refuses it; it never edits
started work. Ordinary independent tool calls do not become an atomic batch merely
because the host transports them together.

`nexus.replace` returns a new Promise for its new work. The original Promise keeps
the result task identities in its acceptance receipt: if its terminal task is retired,
it observes cancellation while the replacement Promise observes the new result.
Consume or explicitly release the original operation as well as awaiting the replacement.
Replacement rewires unstarted downstream reads without retargeting an existing Promise.

To continue without awaiting an existing child, explicitly transfer its ownership:

```javascript
const work = nexus.model({prompt: "Prepare a detailed project summary."});
await nexus.background({operation_key: work.operation_key, lifetime: "conversation", wake: "auto"});
text("The summary will arrive when ready.");
```

A successful transfer receipt releases the parent's obligation to join that work.
It does not settle `work` with an invented result. Cancellation and joins retain the
real child outcomes and their ordinary observation order.

## Runtime boundary

Each `Runtime#call(program:)` creates one VM and keeps it until the invocation
finishes. `program` contains `source`, optional `params`, and the frozen `tools`
declarations, including the `code` schema's `$id`, currently
`urn:cybros:rho:codemode:javascript:1`. The binding is checked before source runs.
An unsupported binding fails with `unsupported_binding`; new work must use the
installed declaration. Nexus stores this schema without interpreting its language.

The runtime yields a `State` with status `request` or `observe` to its host block.
The host returns accepted operation events and recorded observations; final return
has status `finished` or `failed`. An operation event carries `type: "operation"`,
`key`, `request` and exactly one of `receipt`/`refusal`. An observation carries
`type: "observation"`, `key` and exactly one of `outcome`/`refusal`. Durable
`position` belongs to the host. A finite wait supplies no invented observation.

Every observation settles its Promise and drains resulting microtasks before the
next event. External waits occur after a V8 call returns, retaining local variables
and Promises without spending the computation budget. No new VM or source replay
occurs between requests. Lost execution state fails instead of reconstructing
source; receipts can still recover a missing control response for the live owner.

An acceptance that differs from the pending request fails the invocation. Returning
with outstanding attached operations fails, as does a Promise that has no possible
external observation. Transport loss, claim changes and Stop are host control,
outside source `try/catch`.

The supported data boundary is finite JSON: no getters, class instances, functions,
undefined values in arrays/objects, non-finite numbers or cycles. Parameters and
outcomes are immutable. There are no direct filesystem, network, process or module
APIs, ambient time/randomness, locale-dependent formatting, shared memory, WebAssembly
or typed-array allocation. Host control is closed behind a per-VM capability that
source and trace never receive. The bridge's intrinsic prototypes are frozen.

Default bounds are 256 KiB of source, 8 MiB each of program context and one event
batch, and 1 MiB of result and pending-request JSON. Each V8 call, including its
Promise microtasks, has a 1-second execution timeout. External waits do not count
against it; an infinite synchronous or microtask loop still terminates. There is no
cumulative operation-count or elapsed-work ceiling. Cancellation is checked between
bounded V8 calls and throughout host waits.

The 64 MiB V8 heap setting is a garbage-collection soft limit, not a hard process/RSS
limit or an operating-system sandbox. This package does not claim isolation from
native engine faults.

## Verification

Run from this directory:

```sh
bundle install
bundle exec rake
bundle exec rake build
```

The default task tests a live V8 across waits, ordered observations, Promise
behavior, buffered output, control isolation and resource bounds. It also exercises
multiple live parents and their children on the real worker pool, then runs RuboCop
and RBS validation. Kernel acceptance and effect-aware expiry require the host's
integration and E2E suites; runtime tests alone do not establish those facts.
