# Use rho day to day

rho works through conversations stored in Nexus. A selected model answers,
and a runner supplies working files and tools. Start with
[Getting started](getting-started.md) if rho is not connected or has no default model.

Examples below use the installed `rho` command. In a combined Docker stack,
run `./cybros rho ...` from the installation directory instead. File paths in
those commands are paths inside the rho container, so mount files there first.

## Choose an entry point

| Entry point | Use it for |
| --- | --- |
| Browser: the stack's rho URL or host `rho console --open` | Settings, Telegram setup, ongoing conversations, questions, approvals, execution controls and scheduled jobs |
| Telegram | Ongoing conversations, files, voice and controls from an allowed chat; see the [channel guide](../agents/rho/rho-ingress-telegram/README.md) |
| Editor through ACP | Conversations in a compatible editor; see the [ACP guide](../agents/rho/rho-acp/README.md) |
| Terminal: `rho run "..."` | One noninteractive request with output and an exit code |

The installed CLI also manages connections, models, workspaces, runners and
extensions. `rho help` lists the commands available to your configuration;
`rho help COMMAND` shows their options. Ongoing terminal conversation verbs
such as `do`, `say`, `watch` and `approve` belong to the separate development
gem `rho-dev`, which is not installed in the distribution.

## Start and continue a browser conversation

With a host rho running, use `rho console --open`; its single-use code expires
after 90 seconds. For the Docker stack, follow the installer's private rho link
to choose a rho access password and complete account setup. Later, open the saved
rho URL (`CYBROS_RHO_URL` in `.env`), enter that password, and choose **Unlock**.
Unlock again after a daemon restart. `./cybros instructions` generates a fresh
90-second console link using the saved public URL.

Create a conversation with an available model and runner, and choose the
working directory on that runner. Send the first request and follow its answer
and tool activity. Sending another message while work is running queues the
next input; sending when idle starts a new turn. Reopen a saved conversation
to continue from its durable history. Rename, archive and restore controls
organize that history.

Questions and tool approvals appear beside the work. Answer or decide the
specific pending item there. Pause/resume controls suspend and continue
execution; a failed step can be retried or abandoned. **Stop** stops execution,
including derived background work after a reply. Closing the browser or
switching conversations only detaches the viewer.

A failed or uncertain send keeps its draft and request identity for manual
retry in that page. Reloading discards this pending state: inspect history
before resubmitting an uncertain message after reload. Old conversation text
can remain readable after Nexus's retention policy removes execution details;
the page labels those missing details.

A conversation currently bound to Telegram or another ingress is read-only
in the browser except for Stop. Continue its messages and approvals in the
owning channel. Starting a new conversation in that channel releases its
previous current conversation. See the [WebUI guide](../agents/rho/rho-webui/README.md)
for the complete browser scope.

## Choose a model, workspace and runner

```sh
rho models --workload text_generation
rho setup model
rho workspaces
rho runners
```

Use an available model reference from `rho models`, or choose it in the page's
**Settings**. Saving applies the default immediately and overrides the initial
`RHO_DEFAULT_MODEL` value. Model availability comes from Nexus; provider credentials and model
limits are managed in [Nexus administration](nexus-model-settings.md).
Configured availability does not guarantee a successful provider request.

A **workspace** groups conversations and related Nexus resources. rho creates
its own dedicated workspace when none is selected. A **runner** is the
execution environment; its working directory is an ordinary filesystem path.
These choices are independent:

```sh
rho workspaces create "Project work"
rho workspaces use WORKSPACE_ID
rho runners use RUNNER_ID
```

Replace the placeholders with public IDs from the listings. These settings
affect new conversations. Existing conversations keep their original workspace
and runner; selecting another workspace does not move history, and selecting
another runner does not transfer files. An explicit `server --workspace`
launch flag must be removed before persisting a different workspace selection.
`RHO_WORKSPACE` supplies the initial value when no saved choice exists.

`rho runners use --none` clears the saved runner choice. Full mode then uses
its own runner; agent-only mode needs an explicit runner for environment tools.
For a single terminal request, use `--workspace`, `--runner` and `--dir` instead
of changing defaults. The directory is on the selected runner.

## Make a terminal request

```sh
rho run "Summarize the files in this project" --dir /path/on/runner
rho run -p "Summarize the files in this project"
rho run "Explain this image" --attach /path/to/diagram.png
rho run "Check this project" --output-format json --timeout 300
```

`--model PROVIDER/MODEL` overrides the default for that request. `-p` prints
the final answer alone; `--output-format json` prints a result document, and
`stream-json` prints events followed by the final result. Normal output includes
the conversation ID so its history can be found later.

