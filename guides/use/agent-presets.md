---
title: Agent Presets
description: Edit reusable instructions, models and tools, and select the defaults for new work.
---

# Agent Presets

Open **Settings › Agent Presets** to edit reusable agent behavior. A
Preset contains instructions, model selection, fallback models and tool
permissions. It has no conversational identity, conversation history,
memory or channel credentials.

The initial library contains **Probius**, **Adjutant**, **worker**,
**planner**, **explorer** and **reviewer**. Their names and descriptions
are editable. Selecting or copying one does not create a Bot identity.

The initial **planner**, **explorer** and **reviewer** can read local
files and use `web_fetch` to read web pages when the Runner's **Web reader**
plugin is enabled. The reviewer also has `bash` for running relevant checks.

## Edit a Preset

1. Select its name in the library.
2. Edit its name, description and **System prompt**. This prompt contains
   the Preset's instructions; rho adds shared execution and memory guidance.
3. Choose its initial model and fallback behavior.
4. Select **All available tools** or specific names independently for
   **Nexus and application tools** and **Runner tools**.
5. Select **Save**. A rejected save keeps your draft and displays the reason.

**Duplicate** creates a new Preset with copied configuration and a new
name. It does not copy a published role. **Remove** deletes the Preset and
its role publication; reassign any default or Bot reference first.

## Choose defaults

The **Default Presets** card selects the Preset for **Web conversations**
and the default for **New Bots**. These are references to library entries,
not separately editable copies. The main Agent's **Settings** action on
the Agents page opens this section.

Accepted work retains the configuration captured for it. Editing a Preset
or a default does not rewrite an execution already accepted by Nexus.

## Choose models

**Settings › Defaults › Default model** owns rho's global initial model.
A Preset's **Initial model** can select another route or inherit that
global default. The fallback list is independent of this first choice.

| Fallback setting | Behavior |
| --- | --- |
| **Inherit global fallback list** | Use the ordered list in Settings › Defaults. |
| **No fallback** | Disable automatic model switches for this Preset. |
| **Custom ordered list** | Replace the global list with these candidates in this order. |

Use **Add model**, **Move up**, **Move down** and **Remove** to edit the
order. The initial model is never inserted implicitly. In the configuration,
an omitted or null Preset override inherits, an array replaces the list
whole, and `[]` disables fallback.

Model selection also offers **Use the Preset's initial model** and
**Follow the initiating conversation**. For a published Subagent role, the
latter uses the calling task's current actual model and inherits its selection
constraints. A model explicitly requested for that delegation takes precedence.
The child's later messages keep its own current model; they do not follow the
parent again. These choices do not change the global default or combine fallback lists.

Publish a saved Preset under **Settings › Subagent roles** with a role name
and a description of when to use it. The publication refers to this Preset;
instructions, models and tools remain edited here. See
[Subagent roles](sub-agents.md#publish-and-use-subagent-roles) for task and memory behavior.

Unavailable candidates are skipped without a provider call. A model
switch must satisfy the execution's captured model and provider
constraints; an explicit no-fallback selection remains binding. The
[model recovery reference](../reference/agent-api/models.md#model-selection-and-recovery)
describes the finite retry behavior and exact model-identity rules.

## Import and export

**Import Preset** reads a Markdown or JSON file into a new library entry.
An optional name override changes its display name. Importing the same
file again creates another Preset; it does not overwrite an existing
Preset or create a Bot. A rejected document stays open for correction.

Open a saved Preset and use **Export Markdown** or **Export JSON** to
save its configuration. Exports contain no public identity, role
publication, conversations, memory, purpose, Home Workspace or connection
credentials. Duplicate and import likewise start without role publication.

Markdown uses YAML frontmatter and puts instructions in the body:

```markdown
---
name: Code review
description: Review a supplied change for concrete defects.
model_mode: follow
fallback_models: []
tools: [memory_read, session_read]
runner_tool_names: [read, grep]
---
Read the supplied change and report actionable defects with evidence.
```

The flat import fields are `name`, `description`, `system_prompt`,
`model`, `model_mode`, `fallback_models`, `tools`, `runner_tool_names`
and `prompt_template`. `name` defaults to the filename and `description`
is required. `model_mode` is `default` or `follow`; `model: inherit`
imports as follow mode with no initial-model override. Tool lists also
accept comma-separated strings. Unsupported fields are rejected.

Exports use the full form with `name`, `description` and `configuration`,
which preserves all supported execution settings, null inheritance and
empty lists. In Markdown the prompt remains in the body. A file's
configuration is imported once; later edits to it do not change the Preset.

**Import project Presets** reads supported `.md` and `.json` files from
`.agents/agents/`, then `.claude/agents/`, one level below the daemon's
working directory. It reports skipped files with their reasons. No file is
loaded automatically just because it exists there.

```sh
rho presets
rho presets import
rho presets import reviewer
rho presets import-file reviewer.json
rho presets export PRESET_PUBLIC_ID md > reviewer.md
rho presets export PRESET_PUBLIC_ID json > reviewer.json
rho presets duplicate PRESET_PUBLIC_ID "Review copy"
rho presets rm PRESET_PUBLIC_ID
```

## Publish role metadata

The **Delegation role** card saves a role name and a description of when
to use it. It references this Preset's configuration. **Unpublish role**
removes that metadata without deleting the Preset. Publication does not
create an Agent identity, a conversation or a running task.

The Main Agent and Bots use published roles to delegate tasks with captured
configuration and separate child-Conversation memory. [Agents, Bots and
Subagent roles](sub-agents.md) describes role execution and the persistent
Bot identities that select Presets.
