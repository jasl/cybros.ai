# Core concepts

Cybros uses familiar agent vocabulary where the responsibility matches and keeps distinct words where identity, authority or lifecycle differ. This page is the short version; the [glossary](../reference/glossary.md) lists every term.

## The four you meet first

| Concept | What it is |
| --- | --- |
| **Agent** | A member of the Account with its own identity, plus a *configuration* its application declares: tools, approval mode and rules, prompt mechanism, compaction policy, default model, ordered fallback models, lifecycle hooks and prompt documents. |
| **Runner** | An execution environment's delivery address. It serves tools bound to a machine — files, shell, processes — and claims work from its own inbox. A run may use several runners. |
| **Conversation** | The durable dialogue a person works in: inputs, turns, candidate answers, forks, memory and access rules. |
| **Run** | One durable execution: a graph of model and tool tasks with dependencies, approvals, deadlines and write-once results. A run usually backs a conversation turn; it can also run standalone. |

Where a hosted platform has one *session* object, Cybros has a Conversation (the person's unit) and the Runs that back its turns (the execution unit). Where a hosted platform has an *environment*, Cybros has a Runner that is always yours.

## Account and members

- **Account** — the installation's single trust domain. Everything lives under it: users, workspaces, conversations, executors, credentials and usage.
- **Human** — a person with a login. Owners and administrators manage account-wide settings; every human manages their own agents and runners.
- **Agent** — an agent-kind member. Each agent has a human *steward* responsible for it. Agents derive data access from their steward and never gain administration rights.
- **Workspace** — the required container for conversations and runs. A workspace has one human owner and is either private (owner and their agents) or account-wide.

## Execution

- **Executor** — a delivery address with its own transport credential. Three kinds: *agent application* (the program that implements an agent), *runner* and *tool provider*. The executor is where work is delivered; the agent whose authority the work uses is frozen on each task separately.
- **Task** — one unit of work in a run. A task is addressed to an executor, claimed exclusively, extended if needed, and committed once.
- **Tool** — a callable declared on the agent's configuration. Four sources share one provenance model: kernel tools (`delegate_task`, `ask`, `memory_*`, …), runner tools, tool-provider tools and the agent application's own tools.
- **Approval** — a kernel stage every tool call crosses. The agent's mode (`bypass`, `ask`, `rules`) and its rule list decide whether a call runs, parks for a person, or is refused.

## Conversation structure

- **Input** — accepted intent waiting for delivery: a user message, a steering instruction, kernel mail carrying a background result, or a scheduled instruction.
- **Turn** — one slot on the conversation timeline, holding an opening input and its reply.
- **Variant** — one candidate answer for a turn. Regeneration adds a variant; editing or importing content creates one without running a model.
- **Fork** — a new conversation branched from a point in history. A *side* conversation is a particular fork mode.
- **Memory** — model-readable documents scoped to a conversation, a workspace, a person or the answering agent, separate from history and from working files.
- **Store** — opaque JSON state an application keeps on a workspace, a conversation or its own profile.

## Models

- **Model provider** — a configured lane to a model-serving backend: a cloud API, a subscription authorization or a local server.
- **Model** — a definition with a reference such as `openrouter/provider/model`, capability declarations, context limits, optional pricing and visibility. Agents discover usable models; administrators manage them.
- **InferenceRequest** — a direct, bounded model call outside a conversation: text, image, speech, transcription or embedding.

## Signals

Two primitives that are never conflated:

- **Awareness** — notifications fanned out to subscribed or mentioned principals. An agent may ignore them.
- **Obligation** — an inbox task addressed to an executor with a claim, a deadline and a write-once result. Only obligation carries execution semantics.

Realtime channels carry hints and streams; HTTP carries commands, current state and durable event replay. An open socket never proves that work exists or succeeded.
