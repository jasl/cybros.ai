---
title: Manage workspace data
description: Read and maintain a workspace's Memory, character and application Store, and find attachments in retained content.
---

# Manage workspace data

Open a Workspace and choose **Data** to maintain its Memory, character and Store.
These resources belong to that Workspace. Personal, Agent, Speaker and Conversation
data keep their own scopes.

Any Human with data access can edit these resources while the Workspace is live
(`active` or `restoring`). You do not need to own the Workspace. An archived or
archiving Workspace remains readable and has no write controls. Account admin
status does not grant access to a private Workspace's data.

## Edit Memory

1. Choose **Workspace Memory** to list document paths, sizes and current versions.
2. Open a document to read it, then choose **Edit**. To create one, choose
   **New memory document** and enter a path such as `workspace/notes.md`.
3. Enter the text and choose **Save memory document**.

Only `workspace/` paths are available here. The page cannot read or write another
scope. Each Workspace holds up to 64 Memory documents, including its skills;
each document's content is limited to 64 KiB. A `workspace/skills/<name>` document
also needs a skill description. Ordinary documents leave that field empty.

The editor submits the document identity and version it originally read. If
someone changes, deletes or recreates the document, saving refuses the stale
edit and keeps your draft. **Read the saved value** opens the current document
in a new tab. Compare it with your draft and start a fresh edit to apply your
chosen changes. The page does not refresh the version and retry your old text.

Saving replaces the current document. **Delete** removes it after confirmation.
There is no document version browser, restore action or recycle bin. Content
already included in retained execution requests keeps that execution's own
retention rules.

When a Tool provider serves the Workspace's Memory, the ordinary kernel list
and document editor report that provider and are unavailable. The refusal page
lets you open or create an exact `workspace/skills/` path, which retains its
kernel management rule. It does not reveal a list of ordinary Memory documents.

## Edit character

Choose **Workspace character**, then **Edit character**. Select the prompt role,
enter the text and save. The editor lists the supported macros. Invalid text
keeps your draft and role without replacing the saved document.

The character is the Workspace's prompt document. It participates when the
selected prompt template includes the `character` slot. Saving replaces the
whole current document, including any changes another editor saved meanwhile.
Its version counts writes; it does not prevent concurrent replacement.

Saving empty text retains an empty document. **Delete character** removes the
document. Neither operation creates a version history or recycle bin.

## Edit Store entries

Choose **Workspace Store** to browse entries in namespace and key order. Use
the namespace filter to select one exact namespace, then follow the pagination
links as needed. The list shows metadata; open an entry to read its JSON value.

Choose **New Store entry** to supply a namespace, key and JSON value. Namespace
and key are fixed after creation. Each Workspace holds up to 64 entries.
Applications may depend on these values for saved state, so inspect their
meaning before changing them.

The editor accepts raw JSON, including arrays, `false` and `null`. A `null`
value remains a Store entry; use **Delete** to remove it. Nexus does not infer
an application schema or inject Store values as Memory.

Create retries retain the same request key and use the existing create receipt.
The same request can replay while its receipt is retained; different fields
under an accepted key are refused. Open a new entry form for a different create.
Edits and deletes use the version you read. A conflict keeps the draft and its
original version, and requires reading the saved entry before a fresh edit.
There is no recycle bin.

## Find attachments

The Data page links to **Browse Conversations** and **Browse Runs**, filtered to
the Workspace. Open a Conversation to preview or download attachments from
its readable retained content. Open a Run's Task to download files captured in
its output. Supported file types also offer a preview; the original download
remains available when a preview cannot be produced.

Attachments belong to retained messages and results. There is no separate
Workspace file directory or file count. Each destination retains its own
content permissions; Workspace access alone does not grant access to every
Conversation. Upload descriptor access remains separate from reading attachment
bytes through a readable content reference.

## Next

- [Workspace API and data scopes](../reference/agent-api/workspaces.md)
- [Store entries](../reference/agent-api/store-entries.md)
- [Prompt assembly](../reference/agent-api/prompt-assembly.md)
- [Conversation memory](../reference/agent-api/conversation-memory.md)
