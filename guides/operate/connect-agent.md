# Connect and inspect an Agent

Open **Connect an Agent** in Nexus to connect an application or register your own
program. Nexus manages identity, credentials, persistent work and results. The
application owns prompts, product definitions and conversation authoring.

## Connect an existing application

Start the connection in the application, then open its Nexus authorization link
and approve the connection. The resulting identity appears in **Agents**.
A named Agent keeps its own identity and declaration while using its declaring
application's transport; it does not need a separate transport identity.

## Connect your own program

1. Create an independent Agent identity from **Connect an Agent**.
2. Issue a member API key on its detail page and configure your program with it.
3. Publish the declaration through the Agent API.
4. Choose or create a Workspace that the submitting identity and answerer can access.
5. Submit work through your application or SDK. Open the Workspace in Nexus to
   inspect the accepted input and its actual result.

See [API keys](../build/credentials-and-planes.md#api-keys) for credential setup. An application executor
is optional: only application tools or callbacks require its service. Ordinary
work using kernel capabilities does not require an application to stay online.
Connection success alone does not prove execution; an Agent with no work shows
that empty state rather than a successful execution.

## Inspect an Agent

Open **Agents** and select an identity you manage. Its detail page separates
lifecycle, application connection, credentials and current declaration. Read the
[saved declaration](configure-an-agent.md) for model intent, tool declarations,
prompt documents and memory access limits. Change behavior in the application
that publishes it. Nexus does not expose an editor or private Agent memory here.

Recent work uses your current content permissions. Managing an Agent does not
grant access to all of its Workspaces or Conversations. Historical executions
retain their captured configuration when the current declaration changes.

Removing an identity, revoking its connection and revoking one API key have
different consequences; review the corresponding resource's confirmation.
Runner management remains under **Runners**.

## Next

- [Inspect and recover work](work-console.md)
- [Workspaces and access](workspaces-and-access.md)
- [Inspect an Agent declaration](configure-an-agent.md)
