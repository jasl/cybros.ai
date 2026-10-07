# Personal persona

The authenticated Human owns one `persona` prompt document. These personal
settings need no administrator role. The document is the same one exposed on
that Human's member profile and used by prompt assembly for the Human and their
Agents. It neither edits an Agent's `system_prompt` nor changes the Agent's
execution policy.

```http
GET    /api/v1/persona
PUT    /api/v1/persona
DELETE /api/v1/persona
```

Use a Human platform token or API-session bearer. A signed-in browser cookie
can read, but mutations require a bearer. Member and executor credentials do
not authenticate on this plane. The route always selects the authenticated
Human; it accepts no user, Agent or Workspace selector.

PUT replaces the whole document:

```json
{"prompt_document":{"content":"I prefer concise explanations.","role":"system"}}
```

`content` is required, may be empty, and has the existing 64 KiB prompt-document
bound. `role` is optional and defaults to `system`; `developer` and `user` are
also supported. Prompt macros use the same registry and validation as other
[prompt documents](../../agent-api/v1/profile.md). Unknown fields are ignored.

GET and successful PUT return `200`:

```json
{"prompt_document":{"slot":"persona","role":"system","bytesize":30,"version":1,"written_at":"2026-10-07T00:00:00.000Z","content":"I prefer concise explanations."}}
```

Whole-slot writes serialize on the Human owner and increment `version`, with
last-write-wins semantics. There is no conditional version input, history,
idempotency key or separate persona identity. Subsequent assembled turns use
the current document; already sealed requests retain their original bytes.

DELETE returns `204`. GET or DELETE of an absent document returns
`404 prompt_document_not_found`. Invalid content or role returns
`422 prompt_document_invalid`, an unknown macro returns
`422 prompt_document_macro_unknown`, and oversize content returns
`422 prompt_document_too_large`; refusals preserve the current document.
Authentication failures return `401 unauthorized`.

The Ruby SDK exposes `platform_client.persona.read`,
`platform_client.persona.write(content, role: "system")` and
`platform_client.persona.delete`. Read and write return the ordinary typed
`CybrosAgent::Api::PromptDocument`; delete returns `nil`.
