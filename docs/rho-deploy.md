# Deploy rho

rho connects to Nexus and runs as a foreground service. Deploy it with Nexus
in the combined Docker stack, or connect a separate host or container to an
existing Nexus. [Getting started](getting-started.md) covers account setup, pairing
and model selection; [daily use](rho-usage.md) covers conversations and tools.

## Choose the deployment

| Layout | Use it for | Where tools run |
| --- | --- | --- |
| Combined Docker stack | Nexus and a complete rho on one Docker host | Inside the rho container |
| Host installation, full mode | A personal workstation or server connected to Nexus | As the host user running rho |
| Agent mode plus a separate runner | Browser/channel access on one machine, working files on another | On the explicitly selected runner |
| Runner-only host or container | Add another execution environment | On that runner; no conversation UI |

The runner uses the operating-system environment where it is deployed. A host,
container or VM supplies its files, dependencies and chosen isolation. A working
directory is a starting location for tools, not a filesystem access boundary.
Changing runners does not copy files or synchronize a project.

## Nexus and rho together

From the repository root, with Docker and Compose v2 installed and running:

```sh
sh install/stack/install.sh
```

The guided installer asks about local or home-server use, storage location and
ports. It pulls `docker.io/jasl123/cybros-nexus` and
`docker.io/jasl123/cybros-rho`; it does not build them. The release scheme uses
matching Unix-seconds tags and a rolling `latest` tag for Linux amd64 and arm64.
A public installer URL is not yet published; use this repository script.

The installer prepares persistent bind mounts under the chosen directory's
`data/`, waits for service health and prints browser URLs and setup steps.
`--yes` accepts unattended defaults; `--no-start` prepares configuration without
pulling images or starting services. Run these commands from the resulting
installation directory:

```sh
./cybros setup
./cybros status
./cybros rho status
./cybros logs rho
```

Nexus is reached as `http://nexus` from rho inside the stack. Browser links use
the saved public URL. The default ports are `3300` for Nexus and `7777` for rho;
use the URLs printed for your installation. The
[stack guide](../install/stack/README.md) owns the complete configuration,
networking, update and backup procedure.

Open the saved `CYBROS_RHO_URL`, enter `RHO_ACCESS_PASSPHRASE` from the private
`secrets.env`, and choose **Unlock**. A daemon restart requires unlocking again.
A console link generated inside the container uses its internal bind address
and port; use the configured public URL from your browser.

The published rho image includes language toolchains, Chromium, document
conversion tools, fonts and Python file-work libraries. Its installed
`workspace-tools` skill describes those tools to the model on demand. Installing
Chromium does not enable browsing: add `rho/browser` to the existing
`extensions` list when you want the model to use it.

## rho directly on a host

Run the host installer from the repository root:

```sh
bash install/install.sh
```

