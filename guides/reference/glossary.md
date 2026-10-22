# Glossary

| Term | Meaning | Not to be confused with |
| --- | --- | --- |
| **Account** | The installation's single trust domain: members, workspaces, conversations, executors, credentials and usage | A tenant; there is no tenant isolation layer |
| **Agent** | An agent-kind member with a durable identity, stewarded by a human | The program that implements it (the agent) |
| **Agent** | The product runtime implementing an agent's behavior and policy — rho, or yours | Nexus; a runner |
| **Agent configuration** | Identity-free execution settings: tools, prompts, models, approvals and context policy, declared as standing defaults or captured inline | An Agent member; Profile |
| **Agent Preset** | A reusable configuration package managed by an agent such as rho | An Agent identity; a Subagent execution |
| **Approval** | The kernel stage every tool call crosses; the mode and rules decide whether it runs, parks or is refused | A permission the runner enforces |
| **Awareness** | A notification an agent may ignore | Obligation |
| **Capture** | A file an executor publishes and names in a result | An input attachment |
| **Conversation** | The durable dialogue and history host | A session; a run |
| **Cost unit** | The account's configure-once currency for estimates | A price |
| **Executor** | A delivery address with a transport credential: agent, runner or tool provider | A member; a physical machine |
| **Environment** | Facts an executor announces about where its tools run, captured for execution | A separate hosted sandbox resource; a Runner identity |
| **Event** | A durable record exposed through HTTP replay; realtime notifications point readers to current state | Ephemeral transcript deltas or progress frames |
| **Fork** | A new conversation branched from a point in history; a *side* is a fork mode | Regeneration |
| **InferenceRequest** | A bounded, sealed direct model call outside a run | A conversation reply |
| **Input** | Accepted intent awaiting delivery: a message, a steer, kernel mail, a scheduled instruction | A turn |
| **Kernel mail** | A background result, child reply or scheduled report delivered as a kernel-origin input | The executor inbox; a notification |
| **Manager** | The human who approved a runner or tool provider | Steward; owner |
| **Member** | A human or agent account member | The system principal |
| **Memory** | Model-readable documents scoped to a conversation, workspace, person or answering agent | History; the store; working files |
| **Model provider** | A configured lane to a model-serving backend | A tool provider |
| **Model round** | One model Task's request and response within a Run; explanatory vocabulary, not a separate resource | A Turn; an entire Run |
| **Obligation** | An inbox task with a claim, a deadline and a write-once result | Awareness |
| **Owner** | A workspace's one human manager | Account owner (a role) |
| **Plane** | The one authority axis of a credential: member, executor transport or platform | A scope |
| **Profile** | The authenticated member's self-view, including member and credential metadata and, for an Agent, its configuration defaults | An Agent Preset; a second identity |
| **Run** | One durable execution: a task graph with results | A loop (the algorithm); a turn |
| **Runner** | An executor serving tools bound to an execution environment | An in-process orchestration class; a sandbox service |
| **RunnerEffects** | Per-runner evidence of claimed writes: `untouched`, `touched`, `unavailable` | Proof a write completed |
| **Schedule** | A durable instruction and clock dispatching child conversations | A background job |
| **Session** | A Human login credential managed through the Platform API | A Conversation; an agent execution |
| **Speaker** | Attribution of who spoke on an input or turn | The authenticating principal |
| **Steer** | An input delivered to the next model boundary of running work | A queued message |
| **Steward** | The human responsible for an agent | Manager; owner |
| **Store** | Scoped opaque JSON persistence | Memory |
| **Subagent** | A temporary child execution using a delegated role's captured configuration, with its own child history | A persistent Agent or Bot identity |
| **Task** | One durable unit of work in a Run; externally executed work is delivered through an executor inbox | An authored Step; a second delivery entity |
| **Tool provider** | An executor serving tools by name from a pool | A model provider; a runner |
| **Turn** | One slot on a conversation timeline with an opening input and a reply | One model message or provider request |
| **Variant** | One candidate answer for a turn | A provider attempt |
| **Workspace** | The required container for conversations, runs and InferenceRequests, with an owner and an access mode | A directory; a machine |
