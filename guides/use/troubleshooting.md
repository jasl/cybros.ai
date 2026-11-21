# Troubleshooting

Start with `rho status`, `rho doctor --strict` and the relevant channel or plugin status. In the Docker stack, `./cybros status` and `./cybros logs rho` cover the combined installation. Check a conversation's pending questions, approvals and execution status before resubmitting work.

| Symptom | Next step |
| --- | --- |
| Browser setup was skipped | Open the rho URL and choose **Connect to Nexus**; `./cybros instructions` shows the URLs and setup steps again. |
| First login has not finished | Complete account creation and authorization in the same browser tab. For device login, finish setup, choose **Continue after setup**, then approve the displayed code. |
| Optional terminal setup was canceled | Rerun `rho setup` or `./cybros setup`. Earlier saved steps remain saved. |
| Nexus or rho is not healthy | `./cybros status` and `./cybros logs`; `./cybros logs nexus` or `rho` for one service. |
| No usable text models | Check provider enablement, credentials, model visibility, limits and tool support in Nexus; run `rho setup model` or `./cybros setup model`. Prices may stay unset. |
| Change the default model | **Settings › Defaults › Default model** in the browser, or `rho setup model` / `./cybros setup model`; the running daemon applies it immediately. |
| The connection is missing, incomplete or revoked | `rho connect` or `./cybros connect` and complete the displayed browser flow. |
| Login or device code expired | Start a new Nexus login from the rho page. |
| The Nexus authorization expired or was revoked | Open the saved rho URL and choose **Connect to Nexus** again. |
| A LAN browser cannot open the printed link | Check the saved public origins, bind address and host firewall; see [Deployment layouts](../operate/deployment-layouts.md). |
| The agent is waiting | Open its conversation and answer the pending question or approval, or inspect the reported execution failure. |
| A project is absent from the runner | Check the selected runner and bind mount; container paths refer to the container's filesystem. |
| Telegram needs a token or access-list change | Rerun the Telegram setup section; it preserves routes, offsets and pending deliveries. |
| Stack settings saved but health failed | `./cybros logs rho`, then `./cybros up`. |
| Stack secrets are missing | Restore `secrets.env` from the deployment backup before starting; never generate replacement encryption keys for existing data. |

Interactive and `--yes` stack installations print the same browser setup steps; `--no-start` requires `./cybros up` before opening the page. Reinstallation preserves the stack's `.env`, `secrets.env` and local Compose customizations.

## Host connection and first request

Use the same `RHO_HOME` for `connect`, `server`, `settings` and `run`. The default
is `~/.rho`. Follow [Connect a host installation](../get-started/connect-a-host-installation.md)
for the complete sequence.

### Unsupported settings format

`unsupported settings format; reconfigure this rho installation` means the
existing `settings.json` is incompatible with this rho version. Core settings
from older pre-release versions are not migrated automatically.

Stop the daemon or its service before moving the settings file aside:

```sh
rho_home="${RHO_HOME:-$HOME/.rho}"
mv "$rho_home/settings.json" "$rho_home/settings.json.backup-$(date +%s)"
```

Restart rho to create current-format settings, then rerun `rho setup` to choose
your settings again. This resets core settings and plugin overrides, including
saved plugin credentials; keep the backup private. The home binding, Agent
credentials and working files stay in place. Do not just change the file's
version number: its structure may also be incompatible.

### Connection refused

`Errno::ECONNREFUSED` means a connection attempt reached an address where no
service accepted it. For Nexus on the same host at port 3000, check:

```sh
curl -I --connect-timeout 3 http://127.0.0.1:3000
```

An HTTP response, including a login redirect, confirms that the web service is
reachable. Otherwise, start Nexus or correct its listening address and port. For
a development checkout, run `bin/dev` from the `nexus` directory and keep it
running; it also starts jobs and the model runner needed to execute requests.

Current rho normalizes HTTP `localhost` to `127.0.0.1`, so an IPv4-only Nexus
listener works with either spelling. If an older installed rho rejects switching
between those names as a different Nexus, update rho and restart its daemon.
Other address changes still require a different home; see
[Command line](../reference/cli.md). Inside Docker, loopback refers to the
container; use the Nexus address reachable from that container.

If Nexus responds but `connect` still reports a refused connection, inspect
`rho status` and rho's logs to identify the failing endpoint before changing
Nexus's listener.

### Console page unavailable

`rho console --open` reporting `This daemon serves no console page` means the
daemon is running its control API without a browser page. Its listening address
alone does not prove a WebUI is available.

Check `rho extensions list` for `rho.webui`. If it is disabled, run
`rho extensions enable rho.webui`. If it is absent, check
`gem list --local '^rho-webui$'` in the Ruby environment that runs rho. Install
the `rho-webui` gem alongside rho, or use the
[host installer](../get-started/connect-a-host-installation.md), then restart
`rho server`. An installed plugin still missing from the list after restart
requires updating rho as well.

Ensure the deployment's `api_only` setting is false and `RHO_API_ONLY` is unset
or false. Inspect any plugin readiness errors in `rho extensions list`. Once
the plugin is active and page serving is enabled, rerun `rho console --open`;
the page uses the daemon's current port.

### Member credential unavailable

`The member credential is not available` means the running daemon has no usable
Agent member credential for the request. Run `rho status`; a running daemon can
still be disconnected. Rerun `rho connect`, complete the displayed approval and
wait for **Connected** or **Connected as …** before retrying. If connection
fails, resolve that error first.

### Model selection required

`Select a default model or a model for this request` means no model was selected.
Run `rho models --workload text_generation`, then pass an exact identifier with
`rho run "Say hello" --model provider/model`. To save it as the default, use
`rho settings '{"default_model":"provider/model"}'`. Replace `provider/model`
with an identifier from the list. The running daemon applies the saved default
immediately. If the list is empty, configure provider access and model visibility
in Nexus; see [Models and providers](../operate/models-and-providers.md).

Before sharing logs, remove credentials, private setup links, private prompts and file contents.

Installation and connection recovery is covered in [Install the stack](../get-started/install.md); service, path and network configuration in [Deployment layouts](../operate/deployment-layouts.md); upgrade recovery in [Status, logs and upgrades](../operate/status-logs-upgrades.md).
