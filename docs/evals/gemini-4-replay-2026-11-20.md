# Gemini 4 tool continuation and model switching

On 2026-11-20, Nexus sent streaming GenerateContent requests to all four
shipped Gemini 4 models. Each model received a distinct synthetic registry
of about 27,700 input tokens at low thinking effort. It called a local
lookup function three times. Each result supplied the key for the next
call, and the last result contained a newly generated value. All four
models returned that value exactly.

| Model | Cached input tokens across rounds 2–4 | Share of input in rounds 2–4 |
| --- | ---: | ---: |
| Argon | 25,687 / 25,729 / 25,767 | 92.48% |
| Carbon | 25,689 / 25,731 / 25,769 | 92.48% |
| Hydrogen | 25,687 / 25,748 / 25,813 | 92.41% |
| Neon | 25,687 / 25,797 / 25,846 | 92.40% |

Google reported the cache reads. In all 12 continuations, the previous
request's contents were an exact prefix and the result IDs matched the
calls. Argon and Carbon completed a shorter, approximately 15,500-token
trial without reporting any cache read. Implicit caching varies by request.

In a separate Hydrogen round, the model called the same function for two
independent keys in parallel. Google signed only the first call. Nexus
returned that signature on the first Part, left the second unsigned, and
paired two distinct random results by call ID. Hydrogen reported both
values in the requested order.

Hydrogen produced a signed tool call. Neon rejected the continuation when
the signature was stripped. With the original signature on the original
Part, Neon completed the same task. For a Claude tool call without a
Google signature, Hydrogen rejected the unsigned continuation and accepted
the one with Google's documented migration marker. A Grok tool call
followed by a separate user turn also completed on Neon with the marker
retained in the historical prefix. [Google's signature contract](https://aistudio.google.com/docs/thought-signatures?generate-content=true#faqs)

Two paired handoffs tested whether a new model could use a fact found only
in the source provider's public progress summary. Each pair used the same
question, tool results and visible conversation.

| Source → destination | Summary included | Replay off |
| --- | --- | --- |
| Hydrogen → Claude Sonnet 5 | Recovered the intermediate value 154 | Answered UNKNOWN |
| Grok 4.7 → Neon | Recovered the intermediate value 22 | Answered UNKNOWN |

A separate development-database run exercised the persisted path through
one Conversation, two Runs and three real model invocations. Hydrogen called
the lookup tool, Nexus settled its result, and Hydrogen read back the random
checksum. On the next turn Neon received the two original Gemini signatures
and the paired tool result in both the sealed request and the compiled Google
request. It returned the same checksum and correctly doubled the stored
quantity from 17 to 34 without calling the tool again.

The paired cross-provider probes exercised Nexus capture, round replay and
wire compilation with a local lookup function. Both destinations received
ordinary assistant text and paired tool history. The source provider's
encrypted state and signatures stayed off the destination wire. The two
controls measure recovery of these specific facts.
