# CybrosAgent

The Ruby SDK for agent programs that talk to Nexus. It provides OAuth device
connection and credential renewal, member-plane resources for workspaces,
conversations, loops and one-shots, and the executor inbox for claiming and
reporting work. A separate Human Platform client provides session login and
account model administration. The agent-framework helpers add typed step authoring,
stream following, realtime notifications and model adaptation data.

The SDK owns protocols, not local persistence. Applications provide the
credential store and any durable state they need. The synchronous client
plane loads independently of the optional Async realtime stack.

## Installation

The gem is monorepo-internal until Nexus's API v1 freezes; consume it by path:

```ruby
gem "cybros_agent", path: "sdks/ruby"
```

## Usage

```ruby
client = CybrosAgent::DeviceFlow::Client.new(
  base_url: "https://nexus.example",
  request_timeout: 120
)

module MyAgentProduct
  AGENT_IDENTIFIER = "my-agent-product".freeze
end

authorization = client.request_authorization(
  agent_identifier: MyAgentProduct::AGENT_IDENTIFIER,
  agent_display_name: "My Agent",
  executor_display_name: "My Agent on this machine"
)
# Show authorization.user_code and authorization.verification_uri to the
# human. They compare the code and complete the connection, then:
credentials = client.await_credentials(authorization)

rotated = client.rotate(refresh_token: credentials.refresh_token)
client.revoke(token: rotated.access_token)
```

If the application abandons a ceremony while it still has the `Authorization`,
it must ask Nexus for the winner before stopping its poller:

```ruby
case client.cancel_authorization(authorization)
when :canceled
  # Nexus returned safe-to-kill; stop and forget this ceremony.
when :consumed
  # Consume won; keep polling and adopt the credential response.
end
```

Every unknown secret, throttle, transport failure, 5xx, or malformed response
raises instead of returning `:canceled`. The endpoint is a Cybros first-party
extension, not an RFC 8628 cancellation verb.

An application chooses a non-secret registration identifier and keeps it stable
for the installation it represents. Rho combines its product constant with a
per-home instance ID, so separate homes connect as separate Agent Profiles.
Nexus treats the identifier as opaque and resolves it under the connecting
Human steward. Reconnecting the same identifier re-pairs that logical address;
never copy an access/refresh credential document to another installation.

An agent that also serves as a runner on its own machine — rho in full mode —
pairs both in ONE grant, the combined shape, by naming its runner pair on the
same call:

```ruby
authorization = client.request_authorization(
  agent_identifier: MyAgentProduct::AGENT_IDENTIFIER,
  agent_display_name: "My Agent",
  executor_display_name: "My Agent on this machine",
  runner: { identifier: MyAgentProduct::RUNNER_IDENTIFIER, display_name: "My Agent on this machine" }
)
credentials = client.await_credentials(authorization) # branch :combined
planes = CybrosAgent.planes_for(credentials, base_url: "https://nexus.example")
planes.runner_client # the in-process runner's own ExecutorClient
```

The human approves one page; the winning poll carries TWO lineages — the
agent's bundle as above plus `credentials.runner_half`, the runner's
transport-led bundle with its own refresh token, which `Credentials::OAuth.issue`
stores as a second lineage. The runner is registered private to the Agent
Profiles the connecting human manages, its kind fixed `runner`; no
`executor_kind` is sent. Each lineage rotates on its own refresh token and a
rotation never carries the other half. `Credentials::OAuth#revoke` presents a
lineage's refresh token to `/oauth/revoke` and empties its store.

A Runner uses a separate stable `runner_identifier` for its logical registration:

```ruby
module MyRunnerProduct
  RUNNER_IDENTIFIER = "my-runner-product".freeze
end

authorization = client.request_runner_authorization(
  runner_identifier: MyRunnerProduct::RUNNER_IDENTIFIER,
  runner_display_name: "My Runner on this machine"
)
```

A tools provider — the same machine shape, serving tools by name and claiming
from pools — connects on the same branch naming its kind:
`request_runner_authorization(..., executor_kind: "tools_provider")`. The
registration key is kind-blind, so a provider needs its own identifier: one
manager cannot hold a runner and a provider under one constant, and
reconnecting a live key as the other kind is refused (`access_denied`).

The machine request carries no assignment scope. For a fresh registration,
Browser Connect defaults to private access and lets an owner or administrator
opt into account-wide access. Reconnecting a live registration preserves its
stored access and presents no scope input.

`Credentials::OAuth` asks the application-supplied credential Store to
serialize publish and re-read/rotate/persist inside the owning process. The
embedding application owns that process and Store lifecycle; the SDK does not
claim cross-process coordination or copied-store adoption.

Polling honours the server interval, `slow_down`, and `Retry-After`, and
never outlives the 900-second authorization deadline. It also has a finite
consecutive-transient-failure budget independent of that deadline. Connection
failures and unhandled 5xx responses consume the shared budget; a handled
response resets it. Exhaustion raises the typed failure for the last response
class. The exact budget and backoff formula are intentionally not part of the
public contract.

Initial polling also validates the authorization branch: an Agent connection
must receive member plus executor-transport credentials, while a Runner must
receive executor transport only. Refresh rotation remains branch-independent
and may legitimately return a degenerated bundle after member authority dies.

Every machine request has a finite total transport budget (120 seconds by
default). Each poll further caps that budget to the authorization's remaining
monotonic lifetime, and a response arriving at or after the deadline is never
accepted. An injected transport implements the one transport contract
(`call(path, method:, credential:, body:, form:, params:, headers:, timeout:, accept:)`,
`lib/cybros_agent/transport.rb`) and returns `CybrosAgent::Response`; it raises
`CybrosAgent::RequestNotSentError` only when it can prove no request bytes were
dispatched, and `CybrosAgent::TransportError` otherwise.

Raw `sk-`/`rt-`/`dc-`/`rc-` values are redacted from value-object, response,
and error inspection output. Terminal
authorization loss raises `CybrosAgent::DeviceFlow::AuthorizationLostError`;
the recovery is a new device authorization. In particular, if a transport
failure or an unhandled/proxy 5xx leaves a refresh rotation outcome uncertain,
the client treats the connection as lost and never retries the old refresh token.
When the transport can prove the request was not dispatched, it instead raises
`CybrosAgent::RequestNotSentError`; retrying the unchanged refresh
token is safe only for that typed outcome.

Normal endpoint successes and defined OAuth errors use the documented JSON
shapes. Unhandled application or proxy 5xx responses may be non-JSON or empty;
the client classifies them by status without assuming a JSON body, media type,
or cache headers. During `await_credentials` they share the bounded
consecutive-failure budget with connection failures, so one proxy hiccup never
kills a pending connection.

For Agent authorization, the Agent branch itself fixes the executor kind to
`agent_application` and sends no selector; Nexus derives executor creation,
reuse, or reconnection internally from the final Agent. Branch B takes
`executor_kind:` (`runner` by default, `tools_provider` for a provider) and
always sends it; `Authorization#executor_kind` names the kind on both
branches while `branch` stays the credential shape the poll validates
(`:agent` receives both planes, `:runner` — either machine kind — transport
only). On the executor plane, `ExecutorClient#announce(tools:, environment:,
documents:)` replaces whole the list of tools this address serves (`{name,
effect_profile, timeout_ms?, description?, input_schema?}` entries, an
optional `environment:` document and an optional `documents:` list, passed
through as given) so the kernel can address work to it; the kernel refuses a
reserved kernel namespace as `reserved_namespace` and a squatted name as
`reserved_tool_name`, and admits an overridable kernel name (`memory_read`,
…) and the source-routed `skill` as announced. `documents:` is what this address can LOAD for a model — a
project's skills, an MCP server's prompts and resources curated into the
shape — as `{name, description}` entries (`name` under the skill grammar,
`description` a non-empty string ≤ 1024 bytes; 422 `invalid_announcement`
names `documents[i].<field>`); the kernel merges them into the turn's skill
catalog and routes a load of an announced name to this address's inbox as a
`skill` row, so an address announcing documents announces `skill` too.

## Credentials on long-lived clients

Both `CybrosAgent::Client` and `CybrosAgent::ExecutorClient` accept exactly one
of a static `credential:` or a `credential_provider:` callable returning the
current token for that client's plane. A client whose contexts survive OAuth
rotation should use the latter:

```ruby
client = CybrosAgent::Client.new(
  base_url: "https://nexus.example",
  credential_provider: oauth.method(:member_credential).to_proc
)
executor = CybrosAgent::ExecutorClient.new(
  base_url: "https://nexus.example",
  credential_provider: oauth.method(:executor_credential).to_proc
)
```

The callable is read once per HTTP request, including uploads and downloads;
construction and resource scoping do not call it. OAuth persistence and
renewal remain the credential owner's responsibility. The client does not
retry a refusal with another token. Bind the callable to the original
credential owner: changing connection identity should retire the old work,
not give its contexts another identity's bearer.

## Workspaces

`CybrosAgent::Client` carries the member plane's Workspace surface. Lists return a `CybrosAgent::Api::Page` with `items` and `next_after`;
pagination is manual — hand the cursor back to the same list call, repeating
the same filters every page, because the cursor encodes only ordering and the
server rebuilds the scope from each request's own parameters:

```ruby
client = CybrosAgent::Client.new(base_url: "https://nexus.example", credential: member_token)

workspaces = []
page = client.workspaces.list(dedicated_to_current_agent: true)
loop do
  workspaces.concat(page.items)
  break if page.next_after.nil?

  page = client.workspaces.list(dedicated_to_current_agent: true, after: page.next_after)
end
```

The server applies dedication visibility after ordinary
owner/access-mode/steward access. With an Agent credential, omitting
`dedicated_to_current_agent:` or passing `false` lists only undedicated
Workspaces; `true` lists only Workspaces dedicated to that Agent. With a Human
credential, omission or `false` lists every accessible Workspace and `true`
returns an empty page. No raw agent identifier is accepted or returned;
Workspace projections expose only boolean `dedicated`.

Both creates require an explicit, caller-minted `idempotency_key:` — the SDK
never silently mints one. Replaying the same key with the same request returns
the original creation; a different request under the same key is a `Conflict`.

Every typed failure (`CybrosAgent::Api::Error` and its subclasses) carries the
envelope's `code` and, in `details`, every member the kernel rendered beside
`code` and `message` — the four extended envelopes `errors.json` names:
`invalid_steps`' compile errors under `"steps"`, `stale_revision`'s
`"current_revision"`, `edge_authoring_refused`'s `"path"`,
`conversation_hosted`'s `"conversation_public_id"` and `"turn_public_id"`.
Nexus automatically dedicates every Agent-created Workspace under the
authenticated Profile identifier, while a Human-created Workspace remains
undedicated. Dedication grants no access, is frozen when the Workspace is
created, and has no SDK input or mutation method.

```ruby
workspace = client.workspaces.create(
  name: "Notes",
  idempotency_key: SecureRandom.uuid
)
workspace = client.workspaces.fetch(workspace.public_id)
```

An omitted keyword sends no field at all, while an explicit `nil` travels as
JSON null for the server to judge. Management commands live on the scoping
handle `client.workspace(public_id)` — constructing it performs no HTTP — and
every command carries the required `lock_version:` for optimistic concurrency:

```ruby
handle = client.workspace(workspace.public_id)
workspace = handle.update(name: "Renamed", lock_version: workspace.lock_version)
workspace = handle.update_access_mode(access_mode: "account_wide", lock_version: workspace.lock_version)

# Ownership transfer is an alternative final management command: the current
# credential no longer manages the Workspace after handing it to another Human.
# workspace = handle.transfer_ownership(target_user_public_id: human_id, lock_version: workspace.lock_version)

await_state = lambda do |expected|
  loop do
    current = client.workspaces.fetch(workspace.public_id)
    break current if current.state == expected

    sleep 0.25
  end
end

workspace = handle.archive(lock_version: workspace.lock_version)
workspace = await_state.call("archived")
workspace = handle.restore(lock_version: workspace.lock_version)
workspace = await_state.call("active")
workspace = handle.delete(lock_version: workspace.lock_version) # accepted; answers the transition state
```

**Prompt documents — the assembly slots, and the summarizer's.** The
default template compiles three durable texts (the contract pack's
`assembly_slots`) ahead of everything else on an assembled turn, in this order:
the agent's `system_prompt` (its identity, on the Agent Profile), the
workspace's `character` (the room, on the Workspace), and the poster's
`persona` (the person, on their controlling Human). Each anchor fills its own
slot and nothing else; the workspace handle serves `character`, under the
dedication fence — a fenced agent reads it and never writes it:

```ruby
handle.prompt_documents.write("character", "You are the narrator of {{workspace}}; the person is {{user}}.")
handle.prompt_documents.list.map { |doc| [doc.slot, doc.role, doc.version] }   # => [["character", "system", 1]]
handle.prompt_documents.read("character").content                             # as written, macros unrendered
handle.prompt_documents.delete("character")
```

The slot is the URL's member segment and `write` is a PUT — a whole
replacement, 200 whether first or later, `version` counting the writes;
`role:` (`system` by default, `developer`, `user`) is the block's role in the
sealed list. Macros are a closed registry substituted at compile —
`{{agent}}` (the declaring profile's display name), `{{user}}` (the poster's
controlling Human's), `{{workspace}}` (the workspace's name), `{{date}}`
(today, ISO 8601 — a slot naming it moves the cached prefix once a day) — and
a word outside it is refused at the door (`prompt_document_macro_unknown`,
naming it), so a typo never reaches a model as literal braces. `persona` or
`system_prompt` at this door is `prompt_slot_unavailable`; the person's and
the agent's own slots are `client.profile.prompt_documents` (see Conversations).
The fourth slot the pack lists, `summarizer`, is the agent profile's alone and
is never placed: its content is the kernel-mode compaction summarizer's
`instructions` for every conversation the profile answers (absent, the
kernel's default text) — content-only, so a macro is refused and a `role:`
other than the default is `prompt_document_invalid`; a `delegate` policy reads
nothing from it. `client.profile.prompt_documents.write("summarizer", text)`
and `.delete("summarizer")` are the two verbs an application needs (rho writes
its pack row's `summarizer_prompt` there at declare, and deletes it under a
text-less row).

### Tool provider overrides

A workspace may opt a kernel tool family into a tools provider by name — today
the one overridable namespace is `nexus.memory`, the six `memory_*` verbs. The
map is a whole replacement under the required `lock_version:`; `{}` clears it
(the key is always sent — an absent map is a missing parameter, never "clear").
The read renders each entry with the provider's `display_name` and
`assignment_scope`, nil once the provider is reaped while its id stays named:

```ruby
workspace = handle.set_tool_provider_overrides(
  overrides: { "nexus.memory" => provider_public_id }, lock_version: workspace.lock_version
)
workspace.tool_provider_overrides.fetch("nexus.memory").display_name # => "Memory provider"
workspace = handle.set_tool_provider_overrides(overrides: {}, lock_version: workspace.lock_version)
```

Any member with write standing under the dedication fence may set it. The
server refuses with `InvalidRequest` (422) `reserved_namespace` (a namespace
no provider can serve — `nexus.graph`, `nexus.human`, `nexus.conversation`),
`provider_not_eligible` (not a live tools provider of the account, or one some member of the workspace could not reach: it must be account-wide, or private to the owner of this private workspace) or `provider_incomplete` (it does not
announce every live tool of the namespace); a lost race is `Conflict`
`stale_object`. While overridden, that workspace's memory is the provider's:
the six verbs ride the executor inbox to it, the conversation memory routes
answer `Conflict` `memory_overridden` naming the provider, the assembly block
renders nothing, and a tool-less reply has no memory at all. The kernel's rows
wait untouched, so clearing the map restores them. No rho verb sets this.

Store entries are a bounded, namespaced JSON current-value store behind three
handles that share one context — a workspace's, a conversation's (its client
state, which forks with it), and the acting principal's own. The route decides
whose store it is; the body, the projections and the `Idempotency-Key` rule
are the same on all three. A store is data the model never reads: no prompt
renders an entry, which is what separates it from memory. A stored JSON null
is a legal value: `value:` is a required keyword, and passing `nil` sends null
rather than omitting the field.

```ruby
entries = handle.store_entries                               # the workspace's
entries = handle.conversation(conversation_id).store_entries # the conversation's
entries = client.profile.store_entries                       # the acting principal's own
entry = entries.create(namespace: "notes", key: "pinned", value: nil, idempotency_key: SecureRandom.uuid)
entry = entries.update(entry.public_id, value: { "ids" => [1, 2] }, lock_version: entry.lock_version)
entries.delete(entry.public_id, lock_version: entry.lock_version) # => nil
```

The workspace and conversation doors replay a create under its key; the
profile door keeps no receipt — a retried create is `Conflict` `key_taken`,
not a replay.

`WorkspaceSummary`/`StoreEntrySummary` (list items) and
`Workspace`/`StoreEntry` (singular answers) are distinct value types: only the
Full types carry `metadata`/`value`, so an omitted list value can never read
as a stored null. Values are frozen on construction with their nested JSON
deep-frozen, and `Workspace#metadata` / `StoreEntry#value` are redacted from
`inspect`, `to_s`, and `pretty_print` — read them through their accessors.

### One-shots

A one-shot is one direct model call, and it nests under the same handle. There
is one resource for all five workloads — the workload rides in the payload.

**Creation is asynchronous by contract.** The server answers `202` with a
queued resource and the answer arrives later, so `create` hands back something
unfinished and following it is the caller's job. There is deliberately no
blocking spelling: a poll loop hidden inside a method would hide the deadline,
the backoff and the rate limit from the only code that can choose them.

```ruby
one_shots = handle.one_shots
estimate = one_shots.estimate_input(
  workload: "text_generation",
  model: "openai/gpt-5",
  input: "Say hi",
  reasoning_effort: "medium"
)
# Advisory only: use these values to decide whether to compact or trim.
estimate.input_tokens
estimate.tokenizer_exact?
estimate.catalog_input_token_limit

run = one_shots.create(
  workload: "text_generation",
  model: "openai/gpt-5",
  input: "Say hi",
  reasoning_effort: "medium",
  idempotency_key: SecureRandom.uuid
)
run.replayed? # => false; true when the server recognized the key from an earlier request

one_shot = one_shots.fetch(run.public_id)
one_shot.finished?    # => false until the run is terminal
one_shot.output_text  # => the answer, once it is
```

Input estimation uses the model Catalog currently loaded by Nexus, writes
nothing, and contacts no Provider. The Provider remains authoritative for its
actual tokenization and context window; an estimate is not an acceptance or
reservation for the later `create`.

**Ask `finished?`, never a status string.** Nexus emits the `result` envelope
if and only if the run is terminal, and that presence is what `finished?`
reads. A client matching a frozen list of status strings would poll a status
it predates forever — so `status`, `workload` and event `type` are all carried
through verbatim, unknown values included.

```ruby
page = one_shots.events(run.public_id)                 # the durable replay window
page = one_shots.events(run.public_id, after: page.next_after) # strictly after, ascending
one_shots.cancel(run.public_id)  # total and idempotent; answers the standing state
one_shots.delete(run.public_id)  # terminal-only tombstone — running work is a Conflict
```

An `image_generation` or `speech_generation` run produces files. They are
listed on the result and streamed back through the API — never from storage
directly, so the same authorization that guards the run guards its bytes:

```ruby
one_shot.result.files.each do |file|          # [] for workloads that make none
  bytes = one_shots.download(one_shot.public_id, file.index)
  File.binwrite(file.filename, bytes)
end
```

`file.index` is the address and the only one: output files carry no identifier
of their own, and the ordinal is meaningful solely inside the OneShot that
produced it. `download` answers a binary String — where it goes is yours to
decide.

An `embedding` run answers vectors, typed — `result.embeddings` is a list of
`OneShotEmbedding(index, vector)` in the provider's order, `result.vectors`
the numbers alone (`[]` where a workload produced none), and `output_text`
is `nil` on that workload: there is no JSON document to parse.

`result.usage` is the terminal attempt's own receipt — and `nil`, like
`result.timing`, on a run that reached a terminal status before any attempt
wrote one (`status` is the one member every terminal result carries);
`one_shot.usage_summary` is the cumulative cache across the whole attempt
history, retries included, and is always present (zero requests is a true
statement). **Every counter on the receipt is nullable** — providers report different
subsets, and an unreported counter arrives as `nil` rather than as a zero the
gem invented. `cost_amount` is a decimal String on both, never a Float.
A cut-off answer is a success with a caveat: `result.truncated?` is true,
`result.error` stays nil, and the text it did produce is the answer.
A DECLINED answer is not: when the provider's classifier refused the request
(`finish_quality: "refused"`) or a content stop blocked it (`"blocked"`), the
run FAILED — `result.refused?` and `result.failed?` are true, `result.status`
is `failed`, `result.error.code` is `model_refused`, there is no text, and
`result.refusal_category` is the provider's own word for why (`nil` when it
named none). The call was still billed, so `result.usage` is its receipt.
Sending the same request to the same model usually earns another refusal:
continue on another model, or start a new conversation. When the run's
creator is an Agent Profile that declared a `fallback_model` (below), a
refusal — never a content block — or an overload on every attempt of the
budget (`result.error.code` `provider_overloaded`) runs once more on it before the run
settles: `one_shot.status` reads the new execution's (`queued`, then
onward), `one_shot.model` is the fallback's, and the finished
`result.model_change` (`from`, `to`, `reason: "model_refused"` or
`"provider_overloaded"`, `category`) says what it replaced — the rest of `result` is the fallback's
answer and receipt, `usage_summary` counting both calls. A fallback
declined in turn is the failed run above, `model_change` beside it.

Refusals arrive as `CybrosAgent::Api::InvalidRequest` with the domain's own
symbol as the `code` (`unknown_model`, `no_selectable_candidate`,
`provider_disabled`, …). That vocabulary is **open** — Nexus renders whatever
the resolver said — so branch on the codes you know and let the rest reach
your logs intact.

A stale `lock_version` and the other state races surface as
`CybrosAgent::Api::Conflict`; owner-only commands refused to a non-owner and
dedication fences are `CybrosAgent::Api::Forbidden`; an oversized metadata or
value payload is `CybrosAgent::Api::ContentTooLarge`. Each carries the
envelope `code` (`stale_object`, `key_taken`, `not_workspace_owner`, …).

