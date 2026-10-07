# Code orchestration: JavaScript binding

Status: first language binding, implemented by
[rho-codemode](../../agents/rho/rho-codemode/README.md). Normative execution semantics belong to the
[language-neutral code orchestration specification](code-orchestration.md).

This binding defines the JavaScript programming surface. It does not impose JavaScript
semantics on another language binding. rho is the first host; Nexus does not
need rho constants, a JavaScript interpreter or JavaScript-specific protocol values.

Pi codemode's ordinary async code, tool bridge and selective output are the frontend
baseline. The binding also exposes Nexus's general batch and dynamic graph capabilities
where a program needs them. Adopting that baseline does not adopt Pi's session storage
as the execution authority or claim that Pi already implements this durable contract.

## rho integration and model adaptation

The first rho host is a composable extension using rho's existing extension and tool
integration boundaries. It owns the code tool, declarations, prompts, source handling,
language execution and live VM ownership. It can compose with other rho extensions and
tool providers; the rho core does not acquire a second orchestration policy framework.

rho owns enablement through its existing settings and conversation policy. An
explicit request choice wins over a saved conversation choice, then the global
`code_mode` default (`on`). Off narrows the new turn's ordinary tool declarations
and removes the corresponding authoring hint. It does not unregister executors or
change accepted executions, and it adds no code-mode field to the Nexus protocol.

Codemode-specific model adaptation belongs with the Agent extension, independently of
Nexus's provider/catalog definitions. Source wrapping, callable descriptions, prompting,
discovery strategy and model-specific authoring accommodations are application policy.
They may use ordinary model metadata but do not require Nexus to identify a codemode
model family or maintain code-authoring presets. Provider transport and generic model
capabilities retain their existing owners. Another Agent can use the same general
kernel operations without installing this extension or implementing JavaScript.

## Program and callable surface

- An invocation evaluates an async function body with frozen parameters. Top-level
  `await`, ordinary expressions, loops and branching are supported within the documented
  supported subset. TypeScript declarations may describe callable inputs; TypeScript
  compilation and module loading are not required.
- `tools.<name>(arguments)` requests work through the task-scoped bridge and returns a
  Promise. Names map unambiguously to the frozen canonical tool/provider declarations.
  Discovery may shorten model-visible descriptions but never widen that declaration set.
  rho defers Runner/provider schemas behind the kernel's `tool_search` entry point;
  use the returned exact callable name with `tools[name]`. Code mode off retains
  `tool_search` and `tool_call`, so the same deferred tools remain usable without
  JavaScript. Deferral never changes the bridge's frozen authority or target.
- Model work, asks, joins/quorum, cancellation and explicit background ownership use
  the `nexus` helpers below over the core operations.
- Bounded batch submission and controlled replacement of unstarted downstream work
  use helpers over the same general kernel operations. They let a program submit known
  work together and revise pending work after an observation, while ordinary calls,
  loops and result-dependent branching remain available. Helper values carry scoped
  logical task references, not writable raw edges or scheduler internals.
- Direct tool calls outside code remain a valid product choice. Recursive code-tool
  invocation is outside the first binding; normal control flow and child operations
  provide composition without a nested interpreter lifecycle.

The `code` tool receives `{code: string, params?: JsonValue}`. `code` is an async
function body, so no wrapper, Markdown fence or TypeScript compiler is needed. Each
bridge call returns a Promise whose readonly `operation_key` is available immediately.

| Helper | Input and purpose |
| --- | --- |
| `tools[name]` | The declared tool's JSON arguments |
| `nexus.model` | `{prompt, model?, tools?, ...modelStepFields}`; omitted model and tool selection inherit frozen defaults |
| `nexus.ask` | `{prompt, options?: string[], multi?: boolean}` |
| `nexus.steps` | Public step array, or `{steps: [...]}`, accepted as one batch |
| `nexus.replace` | `{operation_key, tasks: [authoredFutureKey], steps: [...]}` |
| `nexus.cancel` | `{operation_key, tasks?: [authoredKey]}` |
| `nexus.join` | `{operations: [operationKey], until: "all" | "any" | number, losers?: "cancel" | "run_out"}` |
| `nexus.background` | `{steps, lifetime: "conversation" | "turn", wake: "auto" | "passive"}`, or `{operation_key, lifetime?, wake?}` to transfer existing work |

`text(string)` selects final model-visible text; `value(json)` selects structured
output; `resource({uri, name, mimeType?})` selects an authorized resource reference.
A returned JSON value replaces `value()`; an absent return preserves the last explicit
selection. Model-only structured output never becomes text implicitly. The package
ships source instructions in its tool description through the authoring boundary.
Old compose aliases and `g.*` are not helper spellings.

## Values and errors

