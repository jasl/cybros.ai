# Your first conversation

With the stack installed and a model configured, open rho's browser URL — `http://localhost:7777` by default, or the LAN address you chose. Choose **Connect to Nexus** if no browser session exists. The tab stays signed in across daemon restarts while its Nexus grant is valid; **Sign out** ends the browser session and leaves the agent's binding and running work in place.

## Start

1. Create a conversation.
2. Choose an available model and the stack's runner.
3. Send a small request:

> Tell me which working directory you can use. List its files without changing them.

The runner uses its default working directory. In the default stack, that is `/home/runner`, mapped to `data/rho/work` under the installation directory. Read the answer and the tool results. Answer questions and decide tool approvals in the conversation as they appear.

## Try a file operation

Ask for a small file in a disposable directory, then inspect it on the host under `data/rho/work`. The runner's working directory is a starting location for tools, not a sandbox: shell commands are limited by the container's permissions and mounts, not by the chosen directory.

To work on an existing host project, configure its bind mount and permissions first (see [Deployment layouts](../operate/deployment-layouts.md)). To work on files on another machine, connect a separate runner and select it in the conversation.

## What you are looking at

- A **turn** holds your message and the agent's reply. A reply can run several model rounds and tool calls; tool results and reasoning stream in as they happen.
- A **question** from the agent and an **approval request** for a tool call appear beside the work. Nothing continues until you answer.
- **Stop** ends execution, including background work derived from the reply. Closing the page only detaches your view.
- Reopening a conversation shows its durable history, kept in Nexus.

## Next

- [Conversations](../use/conversations.md) for queueing, steering, pause, retry and forks
- [Approvals and questions](../use/approvals-and-questions.md)
- [Models, workspaces and runners](../use/models-workspaces-runners.md)
- [Telegram](../use/telegram.md) and [editors](../use/editors-acp.md) as other entry points