### Conversations

A conversation is the multi-turn plane, where a one-shot is a single call. It
nests under the same workspace handle.

**Nothing is authored directly.** A caller enqueues an **input**, which waits
as a durable row, and the kernel materializes it into a **turn** at the next
boundary — FIFO, and an idle conversation drains immediately. That indirection
is the plane's whole concurrency story: a message arriving mid-reply waits as a
row instead of racing it, so enqueueing never fails for being busy.

Both create verbs (`conversations.create`, `agent_loops.create`) take an
optional `runner_executor_public_id:` naming the runner-kind executor the
host's runner-tool calls are addressed to from birth; omitted, the host is
unbound — the kernel infers no runner, however many are eligible — and an
ineligible id is refused 422 `runner_not_eligible`.

`conversations.create` also takes an optional `answering_user_public_id:`
naming the Agent Profile that ANSWERS the conversation — whose engine
replies to every head whoever posts it, whose `system_prompt` slot leads
every assembled turn, and whose standing the runner is judged for; omitted,
the caller answers its own conversation (an agent caller brings its engine,
a person has a plain chat until a profile is named); an ineligible id — not
an agent profile of the account that may write in the workspace — is refused
422 `answerer_not_eligible`. It never changes after create and a fork
copies it; both shapes read it back as `answering_user_public_id`.

