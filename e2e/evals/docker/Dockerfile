# syntax=docker/dockerfile:1

# Build the task's image with rho inside. FROM uses the task's base — the BUILD
# argument names it, tagged: an Agents-on-Rails app image
# (`ghcr.io/evilmartians/lemans-writebook:v1.2.1` or `lemans-fizzy:8112b3d`,
# `E2E::Evals::DockerBases::IMAGES`; `:latest` does not exist on ghcr) or a
# terminal-bench base (`alexgshaw/<name>:20251031` on Docker Hub, one per
# task) — and THE SAME install.sh a host runs, profile `runner`, into
# /opt/rho as uid 1000. The runner serves the image's tree (its WorkingDir:
# `/app`, `/app/dclm` for one of the 21; the rails patch applied there with
# `git apply` before the turn) to a full-mode rho on the host that names it
# by `rho do --runner`. terminal-bench runs the container as ROOT (`docker
# run --user 0`: harbor's parity — several of the 21 assume it, and their
# verifier apt-installs) over this uid-1000 build; the installer's own
# root guard reads BuildKit's RUN as no container, so the image is never
# built as root.
#
# THE APP TREE'S OWNER IS THE FAMILY'S (the second BUILD argument,
# `APP_OWNER`): the rails family's `git apply` runs as uid 1000, so its
# derivation chowns the base's root-owned `/app` to `1000:1000` (the
# default); terminal-bench's container runs as root over harbor's
# root-owned tree, and its derivation passes `APP_OWNER=base` so the
# chown of /app is SKIPPED and the tree keeps the base's owner, byte-
# and owner-identical to harbor's. git ≥ 2.35.2 refuses a repository
# another uid owns ("dubious ownership"): a 1000-owned `/app/dclm`
# under a root container made sanitize-git-repo's verifier raise before
# comparing a file, and every pass on it
# depended on the model adding `safe.directory` itself. /opt/rho and
# /var/lib/rho are rho's own and stay uid 1000's on every base. The
# image TAG carries the owner when it is not the default, so two
# derivations of one base never share a tag.
#
#   docker build --platform linux/amd64 -f e2e/evals/docker/Dockerfile \
#     --build-arg BASE=ghcr.io/evilmartians/lemans-writebook:v1.2.1 --build-arg APP_OWNER=1000:1000 -t rho-evals-writebook .
#   docker build --platform linux/amd64 -f e2e/evals/docker/Dockerfile \
#     --build-arg BASE=alexgshaw/chess-best-move:20251031 --build-arg APP_OWNER=base \
#     -t rho-evals-alexgshaw-chess-best-move-20251031-app-owner-base .
#
# `E2E::Evals::Docker.build_argv(base:, app_owner:)` spells exactly that
# (the lane derives the owner from the task's `container_user`);
# `run_argv` the container (`server --bind 0.0.0.0 --port N` published on
# the host's loopback, the home bind-mounted so the announcement and the
# pairing are readable from the harness; `--network host` on a Linux host).
#
# WHY THE INSTALLER AND NOT `COPY --from=ghcr.io/jasl/rho /opt/rho` (the
# prebuilt image): the rho image compiles its native gems on
# ubuntu:26.04 (glibc 2.43); their bases are Debian-class Ruby 3.4 images
# whose glibc is older, and an extension built with a newer glibc's headers
# (`__isoc23_*` symbols) does not load on an older one. Running the
# installer here builds the extensions against THIS base's libc; the
# portable Ruby, rg and fd are the manifest's pinned artifacts either way,
# and `bundle install` runs once, against their compiler.
#
# The task bases use linux/amd64, so every FROM fixes that platform;
# an arm64 host emulates instead of mixing architectures.
#
# What the rails bases are (read off ghcr's configs): root, `WORKDIR /app`,
# `GEM_HOME=/usr/local/bundle`, `LANG=C.UTF-8`, no ENTRYPOINT. The 21
# terminal-bench bases are Debian/Ubuntu too (`python:3.13-slim-bookworm`
# ×12, `ubuntu:24.04` ×8, `python:3.11-slim` ×1 — apt-get on every one, the
# lane's pre-flight; no `cc` on the slim ones, installed below). So: uid
# 1000 is created here, /app is chowned to it for `git apply` WHEN the
# family's owner says so, and rho's prefix never meets their Ruby or
# their Python.

ARG BASE
# hadolint ignore=DL3029
FROM --platform=linux/amd64 ${BASE}

# hadolint ignore=DL3066
USER root

# The installer's own apt prerequisites row (bash, git, curl, build-
# essential, pkg-config, libssl-dev: the five native gems build against
# this base's libc and OpenSSL headers) plus tini (PID 1, the process-group
# rule), read from the manifest like the rho image does. Debian's own
# versions (DL3008); the list splits on purpose.
# hadolint ignore=DL3008,SC2086
RUN --mount=type=bind,source=install/manifest.sh,target=/tmp/rho-manifest.sh \
    set -eu; . /tmp/rho-manifest.sh; \
    apt-get update -qq; \
    apt-get install --no-install-recommends -y $RHO_APT_PREREQUISITES tini; \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/archives

