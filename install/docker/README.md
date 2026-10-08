# Docker images

The combined stack uses `docker.io/jasl123/cybros-nexus`, `docker.io/jasl123/cybros-rho`
and `docker.io/jasl123/cybros-updater`. All publish the rolling `latest` tag and
support Linux amd64 and arm64.
The rho image publishes the `browser` target below,
including project language toolchains, Chromium, Office converters, fonts and Python file-work
libraries. The existing browser extension remains separately enabled in rho settings.

To install the published images, follow the [stack guide](../stack/README.md).
This page covers image builds, publishing and the standalone Compose template.

For an optional Telegram bot, follow the [stack Telegram setup](../stack/README.md#optional-telegram-bot).
The standalone `compose.yml` also forwards `RHO_TELEGRAM_BOT_TOKEN`, only to
`rho-full`. Supply it in a private Compose environment file alongside any other
standalone settings, set `plugins["rho.ingress_telegram"].enabled` to `true` in
that service's existing
`/var/lib/rho/settings.json`, then recreate the service:

```sh
docker compose --env-file /path/to/private-rho.env -f install/docker/compose.yml \
  --profile full up -d --no-deps --force-recreate rho-full
```

Keep the environment file private (mode `600`). A saved token takes precedence;
without one, an unset or empty environment token keeps Telegram disabled. The
runner receives no bot token. The standalone template's existing named-volume
layout is unchanged.

## Publish the current checkout

Run the relevant project tests first, commit the intended source, and log in to the
registry on the publishing machine. One command then owns native builds, image smoke,
upload and verification. GitHub Actions does not build or publish these images.
The publisher needs a POSIX shell, Docker with Buildx, Git, Ruby with its standard
`json` and `open3` libraries, `tar`, `mktemp`, `date` and `awk`.

Set both native Docker Engines explicitly. Each value is an existing Docker context
name or an `ssh://` Docker endpoint; the SSH user must be able to access that host's
Docker socket. For example, from an arm64 Mac with an amd64 Linux builder:

```sh
export CYBROS_ARM64_DOCKER_CONTEXT=desktop-linux
export CYBROS_AMD64_DOCKER_CONTEXT=ssh://builder@builder.example
sh install/docker/publish.sh                  # UTC minute selected once
sh install/docker/publish.sh 2610080750       # explicit unused UTC minute
```

The script verifies each Engine's native architecture and selects its same-named
Docker driver builder, reusing the Engine's build cache. `BUILDX_BUILDER` does not
override that selection. It creates a temporary context for an SSH URL and removes
only contexts it created. Existing contexts, builders and caches are retained.
Docker streams build contexts and copies smoke scripts through its API, so the remote
host needs no source checkout or copied registry credential file. Pushes use the local
Docker client's existing login.

The checkout must be clean. A temporary local Git archive freezes `HEAD` for all six
builds and excludes ignored and untracked files. Nexus uses `nexus/`, rho uses the
repository root and its `browser` target, and the updater uses
`install/stack/updater`. Each image carries the same OCI version, Git revision and
source labels. No source branch or release archive is downloaded.

All six images build and pass native runtime checks before any push: Nexus boots its
Rails runtime without a database connection, rho runs `version`, `doctor --strict`
and the existing offline coding/Cowork/browser smoke as uid 1000, and the updater
loads its runtime and executes its Docker and Compose clients. These image checks
do not replace the full container, Compose, project and cross-project tests.

The script pushes `:<tag>-amd64` and `:<tag>-arm64`, checks each native image's config
and labels, then assembles the three `:<tag>` indexes from their exact digests.
Every index must contain the checked Linux amd64 and arm64 images and matching
version/revision/source labels before any `latest` write. Promotions use those
verified index digests; success also requires every `latest` digest to match.

Tags use UTC `yyMMddHHmm`, with `yy` interpreted as 2000–2099. For example,
`2610080750` means 2026-10-08 07:50 UTC. The script refuses an existing release or
architecture tag, and registry authentication or network failures also stop it.
Use a new minute for each attempt. A failure before promotion leaves all existing
`latest` tags unchanged. The three rolling-tag writes are separate registry
operations, so a promotion or final verification failure can leave a partial
promotion; the command reports failure. After correcting the cause, rerun the
complete command with a new unused minute. Whole-installation update checks reject
a mismatched Nexus/rho release pair. Installations use `latest`; publishing needs no
product version number or Git release tag.

Architecture tags remain available for diagnosis. The publisher never deletes
registry tags, manifests or blobs. Temporary source and smoke containers, including
their anonymous volumes, are removed on exit; built native images and build caches
remain on their Engines.

To publish to other repositories, set complete repository paths without tags:

```sh
CYBROS_NEXUS_IMAGE_REPOSITORY=ghcr.io/jasl/cybros-nexus \
CYBROS_RHO_IMAGE_REPOSITORY=ghcr.io/jasl/cybros-rho \
CYBROS_UPDATER_IMAGE_REPOSITORY=ghcr.io/jasl/cybros-updater \
sh install/docker/publish.sh
```

Nexus builds its JavaScript and CSS in a separate `BUILDPLATFORM` stage with Bun 1.4.2
and the frozen lockfile. The target-architecture Rails stage copies those outputs and
runs Propshaft with the JS/CSS rebuild tasks disabled. The runtime image needs no Bun.

## rho's image

rho is built on `ubuntu:26.04` by the same `install/install.sh` a person runs on a host —
from the packaged gem trees of the checkout, into `/opt/rho` as uid 1000. It runs in runner
mode by default; the combined stack selects `RHO_MODE=full`. The separate rho deployment
guide is [Deploying rho](../../docs/rho-deploy.md). The image carries the management CLI and
`rho run` alone; the verbs that operate a conversation from a terminal are `rho-dev`'s, a development gem the
checkout's e2e supplies and no target of this Dockerfile installs (`agents/rho/rho-dev/README.md`).

## The Dockerfile

`install/docker/Dockerfile`, built from the REPO ROOT (the root `.dockerignore` whitelists the packaged
trees and `install/`). Four targets:

| target | adds | tag |
|---|---|---|
| `base` | the manifest's apt core (`apt.image`), tini, uid 1000 `rho`, mise and gh (manifest-pinned tarballs, sha256) | build stage only |
| `rho` | `install.sh --from-checkout`, profile `full`: the portable Ruby, the lock's bundler, the gems built here, rg, fd, jq, uv; `libexec/docker-entrypoint`; the bootsnap cache prewarmed on the layer; `rho doctor --strict`; the standalone stack installer | custom smaller builds |
| `toolchains` | mise's `node@24.21.0 go@1.27.1 rust@1.98.1`, npm/pnpm and JavaScript tools; pinned T3, Codex and Claude Code; Rust uses rustup's minimal profile plus rustfmt/clippy; uv's Python 3.14 and ruff/pyright/mypy | operator-selected tag |
| `browser` | Chromium libraries and the existing `dev` driver/headless shell; LibreOffice Writer/Calc/Impress, fonts, and the Cowork Python environment | `docker.io/jasl123/cybros-rho:latest`, `:<yyMMddHHmm UTC>` |

`rho-webui` and its static resources are included from the `rho` target onward. The Ruby daemon
serves the page in `full` and `agent` modes; the default `runner` mode stays headless. No JavaScript
server or frontend build runs in the image. Node in `toolchains` belongs to the project's
tools; Node and Chromium in `browser` belong to the model's Playwright tools. Neither layer is
needed to serve the WebUI. `RHO_API_ONLY=1` keeps the control API and disables the page.

The default project runtimes are one Node LTS, Go, one Rust Stable, and one uv-managed
Python 3.14. LTS and Stable are release-selection rules; image builds install the concrete
versions recorded in the manifest. Rust includes cargo, rustc, rustfmt and clippy without
the rust-docs component. Java, project Ruby and Bun are installed on demand through mise,
which also reads the project's runtime version files. rho's own portable Ruby stays in
`/opt/rho` and is independent of project Ruby. See the [workspace tools guide](workspace-tools.md)
for installation commands.

The default rho user's `~/.gemrc` sets RubyGems to `--no-document`, including for project
Rubies installed later. Builds omit Rust documentation and remove bundled Ruby documentation
and downloaded package caches in their installation layer. This keeps those bytes out of the
image. The Cowork environment and uv tools use the same Python 3.14 installation as project Python.

No version number and no package name lives in the Dockerfile: every RUN that needs one sources
`install/manifest.sh` through a bind mount (rendered from `install/manifest.json` by `rake
install:render`; `rake install:check` — in rho's default rake task — refuses a stale copy). The one ARG
is the base tag, checked against the manifest's `toolchains.base` at the first step. The manifest's
`toolchains` rows (mise, gh, the tool list, uv's Pythons and tools, tini) and `apt.image` /
`apt.chromium` / `apt.cowork` are the image's; `rake install:bump` refreshes mise and gh from their release
checksum files like every other row.

`toolchains.native_coding.packages` pins the native coding programs separately.
T3 stays on an explicitly validated protocol-2 build; `install:bump` preserves
these pins until its protocol is checked. npm verifies registry integrity and
selects the matching native platform packages. The `rho.t3` plugin is disabled
by default even when these programs are preinstalled. Configure and explicitly
enable it through Settings → Plugins or the coding-agent setup commands below.
Local mode runs T3 as one foreground process owned by rho inside the
same container and persists native configuration under `/var/lib/rho/plugins/rho.t3`.
Host mode connects to an explicitly configured, independently managed T3 origin.
Follow [coding-agent setup](../stack/README.md#optional-coding-agents), including
native login, project selection and the distinct readiness checks.

```
docker build -f install/docker/Dockerfile --target browser -t rho:dev .
docker buildx build -f install/docker/Dockerfile --target toolchains \
  --platform linux/amd64,linux/arm64 -t ghcr.io/jasl/rho:release --push .
```

## Cowork libraries and usage

The image includes LibreOffice Writer, Calc and Impress for headless DOCX/XLSX/PPTX conversion;
Poppler and FFmpeg already belong to the apt core. Noto core/CJK, DejaVu and Liberation fonts
cover Latin and Chinese documents. Python 3.14 under `/opt/cowork` includes python-docx,
openpyxl, python-pptx, pypdf, reportlab, Pillow, pandas and matplotlib. `python` / `python3`
select that environment by default; an explicitly activated project virtualenv takes precedence.
There is no global `VIRTUAL_ENV` or `PYTHONPATH`, and `uv run` still owns project dependencies.
These packages are image-only and add no host-installer or gem boot requirement.

The static [workspace tools guide](workspace-tools.md) is installed at
`/usr/local/share/cybros/workspace-tools.md`. It describes commands, imports, conversion and
browser enablement. rho's Coding extension advertises it as the `workspace-tools` skill;
the model loads its body on demand with `skill {"name":"workspace-tools"}`. A same-named
project skill from the runner's announced catalog takes precedence, and that catalog remains
available after a conversation binds to another directory. An installation without the guide
does not advertise it. Nothing writes a default home, credentials or extension settings.

`apt.cowork` uses Ubuntu's package versions, matching `apt.image`. Python direct dependencies
live in `cowork-requirements.in`; every transitive dependency is pinned in
`cowork-requirements.txt`, resolved for Python 3.14 across platforms. Refresh deliberately from
the repository root, then run both platform resolution checks and the native image smoke:

```sh
uv pip compile --upgrade --universal --python-version 3.14 --only-binary :all: \
  install/docker/cowork-requirements.in --output-file install/docker/cowork-requirements.txt
```

Image builds use `uv pip sync --only-binary :all:` and fail when a pinned dependency has no
compatible wheel. Runtime stays uid 1000 without sudo. Office, fonts, Chromium and language
runtimes increase image size; use a smaller explicit target when those tools are not needed.
The measurements below identify the runtime set and Docker storage metric used for each build.

## Optional GHCR toolchain and browser builds

The standalone rho `compose.yml` uses `ghcr.io/jasl/rho:release` as its image reference.
Publish that tag manually with the Buildx command above, or replace it with a tag or digest
from your own build. The `browser` target can similarly be published as `:release-browser`.
These tags do not track source branches automatically. The combined stack uses the Docker Hub
images published by `install/docker/publish.sh` above. To hold a deployment still, pin the
image digest Docker keeps after `pull` instead of a rolling tag:

```
docker image inspect --format '{{index .RepoDigests 0}}' ghcr.io/jasl/rho:release   # ghcr.io/jasl/rho@sha256:…
```

Developers build locally from the checkout, as above (`rho:dev`), and `install/test/docker_test.sh`
proves it. Inside a running container `rho update` refuses — the image rolls (`docker compose pull &&
docker compose up -d`), the prefix does not.

## What the build proves

`rho doctor --strict` runs at the end of the `rho`, `toolchains` and `browser` targets: every receipt
row answers (the portable Ruby, the lock's bundler, the gems, the (ruby, gems) pair, each tool's
`--version`, the driver's Node and playwright-core against the gem's pin, the Chromium shell) or the
build fails — codex-universal's `verify.sh`, one checklist for the host and the image.

The 2026-10-04 native Linux amd64 and arm64 `browser` builds passed the complete container
test, including the offline toolchain, Cowork and browser smoke. Docker was 29.8.2 on amd64
and 29.8.1 on arm64, both using API 1.56. Each platform's comparison uses its previous
release `jasl123/cybros-rho:1791054254-<arch>` and new
`cybros-local/cybros-rho:slim-1791059162-<arch>`, measured on the same host:

| platform | previous `inspect.Size` (bytes) | slim `inspect.Size` (bytes) | reduction |
|---|---:|---:|---:|
| Linux amd64 | 10,330,458,328 | 6,060,257,150 | 4,270,201,178 bytes (41.34%) |
| Linux arm64 | 10,253,224,104 | 5,917,116,551 | 4,336,107,553 bytes (42.29%) |

Docker's `image inspect.Size` here is the local containerd footprint: compressed blobs,
unpacked layers and metadata combined. It is neither registry transfer size nor unpacked
layer size alone. Separately, the Docker history API reports `4,518,494,208` bytes of
unpacked layers for the new amd64 image and `4,434,718,720` bytes for arm64. Both builds
supplied checksum-verified official mise/gh archives through temporary read-only download
seeds; the original checksum, extraction and installation steps remained in place. The
arm64 build also seeded rustup's package download cache with official archives, excluding
documentation, before the normal rustup installation. The amd64 Rust installation used
its ordinary download path. Neither build reused the previous release as a base image.

The historical 2026-10-01 native arm64 build `rho:cowork-20261001-final` used the previous
nine-tool mise set and Python 3.14/3.13/3.12, with Cowork on Python 3.13. It passed the complete
container test and the offline Office/browser smoke on Docker 29.8.1. Docker reported
`image inspect.Size = 10,072,980,756` bytes; its history API's layer sizes summed to
`7,645,192,192` bytes. These are different local storage measurements, not download size
or a claim that all of this space was added by Cowork. Selected history layers were:

| layer | bytes |
|---|---:|
| existing mise language toolchains | 4,168,396,800 |
| existing uv Pythons and tools | 411,086,848 |
| Office, fonts and Chromium system libraries together | 617,320,448 |
| Cowork Python libraries | 214,745,088 |
| existing browser installer rows | 587,427,840 |

In that check, both Linux arm64 and amd64 resolved the locked Python dependencies for
Python 3.13 with binary wheels only. Only arm64 received a native image build/runtime test.
These measurements do not quantify the current runtime reduction.

Measured 2026-09-13 on an M-series Mac (Docker Desktop 29.7.2, arm64, warm network):

| target | build | uncompressed |
|---|---|---|
| `base` | ~80 s (apt: build-essential, clang, cmake, the dev libraries) | 383 MB |
| `rho` | +25 s (the installer: bottle, bundler, four native gems, rg/fd/jq/uv, prewarm, doctor) | 446 MB |
| `toolchains` | +75 s (mise 64 s: nine tools, all precompiled; uv 11 s) | 1.78 GB |
| `browser` | +60 s (the Chromium libraries, Node, playwright-core, the shell) | 1.99 GB |

Under amd64 emulation on the same Mac the `rho` recipe runs (the x86_64 bottle, the four gem compiles,
rg, fd, jq: 147 s apt + 126 s install) but two Go/Rust static binaries do not: git-lfs's postinst and
`uv --version` fail under the emulator. The amd64 tag is therefore built on a native runner (the
workflow), never as a local gate; the arm64 targets are the local gate.

## The test

`install/test/docker_test.sh` (`RHO_INSTALL_TEST_DOCKER=1 install/test/run.sh`, or on its own): builds
`base` and the published `browser` target for the host's arch (or takes `RHO_INSTALL_TEST_IMAGE=<tag>`), then — `rho version`
through the door (tini → `docker-entrypoint` → the wrapper); `rho doctor --strict` inside; `RHO_MODE`,
`RHO_HOME`, unchanged `HOME=/home/rho`, writable `RHO_TOOLS_ROOT=WORKDIR=/home/runner`,
`LANG`, uid 1000 and tini as PID 1; `docker run --init` on top harmless; `/bin/bash` is no
verb (every argument through the door is rho's); rg/fd/jq/uv on the prefix's PATH, gh and mise in the
base; the bootsnap cache prewarmed, 0700; no source tree, no downloads and no baked home on the layer;
the packaged WebUI HTML and assets served in `full` and `agent` modes, and no page in `runner` or
`api_only` mode;
a double-forked orphan under a killed group leader is reaped by tini (counted BEFORE the stop);
`docker stop` returns inside the grace period; the root door — a `--user 0 server` over a bind-mounted
home this user owns boots, announces and answers `status`, the home root's from inside, and on a named
volume (where ownership is real on Docker Desktop too) a `--user 0` boot over a home a default boot
populated as uid 1000 turns it root's, read from a third container, root's 0600 log closed to uid 1000
(an EMPTY volume would not do: docker re-copies the image dir's uid-1000 owner over it on every mount); `compose.yml` validates; the evals Dockerfile pins its
platform. `RHO_INSTALL_TEST_TARGETS="rho toolchains"` also verifies smaller targets with their timings.
The release-image smoke runs with no network as uid 1000: C/Go/Rust compilation, Node/pnpm
execution, Rust formatting/linting, Python static checks, imports and project virtualenv
precedence, real DOCX/XLSX/PPTX creation/reopening,
LibreOffice PDF conversion (including formula recalculation), PDF text extraction, PNG rendering,
CJK font availability, and interaction/screenshot through `Rho::Browser::Driver`.
The test lives under `install/test`; no test support is copied into the runtime image.

hadolint (`docker run --rm -i hadolint/hadolint:latest-alpine hadolint - < install/docker/Dockerfile`)
is clean; the three deliberate ignores are inline with their reasons (apt versions are Ubuntu's, the
manifest lists split on purpose, the evals base's `--platform` is the point).

## Entrypoint and process groups

`ENTRYPOINT ["/usr/bin/tini", "--", "/opt/rho/libexec/docker-entrypoint"]`, `CMD ["server"]` — one
path. The entrypoint (`install/docker-entrypoint`, copied into `libexec/` by the installer) execs
`$prefix/bin/rho "$@"` and appends `--display-name "$RHO_DISPLAY_NAME"` on `server`. tini is PID 1
without `-g`: `docker stop` sends TERM to tini, tini forwards it to rho alone, rho's trap in `exe/rho
server` runs `daemon.stop` (which kills the process groups it owns), and tini reaps every orphan a
killed group leader leaves — the case the process-group note names (a group of only zombies answers
EPERM to `kill(-pgid)`; a reaper is what makes them go away). `docker run --init` adds a second tini
in front; harmless.

The mode is a boot fact: `RHO_MODE=runner` is the image's environment, `CMD ["server"]` carries no
`--mode`, so `-e RHO_MODE=full` turns the same image into the full-mode deployment (a `--mode` on the
CMD would outrank the environment and take that away).

The root door (the postgres/redis entrypoint pattern): a container run as root (`docker run --user 0`;
terminal-bench's images assume it) gets a root-owned state — when `id -u` is 0 and `$RHO_HOME` is not
root's, the entrypoint `chown -R 0:0 "$RHO_HOME"` before the exec. rho's floor stands (the state
directory must be the current user's, `Rho::StateFile`); the door moves the home's owner to meet it.
It is a bind mount on native Linux that needs this — the host dir keeps its owner there, and rho's
boot was refused at once (`daemon.boot_failed … must be owned by the current user`); a named volume
starts as the image's uid 1000 and Docker Desktop maps a bind mount's owner to the container's user.
uid 1000 sees no change.

## What is deliberately not here

- No `sudo`, no root path: the prefix, `/opt/mise`, `/opt/uv`, `/var/lib/rho` and `/home/runner` are uid
  1000's; only the apt steps and the two `/usr/local/bin` binaries are root's, at build.
- No `EXPOSE`: the runner dials out. The full-mode console is published by the deployment
  (`compose.yml`'s `rho-full`), on the host's loopback. The wider internal bind uses the
  explicit plaintext transport option and browser access requires Nexus OAuth login.
  Configure `RHO_PUBLIC_URL`, the browser-visible `RHO_NEXUS_PUBLIC_URL`, and the exact
  `RHO_PUBLIC_URL/auth/callback` redirect in Nexus. The internal `RHO_NEXUS_URL` may differ.
- No egress firewall: a deployment's choice (`NET_ADMIN` + the references' iptables script), not the
  image's.
- No `CODEX_ENV_*` version switch: mise reads the project's own `.ruby-version` / `.nvmrc` /
  `.tool-versions`; the manifest's defaults apply where a project names nothing.
- No Swift, no PHP, no Erlang, no LLVM nightly, no pyenv/nvm/pipx: one manager (mise) and uv.
- `rho update` inside a container refuses (the image rolls: `docker compose pull && docker compose up -d`); `rho update --add-rows --profile dev`
  is how the `browser` target adds its rows and works the same by hand.
