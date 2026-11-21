# GPT-6.2 and GPT-6.1 Terra tool loops and reasoning handoffs

On November 21, 2026, Nexus ran the three GPT text models through the Codex subscription. Direct calls to the public Responses API for each model returned HTTP 429 with `credit_balance_exhausted`. The subscription results below use its own credential, endpoint and Responses Lite wire. Public API behavior is identified separately.

## Tool continuation and cache reads

Each source Conversation looked up two dependent records. The model computed the selector for the first call. Its result provided the random selector required by the second call, whose result contained a fresh checksum and unit count. All three models made the two correct calls and returned the exact checksum. Each continuation preserved the preceding input, tool declarations, reasoning settings and cache key. Where an earlier reply supplied encrypted reasoning, Nexus returned it at its original position alongside the corresponding call and result. The subscription reported an empty `input_transformations` list for these continuations.

| Codex source | First request, cached / input | First continuation, cached / input | Second continuation, cached / input |
| --- | ---: | ---: | ---: |
| GPT-6.2 Astra | 0 / 2,957 | 2,944 / 3,094 | 3,072 / 3,144 |
| GPT-6.2 Sol | 0 / 2,957 | 2,944 / 3,118 | 2,944 / 3,164 |
| GPT-6.1 Terra | 0 / 2,945 | 2,816 / 2,998 | 2,816 / 3,047 |

These are provider-reported token counts from one run per model. Two additional runs, one for Astra and one for Sol, retained the same preceding request and saw zero cache reads on the first continuation. Their second continuations read 3,072 and 2,944 tokens respectively. The subscription sent serial function calls with the Codex Lite tool namespace. These tests kept the tool schema and reasoning effort stable. Parallel function calling on the public API remains unmeasured.

Two separate Sol 6.2 Responses Lite probes set the request-level `prompt_cache_options.ttl` to `30m` and `12h`. The subscription backend rejected each with HTTP 400 `invalid_parameter`. The shipped subscription profiles therefore leave retention to the backend. The public API profiles expose both documented durations.

## Native reasoning compatibility

For each source model, a diagnostic resent the second lookup request with the original sealed conversation, original encrypted item and tool declarations. It changed only the target model and matching subscription routing hint. The table records the target named in the terminal provider response and its verdict on the reasoning item. An empty list means the provider reported zero removals. The verdict measures acceptance and does not measure how the model used the item internally.

| Source on Codex | Receive on Astra 6.2 | Receive on Sol 6.2 | Receive on Terra 6.1 |
| --- | --- | --- | --- |
| Astra 6.2 | Retained | Retained | Removed, `model_mismatch` |
| Sol 6.2 | Retained | Retained | Removed, `model_mismatch` |
| Terra 6.1 | Removed, `model_mismatch` | Removed, `model_mismatch` | Retained |

Changing the first user's text in the captured request caused an explicit `prefix_mismatch` removal and zero cache reads, both for Sol → Sol and Astra → Sol. Sol → Astra with the original prefix retained the item and returned zero cache reads. Cache usage and reasoning retention therefore have separate observations.

Two further Conversations exercised model selection through Nexus after the compatibility change. One went from Sol to Astra and the other from Astra to Sol. Each receiver got the original source ciphertext and the two completed tool pairs, reported an empty transformation list and correctly returned the random checksum and twice the unit count.

Nexus allows both measured directions between the two 6.2 models on Codex. On the public API it allows the documented same-family upgrade from Sol to Astra and uses the public summary in the reverse direction. The direct API matrix remains unverified with the supplied key. Other providers and custom endpoints using the same model names receive portable history. [OpenAI reasoning item removal](https://developers.openai.com/api/docs/guides/reasoning#reasoning-item-removal-across-requests) and [prefix preservation](https://developers.openai.com/api/docs/guides/keep-prefix-unchanged).

## Public summary and visible task state

On an incompatible switch, Nexus can carry the source provider's display summary as a labeled assistant message. The following paired tests selected a word that occurred in that public note and was absent from ordinary visible task text. Each recipient read a compiled request with the two original tool/result pairs. The control removed the labeled note before resending the same request. Source ciphertext and signatures appeared in neither version.

| Source → recipient | With the public summary | With the summary removed |
| --- | --- | --- |
| Codex Sol → Codex Terra | Exact checkpoint | `UNKNOWN` |
| Anthropic Sonnet 5.5 → Codex Sol | Exact checkpoint | `UNKNOWN` |
| Codex Sol → Gemini 4 Hydrogen | Exact checkpoint | `UNKNOWN` |
| Gemini 4 Hydrogen → Codex Sol | Exact checkpoint | `UNKNOWN` |
| Codex Sol → Anthropic Sonnet 5.5 | Provider refused the recall request (`reasoning_extraction`) | No checkpoint recovered |

An early summary-only Astra → Sol test also returned `UNKNOWN` in both arms. The native compatibility test above establishes that this pair can retain its opaque item on the subscription. A summary is optional and the recipient may decline to use it.

A separate ordinary task asked the next model to return the random checksum and a new multiple of the unit count. Terra → Astra → Sol, Astra → Sol → Sonnet, and Sol → Sonnet → Astra all answered exactly. In the last sequence Sol had emitted no display summary. Both later models could still use the two visible tool results. These tasks exercise retrieval of a specific handoff fact and resumption of work. They do not quantify general reasoning quality after a switch.
