# Claude 5 tool loops and model handoffs

On 2026-11-21, Nexus ran four isolated Conversations through its shipped direct
Anthropic profiles. Each used medium effort, streaming and a fresh synthetic
registry. The first lookup supplied a random key for the second. The second
returned a new checksum and a unit count. All four models issued both calls,
returned the exact checksum and retained the two call/result pairs in history.

## Prefix cache

Each Conversation's first request wrote 5,742 tokens to the one-hour cache.
The two subsequent requests extended the prior system, tool and message prefix,
apart from the rolling cache marker. The read share is the provider's cache
reads across the two continuation requests divided by their total input tokens,
including writes and uncached input.

| Model | Round 2 cache read / total input | Round 3 cache read / total input | Read share |
| --- | ---: | ---: | ---: |
| Fable 5.2 | 5,742 / 5,858 | 5,856 / 5,939 | 98.31% |
| Opus 5.5 | 5,742 / 5,859 | 5,857 / 5,939 | 98.31% |
| Sonnet 5.5 | 5,742 / 5,916 | 5,914 / 6,001 | 97.81% |
| Haiku 5.5 | 5,742 / 5,907 | 5,905 / 5,984 | 97.95% |

A direct Haiku probe also issued two independent lookups in parallel. With
parallel calls explicitly disabled for a serial control, Haiku read 25,662 and
25,863 cached tokens in rounds two and three. In separate native API calls,
Haiku returned the requested tool without a thinking block for both forced
choice forms. Sonnet's `between_tools` mode at low effort returned text on
a tool-free request.

## Signed history

A direct Messages API control sent each model's real, untouched signed block
and tool call to each of the four recipients. The tool result contained a
fresh receipt. All 16 requests returned it exactly. Anthropic's
`thinking-binding-controls-2026-08-01` beta reported the outcome for each
model pair. Sonnet's first, simpler task produced no thinking block, so a
more demanding counting task elicited a signed block for its four trials.

| Source | Recipients with no reported drop | Recipients reporting `model_binding_mismatch` |
| --- | --- | --- |
| Haiku 5.5 | Haiku, Sonnet, Opus, Fable | None |
| Sonnet 5.5 | Sonnet, Opus, Fable | Haiku |
| Opus 5.5 | Opus, Fable | Haiku, Sonnet |
| Fable 5.2 | Fable | Haiku, Sonnet, Opus |

In a persisted Nexus Conversation, Fable → Haiku → Sonnet → Fable →
Gemini 4 Hydrogen → Fable correctly returned the checksum and a different
multiple of the original unit count at each switch. Haiku received the Fable
display summary and Anthropic reported dropping the model-bound block. On
both returns to Fable, the earlier signature was back on the wire, no drop
was reported, and cache reads resumed (5,937 and 6,380 tokens). The first
visits to Haiku and Sonnet had zero cache reads.

Gemini Hydrogen → Opus and Fable ↔ Grok 4.7 also finished the registry task.
Those cross-provider requests carried the original readable summary and two
paired tool results. No source-provider signature appeared in the target
request. In the simpler Sonnet → Gemini trial Sonnet emitted no display
summary. Gemini still answered from the visible tool history.

A separately authored three-step Run exercised Fable → Grok → Fable. Before
the sealed-history fix, Grok received the public summary, but Fable's signature
was absent when it returned. Repeating the Run after the fix preserved the
exact signature for Fable, kept it out of Grok's request and yielded no
reported binding drop. Both executions produced the same numeric answers
(20, 40 and 60). The first answer used Markdown bold and missed the probe's
plain-text exact-match check in both runs.

A separate deterministic regression covers an immediate fallback within a new
Conversation turn. A turn initially assembled for a different provider can
already contain the earlier turn's public summary in place of its signed
state. The fallback reuses those admitted contents. A later Conversation turn
can assemble the original signed blocks from stored history again.

## What the public summary contributed

Paired requests asked the receiving model for a two-word checkpoint present
only in a provider-issued display summary. The control removed that labeled
note from the same request and preserved the question, visible work and tool
results. Fable → Gemini Hydrogen recovered the checkpoint with the note and
answered `UNKNOWN` without it. For Fable → Haiku, Haiku initially answered
`UNKNOWN` when asked for a “public progress summary”. When both arms used
“labeled note” for the same source and checkpoint, Haiku recovered it with
the note and began its answer with `UNKNOWN` without it. Its signed Fable
block was present in both requests and the binding rules still applied.

Gemini → Fable did not recover the checkpoint. Fable returned a refusal in
both arms of the labeled-note comparison. Fable did complete the ordinary
tool-result task in the separate model-switch trials. These experiments
measure a specific retained fact and observed cache usage. They provide no
estimate of general reasoning quality after a handoff.

Anthropic documents the [model compatibility matrix](https://platform.claude.com/docs/en/build-with-claude/preserved-thinking#which-model-switches-keep-the-reasoning-on-the-claude-api)
and [prompt caching](https://platform.claude.com/docs/en/build-with-claude/prompt-caching).
