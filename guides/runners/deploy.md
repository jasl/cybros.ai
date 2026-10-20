# Deploy a runner

A runner uses the operating-system environment where it is deployed: the host, container or VM supplies its files, dependencies and isolation. Choose the environment for the work, then connect it.

## Where to run it

| Environment | How | Notes |
| --- | --- | --- |
| The stack's rho container | Already running in full mode | Working directory `/home/runner`, mapped to `data/rho/work`; edit the bind in `compose.yaml` to work on a host project |
| A host, full or agent mode | The host installer, then `rho server --mode full` | Tools run as the host user; the default working directory is the `RHO_TOOLS_ROOT` setting |
| A host, runner mode | `rho server --mode runner` | No browser page, no conversation UI; serves tools only |
| A separate container | The published image, which starts in runner mode by default | Runs as UID 1000 without sudo; mount projects writable by that UID |

The published image includes language toolchains, Chromium, document conversion tools, fonts and Python file-work libraries, described to the model by its `workspace-tools` skill. Chromium alone does not enable browsing: add `rho/browser` to the extensions list for Playwright tools.

## A separate container

```sh
docker run -d --name rho-runner --restart unless-stopped --stop-timeout 30 \
  -e RHO_NEXUS_URL=https://nexus.example \
  -e RHO_DISPLAY_NAME="project runner" \
  -v rho-runner-home:/var/lib/rho \
  -v "$PWD:$PWD" -w "$PWD" -e RHO_TOOLS_ROOT="$PWD" \
  docker.io/jasl123/cybros-rho:latest

docker exec rho-runner rho connect
docker exec rho-runner rho status
docker logs rho-runner
```

Mounting the project at the same path inside and outside the container keeps paths identical. Use a separate state volume for every instance; copying a connected home duplicates its identity and a later pairing can replace the original. A Nexus on a Docker Desktop host is reachable as `host.docker.internal`; Linux needs a host-gateway mapping or another reachable address. The image's entry point runs rho commands (`docker run IMAGE doctor --strict`); use `--entrypoint /bin/bash` for a shell.

## Connect through the console

Open **Runners → Connect runner** in Nexus for deployment guidance and the device-code
entry point. Start the connection in the deployed program, then follow its verification
link or enter its code. Browser approval is followed by the program collecting its
credentials. Use **Refresh connection status**, then **View Runner** to inspect that
exact address. This does not prove that the program is online or a tool has executed.

