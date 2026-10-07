# syntax=docker/dockerfile:1
#
# THE RHO IMAGE : one image
# derived from openai/codex-universal brought current, on ubuntu:26.04,
# built by THE SAME install.sh a person runs on a host — from the packaged
# trees COPYed out of the checkout (`--from-checkout`, never a release
# archive), into /opt/rho as uid 1000. Four targets, built from the REPO
# ROOT (the root .dockerignore whitelists the packaged trees and install/):
#
# base ubuntu:26.04 + the manifest's apt core, tini, uid 1000 `rho`,
# mise and gh (manifest-pinned tarballs) ~ what OQ-3 B would tag -slim
# rho base + install.sh (profile full: portable Ruby, the gems, rg,
# fd, jq, uv), the entrypoint, `rho doctor --strict` the pure-runner runtime
# toolchains rho + the project's world: mise's Node LTS/Go/Rust stable,
# uv's Python + tools; mise installs other project runtimes on demand
# => ghcr.io/jasl/rho:<branch>
# browser toolchains + Cowork libraries, Office conversion and fonts,
# Chromium's shared libraries (the manifest's
# apt.chromium.ubuntu26.04 list, never `playwright install-deps`)
# + the installer's dev rows (Node, playwright-core, the shell)
# => docker.io/jasl123/cybros-rho:<release> and ghcr.io/jasl/rho:<branch>-browser
#
# docker build -f install/docker/Dockerfile --target browser -t rho:dev .
# docker buildx build -f install/docker/Dockerfile --target toolchains \
# --platform linux/amd64,linux/arm64 -t ghcr.io/jasl/rho:release --push.
#
# No version number and no package name lives in this file: every RUN
# that needs one sources install/manifest.sh (rendered from
# install/manifest.json by `rake install:render`; `rake install:check`
# refuses a stale copy). The base tag is the one ARG, checked against the
# manifest's `toolchains.base` at the first step.
#
# Runs RHO_MODE=runner by default (`server` is the CMD; the environment selects the mode); `-e RHO_MODE=full`
# makes the same image the full-mode deployment — an image is not a mode.
# No EXPOSE: the runner dials out to Nexus and is never dialled into.
# tini is PID 1 (the process-group rule): TERM reaches rho
# alone, rho stops the groups it owns, tini reaps the orphans.

ARG UBUNTU_TAG=26.04

# ---------------------------------------------------------------------------
FROM ubuntu:${UBUNTU_TAG} AS base
ARG TARGETARCH
# Every RUN below is bash under pipefail: a `curl | sha256sum -c` whose
# fetch failed is a failed step, not a passed one.
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ENV LANG=C.UTF-8 \
    DEBIAN_FRONTEND=noninteractive

