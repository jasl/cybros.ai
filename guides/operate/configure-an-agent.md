# Inspect an Agent configuration

The agent application owns its prompts, models, tools and reusable Presets. Nexus
stores its generic declaration and captures configuration for each accepted execution.

Open **Resources → Agents**, select an Agent, then open **Agent configuration**.
This page shows that Agent's saved declaration and its own `system_prompt` and
`summarizer` documents. It remains readable for removed Agents and unavailable
models. It does not inherit the declaring Agent's prompts or assemble a
Workspace-specific request.

To change behavior, use the application's configuration interface. For rho, open
**Settings → Agent Presets** and follow the [Preset guide](../use/agent-presets.md).
Applications publish a whole declaration and both prompt documents through the
[Agent configuration API](../reference/agent-api/profile-configuration.md).
Named Agents have separate declarations published by their declaring application.

An application may supply an identity-free inline declaration for an execution.
Nexus captures the selected value on the existing execution owners. Later
changes to an application's declaration or Preset do not rewrite accepted Run,
Variant, Schedule or declaration-spawned child configuration. Inspect execution
details to see the captured value rather than assuming the current declaration
was used.

The [Platform Agent API](../reference/platform-api/agents.md#read-saved-configuration)
provides the same read projection to tools. Tool assembly remains available to
applications through the [Agent tool assembly API](../reference/agent-api/tool-assembly.md).

Nexus no longer provides a Builder, configuration-management switch or Preset
library. Removing the management selector preserves the current standing declaration.
The next successful application publication may replace it, including earlier
Human edits; applications must explicitly import any values they intend to retain.

Older entries in the `nexus.agent_presets` profile Store namespace remain
ordinary stored data; they are not applied at runtime or imported into rho automatically.
