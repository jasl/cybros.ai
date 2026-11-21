# Multimodal provider checks, 2026-11-21

## Image and PDF input

The test built the shipped Nexus execution profile for each model and used the
vendored streaming client to send a synthetic PNG with a random six-character
code rendered in its pixels. Each route that accepts PDFs also received a
one-page PDF containing a second, independently chosen code. The prompt asked
for the codes in attachment order. Both the prompt and the filename omitted
the answers. All 22 routes in the table returned the exact expected text.

| Provider | Shipped models | Input read | Exact replies |
| --- | --- | --- | --- |
| Anthropic | Claude Fable 5.2, Opus 5.5, Sonnet 5.5, Haiku 5.5 | PNG + PDF | 4/4 |
| Google | Gemini 4 Argon, Carbon, Hydrogen, Neon | PNG + PDF | 4/4 |
| Kimi Code | `k3`, `k3-256k`, `k3.1-pro`, `k3.1-pro-highspeed`, `kimi-for-coding` | PNG | 5/5 |
| DeepSeek | `deepseek-flash` | PNG | 1/1 |
| OpenRouter | `qwen/qwen3.8-flash`, `qwen/qwen3.8-max-0902`, `qwen/qwen3.8-max-0902:exacto` | PNG | 3/3 |
| OpenRouter | `deepseek/deepseek-v4.1-flash`, `moonshotai/kimi-k3`, `z-ai/glm-5.3-flash` | PNG | 3/3 |
| xAI | Grok 4.6, Grok 4.7 | PNG | 2/2 |

Kimi Code returned HTTP 403 with a concurrent-request limit on overlapping
calls. All five routes completed when called individually. The supplied
credentials covered Kimi Code and OpenRouter. Direct Moonshot China and
International need their own credentials, so those routes are unverified.
OpenRouter returned HTTP 403 citing upstream terms for a PNG sent to its older
`anthropic/claude-sonnet-5:exacto` route.

DeepSeek's live model inventory listed text and image input for Flash and
text alone for Pro. Flash read `HFP7NJ` from the PNG on the direct Responses
endpoint. Nexus rejected an image for `deepseek-v4-pro` before dispatch.
Sending the same kind of input directly to Pro with thinking off produced
`UNKNOWN` when asked to use that answer for an unavailable picture. The
text-only control returned its random code correctly.
[DeepSeek model inventory](https://api-docs.deepseek.com/api/list-models/)
and [vision contract](https://api-docs.deepseek.com/guides/vision/).

## Conversation history

The later Kimi K3.1 Pro and DeepSeek Flash 1017 checks exercised a tool call
from an image and a model switch within one Conversation.
[OpenRouter results](openrouter-2026-11-21.md)

The `live_vision` product journey staged a PNG through the member upload API
and attached it to a real Conversation. DeepSeek Flash, Claude Haiku 5.5,
Gemini 4 Hydrogen and Qwen 3.8 Flash (OpenRouter) each answered `Red` on the
first turn. A second turn asked for the shape without attaching the PNG again.
All four answered `Square`. On each route, both sealed requests contained the
same upload ID. The four isolated journeys passed all 36 assertions.

## Provider-native video and audio input

These requests went directly to the providers. The Nexus conversation
attachment contract exercised above exposes image and PDF input. The test
used a silent six-second MP4 with two distinct words in chronological order.
For Gemini, a separate WAV contained four spoken digits. The question
contained neither the words nor the digits.

| API | Models | Returned |
| --- | --- | --- |
| Gemini GenerateContent | Gemini 4 Argon, Carbon, Hydrogen, Neon | Each returned `DUSK WOOD 6785` |
| Kimi Code Chat Completions | All five Kimi Code routes listed above | Each returned `DUSK WOOD` |
| OpenRouter Chat Completions | All three Qwen routes above, Kimi K3 and GLM 5.3 Flash | Each returned `DUSK WOOD` |

The probe used inline video bytes and a separate audio part on Gemini.
[Gemini video](https://aistudio.google.com/docs/video-understanding),
[Gemini audio](https://aistudio.google.com/docs/audio),
[Kimi vision](https://platform.kimi.com/docs/guide/use-kimi-vision-model)
and [OpenRouter video](https://openrouter.ai/docs/guides/overview/multimodal/videos).

## Image output

The shipped xAI Images client asked `grok-imagine-image-2.0` for a large
red square on white. It returned one inline JPEG, 1024 × 1024 and 83,689
bytes. Decoding the image yielded a red center pixel (99% red) and a white
corner (over 99% on all three channels).

## OpenAI API and Codex subscription

| Route | Probe | Observed result |
| --- | --- | --- |
| OpenAI API, all five requested IDs | Retrieve each model by its exact ID | Five HTTP 200 responses echoed the expected IDs. |
| OpenAI Responses, Astra 6.2, Sol 6.2, Terra 6.1 | Count a developer message, user prompt and strict function schema, then add inline PNG and PDF bytes | All six input-token requests returned HTTP 200. Astra and Sol went from 58 to 192 tokens. Terra went from 48 to 182. |
| OpenAI Responses, same three models | Ask for independent codes in the PNG and PDF | All three inference requests returned HTTP 429 with `credit_balance_exhausted`. Recognition through the public API could not be measured. |
| OpenRouter Responses with OpenAI as the only upstream, same three models | Submit the same PNG and PDF | All three returned HTTP 403 citing provider terms. |
| Codex subscription, same three models | Submit a PNG through each Nexus profile, with the random code present only in the pixels | All three returned the exact code `BVUBKKJ` with HTTP 200. Each reported 195 input and 8 output tokens. |
| Codex subscription, Sol 6.2 | Send an inline WAV using the Codex `input_audio` form | HTTP 400, `Audio input is not available.` The catalog exposes image input for this route. |
| OpenAI Images, Sunburst 2.6 and Flare 2.6 | Call generation and edit for each model | All four requests returned HTTP 429 with `credit_balance_exhausted`. Output quality and edit fidelity remain unmeasured. |
| Codex subscription, `gpt-image-2` | Generate two colored rectangles. In a separate edit, supply a red-and-blue reference and ask to change blue to green | Both requests returned HTTP 200. The first PNG measured 1774 × 887. The edited PNG measured 1254 × 1254, retained red on the left and changed the right to green. The edit reported 1,024 image input tokens. |

Codex's image-generation extension pins `gpt-image-2` for both operations.
The Nexus subscription profile uses the Codex backend paths and JSON edits.
The public Images profiles use the two 2.6 IDs and multipart edits.
[Codex image-generation tool](https://github.com/openai/codex/blob/bb5b9c6240136de8ff4d30215e2341c44559aa04/codex-rs/ext/image-generation/src/tool.rs)
and [OpenAI image generation guide](https://developers.openai.com/api/docs/guides/image-generation#gpt-image-26).
