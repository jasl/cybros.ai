# Command line

Three command-line tools, each with its own home and credentials. `COMMAND help` and `COMMAND help SUBCOMMAND` list the options available to your configuration.

## `rho`

The agent's control plane. In the Docker stack, run it as `./cybros rho …` from the installation directory.

| Command | Purpose |
| --- | --- |
| `rho server [--bind] [--port] [--display-name]` | Start the foreground daemon |
| `rho setup [--nexus-url URL]`, `rho setup model`, `rho setup telegram [--finish]` | Guided terminal setup, or one section of it |
| `rho connect [--api-key\|--api-key-stdin]`, `rho disconnect`, `rho status` | OAuth or API-key connection and its state |
| `rho console --open` | Open the browser page's public URL |
| `rho run "…" [--model] [--workspace] [--runner] [--dir] [--attach] [-p] [--output-format json\|stream-json] [--timeout] [--code-mode\|--no-code-mode]` | One noninteractive request; see [Terminal requests](../use/terminal-requests.md) |
| `rho models [--workload …]` | Usable models from Nexus |
| `rho workspaces`, `rho workspaces create NAME`, `rho workspaces use ID` | Workspaces and the saved default |
| `rho runners`, `rho runners use ID\|--none` | Eligible runners and the saved default |
| `rho memory CONVERSATION ls\|read\|grep\|write\|edit\|delete [--speaker SPEAKER_UUID]` | [Memory documents](../use/files-images-memory.md#memory) |
| `rho memory-review CONVERSATION status\|enable\|disable\|resume` | Optional [background memory review](../use/files-images-memory.md#background-memory-review) |
| `rho jobs CONVERSATION create\|list\|history\|pause\|resume\|cancel` | Schedules |
| `rho extensions list\|enable\|disable\|configure` | Plugins and their settings |
| `rho settings [JSON]` | Read or update core settings |
| `rho mcp …`, `rho mcp probe`, `rho mcp login\|logout` | MCP servers |
| `rho web fetch URL` | What the `web_fetch` tool would read |
| `rho telegram status` | Shared Telegram Connections, status and update offsets |
| `rho t3 token` | Save or issue the T3 service bearer |
| `rho call_tool`, `rho fetch`, `rho ps`, `rho logs` | Operator calls on a runner: a routed tool, file bytes, processes, process logs |
| `rho agents`, `rho env`, `rho runner`, `rho processes` | Management verbs of the shipped gems |
| `rho version`, `rho doctor [--strict]`, `rho update [--dry-run\|--rollback]`, `rho uninstall` | The installation |
| `rho-acp [--mode] [--model] [--runner]`, `rho-acp connect` | The ACP server for editors |

`rho settings` prints the current core settings. Pass a quoted JSON object to
update only the named fields. For example, list the available models, save the
conversation and title model choices, then read them back:

```sh
rho models
rho settings '{"default_model":"kimi_code/kimi-for-coding","conversation_title_model":"deepseek/deepseek-flash"}'
rho settings
```

Use model references from your own `rho models` output. This example sets Kimi
as the default conversation model and DeepSeek Flash for generated titles.
Other settings are preserved. The choices are saved in `<RHO_HOME>/settings.json`
and apply immediately when rho is running.

Conversational verbs beyond `run` (`do`, `say`, `watch`, `approve`, …) belong to `rho-dev`, a development gem the distribution does not carry.

With `rho-dev` installed, these commands inspect and repair a
[Conversation cost limit](agent-api/conversations.md#cost-limits):

| Command | Purpose |
| --- | --- |
| `rho conversation cost ID` | Read the limit and current usage |
| `rho conversation cost ID AMOUNT` | Set a limit in the Account's cost unit |
| `rho conversation cost ID off` | Clear the limit |
| `rho retry RUN_ID [TASK_KEY]` | Retry the refused task after adjusting the limit |

Changing a limit does not restart work. `resume` is for an explicitly paused
Run; a cost refusal uses task retry and preserves completed work.

`rho connect --api-key` prompts for keys without echoing them. For automation,
`--api-key-stdin` reads one JSON object from standard input: `access_token` for
the Agent member key and `executor_access_token` for its application transport key.
Both keys are required for the application. The flags are
mutually exclusive. Keys are validated and saved in the same private credential
stores used by OAuth, without refresh scheduling. See [Connect a host
installation](../get-started/connect-a-host-installation.md).

`rho setup telegram` configures a shared Connection and, with the daemon running, binds an existing Bot to an explicit chat/topic and owner. `--finish` binds a saved enabled Connection without prompting for its token. See [Telegram](../use/telegram.md).

`rho-dev` also provides `rho skills` to list Agent, workspace and local project skills. `rho skills push DIR`, `rho skills show NAME` and `rho skills rm NAME` use this rho Agent's `agent/skills/` by default. Add `--scope workspace` to manage shared workspace skills.

## `./cybros`

The stack's management script, in the installation directory.

| Command | Purpose |
| --- | --- |
| `instructions` | Browser URLs and setup steps |
| `status`, `logs [nexus\|rho]`, `manager logs` | Health and logs |
| `up`, `stop` | Start and stop, preserving data |
| `setup`, `setup model`, `setup telegram` | Guided terminal setup |
| `connect` | Re-pair rho |
| `rho …`, `cmctl …` | Run the bundled tools |
| `check`, `update [RELEASE] [--no-backup]`, `upgrade-status`, `upgrade-log`, `upgrade-resume ID`, `update-manager` | Upgrades; see [Status, logs and upgrades](../operate/status-logs-upgrades.md) |
| `backup`, `backups`, `restore BACKUP_ID DIRECTORY` | Snapshots; see [Backup and restore](../operate/backup-and-restore.md) |
| `compose …`, `manager …` | Ordinary Compose for operator repairs |

Installer options: `--dir`, `--yes`, `--no-start`, `--upgrade-manager`, `--help`.

## `cmctl`

The human operator CLI over the Platform API; see [cmctl](../operate/cmctl.md).

| Command | Purpose |
| --- | --- |
| `cmctl login --url URL --email EMAIL`, `cmctl logout`, `cmctl status` | The saved operator session |
| `cmctl setup --url URL` | Guided provider and model setup |
| `cmctl providers`, `cmctl provider add\|edit\|show\|enable\|disable\|discover\|reset ID`, `cmctl provider key set ID` | Provider connections and keys |
| `cmctl models [--available] [--workload …]`, `cmctl model add\|edit\|hide\|unhide\|test\|invalidate\|restore\|remove\|reset REF` | Model definitions |
| `cmctl account cost-unit UNIT`, `cmctl account retention [DAYS\|off]` | Account settings |

`CMCTL_HOME` or `--home DIR` selects the connection; each home holds one login.
