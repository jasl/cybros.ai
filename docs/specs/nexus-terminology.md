# Nexus terminology

Status: implemented and locally verified, 2026-10-06. This is the naming contract for the
breaking change, alongside [multi-environment execution](nexus-multi-environment.md).
It is implemented in this checkout; deployment is a separate task. The [change inventory](../plans/2026-10-06-nexus-terminology.md)
defines the coordinated implementation and its consumer boundary.

Use familiar AI and agent terminology where the responsibility matches. Preserve
distinctions that carry identity, authority or lifecycle. A naming change alone
does not introduce a model, table, execution engine or compatibility layer.

## Reference vocabulary and local decisions

Current primary references provide useful conventions, not one universal schema:

| Reference | Relevant convention | Nexus decision |
| --- | --- | --- |
| [OpenAI Agents SDK: running agents](https://openai.github.io/openai-agents-python/running_agents/) | A run executes an agent loop and can contain multiple model/tool interactions | Name the durable execution **AgentRun**; reserve loop for the algorithm |
| [OpenAI Agents SDK: sessions](https://openai.github.io/openai-agents-python/sessions/) | A session preserves conversation history across runs | Keep the already precise **Conversation** for durable dialogue; do not add a Session entity |
| [Google ADK: sessions](https://google.github.io/adk-docs/sessions/) | Session history/state and cross-session memory have different responsibilities | Keep Conversation, execution state and Memory distinct |
| [LangGraph: persistence](https://docs.langchain.com/oss/python/langgraph/persistence) | Threads scope execution checkpoints; stores can hold cross-thread data | Do not equate Nexus Store, conversation history and Runner checkpoints |
| [Claude Agent SDK: sessions](https://platform.claude.com/docs/en/agent-sdk/sessions) | Resume and fork describe different conversation-history operations | Keep explicit resume/fork semantics rather than renaming every host Session |
| [OpenAI Agents SDK: handoffs](https://openai.github.io/openai-agents-python/handoffs/) | Handoff delegates control between agents | Remove handoff from Runner default selection; this creates no new agent-handoff feature |
| [MCP: tools](https://modelcontextprotocol.io/specification/2025-11-25/server/tools) | Tools have schemas and return content, including resource links | Use tool declaration, tool call and tool result; keep protocol content types intact |

Frameworks also overload `turn`, `runner` and `session`. Nexus therefore defines
those terms locally instead of claiming identical semantics. In particular, a
Nexus Runner is an executor advertising environment-local tools; it is not the
in-process orchestration class called Runner in some SDKs.

## Canonical concept map

| Concept | Meaning and ownership | Important distinction |
| --- | --- | --- |
| Account | The deployment's shared trust domain | Not a new tenant-isolation boundary |
| Workspace | Product grouping and access policy for work | Not a directory or execution machine |
| Member | A human or agent account member | Excludes the synthetic system principal |
| User | Existing persistence model for principals, including the system principal | Retain the model; do not mechanically rename it Member |
| Agent | An agent-kind member and its durable identity | Separate from the process that implements it |
| Agent profile / configuration | Settings and declarations belonging to an Agent | A representation of the Agent, not another identity or table |
| Agent application | Product runtime implementing an Agent's behavior and policy | Separate from Nexus and from a Runner |
| Steward | Human responsible for an Agent | Keep distinct from account role, data ownership and executor manager |
| Speaker | Attribution of who spoke on an input or turn | Never the authenticating principal or execution authority |
| TaskExecutor / executor | A delivery address and transport lifecycle | Not a Member or physical machine |
| Runner | Executor serving tools for an execution environment | A default Runner is a convenience; each accepted Runner task has its own target |
| Tool provider | Executor serving a pool of tools | Distinct from an LLM/model provider |
| Environment | Descriptive context of a Runner's execution surface | No new Environment or Machine resource |
| Conversation | Durable dialogue/history host | May contain many turns and executions |
| Input | Accepted intent awaiting or undergoing conversation delivery | Not necessarily an already materialized message or Turn |
| Turn | One conversation timeline slot | May contain an opening input and a reply; not one model message or provider request |
| Variant | A content/execution alternative for a Turn | Can be generated, edited, imported or forked; not an Attempt |
| AgentRun / Run | Durable execution aggregate containing a task graph | May be conversation-backed or standalone; need not contain a loop or model call |
| Step | Authored execution intent submitted to the compiler | May lower to several Tasks or a barrier |
| Task | Identified runtime work within a Run | `AgentRunTask` is its persisted class; graph node is internal structure |
| Model task | Task responsible for model work | Do not call every such row a Turn or a Run |
| ModelInvocation | One sealed logical model invocation | Owns semantic input and cancellation/status independently of provider retries |
| ModelInvocationAttempt | One provider execution attempt for an invocation | Distinct from task retry generations and content Variants |
| InferenceRequest | Public aggregate for direct model inference outside an agent Run | Covers text, image, speech, transcription and embedding; fallback may create more than one invocation |
| Operation | An idempotently accepted command owned by a claimed ToolTask, with an observation | Not a synonym for every task or provider attempt |
| Schedule | Durable instruction and clock which dispatches child conversations | Separate from a Rails background Job and from one dispatch |
| RunnerEffects | Read projection of retained claimed-write evidence per Runner | Evidence of possible effects, not a snapshot or proof a write completed |
| Runner checkpoint | Opaque restoration data supplied by a Runner | May be missing; does not necessarily cover processes, browser state or external services |
| Memory | Agent-consumable persisted memory documents and versions | Not conversation transcript, model context or arbitrary Store entries |
| Store | Existing scoped application key/value persistence | Keep its existing scopes; do not rename it Memory |
| Artifact | User-facing generated or referenced output | Use existing content/upload/resource-link ownership; this word adds no Artifact table |
| ContentBody / ContentFragment / ContentUpload | Existing structured content and upload storage responsibilities | Keep concrete storage nouns and protocol content types |
| Model provider | Configured model-serving lane/backend | Distinct from a Tool provider, credential and model definition |
| ModelProviderConfig | Database configuration/overlay for a model provider | Separate from provider adapter, credential, runtime state and effective catalog |

A common conversation path is Input → Turn → Variant → Run → Tasks. This is a
reading aid, not mandatory cardinality: standalone Runs and InferenceRequests
exist; edited/imported content need not run an agent; a task may have multiple
invocations through existing fallback behavior. Do not infer a new owner from
the diagram-like notation.

## Names across storage, API and SDK

Use singular class/type names, plural collections, snake_case wire keys and
ordinary verb methods. Keep a qualifier where it prevents a real collision.
Public identities remain UUIDv7; names and registration identifiers remain
descriptive/natural keys, never substitutes for public identity or credentials.

| Responsibility | Ruby / storage | Public and SDK vocabulary |
| --- | --- | --- |
| Run aggregate | `AgentRun`, `agent_runs`, `AgentRuns` services | `/runs`, `run`, `runs`, `run_public_id`; SDK `Run`, `RunContext`, `RunsContext`, `workspace.runs` / `workspace.run(id)` |
| Task row | `AgentRunTask`, `agent_run_tasks`, `AgentRunTasks` subclasses | `/runs/:run_public_id/tasks`, `task`, `task_key`; retain existing within-run task identity |
| Task operation | `AgentRunTaskOperation`, `agent_run_task_operations` | `operation`, `operation_key` where already present; no separate scheduler |
| Graph edge | `AgentRunEdge`, `agent_run_edges` | Internal graph implementation; no new node/edge CRUD API |
| Direct inference | `InferenceRequest`, `inference_requests`, `InferenceRequests` | `/inference_requests`, `inference_request`, `inference_requests`, `inference_request_public_id`; SDK `InferenceRequest`, `InferenceRequestsContext` |
| Speaker attribution | `Speaker`, `speakers`, `speaker_id` | `speaker`, `speaker_public_id`; SDK Speaker projections |
| Scheduling | `Schedule`, `schedules`, `Schedules` services | Existing host scope with `/schedules`, `schedule`, `schedules`; SDK `SchedulesContext` |
| Effect evidence | `AgentRuns::RunnerEffects`, `Conversations::RunnerEffectsAt` | `runner_effects`, containing `runners`; SDK `RunnerEffects` |
| Provider configuration | `ModelProviderConfig`, `model_provider_configs`, `ModelCatalog::ModelOverlay` | Provider settings/configuration in prose; preserve already accurate provider resource paths |

Database foreign keys follow their actual model associations, for example
`agent_run_id` and `agent_run_task_id`. Public references use `run_public_id`,
including qualified references such as `source_run_public_id` and
`sender_run_public_id`. Inside a Run document its own identity is still
`public_id`. Executor inbox, claim, commit, progress, task-operation observations,
events and Cable consumers must use the same public names.
Bare UUID selectors currently named `agent_loop`, including the `wait` tool's
source selector, also become `run_public_id`; a resource envelope remains `run`.

Keep product prose concise: “Run” where the owner is clear, “Agent run” when it
is not. `loop` remains valid in an explanation of repeated model/tool
execution. Ordinary programming loops, provider protocol terms, external
session IDs and historical quotations are outside the rename.

## Identity and attribution corrections

The product noun is Agent. Replace “Agent Profile” when it means the member
identity; retain profile when it means settings, including the existing
`/profile` resource. `TaskExecutor#agent_profile` becomes `agent`, its FK becomes
`agent_id`, and any corresponding public reference becomes `agent_public_id`.
The association still resolves an agent-kind User. This introduces no second
Agent model, subclass hierarchy or permission plane.

`Actor` becomes `Speaker`. Existing `speaker_actor_id` and
`speaker_actor_public_id` become `speaker_id` and `speaker_public_id` across
inputs, turns, schedules and projections. The old reserved Actor kind `speaker`
becomes `persona` so it cannot mean both the entire entity and one subtype.
The attribution kinds become `member`, `persona`, `ingress`, `system`; reserving
persona still does not implement persona features. Authority continues to be
the separately recorded User; controller/principal and speaker are not merged.
Ordinary audit terminology such as `UsageBudgetEntry.actor_public_id` is not
part of this entity rename: that field records the acting Human User, not an
Actor/Speaker. Keep the distinct principal attribution.

Use `tool_provider` for the executor kind and `tool_provider?` for its predicate.
Rename the shared `runner_identifier` to `registration_identifier` because both
Runner and Tool provider registrations use it. Preserve `agent_identifier` for
the separate Agent member registration. `User#managed_runners` becomes
`managed_executors`; a genuinely Runner-only selection may still be named
`runners`. Keep `manager` and `steward` where their different owners matter.

## Execution and operation vocabulary

| Current ambiguity | Proposed name and rule |
| --- | --- |
| `spine` for the Run's continuing model path | `mainline`; retain branch/background distinctions |
| `round?` meaning `kind == model_task` | `model_task?`; round is explanatory only for an actual loop iteration |
| Kernel tool `task` for a delegated branch | `delegate_task`, canonical `nexus.graph.delegate_task`; the general runtime entity remains Task |
| Generic `request` convenience that creates one tool Run | `start_tool_call`; returns a `RunContext` without waiting for completion |
| That context's `request_result` | `wait_for_tool_result`; waits for the result under the existing observation policy |
| rho `relay` convenience | `call_tool`; explicitly waits according to its existing observation policy, without a second execution path |
| `Mail`, `mailed_at` for background result input | `ResultDelivery`, `result_delivered_at`; means accepted into the input path, not consumed by the model |
| `one_shot_attempt` invocation purpose | `inference_request`; reserve Attempt for actual provider attempts |
| `agent_loop_step` invocation purpose | `agent_run_task`; keep `conversation_reply` for the distinct existing owner |
| Runner `handoff` / `runner_bound` | `set_default_runner` / `default_runner_changed`, under the multi-environment semantics |

`delegate_task` creates a delegated branch within the same Run with its existing
context rules. It is not `spawn`, which creates a child Conversation, or `fork`,
which branches conversation history. A side conversation remains a particular
fork mode. Authored-step operations and claimed-tool child operations retain their existing
owners; the retired `compose` tool and DSL remain retired. `ask`, `wait`,
`observe`, `approve`, `deny`, `retry`, `resume` and `cancel` keep their specific
meanings. In particular, observe may seal an immutable observation, and an
observation timeout does not cancel the observed work.

An executor-owned tool uses its ordinary claim while submitting and observing child
operations. Waiting and deadline extension do not create a separate continuation
category, suspension protocol or automatic source-replay capability. Native external
session continuation remains an adapter-specific action using that session's identity.

Keep lifecycle actions and status values owned by their existing state machines.
This naming change does not collapse `waiting`, `running`, `dispatched` and
`awaiting_input`: a claimed external task can still be dispatched under today's
contract. Do not “correct” status strings without defining and testing different
transitions. Likewise, task retry, turn regeneration and provider retry remain
different operations.

## Effects, restoration and the other meaning of world

`World` becomes `RunnerEffects`, with the evidence and completeness rules in the
multi-environment specification. Keep `untouched`, `touched` and `unavailable`
as evidence states with their defined meanings. A claimed write can be touched
even when the final effect is uncertain. Calling it Effects never upgrades that
evidence into a successful-write assertion.

Use `restore_checkpoints` for the SDK's multi-Runner composition and
`checkpoint_restore` for the Runner's ordinary single-target restore tool.
Use `restoration` for the composition outcome, distinct from `runner_effects`
as its input evidence. A rewind convenience's `world:` option becomes
`restore_checkpoints:`. There is no `restore_effects` claim or global rollback.
Keep `checkpoint` in Runner result metadata; new names do not widen coverage.

The independent tool-policy field `effect_profile.world` becomes
`effect_profile.effect_scope`. Preserve its existing `closed` / `open` values
and policy semantics. Update declaration validation, frozen profiles, approval
rules, fingerprints and consumers together. This field is not the
RunnerEffects projection; never substitute `runner_effects` into it.

Provider configuration services use `ModelProviders::ConfigCommand` for the
former PolicyCommand. `ModelCatalog::ModelOverlay` applies model overrides;
the existing ProviderOverlay still applies provider definitions. Keep those
two responsibilities and the existing provider configuration presenter.

## rho and protocol boundaries

Nexus, SDK and rho change together. The old rho contract is incompatible with
this cutover. Consumer obligations are part of the same implementation:

- `HostRun` becomes `HostFollower`: it follows a host feed across turns and
  kernel Runs. A follower's identity/lifetime is not a Run's identity/lifetime.
- Expose `runs` for kernel executions and `followers` for local followers.
  Replace responses containing `{loop, run}` with `{run, follower}` and remove
  the old `loops(scope: server)` ambiguity.
- Rename `LoopRequest` to `RunDeclaration` for the execution declaration
  builder. UI state using `execution` must name the actual identity it tracks:
  Run, Variant or follower; do not replace every such field with `run_id`.
- Update rho-runner, rho-browser, rho-mcp, adapters and extension operations
  which carry these fields. This does not authorize native desktop/browser
  features or a rho product redesign during the Nexus milestone.

Preserve externally specified MCP/ACP session, tool and content vocabulary,
provider request/response fields and third-party class names. Adapt at those
boundaries rather than exporting an internal rename into another protocol.
Authentication Session remains an authentication Session. Credential prefixes,
member/management/executor credential planes and claim tokens do not change
because a resource was renamed.

## Scope and acceptance

The inventory is finite: rename the listed responsibility families and their
live writers/readers, then review residual matches by meaning. Preserve names
explicitly retained above. Historical plans, measurements and archived examples
remain records of their original contracts; annotate supersession where useful
rather than falsifying old evidence with a global replacement.

This specification and its companion inventory define the naming cutover. Update
`.ai/`, current API manuals, generated/public schemas, examples and tests in the
same cutover. Acceptance requires both removal of ambiguous live names and
preservation of the identity, lifecycle, authority and evidence distinctions
defined here.
