# Deployment layouts

rho connects to Nexus and runs as a foreground service. Deploy it with Nexus in the combined Docker stack, or connect a separate host or container to an existing Nexus.

| Layout | Use it for | Where tools run |
| --- | --- | --- |
| Combined Docker stack | Nexus and a complete rho on one Docker host | Inside the rho container by default |
| Host installation, full mode | A personal workstation or server connected to Nexus | As the host user running rho |
| Agent mode plus separate runners | Browser and channel access on one machine, working files elsewhere | On each tool's declared runner |
| Runner-only host or container | Another execution environment | On that runner; no conversation UI |

A runner uses the operating-system environment where it is deployed. A host, container or VM supplies its files, dependencies and isolation. A working directory is a starting location for tools, not a filesystem access boundary. One run can use several runners; changing a conversation's default affects future tool calls that omit a target and never copies files.

Full mode's bundled Runner is reserved for that rho instance's eligible Main, Bot and Subagent work. Use an independent runner-only host or container to share an execution environment between rho instances. [Runner identity and scope](../runners/deploy.md#identity-and-scope) describes who may discover and use each Runner.

## The combined stack

[Install the stack](../get-started/install.md) covers installation. The installer pulls `docker.io/jasl123/cybros-nexus`, `jasl123/cybros-rho` and `jasl123/cybros-updater` and prepares bind mounts under the installation directory's `data/`.

Inside the stack, rho reaches Nexus at `http://nexus`; browser links use the saved public URL. The default ports are `3300` for Nexus and `7777` for rho.

```sh
./cybros instructions
./cybros status
./cybros rho status
./cybros logs rho
```

### LAN access

The guided setup's home-server choice asks for an address reachable from your browser. For an unattended LAN installation, supply it explicitly:

```sh
curl -fsSL https://raw.githubusercontent.com/jasl/cybros.ai/main/install/stack/install.sh | \
  CYBROS_BIND=0.0.0.0 \
  CYBROS_NEXUS_URL=http://home-server.local:3300 \
  CYBROS_RHO_URL=http://home-server.local:7777 \
  sh -s -- --yes
```

This publishes HTTP directly and sets up no domain, certificate or reverse proxy; keep it on your own local network. For an operator-managed TLS proxy, change the public origins and bind address in `.env`, set `CYBROS_OAUTH_ALLOW_HTTP='false'` for HTTPS public URLs, and configure the proxy separately. The registered OAuth callback is exactly `CYBROS_RHO_URL/auth/callback`; update it together with the public rho URL. Do not set the public origin to `http://nexus`.

| Variable | Default | Purpose |
| --- | --- | --- |
| `CYBROS_INSTALL_DIR` | `~/.local/share/cybros` | Installation directory; `--dir` takes precedence |
| `CYBROS_PROJECT_NAME` | `cybros` | Compose project name; choose another for a second installation |
| `CYBROS_BIND` | `127.0.0.1` | Host address on which both ports are published |
| `CYBROS_NEXUS_PORT` / `CYBROS_RHO_PORT` | `3300` / `7777` | Host ports |
| `CYBROS_NEXUS_URL` / `CYBROS_RHO_URL` | `http://localhost:3300` / `http://localhost:7777` | Browser-reachable URLs; the rho URL is also the exact OAuth callback origin |
| `CYBROS_OAUTH_ALLOW_HTTP` | `true` for HTTP URLs | Explicit local/LAN HTTP OAuth mode |
| `CYBROS_IMAGE_TAG` | `latest` | `latest` or a UTC `yyMMddHHmm` release tag |

Edit `.env` (Compose dotenv syntax) and run `./cybros up` to apply changes. `secrets.env` holds the database, Rails and encryption secrets; never regenerate the encryption keys while retaining the database.

### Host projects

To work on an existing host project, edit the source of rho's `/home/runner` bind in `compose.yaml` and give container UID 1000 write permission. That project is then outside the installation backup. For files on another machine, deploy a separate runner.

## rho on a host

Install with the host installer ([Connect a host installation](../get-started/connect-a-host-installation.md)), then:

```sh
rho setup --nexus-url https://nexus.example
rho server --mode full
```

| Mode | Browser page | Role |
| --- | --- | --- |
| `full` | Enabled by default | Agent and local runner |
| `agent` | Enabled by default | Agent; select a separate runner for environment tools |
| `runner` | None | Tool execution only |

The daemon serves the browser page's static files itself; no Node, Deno or Bun process is needed. `RHO_API_ONLY=1` disables the page while keeping the control API.

### Settings and the environment

Settings have one owner, `<RHO_HOME>/settings.json`, edited at runtime from the page, `rho settings`, `rho extensions configure` and plugin commands. An environment variable only seeds a setting the file does not have; a saved value wins, and an explicit launch flag wins for that start only. What stays in the environment is what a process needs before it can read its settings:

| Setting | Purpose |
| --- | --- |
| `RHO_HOME` | Settings, instance identity, connections and logs; preserve for upgrades, never share between concurrent installations |
| `RHO_NEXUS_URL` | Nexus API address for this home; recorded at first pairing |
| `RHO_MODE` | `full`, `agent` or `runner` |
| `RHO_BIND`, `--port`, `RHO_API_ONLY`, `RHO_WEBUI_ROOT`, `RHO_PUBLIC_URL` | How it listens and its registered OAuth callback origin |
| `RHO_NEXUS_PUBLIC_URL` | Nexus origin reachable by the user's browser, when different from `RHO_NEXUS_URL` |
| `RHO_TOOLS_ROOT`, `RHO_WORKSPACE`, `RHO_DEFAULT_MODEL`, `RHO_WEBUI_ACCESS` | Seeds for the corresponding saved settings |

### Remote access

A host server binds to loopback by default. Nexus accepts rho's `/auth/callback` URL on private LAN IP addresses and any valid port without extra registration. For a DNS name or public HTTPS origin, configure the exact callback in `NEXUS_OAUTH_REDIRECT_URIS`; this replaces the default allowed set. Provide a transport assertion on each rho start: `--expect-external-encryption` when TLS or an encrypted VPN fronts the socket, or `--unsafe-plaintext` for an explicitly chosen local/LAN HTTP deployment. rho does not terminate TLS.

```sh
rho server --mode agent --bind 0.0.0.0 --port 7777 --expect-external-encryption
```

A wider bind asks every browser for a Nexus sign-in by default. Where a browser cannot complete that flow, set an unlock password under **Settings › General › Opening this page**.

When you change the access mode to **Open** or **Unlock password**, the browser making the change stays in. Other browsers unlocked under the previous mode must enter again under the current mode. Changing to **Nexus sign-in** requires every unlocked browser, including yours, to sign in. Changing the unlock password ends other unlocked sessions while keeping the page that changed it. Browsers already signed in with Nexus keep their Human sessions and authority.

## A separate runner container

The published rho image starts in runner mode unless overridden. Mount a project writable by the image's UID 1000:

```sh
docker run -d --name rho-runner --restart unless-stopped --stop-timeout 30 \
  -e RHO_NEXUS_URL=https://nexus.example \
  -e RHO_DISPLAY_NAME="project runner" \
  -v rho-runner-home:/var/lib/rho \
  -v "$PWD:$PWD" -w "$PWD" -e RHO_TOOLS_ROOT="$PWD" \
  docker.io/jasl123/cybros-rho:latest

docker exec rho-runner rho connect
docker exec rho-runner rho status
```

Complete the device flow printed by `connect`, then select the runner from the agent's installation with `rho runners use RUNNER_ID`. The runner needs outbound access to Nexus and publishes no control port. Use a separate state volume for every instance. The image's working directory is `/home/runner`, its OS home `/home/rho`, and persistent state `/var/lib/rho`; it runs as UID 1000 without sudo. A Nexus on a Docker Desktop host is reachable as `host.docker.internal`.

## Stop, update and recover

Give containers a 30-second stop grace period; rho stops the process groups it owns. Update a stack with `./cybros update`; for standalone containers, pull the image and recreate the container with the same state volume and mounts. For a host installation, `rho update --dry-run` previews and `rho update` fast-forwards the checkout and reruns its installer; restart through the service manager that owns rho.

`rho status` reports connection state and `rho doctor --strict` checks installed runtime and tools. Neither proves a real model request; verify with a normal conversation.
