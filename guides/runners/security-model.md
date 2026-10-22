# Security model

A shared-responsibility description of what a runner sees, what Nexus stores, and who is responsible for which boundary.

## Trust

One installation is one Account of trusted members. The operator of a deployment, the people and agents in it, and the packages the operator installs are trusted. What is untrusted is **content**: model output, tool effects, external ingress payloads and user-supplied data are untrusted regardless of which trusted principal relayed them.

A runner therefore protects against the consequences of untrusted content — a model asking to delete the wrong directory — not against its own operator.

## Who holds what

| | Runner | Nexus | Agent |
| --- | --- | --- | --- |
| Credential | A transport credential proving one delivery address at one epoch; nothing else | Provider credentials (write-only), member and executor credential digests, OAuth lineages | A member credential and its own transport credential |
| Sees | Tool inputs for calls addressed to it, bound attachments it fetches, the conversation and run identifiers on each row | Everything it stores | The conversation, turns, results, approvals and questions |
| Stores | Working files, processes, browser sessions, MCP server state, its own settings and logs | Conversations, turns, task inputs and results, captures, memory, usage | Its settings and credential lineages |
| Never holds | A member credential; the human's password; provider keys | Working files; the runner's processes | The runner's transport credential |

A runner is a machine, not a principal: each task freezes the agent whose authority it runs under, and the runner's credential proves only the address. A tool call's input is the executor's payload; Nexus never interprets it and passes it through the approval rules as opaque JSON.

## Network

- Runners and applications connect **outbound** to Nexus over HTTPS and never listen. A runner publishes no control port.
- HTTPS is the normal deployment contract. An explicit local or LAN HTTP configuration is a supported exception that leaves traffic unencrypted; rho requires a transport assertion (`--expect-external-encryption` or `--unsafe-plaintext`) when it binds beyond loopback.
- Web fetching from a runner reaches only public addresses unless the operator sets `allow_private_network`, with SSRF filtering on every resolved address.

## Execution boundary

- Nexus checks the Runner's [assignment scope](deploy.md#identity-and-scope) for Agent discovery, tool assembly and execution. A Local Runner service belongs to its application address: another rho instance cannot use it merely because both instances have the same Human steward. The application's own execution policies still determine which of its Main, Bot and Subagent executions may use Runner tools.
- A working directory is a starting location, not a sandbox. Shell commands are limited by the operating-system user, container and mounts the operator gave the runner. Choose the host permissions and mounts appropriate for the work.
- Approval rules evaluate in Nexus before a call is addressed; a runner only sees granted calls. Destructive patterns — force pushes, writes to `.env`, protected installation roots — are refused as data the model reads.
- rho's runner additionally applies its own guard on nine protected command shapes and installation roots, and scrubs secrets from the child environment and from results.
- Effects are recorded per runner as evidence, never proof; a rewind restores a checkpoint the runner supplied and does not undo external side effects.
- A claim is exclusive by token, so a duplicate runner process cannot settle a result over the one doing the work. Copied credentials are indistinguishable and unsupported; keep a runner's home private and never share it between instances.

## Lifecycle authority

- The runner's **manager** — the human who approved it — is its only manager. They connect, disconnect and revoke it from **Runners** in the Nexus browser. An administrator has no takeover or emergency bypass for another human's runner.
- Removing or suspending the manager closes admission for their runners; running work settles at data-safe points before transport is fenced.
- Revoking an address fences its transport synchronously; unclaimed rows addressed to it fail `executor_revoked`, and held approvals keep the person's door.

## What this model does not claim

Nexus cannot identify the physical process holding a copied credential; IP address and User-Agent are never identity. Host identity, filesystem paths and package inventories are never admission conditions. Supply-chain protection belongs at the distribution boundary — reviewed source, images with recorded source commits, package installation — not on the execution hot path.
