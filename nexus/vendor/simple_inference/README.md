# SimpleInference

A multi-provider LLM protocol client vendored into the Nexus Rails kernel
(`nexus/vendor/simple_inference`) and consumed through execution profiles
assembled by the caller. It speaks each provider's native wire protocol —
OpenAI Responses, Codex Responses, DeepSeek native Responses, xAI Responses,
OpenRouter Chat Completions lane, Anthropic Messages, Amazon Bedrock Converse, Gemini
`generateContent` / `embedContent`, plus OpenAI images, audio, and
embeddings — and normalizes the results into one shape the kernel can meter,
persist, and replay.

This gem serves this repository only. It is not published — the gemspec pins
an invalid push host so `gem push` fails closed — and breaking changes land
together with their kernel-side consumers. Requires Ruby >= 4.0. The
`aws-eventstream` runtime dependency decodes Bedrock's binary stream framing.

## Execution profiles: the only routing surface

Protocol selection is data, not heuristics — there is no adapter-key or
model-name substring dispatch anywhere:

- **`SimpleInference::ExecutionProfile`** — one frozen profile
  value: `(provider_id, adapter_profile, protocol_route, workload, model_pin,
  credential_lane)` plus the validated facts the compile path may rely on:
  capabilities, input modalities, per-modality MIME allowlists, wire
  options, and `total_execution_deadline_seconds` (positive, finite, within
  the 3600 s release bound). Every vocabulary is closed and absence means
  disabled; invalid values reject at construction — before any credential
  read or IO can exist downstream.
- **`SimpleInference::ApiFormat`** — the one protocol-selection surface. Its
  `PROTOCOL_CLASSES` map resolves the profile's `adapter_profile` to a
  concrete protocol class; `protocol_for(profile:, config:)` constructs that
  class and forwards its declared protocol options from the profile's
  `wire_options` (endpoint paths and lane-specific protocol flags). The
  model's `prompt_format` option instead belongs to request preparation.

`Client.new` requires an `execution_profile:` (an `ExecutionProfile` value)
alongside the connection settings; the resources validate every request
against it — workload, exact model pin, streaming, function/builtin tools,
conversation state, input modalities (`Planning::RequestValidator`) —
failing closed before any protocol object or wire body exists.

```ruby
require "simple_inference"

format = "openai_responses"
profile = SimpleInference::ExecutionProfile.new(
  profile_id: "openai_api/gpt-6-sol@#{format}",
  provider_id: "openai_api",
  adapter_profile: format,
  workload: SimpleInference::ApiFormat.workload(format),
  model_pin: "gpt-6-sol",
  credential_lane: "api_key",
  total_execution_deadline_seconds: 120,
  **SimpleInference::ApiFormat.defaults(format)
)

client = SimpleInference::Client.new(
  base_url: "https://api.openai.com",
  api_key: api_key,
  execution_profile: profile
)

client.responses.create(model: "gpt-6-sol", input: "hi") # model must equal the pin
# resources: responses / images / audio / embeddings
```

`Client.new` recognizes exactly: `base_url`, `api_key`, `api_prefix`,
`base_url_included_api_prefix`, `timeout`, `open_timeout`, `read_timeout`,
`adapter`, `raise_on_error`, `headers`, `execution_profile`. Unknown keys
raise `ConfigurationError` — a typo'd option never no-ops. There are no ENV
fallbacks and no default base URL; configuration is fully explicit.

Protocols remain independently constructible for focused tests — no
client, no profile:

```ruby
protocol = SimpleInference::Protocols::AnthropicMessages.new(
  base_url: "https://api.anthropic.com", api_key: api_key
)

result = protocol.create(model: "claude-opus-5-5", input: "Why is the sky blue?",
                         reasoning_effort: "low", max_output_tokens: 1024)

result.output_text    # accumulated assistant text
result.output_items   # string-keyed items: reasoning / message / function_call
result.tool_calls     # convenience view over function_call items
result.usage          # string-keyed token counts plus retained provider evidence
result.finish_reason  # provider verbatim
```