A GROUP addresses per turn: `inputs.create(to: "@lark")` (an `@handle` or a
public id) names WHO ANSWERS that turn — an agent member of the account
holding `full` on the conversation — while the conversation's stored answerer
stays its default; an unknown name is 422 `principal_unknown`, an ineligible
one 422 `answerer_not_eligible`, and `to:` is create-only. An agent is
addressed, never woken: a `to:` row queues like any other and opens that
agent's turn at the next boundary, on that agent's engine — its last reply
turn's model here, else the conversation's last, else the `model:` you sent.
Every input and turn reads back `answering_user_public_id` and `speaker`
(`{user_public_id, handle, kind, display_name}` — a row's author, a message
turn's speaker, a reply turn's ANSWERER; nil on the kernel's summary turn),
so `turns.list` says which agent's turn is running and who answered each
earlier one.

An ingress bridge registers an explicitly allowed external voice with
`client.profile.register_ingress_actor(channel_key:, external_id:, display_name:)`.
Use a stable bot identity, never its token, for `channel_key`. The returned
`IngressActor#public_id` is accepted by `conversation.inputs.create` as
`speaker_actor_public_id:`. `kind: "message"` records passive speech; a
`direct_reply` uses the ordinary reply fields. Ingress speakers parse as
`Api::IngressSpeaker` (`actor_public_id`, `kind`, `display_name`); member speakers
retain `Api::ConversationSpeaker`. Registration resolves without renaming or
transferring ownership, and unregister is the bridge's refusal of future arrivals.
See [the ingress contract](../../docs/agent-api/v1/ingress.md).

**Discovery and the handoff.** `client.executors.list(kind: "runner")` lists
the executors this credential may address — filtered by eligibility on the
server — each with the tools it announced (`served_tools`, declarations
included), its announced `environment` and the documents it can load for a
model (`served_documents`, `ServedDocument(name, description)`);
`client.executors.show(id)` reads one, and an ineligible id is absence. `chat.bind_runner(executor_public_id:)`
and `loop.bind_runner(...)` are the handoff: the next round's runner-kind
calls land on the named runner, and every dispatched call nobody has claimed
is re-addressed now with its clock re-armed, while a claimed call settles
where it started — 404 `runner_not_found`, 409 `runner_not_eligible` (the
message names why), 403 for a caller that does not run the host, and the same
id is a plain 200. Both host reads carry the binding as `conversation.runner`
/ `loop.runner` (`RunnerBinding`, nil when unbound or reaped), so a follower
learns where the next calls land without inferring it from rows. Every
executor read carries `presence` (`online` / `offline` / `not_yet_seen`) beside
`last_seen_at`. Presence is used to DISPLAY, never to choose or refuse: no
delivery or correctness path reads it — discovery filters by eligibility
alone, a call addressed to an offline runner waits for it rather than moving
on its own — and the marks are the kernel's own edge writes on the
executor-inbox subscription, a mark online iff the server holding its socket
is live. Render it; never branch on it.

**Relay requests.** `workspace.agent_loops.request(runner_executor_public_id:,
tool:, input:, timeout_ms:, approval_rules:, idempotency_key:)` creates AND
STARTS a ONE-TASK standalone loop bound to that runner — the `tool` step
(key `relay`) is its deliverable — and `loop.request_result(poll:, patience:)`
polls the task until it is terminal (`stop`ping the loop behind a failed
one, or when `patience` runs out); a composition over `create`, `start` and
the task read, no new route. `timeout_ms: nil` (the default) leaves the
runner's announced park in force; `approval_rules` is the only shell a
caller shapes (a tool step authored by a member is granted by its origin
unless a rule names `author`). The answer's `content` carries a
`resource_link` when the runner answered with a capture — its bytes read
with `uploads.bytes` below. The runner-side capabilities a person requests
this way (`files_bytes`, `process_log`) are announced without a
description or a schema, so `served_tools` never yields a declaration for
them.

```ruby
created = handle.conversations.create(title: "Field notes", idempotency_key: SecureRandom.uuid)
chat = handle.conversation(created.public_id)

chat.inputs.create(text: "remember the number 41", idempotency_key: SecureRandom.uuid)
chat.inputs.create(
  kind: "direct_reply", model: "openai/gpt-5", text: "what number?",
  idempotency_key: SecureRandom.uuid
)

# A PICTURE BESIDE THE WORDS: stage the bytes, then name them on the input
# (the `Upload` value or its public id; images only; never on a steer).
picture = handle.uploads.create("diagram.png")
accepted = chat.inputs.create(
  kind: "direct_reply", model: "openai/gpt-5", text: "what is this?",
  attachments: [picture], idempotency_key: SecureRandom.uuid
)
accepted.input.attachments  # => [UploadRef(public_id, filename, content_type, byte_size)], nil when none
# THE BYTES BACK OUT: `handle.uploads.bytes(public_id, io, range: nil, etag: nil)`
# streams the bytes into `io` for any upload the credential may read — its own
# staged ones, an attachment of a conversation it can read, a capture a tool
# result it can read names — by the upload's ONE rule (`uploads.md`); a `range:`
# ("bytes=0-1023") answers the slice (206); anything unreadable is 404. The
# answer is an `AttachmentRead`: the status and the strong `etag` the server
# carried (an upload is immutable). Hand the tag back as `etag:` and a matching
# one answers `unchanged?` (304) with nothing written — typed, never raised.
read = File.open("diagram-copy.png", "wb") { |io| handle.uploads.bytes(picture.public_id, io) }
read.status                       # => 200
handle.uploads.bytes(picture.public_id, StringIO.new, etag: read.etag).unchanged?  # => true
# A PICTURE OF IT FOR A UI: `uploads.thumbnail(public_id, io, etag: nil)` (256 px on
# the longest edge) and `uploads.preview(public_id, io, etag: nil)` (1600 px) —
# presets the server names, the same rule, the same tag and 304; an upload with
# no representation of that kind (a text file; a PDF on a host without poppler)
# is `NotFound` with the code `representation_unavailable`.
File.open("diagram-thumb.png", "wb") { |io| handle.uploads.thumbnail(picture.public_id, io) }
# On `update`, an absent `attachments` KEEPS the row's pictures across a text
# edit; `attachments: []` unbinds them; a list rebinds. A turn's
# `active_variant.attachments` shows what its prompt carried, the same shape.

page = chat.turns.list            # a POSITION window, not an opaque cursor
page.items.last.text              # the answer, once it has settled
page.items.last.active_variant.prompt_text  # the words that opened a reply turn; nil on a message turn
```

A materialized turn keeps its `input_public_id` when recorded. Independent
worker callbacks expose `input.callback_result` while queued and
`turn.callback_sources` after consumption. Each source identifies the callback
receipt and its worker's exact conversation, input, turn and variant, plus the
original requester actor. A parent summary can carry several sources; its own
answer is separate from those worker results. Read a result's exact variant
through `handle.conversation(result.conversation_public_id).turns.variants(result.turn_public_id)`
and select `result.variant_public_id`; later active candidates do not replace it.

Search readable conversation history within the workspace, then fetch a bounded
text window around a match. Chinese terms, English words and code identifiers
share the server's search index; the client creates no index or embeddings:

```ruby
matches = handle.conversations.search(query: "中文 memory_write", archived: "include")
match = matches.first
window = handle.conversation(match.conversation_public_id).history.list(
  around_turn_public_id: match.turn_public_id, limit: 20
)
window.turns.each { |turn| puts turn.prompt, turn.content, turn.steers }
```

`search` returns `matches` and an opaque `next_after`; pass it as `after` for
another page. `archived` accepts `exclude` (default), `include`, or `only`.
`include_auxiliary: true` includes auxiliary conversations. `history.list`
accepts at most one of `around_turn_public_id`, `before_position`, or
`after_position`. Its page reports `has_older?`, `has_newer?` and `truncated?`;
individual matches and history turns also report truncation. The server defaults
to 20 items, caps a page at 50, and bounds a history window to 12,000 characters.
No method automatically fetches further pages.

Retention keeps this text after old execution details are removed. A normal
timeline variant and loop overview then expose `details_pruned_at`. The variant's
`world` is `unavailable?` with reason `execution_details_pruned`, never
`untouched?`; `restore_world` reports that reason without contacting a runner.
Old regeneration refuses with that code, and execution-detail subresources answer
HTTP 410. The retained conversation history remains readable.

The kernel compiles the prompt from the timeline; the caller never assembles
history. `estimate_input` is the only way to see the size of what is about to
be sent, and it writes nothing and contacts no provider:

```ruby
estimate = chat.estimate_input(model: "openai/gpt-5", prompt: "what number?")
estimate.input_tokens
estimate.history.trimmed?    # history was left out — that much context is lost
estimate.history.compacted?  # history was SUMMARIZED — a summary turn carries it
```

With `render: true` the same call is THE PREVIEW: the bytes a send of these
words would seal, compiled under the addressee `to:` names (`@handle` or a
public id — the input door's own word, resolved by the same rule; default
the conversation's answerer) with the caller as the author. `variables:`
are the turn's values for the addressee's declared template names;
`template:` is an ESTIMATE-ONLY trial order under the kernel's grammar,
compiled in place of the addressee's and never stored. Nothing is written.

```ruby
preview = chat.estimate_input(model: "openai/gpt-5", prompt: "and so?", render: true,
  to: "@narrator", variables: { "scene" => "a rainy night" })
preview.rendered.mechanism            # "assembly" under a template, else "default"
preview.rendered.entries              # the sealed payloads, verbatim — the send's bytes
preview.rendered.storage.within_bound?  # the seal's one measure; over it, `refusal`
preview.rendered.blocks.map { |b| [b.block, b.state, b.tokens, b.allocated_tokens] }
                                      # one row per block: selected | empty | floor_unmet | carried
preview.rendered.slots                # the registered documents compiled, slot => version
```

A preview and the send that follows on the same conversation state — same
caller, same words, same addressee — produce byte-identical `entries`. A
block the model's window cannot fund reads `floor_unmet`: evidence, never a
byte change (history is trimmed to nothing first; the request still sends whole and the drain's window gate alone refuses). A `lead`
equal to the one the window already carries reads `carried` (`carried?`): it is
laid once, and costs 0 again. Without `render` the
answer is the count alone and `rendered` is nil. An addressee whose standing
word is `raw` has nothing to compile: the estimate — rendered or not — is
refused, `InvalidRequest` with the code `estimate_unavailable_under_raw`,
because a count of something else would be a lie. The turn's values ride the
send the same way: `inputs.create(…, variables: { "scene" => "…" })`,
admitted only when the addressee's standing word is `assembly`.

`chat.compact` asks for that summary now (a `compaction_summary` turn, or — while
a loop-backed reply is running — a repair of its next round, answered as
`task_key`/`summary_task_key`); a reader draws the cut from a summary turn's
`kind` on the timeline and from `compacted_before`/`pruned_before` on a
loop-backed variant's round rows.

**A blocked head stops the queue.** That is the contract, not a bug: skipping it
would reorder what the sender ordered. `blocked_reason` says why, and updating
that row is the unblock path. Every row names its `origin` — the source
kind: `person`, `agent`, `task_result`, `child`. The kernel's own two (a
background task's receipt, a spawned conversation's reply) list first, and
`update`, `destroy` and a `reorder` naming one refuse `kernel_input_immutable`;
a peer's `agent` row is a principal's word and stays editable.

```ruby
head = chat.inputs.list.first
chat.inputs.update(head.public_id, text: "shorter", expected_lock_version: head.lock_version) if head.blocked?
```

**Not before a time.** `create(deliver_in: "20m")` or `create(deliver_at: Time | ISO 8601)`
schedules the row (not before that time; not with `steer`); `update(deliver_in: "0s")`
makes it due now, a new time reschedules it; `delete` cancels it. The row's
`deliver_at` is the ISO string the kernel holds.

**The deck.** A turn holds many candidate answers and points at one as active.
Regenerating and editing both *add* — nothing in this plane replaces — so
swiping back is free:

```ruby
chat.turns.regenerate(turn.public_id, model: "anthropic/claude-sonnet-4-5")
deck = chat.turns.variants(turn.public_id)   # every live candidate, active flagged
chat.turns.activate(turn.public_id, deck.items.first.public_id)
chat.turns.set_variant_view_state(turn.public_id, sample.public_id, concealed: true)  # hide one sample (false restores; the active one refuses `variant_active`)
```

Each candidate exposes its captured `memory_context`, independently of the
conversation's current selection. `nil` means the default roots;
`{ "bindings" => [] }` means memory was explicitly disabled. Named bindings
retain their scope and access. `variant.to_h` keeps `memory_context: nil`, so
serializing a candidate preserves that distinction.

A reply the kernel's agent loop produced is a **loop-backed** variant
(`source: "agent_loop"`, `loop_backed?`): it names its `agent_loop_public_id`
and carries the loop's newest spine `rounds` as the transcript's rows without
their calls, and `world` — what the loop did to the files, a fact the kernel
derives (`untouched`, or `touched` with the writing loop, the runner that
claimed its first write and that call's `checkpoint` record verbatim).
Regenerating such a turn births a new candidate with its own loop (the answer's
variant is `loop_backed?`); the kernel judges nothing about the world — the deck
says what happened, and restoring it first is the caller's choice. While the
origin's loop is `needs_attention` the door refuses `loop_needs_attention`.
A fork's answer carries `world` for the fork point beside the child.

**Two feeds, two questions.** `feed` follows where the conversation *is* — the
durable replay window, drained by the same pump the one-shot feed uses, with an
optional socket. `transcript` follows what a turn *says*: deltas while a reply
runs and the settled turn when it terminalizes, both routed by
`turn_public_id`.

```ruby
chat.feed(realtime: realtime, items: "lifecycle").each { |event| render(event) }

subscription = chat.transcript(realtime: realtime).call
subscription.each do |item|
  item.settled? ? replace(item.turn) : append(item.text)
end
```

A feed accepts an optional `after_replay: ->(head) { ... }` callback. It runs
on the event consumer after each bounded REST drain, before subscribing or
returning to live delivery, with the drain's frozen watermark. Use it to
refresh a projection when sequence gaps or an empty page reveal expired
events. The hosted watermark survives retention; the feed's position still
names only events actually consumed. Recovery failures propagate to the caller
as consumer failures, without spending the feed's transport retry budget.

The transcript is a **tail, not a log**: nothing on it is durable and nothing is
backfilled, so a delta that never arrives costs a frame of latency and never a
fact. `turns.list` is the recovery path, and completion always re-states itself
there. Its item types grow — everything type-specific rides an untyped
`payload`, so an item this gem predates reaches you whole rather than raising.
A loop-backed turn's rounds ride the same feed: `round` and `call` settle each
task under `task_key` with `agent_loop_public_id` beside the turn's keys, then
`turn` settles the turn; a standalone loop opens the same stream on its own
channel with `agent_loop.transcript(realtime:)` (its paginated `transcript`
stays the window), where the turn keys are the absent ones. That window is
the THREAD: typed `ThreadRow`s — the spine's rounds, each with the `calls`
it read (`count` and the first `items`) and `branches`, the call keys a
visible branch hangs under; `context.transcript(prefix: "r4t0")` expands one
branch (a page, never followed).

**Joining the deltas is one object, not each client's own.** `append(item.text)`
above is the whole of it only while nothing goes wrong; the laws that follow
(a `stream_reset` throws the streamed half away, the settled body replaces what
the deltas built, and a bounded preview is a TAIL of a longer answer) ship as
`CybrosAgent::Api::TranscriptAccumulator`, which rho, a console and the webui
share:

```ruby
stream = CybrosAgent::Api::TranscriptAccumulator.new
subscription.each do |item|
  case item.type
  when "text_delta" then print stream.accumulate(item.text, key: item.task_key || item.variant_public_id)
  when "stream_reset" then stream.reset
  when "turn" then print stream.replace_on_settle(item.turn&.text) # only what was not printed
  end
end
```

For a follower snapshot that contains only a bounded tail, use
`stream.replace_snapshot(text, length: total_bytes)`. It returns only unseen
bytes when the shared window continues the previous text, or the replacement
window when it differs. `stream.replaced?` lets a display distinguish a missed
reset from continuation without another transcript buffer.

**The live thread is one object too.** A page seeds it, the spine's settled
`round`/`call` items upsert it (a branch round's key is loop-global and places
nowhere live, so it is dropped), and the progress frames mark what is running
now; completion wins over a live mark. Those laws ship as
`CybrosAgent::Api::ThreadAccumulator` — the one owner of them, as
`TranscriptAccumulator` is of the deltas' — and its `snapshot` is the wire's
own shape (`rows`, `live`), so rho's `transcript --follow`, a console and the
webui fold once and never re-fold:

```ruby
thread = CybrosAgent::Api::ThreadAccumulator.new
thread.seed(context.transcript)                 # the page: the spine, in reading order
subscription.each do |item|                     # transcript(realtime:) — the settled items
  case item.type
  when "round" then thread.settle_round(item)   # nil when the round is a branch's
  when "call" then thread.settle_call(item)     # under the round its number names
  end
end
frames.each do |frame|                          # progress(realtime:) — liveness
  case frame.type
  when "round_started" then thread.round_started(frame)
  when "step_started" then thread.step_started(frame)
  when "step_claimed" then thread.step_claimed(frame)
  end
end
thread.snapshot                                 # {"rows" => [...], "live" => ["r3", "r4t0"]}
```

It holds a bounded buffer and an UNBOUNDED count, which is what makes the settle
exact for a reply longer than the bound: a naive `settled.start_with?(buffer)`
is false for every one of those and reprints the whole answer.

**Forking branches the timeline** at a turn: the child adopts the prefix
through a closure and copies no content bytes.

```ruby
branch = chat.fork(turn_public_id: turn.public_id, idempotency_key: SecureRandom.uuid)
```

A turn read out of a forked conversation may be `inherited?` — the ancestor's
row, same `public_id`, read through the closure. Its content is the ancestor's;
its view state is yours, and setting it writes an override rather than touching
the shared row.

**Rewinding** goes one step further: `chat.rewind(turn_public_id:,
idempotency_key:)` forks at the turn, then restores the world to that point
through the child's bound runner — a request loop, polled — and the fork is
made either way.

The SDK passes both the checkpoint's tree hash and its store identifier,
including when a missing cached checkpoint is recovered from the runner.
This selects the original work root on runners serving several directories;
an unknown store refuses instead of restoring the default directory.

Both `rewind` and `restore_world` accept an optional `restore_guard` callable.
It receives the runner ID and resolved checkpoint, including on a cache miss,
and returns `nil` to proceed or a failure reason to refuse before requesting
the restore. A refused rewind still returns the child and its failed world
outcome. The SDK itself owns no local process or filesystem policy.

```ruby
rewound = chat.rewind(turn_public_id: turn.public_id, idempotency_key: SecureRandom.uuid)
rewound.restored?           # the files were put back
rewound.checkpoint          # the tree restored; rewound.undo replays it forward
```

The answer's `world` says what happened to the files: `restored` (with the
`undo` a later rewind could replay, and `outside` / `ignored` naming any paths
the capture could not reach), `untouched` (nothing wrote above the
turn), `kept` (`world: false` forks alone), `unavailable` (`runner_mismatch`
— another runner holds the tree — or `no_checkpoint`), or `failed` (the
restore failed or the application guard refused it). The kernel judges
nothing; the two facts a rewind
compares — the fork point's `world` (on `rewound.fork_point`) and the child's
bound `runner` — ride one fork answer. To undo turn N's OWN answer, rewind to
N‑1 and say again: N's own writes stand above the point.

**A side conversation** is a fork at the live head: `chat.fork(side: true,
idempotency_key:)` names no turn — the kernel takes the parent's newest settled
turn, even while a later turn runs — and the child (`side?`) renders the
inherited history behind a boundary item with the parent's prefix bytes shared,
so a question about the running work costs a cache read, not a re-read
(`context.cache_read_tokens` on the child's full read is the provider's own
count). Its posture is yours per turn: `tool_names: []` for an answer from
context alone, an inline `tail` entry for "you are in a side conversation". A
side is hidden from `conversations.list`; `conversations.list(side: true)`
lists them. It is never forked again (`side_of_side`), never archived, and
`delete` reaps it at once; one open side per parent and an idle TTL are the
caller's own bookkeeping.

Archive is the recycle bin and `delete` is the tombstone; `cancel` stops a
running reply and answers `Conflict` on an idle lane rather than pretending.

**Durable memory.** A `direct_reply` runs no tools, so `chat.memory` is how
anything reaches the memory block the kernel assembles ahead of a reply — and
how a client reads what the model will be shown. Four verbs: `list` (identity,
version, size and age, never text), `read`, `write` (a conditional whole-document
replace), and `delete` (a conditional permanent removal). Every
verb takes the document's **path in the body**, reads included, because the
path's first segment is the scope and no routing convention survives a slash:
`conversation/…` is this conversation's alone (a fork keeps its own copy),
`workspace/…` is shared by every conversation in the workspace, and `user/…`
belongs to the person the turn answers to and follows them across workspaces.
A bare name is refused (`memory_path_invalid`) rather than defaulted — the
scopes differ in who can read them.

```ruby
document = chat.memory.write("workspace/notes.md", "the plan",
  expected_public_id: nil, expected_lock_version: nil) # create only if absent
chat.memory.list.map(&:path)                 # => ["workspace/notes.md", ...]
document = chat.memory.read("workspace/notes.md")
document = chat.memory.write(document.path, "the revised plan",
  expected_public_id: document.public_id, expected_lock_version: document.lock_version)
chat.memory.delete(document.path,
  expected_public_id: document.public_id, expected_lock_version: document.lock_version)
```

Both condition keywords are required. Use two `nil` values only to create an
absent document; replacing or deleting requires the UUID and version observed
by the caller. A concurrent edit or delete-and-recreate returns
`Conflict` (`stale_object`). Read the new state and reconcile before submitting
another change: the SDK never fetches a fresh version or retries a stale write
for you. These writes do not use an `Idempotency-Key`; replaying a successful
write with its old condition also conflicts.

`workspace.memory` is the room's own door to the same store: the `workspace/`
scope without a conversation — the rows every conversation of the workspace
assembles from, written under write standing on the room (an archived room
reads, never writes) with the same four verbs and the same path-in-body rule.
It serves `workspace/…` alone; the other two scopes at this door are refused
`memory_scope_unavailable`. `client.profile.memory` is the person's own door to the same store: the
`user/` scope of the caller's controlling Human — an agent's steward, a human
themself — readable and writable from any workspace by that person and every
agent they steward, with the same four verbs and the same path-in-body rule.
It serves `user/…` alone; `workspace/` and `conversation/` at this door are
refused `memory_scope_unavailable`.

**Skills are rows under `skills/`.** A document at `user/skills/<name>` or
`workspace/skills/<name>` IS A SKILL: the same conditional `write`
takes the description a model reads in its turn's skills block to choose
(required there — `skill_description_required` — and refused on any other
path, `memory_description_invalid`), the name under the skill grammar
(`[a-z0-9]`, single hyphens, ≤ 64 — `skill_name_invalid` otherwise), never on
the conversation rung (`skill_scope_unavailable`); the content is the markdown
body the model reads when it loads the skill. `MemoryDocument#description` is
nil on a plain document, `#skill?` reads the prefix. A model's own
`memory_write`, `memory_edit` and `memory_delete` never author a `skills/` row
(`memory_reserved_prefix`) — a person or their program does, through these
doors — and the assembly's memory block never renders one.

```ruby
client.profile.memory.write("user/skills/review-checklist", body,
  expected_public_id: nil, expected_lock_version: nil,
  description: "How I review a change. Use before approving a pull request.")
```

`client.profile.store_entries` follows the
other rule: it is the ACTING principal's own store — an agent's entries are the
agent's, not its steward's — where memory's `user/` is the controlling Human's.

**Prompt documents — the slots a turn opens with.** An assembled reply's
sealed list is `[system_prompt][character][persona][memory][skills][history]
[inline lead][inline tail][input]`: the three slots first (adjacent same-role
blocks join, so three `system` slots are ONE system item — Anthropic lifts it
into its system field, a chat lane sends it as `messages[0]`), then the
memory block and the skills catalog, then history, then what changes per
turn — the turn's preface, which later turns replay in place, and the words.
`client.profile.prompt_documents`
is the ACTING user's own slot — an agent profile's `system_prompt` (its own
row, never its steward's; rho writes its guideline here at boot beside the
declaration) or a Human's `persona`, compiled into every turn that person
posts; the workspace's `character` is `workspace.prompt_documents` (see
Workspaces). Same four verbs, same URL-by-slot rule; `character` here is
`prompt_slot_unavailable`.

```ruby
client.profile.prompt_documents.write("persona", "The person is {{user}}, a Rubyist.")
```

An inline entry naming a slot **overrides** the registered document for one
turn and leaves the row untouched — `inline:` passes through as given, so no
SDK grammar stands between you and the kernel's: `{slot:, text:, role?}`
takes the slot's place (registered or not, it lands in slot order), and
`slot` with `position` is refused (400 `parameter_invalid`). Slot-less
entries stay the lead/tail injection (`{role:, text:, position: "lead" |
"tail"}`, `role` `developer` or `user`; `lead` then `tail` ride between
history and the prompt as the turn's preface, sealed with the turn and
replayed in place by its later turns).
Under `context_mode: "raw"` there are no slots and no memory — `entries:` is
the whole list, byte for byte, and `instructions:` is the wire's own system
field, sealed once per round and inherited by every continuation; it is
refused (422) on an assembled input. What you wrote reads back: the accepted
row and every `inputs.list` row carry `instructions` (nil on an assembled
row), and a loop's `task(key)` read carries the `instructions` a `model` step
was authored with, beside its `prompt`.

```ruby
chat.inputs.create(kind: "direct_reply", model: model, text: "go on",
  inline: [{ slot: "character", text: "For this turn only: you are terse." }],
  idempotency_key: SecureRandom.uuid)

chat.inputs.create(kind: "direct_reply", model: model, context_mode: "raw",
  entries: [{ role: "user", parts: [{ type: "text", text: "raw" }] }],
  instructions: "Be brief.", idempotency_key: SecureRandom.uuid)
```

**The sealed request — the debug door.** The bytes a turn was sent — exactly
the sealed entries and the request options, derived from the sealed body and
never re-assembled — for debugging what a model saw:
`chat.turns.request(turn, variant)` on a candidate (a loop-backed one answers
its first round's) and `workspace.agent_loop_task(agent_loop_public_id:,
task_key:).request` on any round (`tools` among its options); both answer a
`SealedRequest` with `entries` and `request_options` and nothing else, and a
row nobody sealed — a tool task, a reply that never minted — is 404
`request_not_sealed`. The loop's full read names the effective word in
`prompt_mechanism` (`raw`, `assembly` or `default` on a loop-backed turn —
the addressee's effective word; a standalone loop's shell word, nil when
its create named none). `rho request <id> <key>` and `rho request <conv> <turn>`
print the same read from a terminal.

### Scheduled jobs

`conversation.scheduled_jobs` authors durable delayed and recurring work.
Nexus starts each occurrence in a fresh child conversation using the ordinary
input and turn path, then reports its result to the owning conversation.

```ruby
jobs = workspace.conversation(conversation_id).scheduled_jobs
created = jobs.create(prompt: "Summarize progress", model: "provider/model",
  rule: { kind: "daily", local_time: "09:00", time_zone: "Asia/Shanghai" },
  idempotency_key: "morning-report-intent")
job = created.scheduled_job
jobs.update(job.public_id, expected_lock_version: job.lock_version,
  prompt: "Summarize progress and blockers")
jobs.pause(job.public_id)
jobs.resume(job.public_id)
jobs.cancel(job.public_id)
page = jobs.list(limit: 20) # page.items, page.next_after
job = jobs.fetch(job.public_id)
executions = jobs.executions(job.public_id, after: cursor, limit: 20)
```

Rules are `once` with `run_at`, `interval` with `every_seconds` and
`starts_at`, or `daily` with `local_time` and `time_zone`. Instants are ISO
8601 strings with a zone; daily rules retain their named IANA time zone.
Create also accepts `name`, `reasoning_effort`, `configuration`, `tool_names`,
`approval_mode`, `to` and `speaker_actor_public_id`. Model-created jobs may
record the immutable pair `source_agent_loop_public_id` and `source_task_key`
at creation; this attribution does not bind the job's lifetime to that loop.

Exact creation retries reuse the caller's idempotency key and expose
`created.replayed?`. Update requires the observed `expected_lock_version`;
omission preserves a field, while explicit `nil` reaches the server for
validation. The SDK never retries a stale mutation. Pause, resume and cancel
are idempotent state commands without a version argument.

`job.rule`, `job.model` and `job.last_execution` are typed values. Job status
describes the schedule; execution status describes the child work. A
`completed` one-time job can therefore still have a `running` execution.
Execution pages expose `items`, `next_after` for paging and `last_cursor`
for following later executions, including on an empty tail read. Each row
names its child conversation, input, turn and loop as they become available.

### Agent loops

The task-grained plane: a loop is a DAG of tasks whose nodes ARE the public
tasks. Authoring is STEPS in written order — `tool`, `model`, `ask`, `script`, and
`parallel` for a fan — and no client writes an edge or a barrier: the kernel
places both, which is what keeps the graph sound. The graph is readable whole
(`context.graph`: nodes, edges as task keys, a Mermaid flowchart) and its
phases derived (`context.phases`). The gem covers both halves — authoring
a graph, and executing the tool calls it hands out.

```ruby
loops = client.workspace(workspace_id).agent_loops

created = loops.create(
  steps: CybrosAgent::Steps.build { |s|
    s.model "fix the failing test", key: "work",
            model: { "model" => "openrouter/deepseek/deepseek-v4.1-flash" }, tools: tool_declarations
  },
  # THE SHELL a standalone loop is created with. `approval_mode` is
  # REQUIRED — `bypass`, `ask` or `rules` — nothing is silently defaulted
  # (an omission is an ArgumentError before any request); `approval_rules`
  # is the optional rule list, sent as written for the kernel to judge.
  # `prompt_mechanism` is the shell's word: `raw` (the seed step's own
  # prompt, instructions and tools ARE the request), or `default` /
  # `assembly` — the kernel compiles the seed ONCE at create (the creator
  # profile's slots, the workspace's and the creator's memory, the words;
  # under `assembly` the creator's own `prompt_template`, else the
  # built-in order) and the seed step's `instructions` is refused by name
  # (`invalid_steps` at `steps[0].instructions`, `instructions_raw_only`);
  # `assembly` on a creator with no template is 422
  # `prompt_template_missing`. The envelope's end is the loop's answer:
  # nothing names a deliverable.
  prompt_mechanism: "raw", approval_mode: "bypass",
  idempotency_key: SecureRandom.uuid
)
loop_id = created.agent_loop.public_id
loops.agent_loop(loop_id).start
```

Every `Steps::Tool`, `Model`, `Ask`, `Wait`, `Script`, and `Parallel` accepts optional
`lifetime: "turn" | "conversation"`. Omission leaves inheritance to Nexus;
a parallel group's explicit value becomes its members' default, while an
individual override does not affect siblings. `detached: true` lets the next
step proceed; `lifetime: "turn"` independently requires consumption and
synthesis of that work's result before the owning reply becomes final.
`conversation` permits later result mail. Standalone loops retain their
all-work completion rule. Task and graph reads expose the resolved `lifetime`.
A `delegation_task` represents a turn-owned spawned child's original report;
it is readable and cancelable, but cannot be authored, resolved, or retried
as execution. See [orchestration](../../docs/orchestration.md).

These steps also accept inherited `wake: "auto" | "passive"`. The default
`auto` starts a reply for results mailed after final delivery. `passive` records
them as readable history without starting a model. It does not suppress an
existing wait or turn-owned result obligation. Task and graph reads expose
the resolved `wake` alongside `lifetime`.

`loops.agent_loop(loop_id).task(key).tool_definitions` reads a model task's
frozen tool declaration, including kernel-alias resolution facts, even before
it is scheduled. `[]` means no tools; `nil` means the response carried no
declaration. Use this field to inspect a round's available calls. A sealed
provider request can carry a different tool list for replay or skill-catalog
reasons. Expired execution details raise `execution_details_pruned` as usual.

To observe existing work later, author a `Wait` step:

```ruby
steps = CybrosAgent::Steps.build do |s|
  s.wait task: "r2t0", agent_loop: source_loop_public_id, timeout_ms: 60_000
end
```

Omit `agent_loop` to observe this execution. Hosted executions can also observe
earlier loops in the same Conversation. `LoopTaskDetail#wait` reads the target
and authored timeout. Waiting does not restart work, consume its mail, or cancel
it when the observer times out. An Agent can expose the same mechanism to the
model by selecting `nexus.graph.wait` from the kernel catalogue.

Order places waits, never reads: a `Model` step reads its prompt and the
results its `results: [key, ...]` names, in that order, and nothing else.
A top-level `Model` step continues the loop's own conversation (the loop's
latest round, or the top-level `Model` before it in the same submission);
a `Model` inside a `Parallel`, or one marked `detached: true`, is a fresh
agent that starts from its prompt.
Leaves accept `after: [key, ...]` for additional waits; scripts also accept
`results:`. References name earlier leaves, or an earlier race by its
`key`, in this submission, or any earlier task of the loop by its key —
how one `append` hands a value to the next; self/forward references,
unknown keys, an `all` fan and other loops are refused. A race's key waits
on its barrier alone and, in `results`, reads what the race selected;
naming one of its members instead waits on that member and spares it when
the race settles. They add dependencies without replacing those implied by
written order. A model result follows its tool rounds to its final answer
and adds only result material, never the producer's conversation history.
A `detached: true` step's result that no step names reaches the loop later,
as the kernel delivers it, once the chain it ends has settled.

