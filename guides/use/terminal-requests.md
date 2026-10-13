# Terminal requests

`rho run` sends one noninteractive request, prints the result and exits with a code. It is the CLI's single conversational verb; connection, model and plugin management are the CLI's main job.

```sh
rho run "Summarize the files in this project" --dir /path/on/runner
rho run -p "Summarize the files in this project"
rho run "Explain this image" --attach /path/to/diagram.png
rho run "Check this project" --output-format json --timeout 300
```

| Option | Effect |
| --- | --- |
| `--model PROVIDER/MODEL` | Override the default model for this request |
| `--workspace`, `--runner`, `--dir` | Select the workspace, runner and working directory without changing defaults |
| `-p` | Print the final answer alone |
| `--output-format json` | Print a result document; `stream-json` prints events followed by the final result |
| `--attach PATH` | Attach a file the daemon can read; repeatable |
| `--code-mode` / `--no-code-mode` | Override the conversation's code-mode choice |
| `--timeout SECONDS` | Stop waiting after the limit |

Normal output includes the conversation ID so its history can be found later.

## Decisions

`rho run` cannot ask you to approve a tool: it denies calls that would park for approval and lets the model continue. The configured rules still apply, so most calls run normally. If the model asks a human question or execution otherwise needs a person, `run` stops its work and exits with `2`. Use the browser, Telegram or an editor for work that needs those decisions.

## Exit codes

| Exit code | Meaning |
| --- | --- |
| `0` | The turn completed |
| `1` | Failure, refusal, external cancellation or usage error |
| `2` | Human intervention or timeout; the command stops its work |
| `130` | Interrupted by SIGINT or SIGTERM; the command stops its work |

A completed turn can still report a limitation or an unsuccessful task. Inspect the answer and the relevant checks before treating it as a successful delivery.

In the Docker stack, use `./cybros rho run "..." --model provider/model` from the installation directory; file paths refer to paths inside the rho container.