It installs a portable Ruby and packaged gems into a user-owned prefix and
prints the launcher/PATH instructions. A preinstalled Ruby is not required;
the compiler, download and platform prerequisites are listed in the
[host installation guide](../install/README.md#rho-directly-on-the-host).
Supported targets are Linux with glibc and macOS, on x64 and arm64.

The default `full` installation profile includes the browser UI. The `dev`
profile adds Playwright and Chromium for the model's optional browser tools.
Installation profiles select installed tools; the runtime mode selects rho's
role:

```sh
rho setup --nexus-url https://nexus.example
rho server --mode full
```

Use another terminal under the same `RHO_HOME` for `rho status` and
`rho console --open`. `rho server` stays in the foreground. For a persistent
service, let your deployment's existing service manager own start, stop and
restart. Do not start a second daemon using the same home.

## A separate runner container

The published rho image starts in runner mode unless the deployment overrides
it. Replace the Nexus URL below; mount a project writable by the image's uid
1000 user:

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

Complete the device flow printed by `connect`. From the agent's installation,
list eligible runners with `rho runners` and choose the returned public ID
using `rho runners use RUNNER_ID`. The choice affects new conversations.
Nexus routes tool requests to the runner; the browser does not connect to it.
The runner needs outbound access to Nexus and publishes no control port.

Use a separate named volume for every rho instance. The project mount above
keeps paths identical on the host and container. The image's default working
directory is `/home/runner`, its OS home is `/home/rho`, and persistent rho
state is `/var/lib/rho`. It runs as uid 1000 without sudo.

The image entry point executes rho commands: `docker run IMAGE doctor --strict`
runs the doctor. To open a shell instead, use `--entrypoint /bin/bash` before
the image name. A Nexus running on a Docker Desktop host is reachable through
`host.docker.internal`; Linux deployments need an appropriate host-gateway
mapping or another reachable address.

The optional [standalone Compose template](../install/docker/compose.yml)
contains runner and full-mode services. Its `ghcr.io/jasl/rho:release` reference
is an operator-published example: replace it with the Docker Hub image above
or your own built image before using it. The template is separate from the
combined stack installer.

## Browser UI and remote access

| Runtime mode | Browser page | Role |
| --- | --- | --- |
| `full` | Enabled by default | Agent and local runner |
| `agent` | Enabled by default | Agent; select a separate runner for environment tools |
| `runner` | None | Tool execution only |

The separate `rho-webui` gem ships with the installer and images. The Ruby
daemon serves its static files; serving the UI needs no Node, Deno or Bun
process. Set `RHO_API_ONLY=1` or `"api_only": true` to disable the page while
keeping the control API. `RHO_WEBUI_ROOT` or `webui_root` can select another
static bundle on the daemon's filesystem; `api_only` takes precedence.

A host server binds to loopback and chooses a port by default. `rho console`
prints a single-use code valid for 90 seconds; `rho console --open` opens the
local page. Boot logs contain no console code. For a remote host or a container
bound to `0.0.0.0`, configure both:

- An access passphrase of at least eight characters, through
  `RHO_ACCESS_PASSPHRASE` or the private home's `access_passphrase` setting.
- A transport assertion on each start: `--expect-external-encryption` when
  TLS or an encrypted VPN fronts the socket, or `--unsafe-plaintext` when
  deliberately using plaintext. rho itself does not terminate TLS.

For example, after configuring the passphrase in the service environment:

```sh
rho server --mode agent --bind 0.0.0.0 --port 7777 --expect-external-encryption
```

The passphrase is required for a non-loopback bind even when Docker publishes
that socket only on the host's loopback. The combined stack configures this
container bind and passphrase. Follow its networking guide before exposing its
ports beyond the selected host interface.

## State and optional tools

| Setting or path | Purpose |
| --- | --- |
| `RHO_HOME` | Settings, instance identity, connections and logs; preserve for upgrades, never share between concurrent installations |
| `RHO_NEXUS_URL` | Nexus API address for this home |
| `RHO_MODE` | `full`, `agent` or `runner` |
| `RHO_TOOLS_ROOT` | Runner's initial working directory |
| `RHO_WORKSPACE` | Override the default workspace for this boot |
| `RHO_ACCESS_PASSPHRASE` | Browser/control unlock secret for wider binds |

The state directory is private. Copying a connected home to run a second
instance copies its identity and can replace the original pairing. Keep
working files separate from rho state and include both in the appropriate
backup plan. Nexus owns durable conversations, uploads, memory and schedules;
rho home alone is not a backup of that data.

Tool plugins are configured in the home's `extensions` list and loaded at
boot. `rho/browser` adds Playwright tools when their runtime is installed;
`rho/web-tools` adds web fetching; `rho/mcp` connects explicitly configured MCP
servers. Preserve existing entries when adding an extension. See the
[package reference](../agents/rho/rho/README.md#extensions) for configuration.

## Stop, update and recover

Give containers a 30-second stop grace period. rho handles termination and
stops the process groups it owns; the image's tini process reaps child
processes. Use `docker stop rho-runner` or the existing service manager.

Update a combined stack with `./cybros update` according to its
[update and backup instructions](../install/stack/README.md). For standalone
containers, pull the chosen image and recreate the container with the same
state volume and project mounts. Pin a release tag or digest when you need a
fixed image. `rho update` inside a container refuses; container updates replace
the image.

For a host installation, `rho update --dry-run` previews the update;
`rho update` fast-forwards the installation's source checkout and reruns that
checkout's installer. Restart through the service manager that owns rho.
The host guide explains `--rollback` and its saved runtime/gem pair.

Use `rho status` for connection state and `rho doctor --strict` for installed
runtime/tool checks. These checks do not prove a real model request or channel
delivery; verify those separately with a normal conversation after setup.

For custom image targets, exact dependency versions and local image acceptance,
use the [image guide](../install/docker/README.md) and
[installation manifest](../install/manifest.json). Publishing images is an
explicit operator action; CI does not publish them.