# The apt core from the manifest (Ubuntu's own versions — the manifest pins what the checkout does not, hadolint's DL3008 is the distro's call); the base tag checked against the manifest so the ARG and
# `toolchains.base` cannot drift. $RHO_APT_IMAGE splits on purpose.
# hadolint ignore=DL3008,SC2086
RUN --mount=type=bind,source=install/manifest.sh,target=/tmp/rho-manifest.sh \
    set -eu; . /tmp/rho-manifest.sh; . /etc/os-release; \
    [ "$ID:$VERSION_ID" = "$RHO_IMAGE_BASE" ] || { echo "this base is $ID:$VERSION_ID, the manifest says $RHO_IMAGE_BASE"; exit 1; }; \
    apt-get update -qq; \
    apt-get install -y --no-install-recommends $RHO_APT_IMAGE; \
    rm -rf /var/lib/apt/lists/*; \
    /usr/bin/tini --version

# mise and gh: manifest-pinned tarballs, verified by sha256 (their apt repos
# pin nothing by version). Into /usr/local/bin as root; nothing else here
# is root's. The four row fields are read by eval from the manifest's
# variables (bash 3.2's indirection, as install.sh does it).
# hadolint ignore=SC2154
RUN --mount=type=bind,source=install/manifest.sh,target=/tmp/rho-manifest.sh \
    set -eu; . /tmp/rho-manifest.sh; \
    case "$TARGETARCH" in amd64) key=linux_x64 ;; arm64) key=linux_arm64 ;; *) echo "no rows for $TARGETARCH"; exit 1 ;; esac; \
    for tool in MISE GH; do \
      eval "url=\$RHO_TOOLCHAIN_${tool}_${key}_URL"; eval "sha=\$RHO_TOOLCHAIN_${tool}_${key}_SHA256"; \
      eval "member=\$RHO_TOOLCHAIN_${tool}_${key}_MEMBERS"; eval "into=\$RHO_TOOLCHAIN_${tool}_INTO"; \
      echo "==> $url"; \
      curl -fsSL --retry 3 -o /tmp/tool.tar.gz "$url"; \
      echo "$sha  /tmp/tool.tar.gz" | sha256sum -c -; \
      mkdir -p /tmp/tool; tar -xzf /tmp/tool.tar.gz -C /tmp/tool "$member"; \
      install -m 755 "/tmp/tool/$member" "$into/$(basename "$member")"; \
      rm -rf /tmp/tool /tmp/tool.tar.gz; \
    done; \
    mise --version; gh --version

# uid 1000 `rho` (ubuntu:24.04+ ships an `ubuntu` user on that uid: it goes),
# the three roots it owns, the work dir, the home volume's mount point.
RUN set -eu; \
    userdel -r ubuntu 2>/dev/null || true; \
    groupadd --gid 1000 rho; \
    useradd --uid 1000 --gid 1000 --create-home --shell /bin/bash rho; \
    mkdir -p /opt/rho /opt/mise /opt/uv /var/lib/rho /home/runner; \
    chown -R rho:rho /opt/rho /opt/mise /opt/uv /var/lib/rho /home/runner

# The image's environment: rho's prefix first on PATH (an image is rho's
# world entirely, unlike a host where only the launcher is exposed), then
# mise's shims and uv's tool bin. mise reads the project's own version files
# (`.ruby-version`, `.nvmrc`, `.tool-versions`: a coding agent lands in the project's version, the way a person does — codex-universal's env switch is dropped); every config under / is trusted because the container
# IS the isolation (the agent runs the project's commands anyway).
ENV PATH=/opt/rho/bin:/opt/mise/shims:/opt/uv/bin:/opt/mise/cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    RHO_TOOLS_ROOT=/home/runner \
    MISE_DATA_DIR=/opt/mise \
    MISE_CONFIG_DIR=/opt/mise/config \
    MISE_CACHE_DIR=/opt/mise/cache \
    MISE_STATE_DIR=/opt/mise/state \
    MISE_TRUSTED_CONFIG_PATHS=/ \
    MISE_YES=1 \
    MISE_RUBY_COMPILE=false \
    MISE_NODE_DEFAULT_PACKAGES_FILE=/opt/mise/default-npm-packages \
    RUSTUP_HOME=/opt/mise/rustup \
    CARGO_HOME=/opt/mise/cargo \
    GOTOOLCHAIN=auto \
    UV_PYTHON_INSTALL_DIR=/opt/uv/python \
    UV_TOOL_DIR=/opt/uv/tools \
    UV_TOOL_BIN_DIR=/opt/uv/bin \
    UV_NO_MODIFY_PATH=1

# The tools' default workspace is separate from rho's state and the OS user's HOME.
WORKDIR /home/runner

# ---------------------------------------------------------------------------
FROM base AS rho
ARG TARGETARCH
LABEL org.opencontainers.image.source="https://github.com/jasl/cybros.ai" \
      org.opencontainers.image.description="rho: the Cybros agent, runner mode by default (RHO_MODE=full for the agent half)"

# The packaged trees and the installer, as the checkout `--from-checkout` reads
# them (the copy excludes .git, tmp, log, vendor/bundle itself).
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
# RHO_HOME on a volume; the bootsnap cache on the image layer (the volume starts empty, so a home-rooted cache would pay the cold boot on every fresh volume; the image's paths never move); runner mode.
ENV RHO_MODE=runner \
    RHO_HOME=/var/lib/rho \
    RHO_PREFIX=/opt/rho \
    RHO_BOOTSNAP_CACHE_DIR=/opt/rho/cache/bootsnap

# THE SAME install.sh: profile full (portable Ruby, the lock's bundler, the
# gems built against it here, rg, fd, jq, uv; the entrypoint beside it
# lands in libexec/), the launcher into rho's own ~/.local/bin (the prefix
# is on PATH already), the PATH line printed and ignored. The verified
# downloads live in a build cache, never in the layer.
RUN --mount=type=cache,id=rho-downloads-${TARGETARCH},target=/opt/rho/cache/downloads,uid=1000,gid=1000 \
    set -eu; \
    printf 'gem: --no-document\n' > "$HOME/.gemrc"; \
    NONINTERACTIVE=1 RHO_PROFILE=full RHO_LAUNCHER_DIR=/home/rho/.local/bin \
      bash /rho/src/install/install.sh --from-checkout /rho/src; \
    rm -rf /rho/src /opt/rho/.install.lock "$HOME/.bundle/cache" \
      /opt/rho/ruby/*/share/ri /opt/rho/ruby/*/lib/ruby/gems/*/doc \
      /opt/rho/ruby/*/lib/ruby/gems/*/cache \
      /opt/rho/versions/*/vendor/bundle/ruby/*/cache