This graph starts patch capture and tests together. Review C waits only for
A; assessment D waits for A and B without waiting for C; the synthesis
names what it reads:

```ruby
steps = CybrosAgent::Steps.build do |s|
  s.parallel do |fan|
    fan.tool "bash", key: "a", input: { "command" => "git diff" }
    fan.tool "bash", key: "b", input: { "command" => "bin/rails test" }
    fan.model "Review the patch.", key: "c", model: selection, results: ["a"]
    fan.model "Assess the patch and tests.", key: "d", model: selection, results: ["a", "b"]
  end
  s.model "Combine the two reviews.", model: selection, results: ["c", "d"]
end
```

`selection` above is a model selection such as `{ "model" => "provider/ref" }`.
A script can calculate from completed results without a model round:

```ruby
steps = CybrosAgent::Steps.build do |s|
  s.tool "bash", key: "patch", input: { "command" => "git diff" }
  s.script "return {patch: results[0].output, error: results[0].error};",
           key: "summary", results: ["patch"]
end
```

The body receives `g`, `params`, and result envelopes (`status`, `is_error`,
`output`, `content`, `structured_content`, `error`). It either returns JSON,
including `null`, or places steps through `g` and returns nothing. Generated
work must end in one readable leaf; a bare fan or race needs a reducer. Only
that final output escapes the stage, and `results[i]` always matches the i-th
explicit input; for a race's key it is the race's answer — its first selected
envelope, or its failure — with every envelope it hands a reader under
`selected` (a failed race's partial winners, then its failure). `model_defaults:` supplies the request defaults when generated
models need them; calculations and tool-only stages need no model. The Ruby
SDK sends this body as data; Nexus executes it in the bounded pure isolate.
See [orchestration](../../docs/orchestration.md#compose-construction-and-result-driven-script-stages)
for dynamic fan/reduction and result-boundary examples.

Only a model step accepts `retries:` (serialized as `retry`). Tool calls, questions, and scripts have no automatic retry budget; their result or explicit resolution
settles the original task.

`create` and `append` are the only doors a graph grows through, and both are
idempotent by key. An `append` additionally takes `expected_revision` as an
optimistic fence — the `revision` of the author's last receipt; the trace
carries no graph counter — and its RECEIPT is the only place a
`resolution_token` is ever returned: replaying the same `Idempotency-Key` is
how a lost one is recovered.

```ruby
context = loops.agent_loop(loop_id)
agent_loop = context.fetch                 # the trace: tasks, progress, attention, turn, input_queue
agent_loop.tasks.select(&:started?)        # in flight: running, dispatched or awaiting_input
context.task("work").output                # what a task answered
context.transcript                         # the THREAD: spine rounds, the calls each read, the branches under them
context.transcript(prefix: "r4t0")         # one branch, expanded — a page, never followed
context.graph.mermaid                      # the whole run as a flowchart; .nodes/.edges behind it
context.inputs.create(text: "actually, start with the parser", delivery_mode: "steer",
  idempotency_key: SecureRandom.uuid)      # the one waiting room, hosted by the loop
context.feed(realtime: realtime).each { |event| … }   # deltas and lifecycle
context.phases                             # how far along: the authored phases, the one in flight, the spend
context.progress(realtime: realtime).call.each { |frame| … }  # what is happening RIGHT NOW: the kernel's own frames (round_started …) and an executor's
```

`context.graph` exposes the current expanded structure. Each node has ordered
`input_from` and `result_from` task-key arrays (empty when unused), plus an
`expansion_parent` task key when another task generated it. These describe
ordinary history/material sources, selected results without their histories,
and generation ownership. Edges carry `from`, `to` and `structural`: every edge
is a scheduling dependency, and a structural edge also records sequence or
branch placement. `graph.before(key)` and `graph.after(key)` follow only these
dependencies, as does `graph.mermaid`. Source lists and ownership remain separate
relationships. To inspect what a model actually read after race selection,
compaction or recovery, use `context.task(key).request`, the sealed-request read.

`phases` is the derived READ; `progress(realtime:)` —
on a loop and on a conversation alike — is the host's EPHEMERAL feed,
yielding `ProgressFrame`s: the kernel's own `round_started` (an attempt
dialled: `spine`, `attempt`, `model`, `request_bytes` in the payload),
`step_started` (a tool row dispatched, run or held, with its `tool_name`
and live `status`) and `step_claimed` (the executor that took it — the one
frame naming an executor), beside an executor's `executor_progress` (a
`bash` tail under a claim) and `process_output` (a process's lines under
the host's binding); nothing durable, nothing replayed. A round's or a
call's END is never a frame: it is the settled `round` / `call` on
`transcript`, whose `started_at` / `completed_at` are the timing.

A task's `status` names WHO is being waited on, not merely that it is busy:
`running` is the kernel, `dispatched` is a holder outside it that was handed a
bearer proof (a runner with a tool call), and `awaiting_input` is a person
nobody handed anything to. Ask `started?` for "in flight at all" and `live?`
for "not settled"; `CybrosAgent::Api::TASK_TERMINAL_STATUSES` is the one copy
of that vocabulary, and an unknown status reads as live rather than finished.

The executing half — listing, claiming, checking a claim, extending and committing — is the EXECUTOR plane's:
`executor_client.inbox.list` and
`executor_client.inbox_task(agent_loop_public_id:, task_key:).claim/claim_status/extend/commit`
(every row carries `workspace_public_id`, the loop's owning workspace, including
standalone loops and nested spawned conversations. A consumer uses this scope
without inferring it from a current workspace selection or local parent tree.
The row also carries `kind` and `addressed_to`, and — only when its tool is a
kernel name the loop's workspace overrides to a tools provider — the kernel's
`scope` stamp, `{workspace_public_id, conversation_public_id | nil,
user_public_id}`, an opaque frozen map beside the untouched `tool_input`
that a memory provider keys its store by; `extend` moves the claim's one
deadline, bounded by the tool's announced park or the kernel's hour; the
commit is write-once).

`task.claim_status(claim_token: granted.claim_token).active?` reads whether
that exact execution is still dispatched, including while its loop is
paused, needs attention or gracefully canceling. The token is sent only in
the `Claim-Token` header. A settled claim returns false; a replaced token
raises `Api::Conflict` with `not_claimant`, and a missing task raises
`Api::NotFound`. A read never extends the deadline or settles the task.
Polling, cancellation and retry policy belong to the caller; a credential,
transport or server error is not an inactive answer. Requests retain the
ordinary finite HTTP timeout, which may outlast the task's remaining time.

`executor_client.report_progress(frame)` posts one
ephemeral frame keyed by its claim (`{agent_loop_public_id, task_key,
claim_token, text_tail}`) or by a host + process (`{conversation_public_id |
agent_loop_public_id, process_id, lines}`) — the kernel's `min_interval_ms`
is the floor of the cadence; a faster post is dropped, never refused. THE
CAPTURES an executor publishes:
`executor_client.uploads.create(path)` (or `create_io(io, filename:)`)
stages a file as this executor's own on the executor plane, and a
`resource_link` block in `commit(content: [...])` names it —
`CybrosAgent::Api::ResourceLink.to_upload(upload.public_id, name:,
mime_type:, size:, title:, description:).to_h` is the wire block, beside
the text blocks; an id that is not this executor's own capture refuses
`422 unknown_result_upload` with the park standing. Nothing on the
executor plane reads a capture back: a reader of the result fetches it on
the member plane (`uploads.bytes`, or a picture of it with
`uploads.thumbnail` / `uploads.preview`). Resolving
an await is the person's `context.task(key).resolution`.
The deciding half is `context.task(key).retry/abandon/compact`, and
`context.task(key).cancel` ends a BRANCH the model started (the `task` call's
key, or any node of it) — the spine is `context.stop`'s; a task that outlived
its turn and was mailed to the conversation reads back with `mailed_at`.
For a failed model task, `loop.tasks_context(key).retry(model: "provider/model",
reasoning_effort: "low")` changes the model for that node's next execution.
Omit the model to keep its current selection, or omit the effort to use the
named model's default. Completed tools remain settled; this does not
regenerate the whole turn or replenish automatic result-mail fallback.
A step a provider's classifier REFUSED (`task.refused?`, error
`model_refused`) re-runs ONCE on the answering profile's declared
`fallback_model` before it fails: the task reads `waiting`, then runs on the
fallback, and `task.model_change` says what it replaced (`{"from",
"reason" => "model_refused", "category"}`) while `task.model` names where it
went; a refusal of the fallback, or a step with no fallback declared, fails
as above and a person's retry may name another model — a step re-runs on a
fallback once, and neither the retry nor a new declaration re-arms it.
A switched spine round's continuations inherit the fallback for the rest of
that turn, and the loop's `turn.model` says so. STAY ON IT: that field is
the model to send the next input on — a caller that sends its next turn on
its own `default_model` again pays one refused call per turn while the
content keeps triggering the classifier, since the kernel keeps no routing
state across turns.
The approving half is `context.task(key).approve` and
`context.task(key).deny(reason: …)` on a tool call resting at
`needs_approval` — parked by the loop's `ask` mode or a rule, announced as
`approval_required` while the loop stays `running`, listed on the agent
application's inbox as kind `approval` with the effect profile the approver
reads (`InboxTask#effect_profile`, nil on every runner row). Any principal
with write standing decides, the agent application included, and the
answered task carries the fact as `approval` (`{origin, decided_by,
decided_at}`); a denial's reason is the row's `error.detail`.

