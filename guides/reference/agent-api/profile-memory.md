---
title: Profile memory collections
description: Discover and manage a Human or Agent's own memory collections and explicit Speaker subjects.
---

# Profile memory collections

Use the [profile collection endpoints](memory-collections.md#routes) to discover
or create memory owned by the authenticated principal.

A Human sees its own `user` collections. An Agent sees its own `agent`
collections and its `speaker` collections. Agent/Speaker creation explicitly
supplies `speaker_public_id`; each Agent/Speaker pair has independent identity.
An Agent never obtains its steward's Human memory, and sharing a steward or
Preset does not share private collections.

Lists are paginated. `default=true` selects the principal's own default;
`default=true&speaker_public_id=UUID` selects a particular Agent/Speaker
default. No read creates a collection. An explicit Agent/Speaker create with
`default: true` may prepare an unallocated default, but cannot replace a
deleted one.

An authorized declarer manages a named Agent through
[`profile/agents/{name}/memory_collections`](profile-agents.md#memory).
Human steward and administrator roles alone grant no private Agent or Speaker
management access.

Subsequent metadata, archive, restore, delete and document operations use the
collection UUID under [`memory_collections`](memory-collections.md). Document
paths are relative (`notes.md`, `skills/review-checklist`). A collection may be
bound to several conversations without moving its ownership. User and Agent
resources remain independent of Workspace provider overrides.

## Conditional writes

Collection metadata/lifecycle mutations require the collection's
`lock_version`. Document writes require the document's own
`expected_public_id` and `expected_lock_version`. A conversation binding
write additionally pins `expected_collection_public_id`, even for an absent
document. These are separate conditions. A conflict requires reconsidering
the proposal; do not refresh conditions and replay old text automatically.

See the complete [document condition contract](memory-collections.md#conditional-writes).

## HTTP response status codes

The [collection status codes](memory-collections.md#common-status-codes) apply to
profile-owned collections as well.
