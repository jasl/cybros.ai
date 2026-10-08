# Local tokenizer assets

Run `bin/download-tokenizers` from Nexus to prepare these files, or
`bin/download-tokenizers --check` to verify them offline. `bin/setup` and the
Docker build use that same installer. Downloaded files are ignored by Git.
The checked-in [manifest](../../config/tokenizers.json) pins the source revision
and SHA256 of every tokenizer and accompanying license. Runtime loads only the
installed JSON and never fetches, executes upstream Python or hashes these files
on the request path.

| Installed vocabulary | Model bindings | Source license |
| --- | --- | --- |
| `deepseek-ai/DeepSeek-V4.1-Flash` | Direct DeepSeek Flash and its OpenRouter row | MIT |
| `deepseek-ai/DeepSeek-V4-Pro-0813` | Direct DeepSeek Pro and its OpenRouter row | MIT |
| `zai-org/GLM-5.2` | OpenRouter GLM 5.2, 5.3 and 5.3 Flash | MIT |
| `tencent/Hy3` | OpenRouter Hy3 | Apache-2.0 |
| `Qwen/Qwen3.8-Flash-Next` | OpenRouter Qwen Flash; local Flash-Next and 27B examples | Qwen Community License 1.0 |
| `Qwen/Qwen3.5-9B` | Local Qwen 3.6 35B-A3B and 3.5 9B examples | Apache-2.0 |

Shared bindings are based on byte-identical official `tokenizer.json` files,
not family-name matching. The GLM comparison used [5.2](https://huggingface.co/zai-org/GLM-5.2/tree/cf457fa734ab149ffef225f80893eb38c6ff5cdc),
[5.3](https://huggingface.co/zai-org/GLM-5.3/tree/aca966e4e02791568aa6a4ced368624b3d897f42)
and [5.3 Flash](https://huggingface.co/zai-org/GLM-5.3-Flash/tree/eb9eb208eb0d988989d07a6a12d0fdeb5f52574a).
The Qwen comparisons used [Flash-Next](https://huggingface.co/Qwen/Qwen3.8-Flash-Next/tree/de4b8e4d43b917e7706784d8bb445c9af86a3540)
and [27B](https://huggingface.co/Qwen/Qwen3.8-27B/tree/1d4bf0f2ff6012fd82039f2fa52739d0dd7c60c0),
and [35B-A3B](https://huggingface.co/Qwen/Qwen3.6-35B-A3B/tree/995ad96eacd98c81ed38be0c5b274b04031597b0)
and [9B](https://huggingface.co/Qwen/Qwen3.5-9B/tree/c202236235762e1c871ad0ccb60c8ee5ba337b9a).
Qwen's [Flash-Next model card](https://huggingface.co/Qwen/Qwen3.8-Flash-Next/blob/de4b8e4d43b917e7706784d8bb445c9af86a3540/README.md)
identifies the Flash API as based on that model; this does not establish a
tokenizer mapping for Qwen Max.

Kimi K3's official release currently supplies a custom Python tokenizer and
`tiktoken.model`, not a compatible `tokenizer.json`. It has no HF counter binding
here. MiniMax has no shipped catalog entry. Neither receives a guessed exact
counter from another family.

To add an installed vocabulary, pin its official tokenizer and license in the
manifest, prepare it with the downloader, and declare it on the model:

```yaml
token_counter:
  kind: huggingface
  tokenizer_id: Qwen/Qwen3.8-Flash-Next
```

The on-disk name replaces `/` with `_` and appends `.json`; the license uses the
same stem with `.LICENSE`. The tokenizer counts text without adding its own
boundary tokens. Nexus adds a separate chat framing allowance. Media and exact
provider-side framing remain outside the local count; provider usage is the
authority for observed consumption.