For API-key setup, the same page lets you choose an active independent Agent you steward,
create its private Runner and issue a transport key. Save the key from its one-time
reveal and import it using the [API-key setup guide](../build/credentials-and-planes.md#api-keys).
Named Agents share their application's assignment and have no independent creation entry.
If the application already connected a bundled Runner, use its existing details instead.

## Identity and scope

A Runner's logical registration is its Account, Human manager and registration identifier. The identifier is stable for the installation; `RHO_DISPLAY_NAME` changes only the display name. Assignment scope controls which Agents may discover and use the Runner:

| Scope | Eligible Agents |
| --- | --- |
| `agent_private` | The bound Agent and Agents owned by its application |
| `user_private` | Agents stewarded by the Runner's Human manager |
| `account_wide` | Eligible Agents across the Account |

Full-mode rho pairs its bundled Runner with `agent_private`. That Runner is available to the same rho instance's Main Agent, Bots and Subagent executions when their execution policy permits Runner tools. Another rho instance cannot discover or use it, even when the same Human manages both. The binding is recorded at pairing; names do not establish application ownership.

The first combined Agent and Runner connection creates this binding automatically. When full-mode rho already has an Agent connection and adds its Runner, it binds the new Runner to that existing Agent. An independent runner-only installation uses `user_private` by default; an owner or administrator may choose `account_wide` when approving a fresh registration. Deploy an independent Runner when several rho instances need the same execution environment.

Scope and the bound Agent are fixed when the Runner registration is created. Reconnecting re-pairs the same address and advances its credential epoch while preserving both. Scope is access control, not part of the logical identity, and does not retarget existing tasks. The [device-flow reference](../reference/oauth/device-flow.md) describes the pairing contract.

## State

| Path or setting | Purpose |
| --- | --- |
| `RHO_HOME` (`/var/lib/rho` in the image) | Settings, instance identity, connection and logs; preserve it across upgrades, never share it between instances |
| `RHO_NEXUS_URL` | The Nexus this home belongs to; recorded at first pairing |
| `RHO_TOOLS_ROOT` | The initial working directory for tools |
| `extensions` in settings | Tool plugins loaded at boot: `rho/browser`, `rho/web-tools`, `rho/mcp` |

The home is private. Working files are separate from runner state; back up both according to their own plans. Nexus owns durable conversations, uploads, memory and schedules, so a runner home alone is not a backup of that data.

## Interactive terminals

The optional **Terminal** plugin (`rho.terminal`) serves an operator-only interactive
Bash tool in full and runner modes. It is disabled by default and is not advertised
to models. It uses the existing task claim, deadline renewal and Stop lifecycle.

1. Build the transport helper from the rho-runner package's `transport/` directory,
   using the Go version declared in its `go.mod`:

   ```sh
   go build -o /absolute/path/rho-webrtc .
   ```

2. On the Runner, configure the installed executable and enable the plugin:

   ```sh
   rho extensions configure rho.terminal '[{"op":"set","path":["executable"],"value":"/absolute/path/rho-webrtc"}]'
   rho extensions enable rho.terminal
   ```

   The browser's **Plugins → Terminal** settings edit the same configuration on a
   full-mode installation. A missing executable reports repair guidance and leaves
   other capabilities available. Go is needed to build the helper, not to run it;
   ordinary rho startup has no Go requirement.

3. If direct connectivity is unavailable, configure `rho.terminal` → `ice_servers`
   on the Runner with your TURN service. Each entry has `urls` (an array), optional `username` and write-only
   `credential`. Signaling uses Nexus; terminal bytes use the direct or TURN channel.

   Use `turn:relay.example.com:3478?transport=tcp` for TCP access to a TURN
   service with a TCP listener, or `?transport=udp` for UDP access. TCP here is
   the client-to-TURN connection; the relay allocation still uses UDP.

   For TLS over TCP, use `turns:relay.example.com:5349?transport=tcp` and a TURN
   TLS listener. Its certificate must match the URL host and be trusted by each
   peer. The native helper uses ordinary platform certificate verification.
   These URLs do not configure an HTTP proxy. Check connectivity from your
   deployed peers; local relay checks do not establish public NAT or proxy
   compatibility.

4. Configure the browser endpoint separately on the rho instance serving the WebUI.
   Its **Web interface** plugin (`rho.webui`) owns browser `ice_servers`. For example,
   replace the placeholders and submit the complete list through the existing CLI:

   ```sh
   rho extensions configure rho.webui '[{"op":"set","path":["ice_servers"],"value":[{"urls":["turn:relay.example.com:3478?transport=tcp"],"username":"BROWSER_USERNAME","credential":"BROWSER_TURN_PASSWORD"}]}]'
   ```

   The empty default uses no browser ICE servers. The secret-bearing list is edited
   through the CLI; ordinary settings views redact its credentials. Use credentials
   intended for admitted browsers, independently of the Runner's configuration.
   rho delivers this list through authenticated `GET /realtime/ice_servers` with
   `Cache-Control: no-store`; it is never embedded in static HTML or browser storage.
   Each new peer reads the current list, so configuration changes apply on reconnect.
   Failure to read it reports a connection error rather than silently using no servers.

   Browser TURN/TCP and TURN/TLS are covered by real terminal journeys with relay-only
   browser candidates and local TURN listeners. The TLS test uses a disposable
   browser profile that trusts its fixture certificate; certificate verification
   stays enabled. These tests verify the browser-to-TURN segment, not an all-UDP
   firewall outage, public certificate deployment, public NAT traversal or HTTP-proxy
   compatibility. The production browser leaves ordinary ICE path selection enabled;
   the relay-only policy belongs to those tests.

   An untrusted TURN TLS certificate prevents that relay connection. Correct the
   certificate chain or browser ICE configuration, then close and reopen the
   terminal panel. The terminal keeps its existing task and shell while the viewer
   is disconnected; Stop remains the command that ends it. The tested repair path
   changes an untrusted TLS endpoint to a working TCP endpoint and preserves the
   original shell.

Users can then [open a terminal](../use/conversations.md#open-a-terminal) from rho's
browser page. The shell has an 80×24 PTY and starts without the user's profile or
bashrc. Its startup file cleans ordinary shell jobs when the shell exits. Resizing
and Windows PTYs are not supported. Reconnection replaces the transport, retaining
the shell and original claim; it never replays input.

## Several runners

One run can use several runners. Each tool declaration carries a concrete runner UUID and the served tool name separately from the callable name the model sees, so two runners can both serve `read` under different callable names. A conversation's default runner applies to future calls that omit a target; accepted tasks keep their original target across waits, approval, retry and claim generations. Changing the default never copies files or synchronizes a project.

## Stop, update, recover

Give containers a 30-second stop grace period; rho stops the process groups it owns. Pull the chosen image and recreate the container with the same state volume to update; `rho update` refuses inside a container. On a host, `rho update --dry-run` previews and `rho update` applies; restart through the service manager that owns rho.

`rho status` reports the connection; `rho doctor --strict` checks the installed runtime and tools. Reconnect with `rho connect` after revocation or expiry. See [Monitor and troubleshoot](monitor-and-troubleshoot.md).
