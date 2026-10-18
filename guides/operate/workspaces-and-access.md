# Workspaces and access

Workspaces organize collaboration inside one account. They are not a tenant boundary: every member is trusted, and access controls decide what each member can read and change.

## Workspaces

Every conversation, run and direct model request belongs to exactly one workspace. Nexus creates no default workspace.

- A workspace has one human **owner** and an access mode: **Private** (the owner and their agents) or **Account-wide** (every member and their agents can use its data). The owner remains the only one who manages it.
- Use **Workspaces → New workspace** in the Nexus browser to create one you own. **Private** is selected by default.
- Agent applications create their own **dedicated** workspaces, owned by the agent's steward and tagged with the agent's identifier. Dedication fences writes from other agents; it grants no access and no management rights. rho creates one when none is selected.
- Ownership can be transferred to another active human in the same account. Transfer changes nothing about who created what.
- A workspace can be archived — a recycle bin it can be restored from, in which it still reads but never writes — or deleted, after which it is absent from every surface. Removing a human requires every workspace they own that is not deleted to be transferred or deleted first.

## Agent messaging

Each Agent in a Workspace is **Public** by default: every otherwise eligible Agent may contact it through `send` and `spawn`. The Workspace owner can make an Agent **Private** and select which Agents may contact it. The setting belongs to the receiving Agent. Allowing A to contact B does not also allow B to contact A. Each bot keeps its own identity, including bots served by the same rho instance. An Agent may always contact itself.

1. In Nexus, open the Workspace and choose **Agent messaging → View messaging settings**.
2. Under **Agent to configure**, select the receiving Agent and choose **Choose agent**.
3. Choose **Public** or **Private**. Under **Allowed senders in Private mode**, select the Agents that may contact it when Private, then choose **Save messaging settings**.

Public preserves the saved sender list but accepts every otherwise eligible Agent. Switching back to Private uses that list again. A Private Agent with an empty list accepts only itself. Existing requests continue, and their results can return without a reverse permission. These controls do not change who can read conversations, inspect history or stop work. Conversation access below remains separate. The [messaging API](../reference/agent-api/workspaces.md#read-messaging) exposes the same policy and its Workspace version.

## Conversation access

Under the workspace's access, each conversation carries a default level for everyone its entries do not name — `full`, `read` or `none`, born `full` — and one entry per named member. The creator and the answering agent always have full access by derivation.

| Level | Effect |
| --- | --- |
| `full` | Read and write, including changing the conversation's access |
| `read` | Every read answers; every write is refused by name |
| `none` | The conversation is concealed: lists, document, turns, events, inputs and runs all behave as if it did not exist |

Access is set at creation and replaced whole through the conversation's access operation by a member with full access and write standing on the workspace. A member with `read` can never raise their own level. A fork or side conversation copies the access rows at the fork instant. Changes are recorded as an `access_changed` event naming the actor and their kind.

The kernel's own acts never consult these rules: the answering agent writes its turns, a task's receipt lands as kernel mail, and a spawned child's reply is relayed, whatever the creator's level.

## Agents, runners and tool providers

- Each **agent** has a human steward. Agents derive data access from the steward and never administer the account.
- Each **Runner** and **tool provider** has a Human manager. An independent registration uses `user_private` (Agents stewarded by that Human), or `account_wide` when an owner or administrator chooses it during fresh registration. A bundled Runner uses `agent_private`, binding it to one Agent application and that application's owned Agents. Other applications cannot discover or use it, including another rho instance under the same Human. See [Runner identity and scope](../runners/deploy.md#identity-and-scope).
- Runner scope and application binding are fixed at creation and preserved by re-pairing. Scope is access control only; it never changes logical identity or an existing task's accepted target.
- A manager connects and disconnects their own runners and providers from **Runners** in the Nexus browser. Administrators have no takeover or removal path for another human's runner.

## Members a conversation can name

The principals a conversation's access may name are the members with access to its workspace, listed by the workspace's principals endpoint in the [Workspaces reference](../reference/agent-api/workspaces.md); the access carrier itself is in the [Conversations reference](../reference/agent-api/conversations.md). That listing shows a user's own non-secret registration identifier beside its steward, never a workspace's dedication tag.