`rho run` cannot ask you to approve a tool: it denies calls that park for
approval and lets the model continue. This does not mean every tool requires
approval; the configured rules still apply. If the model asks a human question
or execution otherwise needs a person, `run` stops its work and exits with `2`.
Use an interactive entry point for work that needs those decisions.

| Exit code | Meaning |
| --- | --- |
| `0` | The turn completed |
| `1` | Failure, refusal, external cancellation or usage error |
| `2` | Human intervention or timeout; the command stops its work |
| `130` | Interrupted by SIGINT or SIGTERM; the command stops its work |

A completed turn can report a limitation or an unsuccessful task; inspect the
answer and relevant checks before treating it as a successful delivery.
See `rho help run` and the [run reference](../agents/rho/rho/README.md#starting-work)
for stdin, structured results and the optional `--until` check loop.

## Work with files and images

Use repeatable `rho run --attach PATH` options or send a file in Telegram.
The daemon must be able to read CLI attachment paths. Documents retain a Nexus
upload reference; the model can import them into the selected runner, inspect
them with its available tools and publish an output file. Installing rho on a
host does not install every document parser or project dependency. The published
Docker image includes the tools listed in its
[workspace tools guide](../install/docker/workspace-tools.md).

Image input depends on the selected model's capabilities. Keeping an attachment
does not imply that a model can view its media type. To generate or edit images,
configure an available image-generation model as `image_model` in rho settings;
see the [image tool reference](../agents/rho/rho/README.md#extensions).

The browser displays linked artifacts and downloads them through rho, including
artifacts on a separate runner. **Browser file upload is not currently available.**
Use CLI attachments, Telegram, or files already present on the runner.

## Remember and recall

Ask rho to remember a preference, confirmed fact or project decision, or ask it
to forget an existing note. The default assistant uses Nexus's memory tools
during ordinary work and searches relevant memory when a request needs it.
Memory is stored as logical documents bound to the conversation's context:
conversation notes, shared workspace knowledge, and person/group notes when
those bindings are available. It is separate from working files and full
conversation history.

You can inspect the documents from the terminal. The daemon uses a known
conversation's original workspace. If an older conversation is not found after
you switch workspaces, select its original workspace and retry:

```sh
rho memory CONVERSATION_ID ls
rho memory CONVERSATION_ID read conversation/project.md
rho memory CONVERSATION_ID grep deployment
```

Use a path returned by `ls`. The same command also supports `write`, `edit`
and `delete`; `rho help memory` and the
[memory reference](../agents/rho/rho/README.md#remembering-and-recalling) describe
the interface. Available bindings and read-only rules determine what can be
changed. A model saying it remembered something should be backed by a successful
memory operation. Memory guidance is not a guarantee that every model records
or recalls every relevant fact; no separate background extraction job runs.

## Schedule delayed or recurring work

Open **Scheduled jobs** in a browser conversation. Create a one-time job, an
interval with its first execution time, or a daily time with an IANA time zone.
The panel lists jobs and supports edits, pause, resume, cancellation and
execution history. Telegram provides the corresponding `/job` commands.

The installed CLI uses the same schedule grammar:

```sh
rho jobs CONVERSATION_ID create once in 30m Check the build and report here
rho jobs CONVERSATION_ID create every 2h Review incoming changes
rho jobs CONVERSATION_ID create daily 09:00 Asia/Shanghai Summarize progress
rho jobs CONVERSATION_ID list
rho jobs CONVERSATION_ID history JOB_ID
rho jobs CONVERSATION_ID pause JOB_ID
rho jobs CONVERSATION_ID resume JOB_ID
rho jobs CONVERSATION_ID cancel JOB_ID
```

Use `--workspace WORKSPACE_ID` for a conversation outside the current default
workspace, `--model PROVIDER/MODEL` to select a model when creating a job, and
`--json` for structured output. Absolute one-time dates need `Z` or an explicit
UTC offset. See `rho help jobs` and the
[schedule reference](../agents/rho/rho/README.md#scheduled-jobs) for editing.

Nexus stores the schedule and starts each occurrence in a fresh child
conversation. The result reports back to the original conversation. Keep
Nexus's workers and the required agent/runner available for execution.
**Pause and cancel affect future occurrences.** Stop an already running child
inside its execution. A one-time schedule marked `completed` may still have a
running child; execution history shows the child's actual status.

## Troubleshooting

Start with `rho status`, `rho doctor --strict` and the relevant channel or
extension status. Use `./cybros logs rho` for the combined stack. Check the
conversation's pending questions, approvals and execution status before
resubmitting work. Installation and connection recovery are covered in
[setup recovery](getting-started.md#rerun-or-recover); service, path and network
configuration belong to [deployment](rho-deploy.md).