An Agent Profile declares its policy whole with
`client.profile.declare_configuration(tool_definitions:, approval_mode:,
approval_rules:, prompt_mechanism:, compaction_policy:, prompt_template:,
default_model:, lifecycle_hooks:, fallback_model:)` — every column named, `approval_rules: nil` for none,
`default_model:` the profile's OWN model as a catalog ref `provider/model`
(the kernel answers every turn addressed to the profile on it before the initiator's; nil declares none; a ref the account may not run is `validation_failed` naming the field),
`fallback_model:` the model a step the profile answers — or a one-shot it
creates — re-runs on ONCE when
a provider's classifier declined it — never for an unavailable model, an
overload, an error or a content block (`finish_quality: "blocked"`), judged
the same way, nil for none; for an Anthropic refusal the provider recommends
another Claude model, and a model of another vendor carries the refused
request's whole context there — and a reply's
`inputs.create(…, approval_mode: "ask")` tightens the profile's word for one
turn (never loosens it). `prompt_template` is the assembly template
: the block list the profile compiles under `prompt_mechanism:
"assembly"` — the three assembly slots, `memory`, `lead`/`tail`, `history` and the
`input` in the profile's own order, `inline` blocks of its own text, root
`variables` with defaults — REQUIRED under `assembly` (422
`validation_failed` naming the JSON-pointer path of a fault), stored unread
under any other word; it may be omitted (nil) when the word is `default` or
`raw`. The grammar is the kernel's ([Conversations](../../docs/agent-api/v1/conversations.md#the-assembly-template--your-own-order));
the SDK carries it opaque and reads it back as a frozen snapshot.

`lifecycle_hooks` is optional and defaults to nil. It maps `turn_start`,
`pre_compact`, `post_compact`, and `stop` to external tools with finite timeouts.
Only Stop can request bounded continuation with feedback. The SDK transports
this configuration unchanged; Nexus owns its validation and execution.
See [lifecycle hooks](../../docs/lifecycle-hooks.md) for the result protocol.

`tool_definitions` holds three kinds of entry: a runner's tool (any bytes),
a kernel tool in the catalog's exact bytes (`client.tools.definitions_for`),
and an ALIAS of a kernel tool — the agent's own spelling of it, built with
`client.tools.alias(name: "Agent", canonical: "nexus.graph.task", params: {
run_in_background: { maps_to: "wait", invert: true, description: "…" } })`
(`omit:` drops kernel parameters the alias never exposes; `description:`
replaces the kernel's text, with `{{task}}`-style macros for the names as
this profile spells them). The kernel stores the profile's RENDER — the
alias as a full function block with its facts (`canonical`, `params`,
`omit`, `description`) beside it, and every kernel text re-spelled with the
declared names — and `profile.read` returns that render. A call the model
makes under the alias runs under the kernel's wire name; the transcript's
call row shows `name` (the alias) and `tool` (the kernel's).

An Agent Profile MINTS ITS OWN NAMED SUB-AGENTS through
`client.profile.agents`: `declare(name:, scope:,
description:, configuration:, display_name: nil, system_prompt: nil)` is a
whole replacement by name — a member row of kind `agent` under the
profile's steward, identifier `<its identifier>/<name>` composed by the
kernel, handle `name` when free (else `name-2`, …), NO credential and NO
address — that a spawner names as `spawn(agent: "@reviewer")` like any
peer; `configuration:` carries the same fields as
`declare_configuration` takes them (the same writer and refusals; `default_model:` judged at declaration and preferred when that Agent answers);
`system_prompt:` is the row's slot, nil deletes it. `scope: "instance"`
is the profile's own row (re-declared at every boot, removed with the
profile, fenced as it is); `scope: "steward"` PUBLISHES it — the same row
flips, persists on its own for every agent of the steward and is never
dedication-fenced. `list` answers `NamedAgent` rows — the profile's own of
both scopes plus the steward's other published ones (`published?`,
`derived_from_public_id` the declarer) — and `remove(name:)` is the
kernel's reversible removal (a later `declare` restores the SAME row).
A Human bearer is `Forbidden not_agent_profile`; a paired program holding
the composed identifier is `Conflict identifier_taken`.