A settled task resolves a result envelope retaining status, `is_error`, content,
structured value and execution error. `null` and `false` remain values; absent output
is distinct. A tool's `is_error: true` does not reject the Promise. The uncertain
outcome is explicit and never causes automatic bridge replay of an external effect.

Language errors and deterministic bridge refusals may reject. If source can catch a
bridge refusal and continue, that refusal is a recorded observation under the core
spec. A lost transport response, stale claim, Stop or unknown acceptance is host control,
not an ordinary catchable result permitting the program to keep issuing work.

`try/catch` and `Promise.allSettled` therefore observe language/bridge rejection without
erasing task-level outcome data. Documentation must teach this distinction rather than
copy the experiment's synthetic `result.ok` fixture shape.

## Concurrency and child disposition

Use ordinary JavaScript Promise semantics. `Promise.all` preserves input-array order;
callbacks can still observe completion in a different order. `Promise.race` selects the
first observed settlement and does not cancel losers. That intentionally differs from
compose's default race cancellation; explicit kernel-backed cancellation/quorum helpers
preserve the capability without redefining Promise behavior.

A successful return cannot accidentally abandon accepted children. The source must
join them, settle cancellation, or explicitly assign background ownership under the
core contract. An unjoined return fails. An uncaught failure uses the owning execution's
ordinary attached-child cancellation, keeping completed/uncertain effects and explicit
background obligations. An unresolved Promise with no possible external observation
or pure progress is an execution failure, not a task that waits forever.

Batch helpers preserve atomic acceptance of the complete child subgraph. A rejected
batch never leaves some children running. A future-replacement helper preserves the
core's all-or-none replacement and task-start winner: it cannot edit started work,
consumed results or source history. Its recorded outcome is delivered to the live VM
like any other observation. Batching transport for independent Promise calls does not
silently turn those calls into one atomic batch; the binding must distinguish explicit
batch semantics from an implementation's transport optimization.

`nexus.replace` returns a new Promise for the replacement work. The original operation's
Promise keeps its accepted result identities: when its terminal task is retired, that
Promise observes cancellation, while the replacement Promise observes the new result.
The source must consume or explicitly release the original operation as well as await
the replacement; replacement does not silently retarget a previously returned Promise.

## Live execution

One invocation evaluates the original source once and retains the same MiniRacer V8
context across external waits. The host accepts child work and observes its results
outside the V8 call, then delivers each recorded settlement into that same context.
Promise callbacks and their microtasks run before the next host event is accepted.
This preserves locals and causal order without rebuilding source prefixes.

The ordinary Runner hosts handlers as Async tasks on its configured worker threads.
Waiting yields scheduling capacity, including for children on the same executor;
claim cancellation, finite deadline extension and resource leases retain their original
execution owner. Native V8 calls have a finite execution bound. Host waiting time does
not consume that CPU bound, and no cumulative source-replay budget exists.

The subset excludes direct host filesystem/network/process APIs, imported modules,
ambient time and randomness. Needed observations arrive through declared operations
or fixed inputs. The package embeds V8 through MiniRacer and needs no Node, Bun or Deno
runtime. Its README states concrete source, JSON, event and execution limits; the V8
heap limit is a soft collection limit, not a hard process-memory boundary.

A lost HTTP response is reconciled from accepted operations and ordered observations
while the VM remains alive. Loss of the VM/process instead fails or times out the
ordinary invocation; source is not automatically replayed. An adapter's ability to
reconnect to a native external session does not extend to arbitrary JavaScript state.

## Output and implementation acceptance

The program may filter/reduce intermediate data and explicitly select final text,
structured values and authorized media references. The caller's model need not receive
every intermediate task result. Task result/audit/usage owners still retain their facts.

The implementation buffers output until finalization. `text()` selects local output;
only the ordinary final commit publishes durable content. Any live progress uses
the existing best-effort progress contract; final output remains write-once.

The binding must pass every core conformance scenario, plus ordinary JS sequential,
conditional, parallel/all-settled/race, callback-issued-operation and unjoined/stalled
Promise cases. Explicit batch and future-replacement helpers must also pass acceptance,
retry, refusal and receipt-reconciliation cases through the real kernel boundary. Its VM isolation
and finite resource bounds require production tests.
Production tests must prove one live VM across waits, child progress with one worker
and with all workers initially hosting waiting parents, and truthful lost-state failure.
Historical replay experiments do not qualify this execution lifecycle.

Supported weaker models must be able to generate an acceptable, structurally correct,
executable program. The extension may supply appropriate declarations, examples and
model adaptation to reach that floor. Runtime conformance separately verifies execution
and result behavior; a valid program or published graph alone cannot prove that runtime.
Model task success, voluntary use, maximal capability use and optimal parallelism are
measured separately from structural generation. Full use of the orchestration surface
is not a mandatory authoring criterion. Optional real-model
diagnostics require an explicit budget and authorization.