# uid 1000 `rho`, owning the prefix, the home's mount point and — for the
# family whose container runs as it — the app tree (root-owned in the
# base; the rails `git apply` runs as this uid). The rails bases have no
# user on 1000 (created here); `ubuntu:24.04` — eight of the 21 terminal-
# bench bases — ships `ubuntu` on uid/gid 1000 (proof 1 on
# chess-best-move: `groupadd: GID '1000' already exists`, exit 4), so an
# existing 1000 is RENAMED to `rho` with its home moved to /home/rho
# (`RHO_LAUNCHER_DIR` below) — the uid is what the recipe needs, never the
# base's name for it; harbor runs the agent as root and no task names the
# base's user. APP_OWNER: `<uid>:<gid>` chowns /app to it; the word
# `base` leaves /app exactly as the base made it (terminal-bench: root's,
# the user its container runs as — git refuses a tree another uid owns).
ARG APP_OWNER=1000:1000
RUN set -eu; \
    if getent group 1000 >/dev/null; then groupmod --new-name rho "$(getent group 1000 | cut -d: -f1)"; \
    else groupadd --gid 1000 rho; fi; \
    if getent passwd 1000 >/dev/null; then \
      usermod --login rho --home /home/rho --move-home --shell /bin/bash "$(getent passwd 1000 | cut -d: -f1)"; \
    else useradd --uid 1000 --gid 1000 --create-home --shell /bin/bash rho; fi; \
    mkdir -p /opt/rho /var/lib/rho /app; \
    chown -R 1000:1000 /opt/rho /var/lib/rho; \
    case "$APP_OWNER" in base) ;; *) chown -R "$APP_OWNER" /app ;; esac

# The packaged trees and the installer, from the repo-root context.
COPY --chown=1000:1000 sdks/ruby /rho/src/sdks/ruby
COPY --chown=1000:1000 cmctl /rho/src/cmctl
COPY --chown=1000:1000 agents/rho/rho-runner /rho/src/agents/rho/rho-runner
COPY --chown=1000:1000 agents/rho/rho-browser /rho/src/agents/rho/rho-browser
COPY --chown=1000:1000 agents/rho/rho-mcp /rho/src/agents/rho/rho-mcp
COPY --chown=1000:1000 agents/rho/rho-web-tools /rho/src/agents/rho/rho-web-tools
COPY --chown=1000:1000 agents/rho/rho-codemode /rho/src/agents/rho/rho-codemode
COPY --chown=1000:1000 agents/rho/rho-webui /rho/src/agents/rho/rho-webui
COPY --chown=1000:1000 agents/rho/rho-ingress-telegram /rho/src/agents/rho/rho-ingress-telegram
COPY --chown=1000:1000 agents/rho/rho-acp /rho/src/agents/rho/rho-acp
COPY --chown=1000:1000 agents/rho/rho-acp-client /rho/src/agents/rho/rho-acp-client
COPY --chown=1000:1000 agents/rho/rho-t3 /rho/src/agents/rho/rho-t3
COPY --chown=1000:1000 agents/rho/rho /rho/src/agents/rho/rho
COPY --chown=1000:1000 install /rho/src/install

USER 1000:1000
# RUNNER MODE, ITS HOME ON A VOLUME (rho's own image, verbatim); the
# prefix first on PATH so `docker exec … rho status` works; the bootsnap
# cache on the layer.
ENV RHO_MODE=runner \
    RHO_HOME=/var/lib/rho \
    RHO_PREFIX=/opt/rho \
    RHO_BOOTSNAP_CACHE_DIR=/opt/rho/cache/bootsnap \
    PATH=/opt/rho/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

RUN --mount=type=cache,id=rho-downloads-amd64,target=/opt/rho/cache/downloads,uid=1000,gid=1000 \
    set -eu; \
    NONINTERACTIVE=1 RHO_PROFILE=runner RHO_LAUNCHER_DIR=/home/rho/.local/bin \
      bash /rho/src/install/install.sh --from-checkout /rho/src; \
    rm -rf /rho/src /opt/rho/.install.lock

# Harbor's `acp:rho`
# cell execs this launcher as its `local` distribution — with no
# announcement live it starts a full-mode daemon (all three fds
# redirected), writes the pairing document for the harness's sidecar,
# waits for the workspace, then execs `rho-acp`. After the install, so the
# prefix's libexec exists; its own layer, so a launcher edit never
# rebuilds the install. The root .dockerignore lets this one file through.
COPY --chown=1000:1000 e2e/evals/docker/rho-acp-launch /opt/rho/libexec/rho-acp-launch
VOLUME /var/lib/rho
WORKDIR /app

RUN rho doctor --strict

ENTRYPOINT ["/usr/bin/tini", "--", "/opt/rho/libexec/docker-entrypoint"]
CMD ["server"]
