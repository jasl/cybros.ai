# OpenRouter model checks, 2026-11-21

## Kimi K3.1 Pro tool call and handoff to DeepSeek

Two isolated Nexus Conversations exercised `openrouter/moonshotai/kimi-k3.1-pro`.
Each received a PNG containing a fresh six-character code. The prompt asked
Kimi to call `lookup_record` with the code and return the tool's checksum.
The image filename and prompt omitted the code. Both Runs captured the
upload, dispatched both model rounds through OpenRouter and settled the
tool result through Nexus. Each continuation carried the image, the native
Kimi reasoning field and the tool result paired to its call ID.

| Conversation | Code read from the image and sent to the tool | Checksum returned by Kimi |
| --- | --- | --- |
| First | `NRJ74N` | `C34E7307489F` |
| Second | `JK9N64` | `DECC9760BA32` |

The second tool result contained an additional random audit tag. Kimi's
answer omitted it. On the next turn, `openrouter/deepseek/deepseek-v4.1-flash-1017`
received a request for that tag with tools disabled. The compiled request
contained the tag only in the historical tool result, paired by call ID.
DeepSeek returned the exact value `449D011FBDB5560F`.

Kimi's capture on that Run contained native reasoning text and token counts.
The provider supplied no public reasoning summary. Inspection of DeepSeek's
request confirmed that both the native reasoning fields and the source
reasoning text were absent. The recovered tag measures continuity of visible
tool history across this switch.

| Conversation and round | Input tokens | Cached input tokens | Output tokens | OpenRouter charge (USD) |
| --- | ---: | ---: | ---: | ---: |
| First, Kimi tool call | 377 | 0 | 64 | 0.001394 |
| First, Kimi continuation | 479 | 320 | 26 | 0.000642 |
| Second, Kimi tool call | 377 | 0 | 70 | 0.001454 |
| Second, Kimi continuation | 496 | 320 | 19 | 0.000606 |
| Second, DeepSeek handoff | 376 | 0 | 40 | 0.0001608 |

Nexus recorded the broker's reported token counts and USD charges. The two
Kimi continuations each read 320 cached input tokens. This sample measures
one continuation per Conversation.

## Direct Chat Completions image checks

Two additional OpenRouter Chat Completions requests each sent a PNG with a
different random code. Each model transcribed its code exactly.

| OpenRouter model | Code in pixels and returned text | Reported charge (USD) |
| --- | --- | ---: |
| `tencent/hy4` | `RRJEED` | 0.001134724 |
| `deepseek/deepseek-v4.1-flash-1017` | `M2HH2M` | 0.0002142 |

The earlier cross-provider test covered the previous OpenRouter Kimi K3
route with a single PNG. The new Kimi and DeepSeek rows were exercised
through the broker under their shipped IDs.
[Earlier multimodal results](provider-multimodal-2026-11-21.md)
