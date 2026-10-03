# Ingress speakers

An Agent may register external speakers and post their words through the existing
conversation input door. An ingress Actor is a voice controlled by that Agent,
not a User, authentication principal, credential, or conversation participant.
Workspace and conversation authorization still use the authenticated Agent.

## Register or resolve

```text
POST /agent_api/v1/profile/ingress_actors
```

Requires an Agent member credential.

```json
{"ingress_actor":{"channel_key":"bridge:123","external_id":"456","display_name":"Ada"}}
```

```json
{"ingress_actor":{"public_id":"01900000-0000-7000-8000-0000000000a8","kind":"ingress","channel_key":"bridge:123","external_id":"456","display_name":"Ada"}}
```

The existing Account + channel_key + external_id natural key is the registration
identity. First creation returns 201; resolving an existing identity controlled
by the same Agent returns 200 with its original name and UUID. It does not rename
or transfer the Actor. No Idempotency-Key is needed for natural-key resolution.
A key controlled by another Agent refuses `403 not_authorized`. A Human member
refuses `403 not_agent_profile`; the executor and platform planes cannot use this
door. Invalid or blank fields return `422 validation_failed`; missing required
fields return `400 parameter_missing`. Unknown fields are ignored.

The maximum lengths are 64 characters for channel_key, 128 for external_id, and
100 for display_name. The channel keys `member` and `system` are reserved. Use a
stable bridge or bot identity in channel_key, never a token or other secret.
The application must obtain its manager's explicit authorization before registering
an external speaker; the kernel does not infer consent from receiving a message.

## Submit speech or listen

On `POST /agent_api/v1/workspaces/{workspace}/conversations/{conversation}/inputs`,
add `speaker_actor_public_id` to the existing `input` envelope. The Actor must be
an ingress Actor in the same Account controlled by the authenticated Agent.
Another Agent's Actor, a member Actor, and an unknown UUID refuse
`403 not_authorized`; a malformed UUID returns `400 parameter_invalid`. Only
`role: "user"` is admitted with this selector (`422 validation_failed` otherwise).
The selector is create-only, canonicalized as a lowercase UUID, and participates
in the existing receipt digest. Reusing a key with another speaker returns
`409 idempotency_envelope_mismatch`. Receipt retention remains 24 hours.

```json
{"input":{"kind":"message","role":"user","text":"I will join later.","speaker_actor_public_id":"01900000-0000-7000-8000-0000000000a8"}}
```

`kind: "message"` records a completed user message when the queue drains, with no
model invocation or loop. `kind: "direct_reply"` requests a response using the
ordinary model, prompt and tool fields. The Agent remains the input's author and
control owner; `origin` remains `agent`. ACLs, addressee, queue/steer and prompt
assembly rules do not change. Standalone-loop inputs do not accept this selector.

Input and user-message turn projections carry
`speaker: {actor_public_id, kind: "ingress", display_name}`. A reply turn's speaker
is still its answering Agent; its seed retains the ingress Actor. Existing member
speaker projections remain `{user_public_id, handle, kind, display_name}`.

The existing renderer wraps ingress speech at assembled-input, history, steer,
regeneration and compaction sites:

```text
<message from="Ada" kind="ingress" actor="01900000-0000-7000-8000-0000000000a8">
I will join later.
</message>
```

Display-name attributes are escaped, and the existing body-envelope escape applies.
Raw prompt mode retains its existing caller-authored request semantics.

## Application-owned transport

Bot credentials, chat/topic-to-conversation routing, mention/reply rules and
unregister are application policy. Unregister means the application stops accepting
future messages; there is no kernel revoke or delete operation for this binding.
Already accepted inputs retain their usual lifecycle and authority checks.

Ruby SDK: `client.profile.register_ingress_actor(channel_key:, external_id:,
display_name:)` returns `Api::IngressActor`; `conversation.inputs.create` accepts
`speaker_actor_public_id:`. Ingress projections parse as `Api::IngressSpeaker`;
member projections remain `Api::ConversationSpeaker`.
