# Roadmap

This page lists direction, not shipped behavior. Everything else in these guides describes what the current installation does.

## Desktop runners for macOS and Linux

Cybros does not provide a cloud sandbox. Its answer to "where does the agent work?" is a runner on a machine you control, and the next step is a runner packaged for a personal desktop environment on macOS and Linux: the user's own files, applications and browser, with the same outbound-only transport, approval rules and effect recording as today's runners. A runner that drives a screen takes one task at a time, a rule the runner enforces itself by what it claims; file and shell tools with their own working directories need no such exclusivity.

Today: the stack's in-container runner, a runner on a host through the host installer, and a separate runner container. The runner reserves worker-pool admission capacity before claiming work; it does not yet enforce exclusivity by capability class. Desktop computer-use tools are not included. See [Deploy a runner](../runners/deploy.md).

## SDKs beyond Ruby

The Agent API is an HTTP contract and is documented as such so that clients can be written in any language. The short-term plan is two first-party SDKs: Ruby, which ships today, and JavaScript/TypeScript next, covering the same surfaces — device connection and credential rotation, member resources, the executor inbox and durable event following.

Today: the `cybros_agent` Ruby gem. See [SDKs](../build/sdks.md) and [Build your own agent](../get-started/build-an-agent.md).

## Messaging platforms

Additional messaging platforms will use rho's shared Bot and Conversation
ownership while retaining their own authentication, connection and message
delivery behavior. Platform expansion follows complete Telegram acceptance.

Today: [Agent Presets](../use/agent-presets.md) supply captured configuration,
and [Subagent roles](../use/sub-agents.md#publish-and-use-subagent-roles)
start temporary work with child-Conversation memory. Persistent Bots bind
one concrete [Telegram destination](../use/telegram.md), may share a
connection, and retain their own current conversation and history. `/new`
selects a new conversation while accepted work continues in the previous one;
see [Bot conversations](../use/conversations.md#bot-conversations) for archiving.
The sidebar separates WebUI Conversations from Bots.

## Refinements

Smaller additions on the existing kernel and on rho, scheduled as ordinary work rather than as projects:

- **A spend limit per conversation.** A conversation will carry an optional limit in the account's cost unit. Once its recorded cost passes the limit, Nexus refuses new priced model work in that conversation — the run holds with a named reason, and a person raises the limit, stops, or moves on. The check sits beside the member budget check at admission, so work already in flight finishes and the overshoot is bounded by concurrency; unpriced work is not governed.
- **Conversation export.** A person with read access will be able to export a conversation as gzip-compressed JSON Lines — inputs, turns, prompts, tasks and their results, usage and events — for audit, for keeping, and for feeding other tools. The export is the person's own; it is not a telemetry pipeline.

The kernel tool groups an application declares by capability already ship (`CybrosAgent::Toolsets`, [SDKs](../build/sdks.md)).

## Chinese

Documentation, Nexus and rho will be available in Chinese. The documentation site adds a `zh` locale after the English reference settles. Nexus's pages use Rails I18n with a `zh-CN` catalog. rho and every plugin — including third-party plugins, whose authors may write in any language — follow one convention: optional static catalogs per plugin and one lookup API that never fails. A plugin without catalogs is shown as its code writes it; a plugin with one language is shown in that language; a plugin with several follows the person's preference and falls back to English.

## Stable release

The rolling release will be followed by a stable channel with incremental database migrations for installed databases and frozen public contracts. See [Release and compatibility](release-and-compatibility.md).

## Not planned

- **A hosted sandbox.** Execution stays on infrastructure you control.
- **Webhooks from Nexus to your application.** Components connect outbound to Nexus; durable replay plus cable subscriptions cover application integration without an inbound dial.
- **A tenant isolation layer.** One installation is one Account of trusted members. A hosted multi-account service would be a separate product on the same kernel.