For text results, `output_tokens` is the reasoning-inclusive output total and
`reasoning_tokens` is a subset of that total; consumers must not add the two.
Provider-native aliases such as `completion_tokens` retain the same inclusive
wire semantics, while provider-specific accounting evidence may remain beside
the common fields.

## Compile and execute

Client resources validate the request against their execution profile and
compile its protocol payload before provider IO. The resulting
`SimpleInference::CompiledRequest` is short-lived process state: it carries
the serialized payload and result assembler, then receives the client's
current connection configuration when executed. Offline replay uses the same
resource path with a replay adapter.

An explicitly configured model may declare
`wire_options: { prompt_format: "qwen3_5" }`. This describes only its
instruction-role layout, not a complete chat template, thinking mode or
serving framework. It combines separate `instructions` and consecutive
leading `system`/`developer` messages into one initial `system` message,
with two newlines between their contents. Later `system`/`developer`
messages become `user` messages in their original positions. Instruction
content in the merged initial system message must be text-only; media there
raises `ValidationError`. Later instruction messages keep their content,
including media, when their role becomes `user`. User media, assistant
messages, tool calls/results and reasoning items keep their order and content.

This projection runs in `Planning::RequestValidator`, shared by streaming
and unary resource compilation, before protocol lowering. It does not
modify the caller's input or nested values. Recompile the same original
input with another model's profile to use that model's layout; never use a
previously compiled payload as the source. Omitted or `nil` `prompt_format`
leaves input and separate instructions unchanged. Unknown formats refuse at
profile construction. No provider name, model name or endpoint selects a
format implicitly, and independently constructed protocol objects have no
model profile to apply.

## Independent reasoning controls

Text requests accept `reasoning_enabled: true | false | nil` independently
of `reasoning_effort`. Omission or `nil` leaves the existing native controls
and provider defaults unchanged. An explicit `false` suppresses effort,
summary, and replay-context controls before lowering. `true` retains the
chosen effort; the gem never invents an effort level or decides whether a
model supports disabling reasoning. Model support and defaults belong to
the consumer's catalog and selection boundary.

The wire spelling follows the protocol:

- OpenRouter sends `reasoning.enabled`, including for models with no effort
  vocabulary.
- Anthropic sends `thinking.type: disabled` when off and adaptive thinking
  when on, preserving structured output while omitting its reasoning effort
  when off.
- Responses protocols use their native `reasoning.effort: none` disable
  value. Protocol-required fields, such as Codex Lite's reasoning context,
  remain required.
- Generic Chat uses `reasoning_effort: none` by default. A host that instead
  accepts a template switch declares
  `wire_options: { reasoning_control: "chat_template_kwargs" }`; the boolean
  then becomes `chat_template_kwargs.enable_thinking`. An effort may still
  be sent independently while enabled. The other allowed value is
  `"reasoning_effort"`. This option belongs only to `openai_compatible_chat`
  and is never inferred from the provider, model, or `prompt_format`.
- Gemini 3.x retains its existing thinking levels when enabled. Its wire
  cannot disable thinking, so a direct `false` raises `ValidationError`;
  consumers that silently ignore unsupported disable requests resolve them
  before calling the gem.

Native low-level options, including supported `reasoning_effort: "none"`
spellings, remain available when the normalized boolean is omitted. Pairing
an explicit `true` with a native `none` effort raises `ValidationError` as a
contradictory request.

## Request options: declared vocabulary + `extra_body`

`bedrock_converse` uses native Converse JSON and ConverseStream binary events
through the same HTTPX/AsyncHTTP adapters. Configure the regional runtime URL
as `base_url` and an API key as a bearer credential. AWS profile discovery and
SigV4 signing are not part of this adapter. The model identifier, including
an inference-profile ARN, is encoded in the request path.