VOLUME /var/lib/rho

# The build-time verify (codex-universal's verify.sh, one checklist for
# both worlds): every receipt row answers, or the build fails.
RUN rho doctor --strict

# A published image carries its matching standalone stack installer.
COPY --chmod=755 install/stack/install.sh /usr/local/share/cybros/install.sh

# Both commands use the installer's portable Ruby and the same locked bundle.
RUN cmctl --help

ENTRYPOINT ["/usr/bin/tini", "--", "/opt/rho/libexec/docker-entrypoint"]
CMD ["server"]

# ---------------------------------------------------------------------------
FROM rho AS toolchains
ARG TARGETARCH
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
# The project's world, as uid 1000 under /opt/mise and
# /opt/uv: Node LTS with the default packages, Go and one minimal Rust
# stable toolchain with formatting/linting; uv's Python and its tools.
# Other project runtimes can be installed with mise or uv. What mise and uv
# fetch is verified by them (the manager-verified class), not by the
# manifest. The tool lists split on purpose.
# hadolint ignore=SC2086
RUN --mount=type=bind,source=install/manifest.sh,target=/tmp/rho-manifest.sh \
    --mount=type=cache,id=mise-cache-${TARGETARCH},target=/opt/mise/cache,uid=1000,gid=1000 \
    set -eu; . /tmp/rho-manifest.sh; \
    [ "$(mise --version | cut -d' ' -f1)" = "$RHO_TOOLCHAIN_MISE_VERSION" ] || { echo "mise $(mise --version) is not the manifest's $RHO_TOOLCHAIN_MISE_VERSION"; exit 1; }; \
    [ "$RHO_TOOLCHAIN_MISE_RUBY_COMPILE" = "false" ] && [ "$MISE_RUBY_COMPILE" = "false" ]; \
    printf "%s\n" $RHO_TOOLCHAIN_NPM_DEFAULT_PACKAGES > "$MISE_NODE_DEFAULT_PACKAGES_FILE"; \
    for tool in $RHO_TOOLCHAIN_MISE_TOOLS; do \
      case "$tool" in \
        rust@*) mise use --global --tool-option "profile=$RHO_TOOLCHAIN_RUST_PROFILE" \
          --tool-option "components=$RHO_TOOLCHAIN_RUST_COMPONENTS" "$tool" ;; \
        *) mise use --global "$tool" ;; \
      esac; \
    done; \
    mise reshim; \
    mise ls; \
    npm install --global --prefix /opt/rho $RHO_NATIVE_CODING_PACKAGES; \
    t3 --version; codex --version; claude --version; \
    node --version; pnpm --version; go version; rustc --version; cargo fmt --version; cargo clippy --version; \
    rm -rf "$HOME/.npm" /tmp/node-compile-cache; \
    rm -rf /opt/mise/state/*.log "$MISE_CONFIG_DIR"/*.lock 2>/dev/null || true

# hadolint ignore=SC2086
RUN --mount=type=bind,source=install/manifest.sh,target=/tmp/rho-manifest.sh \
    --mount=type=cache,id=uv-cache-${TARGETARCH},target=/opt/uv/cache,uid=1000,gid=1000 \
    set -eu; . /tmp/rho-manifest.sh; \
    export UV_CACHE_DIR=/opt/uv/cache; \
    uv python install $RHO_TOOLCHAIN_UV_PYTHON; \
    for tool in $RHO_TOOLCHAIN_UV_TOOLS; do \
      uv tool install --python "$RHO_TOOLCHAIN_UV_PYTHON" --managed-python --no-python-downloads "$tool"; \
    done; \
    uv python list --only-installed; python3 --version; ruff --version

RUN rho doctor --strict

# ---------------------------------------------------------------------------
FROM toolchains AS browser
# Office converters and fonts, plus Chromium's shared libraries by name from the manifest (OQ-2: never
# `playwright install-deps`, whose distro table may lag 26.04), as root;
# then the installer's dev rows as uid 1000 — Node into lib/playwright/node,
# playwright-core at the gem's version, the headless shell under
# /opt/rho/browsers (HTTPS-only: the one row nothing pins, named). The rows
# already present skip by sha. The browser extension registers when
# `plugins["rho.browser"].enabled` is true in the home's settings.json.
# hadolint ignore=DL3066
USER root
# hadolint ignore=DL3008,SC2086
RUN --mount=type=bind,source=install/manifest.sh,target=/tmp/rho-manifest.sh \
    set -eu; . /tmp/rho-manifest.sh; \
    apt-get update -qq; \
    apt-get install -y --no-install-recommends $RHO_APT_CHROMIUM_ubuntu26_04 $RHO_APT_COWORK; \
    rm -rf /var/lib/apt/lists/*; \
    mkdir -p /opt/cowork; chown rho:rho /opt/cowork
USER 1000:1000
ARG TARGETARCH
# Default Python for file work. Activating a project's own virtualenv prepends
# its bin directory normally; no global VIRTUAL_ENV or PYTHONPATH is imposed.
ENV PATH=/opt/cowork/bin:${PATH}
COPY install/docker/workspace-tools.md /usr/local/share/cybros/workspace-tools.md
RUN --mount=type=bind,source=install/manifest.sh,target=/tmp/rho-manifest.sh \
    --mount=type=bind,source=install/docker/cowork-requirements.txt,target=/tmp/cowork-requirements.txt \
    --mount=type=cache,id=uv-cache-${TARGETARCH},target=/opt/uv/cache,uid=1000,gid=1000 \
    set -eu; . /tmp/rho-manifest.sh; \
    export UV_CACHE_DIR=/opt/uv/cache; \
    uv venv --python "$RHO_COWORK_PYTHON" --managed-python --no-python-downloads /opt/cowork; \
    uv pip sync --python /opt/cowork/bin/python --only-binary :all: /tmp/cowork-requirements.txt; \
    uv pip check --python /opt/cowork/bin/python
RUN --mount=type=cache,id=rho-downloads-${TARGETARCH},target=/opt/rho/cache/downloads,uid=1000,gid=1000 \
    set -eu; \
    NONINTERACTIVE=1 bash /opt/rho/libexec/install.sh --add-rows --profile dev; \
    rm -rf /opt/rho/.install.lock
RUN rho doctor --strict