```ruby
agents = client.profile.agents
agents.declare(name: "reviewer", scope: "instance",
  description: "Reviews a diff for defects; use it after a change lands.",
  system_prompt: "You are a code reviewer. …",
  configuration: { tool_definitions: [read, grep], approval_mode: "bypass", approval_rules: nil,
                   prompt_mechanism: "default", prompt_template: nil,
                   compaction_policy: { "mode" => "kernel" }, default_model: nil })
agents.list.map(&:handle)                                    # => ["reviewer", …]
agents.declare(name: "reviewer", scope: "steward", …)        # publish: the same row, now the steward's
agents.remove(name: "reviewer")
```

### Available models and provider lanes

`client.models.list(workload: "text_generation")` returns the account's
configured, available models for every Agent. The server applies availability;
the member method has no `available` selector and does not list unavailable
models. Rows include capabilities and pricing so an agent can choose a model.

`client.model_providers.list` answers one `Lane` per provider the kernel serves
(`enabled?`, `configured?`, `ready?` = both and no reauthorization pending);
the member client reads lanes but does not manage them. `unavailable_until` is the provider's own retry-after clock (an
ISO string, `nil` when clear); `ready?` ignores it — a floored lane is waiting,
not off.

### Human model administration

Operator applications use a Human API Session or a platform-plane access token
with `PlatformClient`. Device connection never grants Platform authority.
The server checks the current Human administrator role on every model-management
request. The member client and executor client remain separate.

```ruby
grant = CybrosAgent::Sessions.new(base_url: "https://nexus.example")
  .create(email: email, password: password)
# Persist grant.token and grant.session.public_id through the application's
# credential store. Do not log the grant or print its token.
platform = CybrosAgent::PlatformClient.new(
  base_url: "https://nexus.example", credential: grant.token
)
platform.profile.fetch.member.role
platform.session.fetch.expires_at
platform.cost_unit.fetch.cost_unit # nil until configured
platform.cost_unit.configure("USD")
platform.retention.fetch.execution_details_retention_days # 90 by default
platform.retention.update(execution_details_retention_days: 180)
platform.retention.update(execution_details_retention_days: nil) # disable cleanup

provider = platform.model_providers.provider("openrouter")
lane = provider.fetch
provider.install_api_key(api_key)
provider.enable(expected_lock_version: lane.lock_version)
models = platform.models.list(workload: "text_generation", available: true)
provider.set_model_visibility(model: "openrouter/vendor/model", visible: false,
  expected_lock_version: provider.fetch.lock_version)
provider.set_model_visibility(model: "openrouter/vendor/model", visible: true,
  expected_lock_version: provider.fetch.lock_version)

# Explicit account changes and logout:
provider.disable(expected_lock_version: provider.fetch.lock_version)
provider.remove_api_key
platform.session.revoke
```

`platform.model_providers.list` and `platform.models.list` return the same typed
projections as the member's read surface, through the administrator routes.
`platform.models.list` includes unavailable models and their reasons by default;
`available: true` narrows this administrative catalog to available rows.
`visible?` states the model's visibility separately from `available?`. Hiding a
model retains its definition and pricing, removes it from member discovery and
refuses new calls. The administrative row remains with `visible: false`;
when its provider is enabled, its refusal reason is `model_hidden`. A disabled
provider reports `provider_disabled` first. Restoring visibility does not enable a
provider or install a key; those independent requirements still apply. Visibility
writes use the provider policy's current version and return its updated `Lane`;
an untouched provider with no policy raises `Api::NotFound`.
The key is write-only. A stale lane version raises `Api::Conflict` without a
retry; an untouched lane has a `nil` version. Configuring the same account cost
unit again succeeds; changing an existing unit raises `Api::Conflict` with code
`cost_unit_conflict`. Prices are optional: an available model may have
`unmetered` or `cost_unknown` pricing and still run. Usage quantities continue
to be recorded independently of monetary estimates.

The same Human context authors supported provider connections and model
definitions. Each write returns `ModelProviderConfiguration`, including the
updated `provider` lane, complete `definition`, `source` and `models`:

```ruby
local = platform.model_providers.provider("local")
saved = local.set_definition(definition: {
  "base_url" => "http://127.0.0.1:11434/v1",
  "api_format" => "openai_compatible_chat", "credentials" => "none",
}, expected_lock_version: nil)
local.discover_models.map(&:id) # explicit directory request; manual IDs also work
saved = local.set_model_definition(model: "local/my-model", definition: {
  "capabilities" => { "limits" => { "input_tokens" => 32768, "output_tokens" => 8192 } },
}, expected_lock_version: saved.provider.lock_version)
local.enable(expected_lock_version: saved.provider.lock_version)
current = local.configuration
# current.source: catalog, override or custom; a removed custom lane reads removed
```

`remove_model_definition(model:, expected_lock_version:)` writes a removal
entry; `reset_model_definition` restores file inheritance. `reset_definition`
restores a deployment provider or removes a custom connection and disables its
retained policy. A removed custom provider remains readable by ID so its current
version can be used to recreate it. Credentials remain in their separate owner.
Changes apply to subsequent reads and requests without restarting Nexus. Model
directory discovery supplies IDs, not proof of inference, capabilities or prices.
The full contract is [Admin models](../../docs/platform-api/v1/admin-models.md).

API Sessions expire at their fixed server-reported time; the SDK neither stores
nor refreshes them. Session revocation returns `nil`; a repeat with the revoked
bearer is unauthorized. A platform-plane access token can use administration
but has no Session, so `platform.session.fetch` and `revoke` raise `Api::NotFound`.
Subscription authorization uses the same Human-only client:

```ruby
authorization = platform.model_providers.provider("codex_subscription").authorization
current = authorization.fetch # state, expires_at, and nullable latest session
session = authorization.start # resume this Human's pending device ceremony
session.user_code # explicit display only; inspect/to_s/pp redact it
session.verification_uri
status = authorization.session(session.public_id).fetch # read this exact ceremony
# An explicit user decision may replace an existing ceremony:
# authorization.start(restart: true)
# authorization.clear # revoke pending work and clear local OAuth credentials
```

Enable the lane before starting. The server advances authorization in its workers;
reads perform no provider IO. `start` is sent once and never automatically retried.
After an uncertain response, use `fetch` to recover the current session. Wait for
that exact session's `completed` state and `authorized` outcome: an older installed
credential may keep the top-level state `authorized` while a new ceremony runs.
The credential and all refresh operations remain Nexus-owned.

`PlatformClient` exposes no workspaces, conversations or OneShots. To exercise a
model, use an independently authenticated member client or an agent application.

### Model adaptations