Bedrock reasoning uses explicit `wire_options.bedrock_thinking_control`:
`adaptive`, `budget`, `reasoning_effort`, `nested_effort`, or `none`. Model
names select no behavior. Optional `thinking_budgets`, `reasoning_effort_map`,
`thinking_binding`, and `bedrock_omit_thinking_display` capture model and
regional differences. Native reasoning content, including signature-only
and encrypted blocks, remains available in `provider_payload` for exact
replay. Usage retains the wire's uncached input count beside its cache read
and write counts; accounting consumers must include all three in total input.

Every protocol declares the symbol options it understands:

```ruby
SimpleInference::Protocols::GeminiGenerateContent.request_option_keys
# => [:tools, :tool_choice, :instructions, :max_output_tokens, :temperature,
#     :top_p, :top_k, :reasoning_enabled, :reasoning_effort, :thinking_config, :seed, :n, :response_format]
```

An unknown symbol option raises `ValidationError` and points at the escape
hatch. Provider-specific wire fields ride `extra_body`, a string-keyed hash
merged verbatim into the built request body:

```ruby
protocol.create(model: "deepseek-flash", input: "hi", extra_body: { "min_p" => 0.05 })
```

`extra_body` semantics are strict on purpose:

- keys must be strings (they are wire fields, not Ruby options);
- a collision with a protocol-built top-level field raises instead of
  silently overwriting;
- for multipart endpoints (audio transcription) entries become form fields;
- lane pins hold even here (e.g. `xai_responses` rejects stateful
  continuation fields smuggled through `extra_body`).

The kernel uses `request_option_keys` to split catalog request options into
declared kwargs vs `extra_body`.

## Key-type contract

One rule per boundary, one conversion site per direction
(`Internal::Keys` / `Internal::Envelope`):

| Boundary | Keys |
| --- | --- |
| Ruby options / kwargs | symbols |
| Application message payloads (from JSON columns) | strings, passed through verbatim |
| Built wire bodies | any internal key type; the single exit `finalize_wire_body` deep-stringifies, collision-checks, then merges `extra_body` |
| Parsed responses, normalized results, usage | strings (they flow into kernel JSON columns) |
| HTTP adapter envelope | symbols, strict `fetch` |

## Media ingress: bytes only

`SimpleInference::MediaInput.from_bytes(bytes, declared_media_type: nil)` is
the public media boundary. It accepts raw bytes, detects their type from magic
numbers, and rejects paths, URLs, data URIs, unknown bytes, or a declared type
that disagrees. The resulting value carries the original bytes, normalized
`media_type`, and O(1) `byte_size`; inner protocol layers trust it without
copying, hashing, or detecting the same bytes again. Transcription's `file:`
takes `{ body: <raw bytes> }` rather than a host path.

Native PDF inputs use the same bytes-only value on the `openai_responses`,
`openai_compatible_chat`, `anthropic_messages`, and `gemini_generate_content`
formats. The model's profile must declare `file` in `input_modalities`, with
`input_media.file.mime_allowlist: [application/pdf]`. Place the PDF in message
content as `{ type: "input_file", filename: "report.pdf", file_data: media }`,
where `media` is a `MediaInput`. OpenAI requires the filename; the other wires
carry the PDF's media type and bytes. Each protocol constructs its native
inline file/document block. URLs, provider file handles, and caller-encoded
data strings are rejected. Other document formats are not native file inputs.
PDFs are sent whole without extraction or raster conversion; no fixed token
cost is declared for an arbitrary document.

`Measure` is the zero-IO preflight half of the bounds story:
`unicode_scalar_count`, `utf8_byte_count` (the token-conservative proxy —
bytes bound BPE tokens from above; scalar counts do not), and
`ensure_within`, which raises `BoundExceededError` before any request body
or IO exists.

## Finish quality

`FinishQuality.for(adapter_profile:, detail:)` maps the typed finish details
reported by text protocols to `output_budget_exhausted`,
`context_window_exhausted`, `refused` or `blocked`. Unknown details return
`nil`.

