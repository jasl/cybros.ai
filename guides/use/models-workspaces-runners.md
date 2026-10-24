# Models, workspaces and runners

Three independent choices shape a conversation: which model answers, which workspace holds it, and which runner executes its tools.

```sh
rho models --workload text_generation
rho setup model
rho workspaces
rho runners
```

In the stack, prefix commands with `./cybros rho`. Examples below use the installed `rho` command.

## Models

Use an available reference from `rho models`, or choose it under **Settings › Defaults › Default model** in the browser. Saving applies the default immediately and overrides the initial `RHO_DEFAULT_MODEL` value. An [Agent Preset](agent-presets.md) can select another initial model and an independent ordered fallback list. Model availability comes from Nexus; provider credentials, visibility and limits are administered there (see [Models and providers](../operate/models-and-providers.md)). Configured availability does not guarantee that a provider request succeeds; the first real conversation does.

`--model PROVIDER/MODEL` overrides the default for one terminal request.

## Workspaces

A workspace groups conversations and related Nexus resources. rho creates its own dedicated workspace when none is selected.

```sh
rho workspaces create "Project work"
rho workspaces use WORKSPACE_ID
```

The browser's sidebar switcher is that page's current workspace; it scopes the conversation list and new conversations. rho's saved default workspace is what the CLI uses. A [Bot](telegram.md#connect-a-bot) starts new conversations in its own Home Workspace, including through Telegram. Existing conversations keep their original workspace; selecting another does not move history. An explicit `server --workspace` launch flag must be removed before a different selection can be persisted. `RHO_WORKSPACE` seeds the initial value when no saved choice exists.

Workspace ownership and access are managed in Nexus; see [Workspaces and access](../operate/workspaces-and-access.md).

## Runners

A runner is the execution environment. Its working directory is an ordinary filesystem path on that machine.

The Runner list contains only environments this rho instance may use. Its bundled Runner is reserved for its own Main Agent, Bots and Subagent work, subject to their tool policies. Another rho instance's bundled Runner is unavailable even if you manage both. To share an environment between instances, [connect an independent Runner](../runners/quickstart.md).

```sh
rho runners use RUNNER_ID
rho runners use --none
```

These settings affect new conversations. Selecting another runner does not transfer files. `--none` clears the saved choice: rho then uses its Local environment.

For a single terminal request use `--workspace`, `--runner` and `--dir` instead of changing defaults; the directory is on the selected runner.

A conversation's default runner applies to future tool calls that do not name a target; already accepted calls keep their original runner. To add a machine, see [Deploy a runner](../runners/deploy.md).

The directory selected when rho accepts work is retained with that work, including
after a Runner restart. Changing a default affects future requests. If the selected
directory disappears or cannot be used, the tool fails explicitly; it does not run
in another directory. Remote directory selections must be absolute paths on the
selected Runner. Directory selection sets the base for relative paths; it is not
a filesystem sandbox.
