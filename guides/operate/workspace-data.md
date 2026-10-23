---
title: Manage workspace data
description: Read and maintain a workspace's Memory, character and application Store, and find attachments in retained content.
---

# Manage workspace data

Open a Workspace and choose **Data** to maintain its Memory, character and Store.
These resources belong to that Workspace. Personal, Agent, Speaker and Conversation
data keep their own scopes.

Any Human with data access can edit document content and Store while the Workspace is live
(`active` or `restoring`). You do not need to own the Workspace. An archived or
archiving Workspace remains readable and has no write controls. Account admin
status does not grant access to a private Workspace's data. Creating collections and
changing their metadata or lifecycle requires the active Human Workspace owner.

## Edit Memory

1. Choose **Memory collections** from Workspace Data, or use the sidebar to
   browse all collections your own authority can access.
2. Search by name or exact collection ID and filter by scope or status. The
   list starts with active collections; select **Archived** to find collections
   you can restore. Open a collection and choose **Documents** to read its contents.
   The Workspace owner can create
   additional collections and edit their names and descriptions.
3. Open a document and choose **Edit**, or choose **New memory document** with
   a relative path such as `notes.md`. Save the text and optional skill description.

Each collection holds up to 64 documents of at most 64 KiB each. A
`skills/<name>` document requires a skill description; ordinary documents
leave that field empty. Collection and document UUIDs identify the resources;
renaming a collection does not move its documents or change conversation paths.

The editor submits the original document UUID and version. A concurrent edit,
deletion or recreation refuses a stale save and keeps your draft. **Read the
saved value** opens the current document in a new tab. Compare it with your
draft before starting a fresh edit; the page does not refresh conditions and
retry old text. Collection metadata changes use their own version condition.

**Archive** makes the collection read-only. **Restore** reopens the same
collection. **Delete** permanently closes content access and starts cleanup;
it does not stop conversations using it. Deleting a default collection does
not create a replacement. Document deletion has no restore action or recycle
bin. Copies and content already retained in execution requests remain separate.

Creating a collection does not attach it to a Conversation. Applications select
collections through the [memory binding API](../reference/agent-api/conversation-memory.md).
The Conversation page's **Memory bindings** section shows the current effective
selection and, while a reply is running, its separately captured binding identities.
It displays source scope, collection UUID, effective access and collection state.
Only sources visible under your current access appear; a collection link requires
independent owner access. Agent/Speaker bindings do not grant private-document access.
The owner-scoped collection inventory remains separate from these binding views. **New collection** from the global
inventory creates personal memory; use a Workspace's Data page or a Conversation's
Memory collections link to create memory owned by that resource.

A provider override blocks ordinary kernel content even when opened by
collection UUID. Collection metadata remains manageable. The refusal page
allows an exact `skills/` path, which retains kernel handling, without
revealing an ordinary document list.

The sidebar also shows your own Human collections and readable Conversation
collections. It does not grant access to an Agent's or Speaker's private
collections because you are its steward or an administrator.

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