The last two are `FinishQuality::DECLINED`: the provider answered HTTP 200 and
declined. `refused` is a safety classifier's decline on the request or the
answer (Anthropic `stop_reason: refusal`; a Responses refusal part or
`content_filter`; a chat `message.refusal` or `content_filter`; Gemini's
`SAFETY`, `IMAGE_SAFETY`, `RECITATION`, `IMAGE_RECITATION`, `LANGUAGE`, and a
prompt blocked for `SAFETY`, `IMAGE_SAFETY`, `OTHER`, `JAILBREAK` or an
unspecified reason); another model may answer the same request. `blocked` is a
content-protection stop on the content itself (Gemini's `PROHIBITED_CONTENT`,
`IMAGE_PROHIBITED_CONTENT`, `SPII`, `BLOCKLIST`, and a prompt blocked for
`PROHIBITED_CONTENT`, `BLOCKLIST` or `MODEL_ARMOR`), which is not sent anywhere
again. A declined finish carries `Result#refusal`, a
`Responses::Refusal {category, explanation}` holding the provider's own words
verbatim — Anthropic's `stop_details` category and explanation, the refusal
text on the OpenAI wires (which name no category), Gemini's finish or block
reason as the category — each `nil` when the wire sent none. Every other finish
has `refusal: nil`, and refusal text never enters `output_text`.

## Streaming

```ruby
stream = protocol.stream(model: "claude-opus-5-5", input: "hi", reasoning_effort: "low")

stream.each do |event|
  case event
  when SimpleInference::Responses::Events::TextDelta      then print event.delta
  when SimpleInference::Responses::Events::ReasoningDelta then log(event.delta, event.kind)
  when SimpleInference::Responses::Events::ToolCallDelta  then accumulate(event)
  when SimpleInference::Responses::Events::ToolCallDone   then dispatch(event)
  end
end

result = stream.final_result # same Result shape as #create
```

- One SSE engine lives in `Protocols::Base` and handles the three response
  shapes providers actually produce: incremental SSE, buffered SSE bodies,
  and plain-JSON fallbacks from gateways that ignore `Accept`. Unrecognized
  non-error events remain internal and do not interrupt result assembly.
- Interrupted consumption is loud: calling `final_result` after breaking
  out of `each` raises `StreamError` instead of returning a truncated result.
- Streamed Gemini message/reasoning items accumulate across chunks (both
  wire shapes), so persisted `output_items` always carry the same text as
  `output_text`.
- There are no hidden retries anywhere in the gem: one call is one attempt.

## Errors

```text
SimpleInference::Error
├── CapabilityError         # the execution profile forbids the request
├── ValidationError         # bad options, unknown keys, malformed payloads
│   ├── BoundExceededError  # deterministic zero-IO cap rejection (Measure)
│   ├── ConfigurationError  # bad construction options / profile values
├── HTTPError               # non-2xx (status / body / raw_body accessors)
├── TimeoutError
├── ConnectionError
│   └── ConnectionNotEstablishedError  # HTTPX lane only: the connection was
│                               # never established, so no request bytes were
│                               # written. A caller may safely resend.
├── DecodeError             # malformed JSON / SSE payloads
└── StreamError             # interrupted or double stream consumption
    └── ProviderStreamInterruptedError # a 2xx provider stream ended without
                                      # a valid terminal; retry policy is the caller's
```

`raise_on_error: false` suppresses `HTTPError` on non-2xx: entry points
still return their result objects — with empty output and the error
`Response` available via `provider_response`. Transport errors always raise.

## Protocol lane notes

