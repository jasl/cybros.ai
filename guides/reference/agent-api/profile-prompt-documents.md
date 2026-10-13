---
title: Profile prompt documents
description: "The agent's system_prompt and summarizer slots and the person's persona slot: the durable rows an assembled turn renders."
---

# Profile prompt documents

The slots this door owns are the agent's own `system_prompt` and
`summarizer` and the person's `persona`. What an assembled turn does
with them is [Prompt assembly](prompt-assembly.md); the room's
`character` slot is at
[`workspaces/{id}/prompt_documents`](workspaces.md#prompt-documents).

## Routes

```http
GET /agent_api/v1/profile/prompt_documents
GET /agent_api/v1/profile/prompt_documents/{slot}
PUT /agent_api/v1/profile/prompt_documents/{slot}
DELETE /agent_api/v1/profile/prompt_documents/{slot}
```

The acting user's OWN slots. Of the default template
([Prompt assembly](prompt-assembly.md#slots)):
an Agent holds `system_prompt` — its identity, compiled first
into every assembled turn it is the declaring profile of (its own row,
never its steward's); a Human holds `persona` — who the person is,
compiled into every turn that person posts, in every workspace, behind
the room's `character`. The workspace's `character` has its own door
([Workspaces](workspaces.md#prompt-documents)). An
Agent holds one more slot the template never places:
`summarizer` — the text of the kernel-mode compaction summarizer for
every conversation it answers ([Conversation context](conversation-context.md#automatic-repair)),
read as that step's raw `instructions` in place of the kernel's default;
absent, the default. It is CONTENT-ONLY: no macro (its request has no
sources, so a `{{…}}` is refused by name as everywhere) and no role — a
`role` other than `system` on it is `prompt_document_invalid`. Under a
`delegate` policy nothing reads it. The slot the caller's kind cannot
hold is refused here by name (`prompt_slot_unavailable`) before any row
is touched. The slot is the URL's member segment and the write is a
`PUT`: a whole replacement, first or later write alike, `version`
counting the writes.

- `GET /agent_api/v1/profile/prompt_documents` — the caller's slots, as
  `{slot, role, bytesize, version, written_at}`.
- `GET /agent_api/v1/profile/prompt_documents/{slot}` — the document with
  its `content`, as written (macros unrendered).
- `PUT /agent_api/v1/profile/prompt_documents/{slot}` —
  `{prompt_document: {content, role?}}`; 200 with the document. `role` is
  `system` (default), `developer` or `user`. Omitting `role` uses `system`
  on every write, including replacement of a document with another role.
  The macros `{{agent}}
  {{user}} {{workspace}} {{date}} {{conversation_kind}}` are substituted at compile;
  [prompt assembly](prompt-assembly.md#slots) defines their sources. A word
  outside the registry is refused, naming it.
- `DELETE /agent_api/v1/profile/prompt_documents/{slot}` — 204, gone.

No fence and no workspace: the users row is the caller's own and the
lock. A write bumps no conversation's `context_revision` — the next turn
of ANY conversation reads it live. Bound: 64 KiB. rho resolves its own
`work_preset` (`standard` or `compact`), optional `base_prompt` replacement and
appended `custom_instructions` into `system_prompt` at each settings/declaration
edge in the atomic configuration declaration above. `base_prompt: null` uses
the selected preset; `base_prompt: ""` supplies an empty base. rho owns these
application settings; they introduce no additional Nexus profile mechanism.
Named-agent prompt bodies, Human persona and Workspace character remain
independent. Already materialized turns keep their captured document.
For rho's assembled turns, Nexus renders the
frozen selected environment as a `user`-role lead, and rho supplies its application
context as a `developer`-role inline lead after history; later turns replay both
through the sealed preface. rho's `summarizer` slot carries the
`summarizer_prompt` of the SDK pack row its summary model resolves to,
replaced in that same PUT and cleared when the row carries none, the
knob is `off`, or the policy is `delegate`. `rho prompt show [SLOT]` (rho-dev) reads
this door from a terminal. Use the default agent's settings page in rho's WebUI to persist a
custom base or additional instructions; rho ships no direct slot `write`/`delete`
verb, because its own slots are rewritten from configuration at declaration.

## HTTP response status codes

| Status | Code | Description |
| --- | --- | --- |
| `200 OK` | — | The listing, the document, or the written document. |
| `204 No Content` | — | Deleted. |
| `401 Unauthorized` | `unauthorized` | The credential is missing, unusable, or not a member-plane credential. |
| `404 Not Found` | `prompt_document_not_found` | The slot holds no document. |
| `422 Unprocessable Content` | `prompt_slot_unavailable` | The slot is not the caller's to hold: `character` at this door, `persona` for an agent, `system_prompt` for a Human. |
| `422 Unprocessable Content` | `prompt_document_too_large` | The content exceeds 64 KiB. |
| `422 Unprocessable Content` | `prompt_document_macro_unknown` | A `{{word}}` outside the registry, named in the message. |
| `422 Unprocessable Content` | `prompt_document_invalid` | No `content`, a non-string, a role outside `system \| developer \| user`. |
| `429 Too Many Requests` | `rate_limited` | The ordinary caller budget or broad source-IP backstop is spent. |
