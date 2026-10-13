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

Before sharing logs, remove credentials, private setup links, private prompts and file contents.

Installation and connection recovery is covered in [Install the stack](../get-started/install.md); service, path and network configuration in [Deployment layouts](../operate/deployment-layouts.md); upgrade recovery in [Status, logs and upgrades](../operate/status-logs-upgrades.md).