- **`DeepSeekResponses`** — DeepSeek's native `POST /responses` (no `/v1`);
  the provider lists two ids on it, `deepseek-flash` and `deepseek-v4-pro`
  (the pricing page's table, read 2026-09-16).
  `reasoning.effort` is the verbatim closed set
  `none|minimal|low|medium|high|xhigh|max`; statelessness is structural, so
  `store`/`previous_response_id`/`conversation` are not in the vocabulary;
  reasoning arrives as plaintext; text-only.
- **`XAIResponses`** — `store: false` pinned on every request (`store: true`
  is a loud rejection). Continuation is encrypted-reasoning replay;
  `previous_response_id`/`conversation` are rejected in the vocabulary and
  in `extra_body`. `usage.cost_in_usd_ticks` stays a lossless integer
  (1 USD = 10^10 ticks).
- **`OpenRouterResponses`** — the audited `openrouter_chat` lane under the
  `:exacto` discipline (the variant rides the model string; the endpoint
  slug pin is retired). Every request carries the frozen provider block
  (`require_parameters: true`) and `X-OpenRouter-Metadata: enabled`; usage
  accounting is always-on, so the lane must be constructed with the
  registry-declared `stream_include_usage: false` and never emits the
  deprecated `stream_options.include_usage` opt-in. `usage.cost` and
  `usage.cost_details.upstream_inference_cost` stay distinct typed fields.
- **`GeminiEmbeddings`** — the singular `embedContent` route only. Array
  input (the batch shape) is a pre-IO rejection; the wire reports no usage,
  so usage is truthfully `nil`, never fabricated.
- **`GeminiGenerateContent`** — `reasoning_effort` maps 1:1 onto
  `thinkingConfig.thinkingLevel` (`minimal|low|medium|high`; no disable
  level, no nearest-level guess); a caller `thinking_config:` hash passes
  through verbatim. `temperature`/`top_p`/`top_k`/`n` are declared but
  locally rejected on this lane (deprecated/removed upstream). A response
  with `promptFeedback.blockReason` is a Result with no answer, its typed
  `finish_detail` `PROMPT_<blockReason>`, the reason as `refusal.category`
  and the normalized usage — a finish, never a retryable interruption; a
  block reason outside the released SDK's enum fails closed like an unknown
  `finishReason`.
- **`AnthropicMessages`** — an HTTP-200 stream `overloaded_error` raises
  `StreamOverloadedError`, the typed retryable equivalent of HTTP 529;
  other stream error events remain terminal provider errors.
- **`CodexResponses`** — OAuth backend; the responses-lite reshape is
  construction-driven (profile wire option `use_responses_lite`), and
  `originator` plus the lite marker are the only protocol-emitted headers —
  both registry-declared wire options, like the intake defaults
  (`default_store`, `encrypted_reasoning_include`)
  (`Authorization` / `ChatGPT-Account-ID` are credential-derived Config
  headers, merged at execution).
  Prompt image parts carry prepared `MediaInput` bytes as inline data URLs.
  The format declares PNG/JPEG/WebP and a 2048-pixel local preparation bound;
  models still declare whether they accept images. No image token cost is
  inferred from that resize bound.
- **`OpenAIResponses`** — applies stateless-CoT capture defaults
  (`store: false` + `include: ["reasoning.encrypted_content"]`) unless the
  caller sets them explicitly; family lanes tune the lowering through the
  `reasoning_summary_default` / `reasoning_capture_defaults?` seams
  (DeepSeek turns both off and calls `super`) rather than copying the
  method.

## Extension contract

These seams ARE this gem's middleware. A new lane (or a lane variant)
reaches for one of them, never for a fork of a shared engine — every one is
already exercised by a shipped lane, so overriding it composes with the
create/stream machinery instead of re-implementing it.

- **The compat family's four observer hooks**
  (`OpenAICompatibleResponses`): `new_wire_observation` /
  `observe_stream_event` / `observe_terminal_body` /
  `synthesized_message_extras` — a lane whose wire carries terminal facts
  beyond the plain chat-completions shape observes them at the shared
  seams (OpenRouter: cost/BYOK/native finish reason/broker
  metadata/reasoning_details) without re-implementing the streaming loop.
- **`finalize_wire_body`** (`Protocols::Base`) — the ONE exit where a
  protocol's built body meets the caller's verbatim `extra_body`; override
  it to refuse lane-forbidden wire fields at the escape hatch (xAI rejects
  the stateful-continuation spellings there).
- **`protocol_headers` / `compiled_connection_headers`**
  (`Protocols::Base`) — protocol markers compiled with the payload and the
  execution-time credential lane (Gemini's `x-goog-api-key`, Anthropic's
  `x-api-key`).
- **`json_parse_options`** (`Protocols::Base`) — the hook over EVERY wire
  JSON parse (unary bodies and SSE events alike); a lane whose wire
  carries decimals that must not round-trip through Floats overrides it
  (OpenRouter: `decimal_class: BigDecimal`).

## HTTP adapters

**`HTTPAdapters::Default`** (Net::HTTP, the default) — per-instance state
only, no connection pooling: every request pays DNS+TCP+TLS. Scheduler-aware
on Ruby 3+.

**`HTTPAdapters::HTTPX`** — persistent connection pool for non-streaming
calls, private one-shot sessions per stream (a shared session would serialize
concurrent HTTP/1.1 streams and an aborted stream could poison the pool).
The persistent plugin loads HTTPX's `fiber_concurrency`, so it composes with
a Fiber scheduler; it suits thread-based hosts (Puma, Solid Queue). Requires
the `httpx` gem (lazily).

**`HTTPAdapters::AsyncHTTP`** — reactor-native via `async-http` (required
lazily). ONE shared adapter pools connections per origin and multiplexes
concurrent same-origin streams natively (HTTP/2 via ALPN). Measured
semantics (2026-07-09, pinned by `test_async_http_adapter.rb`): `timeout:`
caps total call duration streams included, `read_timeout:` is a genuinely
per-chunk idle deadline (inert on streams under HTTPX), and aborting a
consuming fiber cancels only that stream — h2 siblings and the pool stay
healthy. Outside a reactor each call runs a temporary reactor with a
one-shot client (no pooling — prefer HTTPX or Default there).

Custom adapters subclass `SimpleInference::HTTPAdapter` and implement
`call(request)` → `{ status:, headers:, body: }` and
`call_stream(request) { |chunk| }` (same envelope, `body: nil`) over the
symbol-keyed request envelope (`method:`, `url:`, `headers:`, `body:`, and
the three timeouts).

## Concurrency

**Fiber** — the gem is fiber-friendly end to end: request state is
stack-local, the adapter-internal Mutexes (session caches) hold no IO under
lock, and there are no Thread- or Fiber-locals.

## Request controls and deliberate limitations

These controls distinguish caller-owned policy from protocol lowering.

1. **OpenAI Responses and Codex declare `verbosity`, `prompt_cache_key`, and
   `service_tier`.** `verbosity: "low" | "medium" | "high"` lowers into
   `text.verbosity`, alongside any response format. `prompt_cache_key` and
   `service_tier` pass through as same-named wire fields; the caller chooses
   their values. These controls need no `extra_body` escape hatch.

2. **Codex session/thread id headers have no body-derived source here.**
   They exist on the upstream contract; deployments that hold them supply
   them as Config `headers:` alongside the credential pair.

3. **Anthropic `cache_control` passthrough covers system / text / image /
   `tool_result` blocks only.** The protocol forwards a caller-placed
   `cache_control` on those block shapes (and `instructions:` may be a
   String or an array of `{text, cache_control}` blocks). `normalize_tools`
   deliberately drops it, and the protocol never *places* a marker —
   placement policy lives in the kernel.

## Testing

```bash
bundle exec rake        # unit suite + RuboCop
```

The unit suite covers every protocol's wire contract with fake adapters,
execution-profile and request validators, request compilation, media ingress,
result normalization, and Fiber concurrency. No test performs network IO.

## License

MIT. See [LICENSE](LICENSE.txt).
