# Editors (ACP)

rho speaks the Agent Client Protocol. An ACP-capable editor spawns the `rho-acp` program and talks JSON-RPC over its stdin and stdout; the program opens conversations, sends turns and relays questions and approvals through the same daemon core the browser page uses. The daemon owns the conversation; the editor process only speaks for it.

## Run it

Point your editor's ACP agent configuration at the installed executable:

```
rho-acp [--mode bypass|ask|rules] [--model MODEL] [--runner EXECUTOR_ID]
```

The flags are defaults for new sessions: the approval mode (`bypass` is rho's own posture; an editor that wants prompts passes `--mode ask`), the model (otherwise the home's default model), and, for an agent-mode rho, the runner that serves the session's tools.

`rho-acp connect` runs the pairing ceremony on plain stdio for editors that offer a terminal authentication step: it prints the code and the identity and exits `0` when connected. A home that is already connected exits `0` at once.

## In the session

- Each editor session maps to a conversation. Turns, streamed answers, tool results and artifacts flow back through the protocol.
- Questions and tool approvals are relayed to the editor's permission prompts.
- The `code_mode` option offers `on` and `off` and reloads the saved choice when a session resumes. The global default sets the initial choice for a new conversation and does not change existing conversations.
- Ending the editor process releases the session's live members; the kernel's turns keep running and remain in the conversation.

## Delegating to other ACP agents

The separate `rho.acp-client` plugin lets rho act as an ACP client: another agent an operator configures becomes a `delegate_agent` tool. The child's permission requests pass through rho's own approval floor and are never auto-granted. The plugin is disabled by default; enable it under **Plugins** and configure the agents' commands there. See [Plugins and code mode](plugins-and-code-mode.md).