`CybrosAgent::ModelAdaptations` is a documented YAML data format the gem
ships under `lib/cybros_agent/model_adaptations/` — the reference for other
languages, and the ONE home of this text. It carries what an agent
application applies on top of the kernel's facts, in rows matched to a
model by PATTERN: the kernel tools' spellings for the models a row covers,
a summarizer prompt, lead hints, compose advice — every text the row's
data, measured before it lands, never hand-tuned.
Three layers: the kernel keeps behaviour FACTS (`GET /models`
`capabilities`) and neutral MECHANISMS (the alias entry, the macros, the
`summarizer` slot); the pack keeps the TABLES and TEXTS; the
application keeps the POLICY (which row, when). An agent reads facts from
the kernel, never from the pack.

```ruby
pack = CybrosAgent::ModelAdaptations.load                 # the gem's rows
pack = CybrosAgent::ModelAdaptations.load(extra: [dir])   # plus LOCAL rows
row = pack.for("openrouter/z-ai/glm-5.3")                 # → the glm-5.3 row; a reference no row covers → `default`
templates = client.tools.list.to_h { |entry| [entry.canonical_name, entry.template] }
entries = pack.apply(client.tools.list.map(&:definition), row, templates: templates)
```

**`presets.yml` — the alias tables.** `format: 1`; `words` (the declaration
order — `[nexus, claude, codex, workflow]`; a row's `tool_style` is a
subset); `plain` (canonical → the kernel's plain wire name, one entry per
canonical a preset may re-spell); `presets` keyed by exactly the words,
each `{supersedes: [canonicals], aliases: [entries]}`. `nexus` supersedes
nothing and declares nothing: the plain names. An alias entry is the
kernel's alias grammar with one addition — `{name, canonical, params?,
omit?, description? | recut?}` — where `recut: {anchor, replacement}` is
ONE anchored edit of the template `GET /tools` serves (`Entry#template`,
the macro-bearing source), rendered at declare as
`template.sub(anchor, replacement)`. No kernel text is copied into the
pack; a `recut` whose anchor the served template no longer carries raises
`ModelAdaptations::AnchorMoved` naming the entry — loud, never a silent
fallback to the plain text. A `description` and a `recut` on one entry is
refused: a text has one source.

**`rows/<id>.yml` — one file per row**, `id` equal to the file name:

| key | value |
|---|---|
| `format` | `1` |
| `row` | the id (`default`, `glm-5.3`, `kimi-k3`, `claude`, `codex`) |
| `models` | the row's model PATTERNS (*Model patterns*, below), each tested on the REFERENCE: the kernel's `ref` minus its lane segment (`openrouter/z-ai/glm-5.3` → `z-ai/glm-5.3`; `gpt-6.1-sol` under `openai_api` and `codex_subscription` alike). An entry is EXACT (`z-ai/glm-5.3`) or a PREFIX ending in one `*` after a separator (`claude-*`, `z-ai/glm-5.3:*`). A variant is covered only when a row writes it: `openrouter/anthropic/claude-sonnet-5:exacto` resolves to `default` until an entry spells `anthropic/claude-sonnet-5:exacto` or a stem whose `*` spans the variant. `[]` on `default` and on a row an application reaches only by naming it (rho's `adaptations: <id>`: the e2e harness's `bench-*`, `mock` and `sweep` rows). An entry appears once per row, and once across the rows of one source; a repeat is a load error |
| `tool_style` | words of `presets.yml`, the row's universe: a plain name is withheld only when `nexus` is absent AND an active preset supersedes it; then each active preset's aliases in `words` order |
| `tool_descriptions` | RENAMED alias entries with their own text (the same grammar as a preset alias; the "alias with its own description" the kernel renders) — never a same-name variant, which the kernel refuses `alias_name_reserved`. `[]` on every gem row today |
| `summarizer_prompt` | the text an application writes into the profile's `summarizer` slot; `null` → the kernel's default |
| `lead_hints` | `[{id, text}]` — per-request lines appended to the developer-role lead, behind history and outside the stable prefix. Spelled in the row's OWN style: a backticked plain word the row's styles supersede is refused (the model never sees that word); no hint names an application's own surface |
| `compose` | `on \| off` — the recommendation an application's compose switch reads |

**Model patterns** (`CybrosAgent::ModelPattern`, a standalone helper any
consumer may call). An entry is EXACT — it matches a reference byte for
byte, case-sensitively — or a PREFIX: one trailing `*` whose STEM, every
byte before it, must begin the reference. Every other character is
literal, `.` included. The rules, checked in this order, the first failure
reported (`ModelPattern.refusal`):

1. Printable ASCII (`!` to `~`): no whitespace, control character or
   non-ASCII, and none of the reserved `? [ ] { } ( ) | ^ $ + \`. Every
   other printable character (`- _ . : / @ ~ = , %` and the rest) is
   literal, so every reference a kernel ref may carry stays nameable.
2. At most one `*`, and only as the last character.
3. A `*` with a character before it follows one of `- _ : / @`, never a
   letter, a digit or a `.` (a lone `*` falls to rule 5):
   `z-ai/glm-5.3*` would reach `z-ai/glm-5.3-flash`, and a regular
   expression's `.*` would load as a stem ending in a literal `.`; both are
   refused, the second with its own sentence.
4. No empty segment: no leading, trailing or doubled `/`.
5. At least one letter or digit.

YAML reads a plain scalar that starts with `@` as an error, so quote such
an entry (`- "@acme/*"`). SPECIFICITY ranks the entries matching one
reference: an exact match scores its length + 1, a prefix its stem's
length, so exact outranks every prefix and a longer stem a shorter one.
Every stem matching a reference is a prefix of it, so two different
entries never tie — the reason there is no `?`, inner `*`, character
class, alternation or regular expression: each lets two entries match one
reference with neither containing the other. Granularity is the stem's
length at a separator; for the z-ai line `z-ai/*` (the vendor) →
`z-ai/glm-*` → `z-ai/glm-5.3-*` → `z-ai/glm-5.3:*` (one model's broker
variants) → `z-ai/glm-5.3` (one reference), where every rung above
`z-ai/glm-5.3:*` also reaches the floor model `z-ai/glm-5.3-flash`. A
direct lane's reference is the bare id and a broker's carries the vendor,
so kimi on both is `[kimi-*, moonshotai/kimi-*]`. Entries never see the
lane: an entry written as a full kernel ref or a lane glob
(`openrouter/*`) is matched as a reference like any other and covers what
its text covers — usually nothing (rho's `rho adaptations --model` names
the entry that matched). A lane-specific choice is the application's
policy (rho's `adaptations: <row>`), not a row's.

A port reproduces the same accept-or-refuse decision under the same rule,
and the same resolution; the English of a refusal is not part of the
format. It needs no regular-expression or glob engine and must hand an
entry to none (`fnmatch` and minimatch give `?`, `[` and `\` meanings, Go's
`path.Match` stops `*` at `/`, a regular expression reads `.` as any
character):

```text
reference(ref)   = the text after ref's FIRST "/"; nil → no model; non-nil without "/" → error
refusal(entry)   = the five rules above, in order
specificity(e,r) = if e ends with "*": (r starts with e minus its last char) ? len(e)-1 : none
                   else: (e == r) ? len(e)+1 : none
rank(row, r)     = the maximum over the row's entries; none when every entry is none
for(ref)         = nil → default; else the best OWN row, else the best STANDING row
                   (on equal rank the local row), else default
```

| entry | reference | specificity |
|---|---|---|
| `z-ai/glm-5.3` | `z-ai/glm-5.3` | 13 |
| `z-ai/glm-5.3` | `z-ai/glm-5.3-flash` | none |
| `z-ai/glm-5.3:*` | `z-ai/glm-5.3:exacto` | 13 |
| `z-ai/glm-5.3:*` | `z-ai/glm-5.3-flash` | none |
| `claude-*` | `claude-opus-5-5` | 7 |
| `claude-*` | `anthropic/claude-opus-5-5` | none |
| `z-ai/glm-5.3-*` | `z-ai/glm-5x3-flash` | none |

Refused, by rule: `z-ai/glm 5.3`, `glm-5\.3`, `glm-[0-9]`, `gpt-5.?-sol`
(1); `z-ai/*/glm`, `**` (2); `z-ai/glm-5.3*`, `claude-.*`, `gpt-5.*` (3);
`z-ai/`, `/z-ai`, `z-ai//glm` (4); `*`, `-*` (5).

The loader (`ModelAdaptations.load(dir, extra:)`) refuses a malformed file
with `ModelAdaptations::Invalid` naming the file and the YAML path: an
unknown key at any level, a `format` other than 1, an id unequal to the
file name, an entry outside the pattern grammar (at `models[i]`, with
`ModelPattern.refusal`'s sentence), an entry repeated on one row or across
the rows of one source, a `tool_style` word the tables lack, a `compose`
other than `on`/`off`, a hint in a spelling the row's own styles
supersede. Every text field is honoured as written, on a gem row and a
local row alike. Evaluation history belongs in commit history, not a
runtime field. It validates NO alias name and knows NO catalog — the kernel is the one validator of every alias entry at
declaration, and whether an entry matches a catalog model is the e2e
harness's pin. `source` (`gem` | `local`) is derived from where a file was
loaded, never written. LOCAL rows (`extra:` — files, or directories of
them) are the operator's: one of a gem row's id replaces that row in its
place, and one that replaces no gem row is the operator's OWN per-model
override (`Pack#rows` lists local rows first, an order resolution never
reads).

**Resolution and application.** `Pack#for(ref)` strips the lane segment
(`ModelPattern.reference`: a ref without one is an `ArgumentError`, `nil`
is `default`) and resolves in two tiers. The OWN rows answer first, the
most specific entry winning; then the STANDING rows — the gem's, a local
replacement in its row's place — the most specific entry winning and, on
the same entry, the local row; else `default` (`models: []`,
`tool_style: [nexus]`, `compose: on`). The loader refuses one entry on two
rows of a source, so each tier's winner is unique and file order never
decides. Writing a gem row back as a local row of its own id moves no
reference, while an operator's own `z-ai/*` takes every `z-ai/` reference,
`z-ai/glm-5.3` included, from the gem's rows.
`Pack#apply(definitions, row, templates:)` — `Styles.apply` — is the pure
set function: the kernel's fetched definitions minus the withheld plain
names, then the row's alias entries (each built with `client.tools.alias`,
its `recut` rendered against `templates[canonical]`) for the canonicals
the catalog carries. `Pack#alias_entries(row, templates:)` is the alias
half alone. How an application applies a row: `tool_style` +
`tool_descriptions` → the declaration's entries; `summarizer_prompt` → the
`summarizer` slot write (or delete); `lead_hints` → the per-request lead;
`compose` → a rung of its compose switch.

**Where a text comes from, and where candidates live.** A strong model's
row may carry a per-model text when a smoke on the strong models shows it
helps. A floor resolves to `default`, whose texts stay empty. Candidates
are NOT in the gem: they live in the e2e harness
(`e2e/evals/candidates/<row>.yml`, `{id, kind, value | text | recut |
entry, seed}`), and the loader has no `candidates` grammar; how the
September 2026 candidates were read is the evals runbook's record
(`docs/evals-runbook.md`, §7a).

## Development

After checking out the repo, run `bin/setup` to install dependencies, then
`bundle exec rake` to run the tests and RuboCop. `bin/console` opens an
interactive prompt.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
