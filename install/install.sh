#!/bin/bash
# Generated from install/src/*.sh and manifest.json by rake install:render. Do not edit this output.
# rho's installer — one file, readable before it runs.
#
#   git clone https://github.com/jasl/cybros.ai.git && bash cybros.ai/install/install.sh
#
# Checks the prerequisites it never installs
# (git, bash, curl, tar, a C compiler), then, into a prefix YOU own
# (default ~/.local/share/rho, never sudo), unpacks Homebrew's portable
# Ruby 4.0.7 bottle (sha256-pinned, the sha IS the download address),
# installs the lock's bundler into it, copies rho's packaged gem trees out of
# the checkout this script sits in and runs `bundle install --deployment`
# there, adds the tool rows of the chosen profile (rg, fd; jq, uv; Node +
# playwright-core + the Chromium headless shell), writes the wrapper
# bin/rho and links ~/.local/bin/rho. Every download is pinned in the
# manifest block below (rendered from install/manifest.json by `rake
# install:render`). The app has ONE source, a checkout: `rho update`
# fast-forwards it and re-runs the checkout's own copy of this script, so
# the script that runs is the one you can read in the commits it just
# pulled.
#
# Verification classes, stated plainly: manifest-pinned sha256 (the Ruby,
# rg, fd, jq, uv, Node, playwright-core); manager-verified (the gems, by
# bundler's CHECKSUMS in the lock); git (the app: the checkout's commit,
# recorded in the receipt as app.commit); HTTPS-only (the Chromium shell,
# downloaded by playwright-core, which verifies no hash).
#
# Modes:  (none)        install from the checkout (re-run: rows already at the manifest's sha are skipped)
#         --update      `git pull --ff-only` the checkout this install came from, then run ITS install.sh (rho update)
#         --rollback    repoint `current` at the previous (ruby, gems) pair (rho update --rollback)
#         --add-rows    add the profile's missing tool rows from THIS script (the image's use)
#         --uninstall   remove the launcher, the rc line, the prefix (rho uninstall; --purge: RHO_HOME too)
#         --dry-run     print the plan and the exact URLs (install), or the commits an update would pull
#                       and the script it would then run (--update); change nothing
# Knobs (environment or flag): RHO_PROFILE / --profile runner|full|dev (default full);
#   RHO_PREFIX / --prefix DIR; RHO_HOME (untouched, printed); RHO_SOURCE / --from-checkout DIR
#   (the checkout to install the packaged trees from; default: the one this script sits in);
#   NONINTERACTIVE / CI / --non-interactive; RHO_MODIFY_PATH=1 / --modify-path
#   (write the rc line: by default it is PRINTED); RHO_ARTIFACT_DOMAIN (a mirror tried first: the same
#   path under your domain); RHO_NO_BOOTSNAP; RHO_BOOTSNAP_CACHE_DIR (baked into the wrapper);
#   RHO_LAUNCHER_DIR (default ~/.local/bin); RHO_DOWNLOAD_CACHE (default <prefix>/cache/downloads).
#
# bash 3.2 (macOS) is enough: no associative arrays, no mapfile.
# shellcheck disable=SC2034  # the manifest and receipt variables are read by indirect expansion
set -u

# ---------------------------------------------------------------------------
# Guards a shell can fail before any function exists (Homebrew's).
if [ -z "${BASH_VERSION:-}" ]; then
  printf "%s\n" "rho install: bash is required to interpret this script" >&2
  exit 1
fi
if [ -n "${POSIXLY_CORRECT+1}" ]; then
  printf "%s\n" "rho install: bash must not run in POSIX mode; unset POSIXLY_CORRECT" >&2
  exit 1
fi
if [ -n "${INTERACTIVE-}" ] && [ -n "${NONINTERACTIVE-}" ]; then
  printf "%s\n" "rho install: both INTERACTIVE and NONINTERACTIVE are set; pick one" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Output (Homebrew's idioms): colours only on a TTY, every command echoed
# before it runs, one abort function.
if [ -t 1 ]; then
  tty_blue=$(printf '\033[34m'); tty_bold=$(printf '\033[1m'); tty_red=$(printf '\033[31m'); tty_reset=$(printf '\033[0m')
else
  tty_blue=""; tty_bold=""; tty_red=""; tty_reset=""
fi

shell_join() {
  local arg
  printf "%s" "$1"
  shift
  for arg in "$@"; do
    printf " "
    printf "%s" "${arg// /\ }"
  done
}

abort() { printf "%s\n" "$@" >&2; exit 1; }
ohai() { printf "%s==>%s %s%s\n" "$tty_blue" "$tty_bold" "$(shell_join "$@")" "$tty_reset"; }
warn() { printf "%sWarning%s: %s\n" "$tty_red" "$tty_reset" "$1" >&2; }
execute() {
  if ! "$@"; then
    abort "$(printf "Failed during: %s" "$(shell_join "$@")")"
  fi
}
# Echo, then run — unless --dry-run, which prints alone.
run() {
  ohai "$@"
  [ -n "$DRY_RUN" ] && return 0
  execute "$@"
}

# ---------------------------------------------------------------------------
# THE MANIFEST, as shell variables. Rendered from install/manifest.json by
# `rake install:render`; `rake install:check` fails when the two differ.
# >>> rho manifest (rendered from install/manifest.json by `rake install:render`; do not edit by hand)
# shellcheck disable=SC2034
RHO_MANIFEST_VERSION="1"
RHO_MANIFEST_GENERATED="2026-09-18"
RHO_PLATFORMS="darwin-arm64 darwin-x64 linux-x64 linux-arm64"
RHO_PROFILES="runner full dev"
RHO_APP_TREES="sdks/ruby cmctl agents/rho/rho-runner agents/rho/rho-browser agents/rho/rho-mcp agents/rho/rho-web-tools agents/rho/rho-codemode agents/rho/rho-webui agents/rho/rho-ingress-telegram agents/rho/rho-acp agents/rho/rho-acp-client agents/rho/rho-t3 agents/rho/rho"
RHO_APP_ENTRY="agents/rho/rho/exe/rho"
RHO_APP_GEMFILE="agents/rho/rho/Gemfile"
RHO_APP_BUNDLE_WITHOUT="development:test"
RHO_RUBY_VERSION="4.0.7"
RHO_RUBY_BUNDLER="4.0.22"
RHO_RUBY_HEADER="Authorization: Bearer QQ=="
RHO_RUBY_darwin_arm64_TAG="arm64_big_sur"
RHO_RUBY_darwin_arm64_FILENAME="portable-ruby-4.0.7.arm64_big_sur.bottle.tar.gz"
RHO_RUBY_darwin_arm64_URL="https://ghcr.io/v2/homebrew/core/portable-ruby/blobs/sha256:e0088dff5614b39387300136ec7a5f95bf1e07589547245c919524fc9e8b4197"
RHO_RUBY_darwin_arm64_SHA256="e0088dff5614b39387300136ec7a5f95bf1e07589547245c919524fc9e8b4197"
RHO_RUBY_darwin_arm64_BYTES="12686106"
RHO_RUBY_darwin_x64_TAG="big_sur"
RHO_RUBY_darwin_x64_FILENAME="portable-ruby-4.0.7.big_sur.bottle.tar.gz"
RHO_RUBY_darwin_x64_URL="https://ghcr.io/v2/homebrew/core/portable-ruby/blobs/sha256:57bebadc864405cbd39743e32eef741f4b75c0ba121f5cd9296ab84994b9f83b"
RHO_RUBY_darwin_x64_SHA256="57bebadc864405cbd39743e32eef741f4b75c0ba121f5cd9296ab84994b9f83b"
RHO_RUBY_darwin_x64_BYTES="12241978"
RHO_RUBY_linux_x64_TAG="x86_64_linux"
RHO_RUBY_linux_x64_FILENAME="portable-ruby-4.0.7.x86_64_linux.bottle.tar.gz"
RHO_RUBY_linux_x64_URL="https://ghcr.io/v2/homebrew/core/portable-ruby/blobs/sha256:bf2a9bf102694d40084ed436b06a1566dded60a519f4d1879c90c81046e11081"
RHO_RUBY_linux_x64_SHA256="bf2a9bf102694d40084ed436b06a1566dded60a519f4d1879c90c81046e11081"
RHO_RUBY_linux_x64_BYTES="14350857"
RHO_RUBY_linux_arm64_TAG="arm64_linux"
RHO_RUBY_linux_arm64_FILENAME="portable-ruby-4.0.7.arm64_linux.bottle.tar.gz"
RHO_RUBY_linux_arm64_URL="https://ghcr.io/v2/homebrew/core/portable-ruby/blobs/sha256:c9b75dd6bd9578921f3ce739dacae8866698c3399c0f83574a5d5fadda2aab2d"
RHO_RUBY_linux_arm64_SHA256="c9b75dd6bd9578921f3ce739dacae8866698c3399c0f83574a5d5fadda2aab2d"
RHO_RUBY_linux_arm64_BYTES="14660663"
RHO_TOOLS="rg fd jq uv node playwright_core chromium"
RHO_TOOL_rg_NAME="rg"
RHO_TOOL_rg_VERSION="15.2.0"
RHO_TOOL_rg_PROFILES="runner full dev"
RHO_TOOL_rg_INTO="bin"
RHO_TOOL_rg_UNPACK="members"
RHO_TOOL_rg_darwin_arm64_URL="https://github.com/BurntSushi/ripgrep/releases/download/15.2.0/ripgrep-15.2.0-aarch64-apple-darwin.tar.gz"
RHO_TOOL_rg_darwin_arm64_SHA256="3750b2e93f37e0c692657da574d7019a101c0084da05a790c83fd335bad973e4"
RHO_TOOL_rg_darwin_arm64_MEMBERS="ripgrep-15.2.0-aarch64-apple-darwin/rg"
RHO_TOOL_rg_darwin_x64_URL="https://github.com/BurntSushi/ripgrep/releases/download/15.2.0/ripgrep-15.2.0-x86_64-apple-darwin.tar.gz"
RHO_TOOL_rg_darwin_x64_SHA256="af7825fcc69a2afc7a7aea55fc9af90e26421d8f20fe59df32e233c0b8a231c1"
RHO_TOOL_rg_darwin_x64_MEMBERS="ripgrep-15.2.0-x86_64-apple-darwin/rg"
RHO_TOOL_rg_linux_x64_URL="https://github.com/BurntSushi/ripgrep/releases/download/15.2.0/ripgrep-15.2.0-x86_64-unknown-linux-musl.tar.gz"
RHO_TOOL_rg_linux_x64_SHA256="33e15bcf1624b25cdd2a55813a47a2f95dbe126268203e76aa6a585d1e7b149c"
RHO_TOOL_rg_linux_x64_MEMBERS="ripgrep-15.2.0-x86_64-unknown-linux-musl/rg"
RHO_TOOL_rg_linux_arm64_URL="https://github.com/BurntSushi/ripgrep/releases/download/15.2.0/ripgrep-15.2.0-aarch64-unknown-linux-musl.tar.gz"
RHO_TOOL_rg_linux_arm64_SHA256="800b1e7206afe799dfb5a6901f23147cfaabe0e52210538100f61e86e1740915"
RHO_TOOL_rg_linux_arm64_MEMBERS="ripgrep-15.2.0-aarch64-unknown-linux-musl/rg"
RHO_TOOL_fd_NAME="fd"
RHO_TOOL_fd_VERSION="10.5.0"
RHO_TOOL_fd_PROFILES="runner full dev"
RHO_TOOL_fd_INTO="bin"
RHO_TOOL_fd_UNPACK="members"
RHO_TOOL_fd_darwin_arm64_URL="https://github.com/sharkdp/fd/releases/download/v10.5.0/fd-v10.5.0-aarch64-apple-darwin.tar.gz"
RHO_TOOL_fd_darwin_arm64_SHA256="b67e1836c468e42e411984b56e52fa7abec08c2bd22c867398e7cc134aac5e12"
RHO_TOOL_fd_darwin_arm64_MEMBERS="fd-v10.5.0-aarch64-apple-darwin/fd"
RHO_TOOL_fd_darwin_x64_URL="https://github.com/sharkdp/fd/releases/download/v10.5.0/fd-v10.5.0-x86_64-apple-darwin.tar.gz"
RHO_TOOL_fd_darwin_x64_SHA256="7e31028c62c6955877735d0406807aa484c2a5e6f86235a59e26c29c301da590"
RHO_TOOL_fd_darwin_x64_MEMBERS="fd-v10.5.0-x86_64-apple-darwin/fd"
RHO_TOOL_fd_linux_x64_URL="https://github.com/sharkdp/fd/releases/download/v10.5.0/fd-v10.5.0-x86_64-unknown-linux-musl.tar.gz"
RHO_TOOL_fd_linux_x64_SHA256="761c72dc8e120d85b22292063be8a796e2eeb20eb3e4f38b8fa2343ccf3514a7"
RHO_TOOL_fd_linux_x64_MEMBERS="fd-v10.5.0-x86_64-unknown-linux-musl/fd"
RHO_TOOL_fd_linux_arm64_URL="https://github.com/sharkdp/fd/releases/download/v10.5.0/fd-v10.5.0-aarch64-unknown-linux-musl.tar.gz"
RHO_TOOL_fd_linux_arm64_SHA256="d76c4317f7d5dba69f8a2a15856c90c777e7f0dd4e85f0de8c76de6992c374d4"
RHO_TOOL_fd_linux_arm64_MEMBERS="fd-v10.5.0-aarch64-unknown-linux-musl/fd"
RHO_TOOL_jq_NAME="jq"
RHO_TOOL_jq_VERSION="1.8.2"
RHO_TOOL_jq_PROFILES="full dev"
RHO_TOOL_jq_INTO="bin"
RHO_TOOL_jq_UNPACK="binary"
RHO_TOOL_jq_darwin_arm64_URL="https://github.com/jqlang/jq/releases/download/jq-1.8.2/jq-macos-arm64"
RHO_TOOL_jq_darwin_arm64_SHA256="2d75340ba57a4b4b4c8708a21c2dc8e958a48aaa8bba13b27f77f6e4c0eca07e"
RHO_TOOL_jq_darwin_arm64_MEMBERS="jq"
RHO_TOOL_jq_darwin_x64_URL="https://github.com/jqlang/jq/releases/download/jq-1.8.2/jq-macos-amd64"
RHO_TOOL_jq_darwin_x64_SHA256="e94b266e3c26690550006abe63152b782280f4e14374accdf04cbde844f00bc0"
RHO_TOOL_jq_darwin_x64_MEMBERS="jq"
RHO_TOOL_jq_linux_x64_URL="https://github.com/jqlang/jq/releases/download/jq-1.8.2/jq-linux-amd64"
RHO_TOOL_jq_linux_x64_SHA256="b1c22172dd303f3be49e935aa56aa48a8b7a46e0bc838b4997d3bb451495870f"
RHO_TOOL_jq_linux_x64_MEMBERS="jq"
RHO_TOOL_jq_linux_arm64_URL="https://github.com/jqlang/jq/releases/download/jq-1.8.2/jq-linux-arm64"
RHO_TOOL_jq_linux_arm64_SHA256="8b85c817833814ddca00a144c33705546355afccf0cf39b188f3cdb48b852309"
RHO_TOOL_jq_linux_arm64_MEMBERS="jq"
RHO_TOOL_uv_NAME="uv"
RHO_TOOL_uv_VERSION="0.12.13"
RHO_TOOL_uv_PROFILES="full dev"
RHO_TOOL_uv_INTO="bin"
RHO_TOOL_uv_UNPACK="members"
RHO_TOOL_uv_darwin_arm64_URL="https://github.com/astral-sh/uv/releases/download/0.12.13/uv-aarch64-apple-darwin.tar.gz"
RHO_TOOL_uv_darwin_arm64_SHA256="7e6ddb9316acc00f2296c82ff4d99977870ee34b2f0ddcae9444d714db9364ed"
RHO_TOOL_uv_darwin_arm64_MEMBERS="uv-aarch64-apple-darwin/uv uv-aarch64-apple-darwin/uvx"
RHO_TOOL_uv_darwin_x64_URL="https://github.com/astral-sh/uv/releases/download/0.12.13/uv-x86_64-apple-darwin.tar.gz"
RHO_TOOL_uv_darwin_x64_SHA256="5e287ef61cb6a9b61b3a83fef124fd143e400468a7dac794230147a810e17119"
RHO_TOOL_uv_darwin_x64_MEMBERS="uv-x86_64-apple-darwin/uv uv-x86_64-apple-darwin/uvx"
RHO_TOOL_uv_linux_x64_URL="https://github.com/astral-sh/uv/releases/download/0.12.13/uv-x86_64-unknown-linux-gnu.tar.gz"
RHO_TOOL_uv_linux_x64_SHA256="745765a3b6e360ad76743599ae5c42e9278c7edf8bbff9fc76d05bf2623a04dd"
RHO_TOOL_uv_linux_x64_MEMBERS="uv-x86_64-unknown-linux-gnu/uv uv-x86_64-unknown-linux-gnu/uvx"
RHO_TOOL_uv_linux_arm64_URL="https://github.com/astral-sh/uv/releases/download/0.12.13/uv-aarch64-unknown-linux-gnu.tar.gz"
RHO_TOOL_uv_linux_arm64_SHA256="2eaa5d94f5db7b3a1a092156b9420459e42ab0217d917fe74a876309cef9b5e9"
RHO_TOOL_uv_linux_arm64_MEMBERS="uv-aarch64-unknown-linux-gnu/uv uv-aarch64-unknown-linux-gnu/uvx"
RHO_TOOL_node_NAME="node"
RHO_TOOL_node_VERSION="24.21.0"
RHO_TOOL_node_PROFILES="dev"
RHO_TOOL_node_INTO="lib/playwright/node"
RHO_TOOL_node_UNPACK="tree"
RHO_TOOL_node_darwin_arm64_URL="https://nodejs.org/dist/v24.21.0/node-v24.21.0-darwin-arm64.tar.gz"
RHO_TOOL_node_darwin_arm64_SHA256="bed7eea5325e1108f32ce5228ddd6a5f0f08a499ee42aa7442aea583702f6057"
RHO_TOOL_node_darwin_arm64_MEMBERS=""
RHO_TOOL_node_darwin_x64_URL="https://nodejs.org/dist/v24.21.0/node-v24.21.0-darwin-x64.tar.gz"
RHO_TOOL_node_darwin_x64_SHA256="1462cb3b3046b815cf8ea436d3da450ec1a9f11dac7e5a46b0ada5305d7e8097"
RHO_TOOL_node_darwin_x64_MEMBERS=""
RHO_TOOL_node_linux_x64_URL="https://nodejs.org/dist/v24.21.0/node-v24.21.0-linux-x64.tar.xz"
RHO_TOOL_node_linux_x64_SHA256="fd8e59d5a511510f6a298afb548f18c7d2b1be404d8b4a27d94fbe49f56cb2d6"
RHO_TOOL_node_linux_x64_MEMBERS=""
RHO_TOOL_node_linux_arm64_URL="https://nodejs.org/dist/v24.21.0/node-v24.21.0-linux-arm64.tar.xz"
RHO_TOOL_node_linux_arm64_SHA256="6ad1325edbdb5649c379b75a237147a666c95d4f9ae8d340fef2d1575d289ad2"
RHO_TOOL_node_linux_arm64_MEMBERS=""
RHO_TOOL_playwright_core_NAME="playwright-core"
RHO_TOOL_playwright_core_VERSION="1.62.1"
RHO_TOOL_playwright_core_PROFILES="dev"
RHO_TOOL_playwright_core_INTO="lib/playwright/package"
RHO_TOOL_playwright_core_UNPACK="tree"
RHO_TOOL_playwright_core_all_URL="https://registry.npmjs.org/playwright-core/-/playwright-core-1.62.1.tgz"
RHO_TOOL_playwright_core_all_SHA256="954be1e183d0ddb9748fe0d2d08b0b66a9210c74dd75c397aeb70303b9f08a00"
RHO_TOOL_playwright_core_all_MEMBERS=""
RHO_TOOL_chromium_NAME="chromium"
RHO_TOOL_chromium_VERSION="headless-shell"
RHO_TOOL_chromium_PROFILES="dev"
RHO_TOOL_chromium_INTO="browsers"
RHO_TOOL_chromium_UNPACK="command"
RHO_TOOL_chromium_COMMAND="install --only-shell chromium"
RHO_APT_PREREQUISITES="bash ca-certificates curl git build-essential pkg-config libssl-dev xz-utils"
RHO_BREW_PREREQUISITES="git"
RHO_APT_CHROMIUM_DISTROS="ubuntu26_04 ubuntu24_04 debian13 debian12"
RHO_APT_CHROMIUM_ubuntu26_04="libasound2t64 libatk-bridge2.0-0t64 libatk1.0-0t64 libatspi2.0-0t64 libcairo2 libcups2t64 libdbus-1-3 libdrm2 libgbm1 libglib2.0-0t64 libnspr4 libnss3 libpango-1.0-0 libx11-6 libxcb1 libxcomposite1 libxdamage1 libxext6 libxfixes3 libxkbcommon0 libxrandr2"
RHO_APT_CHROMIUM_ubuntu24_04="libasound2t64 libatk-bridge2.0-0t64 libatk1.0-0t64 libatspi2.0-0t64 libcairo2 libcups2t64 libdbus-1-3 libdrm2 libgbm1 libglib2.0-0t64 libnspr4 libnss3 libpango-1.0-0 libx11-6 libxcb1 libxcomposite1 libxdamage1 libxext6 libxfixes3 libxkbcommon0 libxrandr2"
RHO_APT_CHROMIUM_debian13="libasound2t64 libatk-bridge2.0-0t64 libatk1.0-0t64 libatspi2.0-0t64 libcairo2 libcups2t64 libdbus-1-3 libdrm2 libgbm1 libglib2.0-0t64 libnspr4 libnss3 libpango-1.0-0 libx11-6 libxcb1 libxcomposite1 libxdamage1 libxext6 libxfixes3 libxkbcommon0 libxrandr2"
RHO_APT_CHROMIUM_debian12="libasound2 libatk-bridge2.0-0 libatk1.0-0 libatspi2.0-0 libcairo2 libcups2 libdbus-1-3 libdrm2 libgbm1 libglib2.0-0 libnspr4 libnss3 libpango-1.0-0 libx11-6 libxcb1 libxcomposite1 libxdamage1 libxext6 libxfixes3 libxkbcommon0 libxrandr2"
RHO_APT_IMAGE="bash tini ca-certificates curl git git-lfs build-essential pkg-config unzip zip xz-utils rsync openssh-client sqlite3 procps less libssl-dev libyaml-dev libffi-dev zlib1g-dev libreadline-dev libsqlite3-dev libpq-dev clang clang-format clang-tidy cmake ninja-build ccache dnsutils iputils-ping netcat-openbsd tzdata moreutils gnupg poppler-utils ffmpeg"
RHO_APT_COWORK="libreoffice-writer libreoffice-calc libreoffice-impress fontconfig fonts-dejavu-core fonts-liberation fonts-noto-core fonts-noto-cjk"
RHO_IMAGE_BASE="ubuntu:26.04"
RHO_COWORK_PYTHON="3.14"
RHO_TOOLCHAIN_MISE_VERSION="2026.9.5"
RHO_TOOLCHAIN_MISE_RUBY_COMPILE="false"
RHO_TOOLCHAIN_MISE_INTO="/usr/local/bin"
RHO_TOOLCHAIN_MISE_TOOLS="node@24.21.0 go@1.27.1 rust@1.98.1"
RHO_TOOLCHAIN_RUST_PROFILE="minimal"
RHO_TOOLCHAIN_RUST_COMPONENTS="[\"rustfmt\",\"clippy\"]"
RHO_TOOLCHAIN_NPM_DEFAULT_PACKAGES="pnpm prettier eslint typescript"
RHO_NATIVE_CODING_PACKAGES="t3@0.0.46-nightly.20261006.2752 @openai/codex@0.160.1 @anthropic-ai/claude-code@2.1.292"
RHO_TOOLCHAIN_UV_PYTHON="3.14"
RHO_TOOLCHAIN_UV_TOOLS="ruff pyright mypy"
RHO_TOOLCHAIN_GH_VERSION="2.100.0"
RHO_TOOLCHAIN_GH_INTO="/usr/local/bin"
RHO_TOOLCHAIN_TINI_VERSION="0.19.0"
RHO_TOOLCHAIN_MISE_linux_x64_URL="https://github.com/jdx/mise/releases/download/v2026.9.5/mise-v2026.9.5-linux-x64.tar.gz"
RHO_TOOLCHAIN_MISE_linux_x64_SHA256="d71e94e1ed59d4d0ca4ac847fa321d6d6615a8e613e9b468c9fb39f0dddd06d5"
RHO_TOOLCHAIN_MISE_linux_x64_MEMBERS="mise/bin/mise"
RHO_TOOLCHAIN_MISE_linux_arm64_URL="https://github.com/jdx/mise/releases/download/v2026.9.5/mise-v2026.9.5-linux-arm64.tar.gz"
RHO_TOOLCHAIN_MISE_linux_arm64_SHA256="3a52c7c7c58d21a0791516950ebf4bc915f403277b49c93d657fc585259625ec"
RHO_TOOLCHAIN_MISE_linux_arm64_MEMBERS="mise/bin/mise"
RHO_TOOLCHAIN_GH_linux_x64_URL="https://github.com/cli/cli/releases/download/v2.100.0/gh_2.100.0_linux_amd64.tar.gz"
RHO_TOOLCHAIN_GH_linux_x64_SHA256="e4d4bb4498e8d007abe545b6568926793ace1b6447da598294a610018cb164be"
RHO_TOOLCHAIN_GH_linux_x64_MEMBERS="gh_2.100.0_linux_amd64/bin/gh"
RHO_TOOLCHAIN_GH_linux_arm64_URL="https://github.com/cli/cli/releases/download/v2.100.0/gh_2.100.0_linux_arm64.tar.gz"
RHO_TOOLCHAIN_GH_linux_arm64_SHA256="ea4e7a581a32ccad6cc7923cb1576ac5859ba4b9a16ab22eb8f8a96e78e2e961"
RHO_TOOLCHAIN_GH_linux_arm64_MEMBERS="gh_2.100.0_linux_arm64/bin/gh"
# <<< rho manifest
# >>> rho manifest.json (the same document, verbatim, for the prefix's copy and `rho doctor`)
RHO_MANIFEST_JSON=$(cat <<'RHO_MANIFEST_JSON_EOF'
{
  "manifest_version": 1,
  "generated": "2026-09-18",
  "platforms": [
    "darwin-arm64",
    "darwin-x64",
    "linux-x64",
    "linux-arm64"
  ],
  "profiles": {
    "runner": "portable Ruby, the gems, rg, fd — a machine or container that serves tools alone (RHO_MODE=runner)",
    "full": "runner + jq + uv — a person's machine running agent and runner",
    "dev": "full + Node + playwright-core + the Chromium headless shell — browsing tasks (extensions: [\"rho/browser\"])"
  },
  "app": {
    "name": "rho",
    "trees": [
      "sdks/ruby",
      "cmctl",
      "agents/rho/rho-runner",
      "agents/rho/rho-browser",
      "agents/rho/rho-mcp",
      "agents/rho/rho-web-tools",
      "agents/rho/rho-codemode",
      "agents/rho/rho-webui",
      "agents/rho/rho-ingress-telegram",
      "agents/rho/rho-acp",
      "agents/rho/rho-acp-client",
      "agents/rho/rho-t3",
      "agents/rho/rho"
    ],
    "entry": "agents/rho/rho/exe/rho",
    "gemfile": "agents/rho/rho/Gemfile",
    "bundle_without": "development:test"
  },
  "runtime": {
    "kind": "ruby",
    "version": "4.0.7",
    "ruby": "4.0.7",
    "provenance": "Homebrew portable-ruby: Homebrew/brew Library/Homebrew/vendor/portable-ruby-version and the four vendor/portable-ruby-<arch>-<os> files; homebrew-core Formula/p/portable-ruby.rb bottle block",
    "bundler": "4.0.22",
    "bundler_provenance": "agents/rho/rho/Gemfile.lock BUNDLED WITH (the lock's version is installed into the portable Ruby always)",
    "headers": {
      "Authorization": "Bearer QQ=="
    },
    "verification": "manifest-sha256 (the sha256 IS the ghcr blob address)",
    "artifacts": {
      "darwin-arm64": {
        "tag": "arm64_big_sur",
        "filename": "portable-ruby-4.0.7.arm64_big_sur.bottle.tar.gz",
        "url": "https://ghcr.io/v2/homebrew/core/portable-ruby/blobs/sha256:e0088dff5614b39387300136ec7a5f95bf1e07589547245c919524fc9e8b4197",
        "sha256": "e0088dff5614b39387300136ec7a5f95bf1e07589547245c919524fc9e8b4197",
        "bytes": 12686106
      },
      "darwin-x64": {
        "tag": "big_sur",
        "filename": "portable-ruby-4.0.7.big_sur.bottle.tar.gz",
        "url": "https://ghcr.io/v2/homebrew/core/portable-ruby/blobs/sha256:57bebadc864405cbd39743e32eef741f4b75c0ba121f5cd9296ab84994b9f83b",
        "sha256": "57bebadc864405cbd39743e32eef741f4b75c0ba121f5cd9296ab84994b9f83b",
        "bytes": 12241978
      },
      "linux-x64": {
        "tag": "x86_64_linux",
        "filename": "portable-ruby-4.0.7.x86_64_linux.bottle.tar.gz",
        "url": "https://ghcr.io/v2/homebrew/core/portable-ruby/blobs/sha256:bf2a9bf102694d40084ed436b06a1566dded60a519f4d1879c90c81046e11081",
        "sha256": "bf2a9bf102694d40084ed436b06a1566dded60a519f4d1879c90c81046e11081",
        "bytes": 14350857
      },
      "linux-arm64": {
        "tag": "arm64_linux",
        "filename": "portable-ruby-4.0.7.arm64_linux.bottle.tar.gz",
        "url": "https://ghcr.io/v2/homebrew/core/portable-ruby/blobs/sha256:c9b75dd6bd9578921f3ce739dacae8866698c3399c0f83574a5d5fadda2aab2d",
        "sha256": "c9b75dd6bd9578921f3ce739dacae8866698c3399c0f83574a5d5fadda2aab2d",
        "bytes": 14660663
      }
    },
    "floors": {
      "darwin": "macOS 11 (big_sur)",
      "linux-x64": "glibc 2.13",
      "linux-arm64": "glibc 2.17",
      "musl": "no build: the image, or a distro Ruby >= 4.0"
    }
  },
  "tools": {
    "rg": {
      "version": "15.2.0",
      "profiles": [
        "runner",
        "full",
        "dev"
      ],
      "into": "bin",
      "unpack": "members",
      "verification": "publisher-sha256 (each release asset's .sha256 sidecar, copied at bump)",
      "artifacts": {
        "darwin-arm64": {
          "url": "https://github.com/BurntSushi/ripgrep/releases/download/15.2.0/ripgrep-15.2.0-aarch64-apple-darwin.tar.gz",
          "sha256": "3750b2e93f37e0c692657da574d7019a101c0084da05a790c83fd335bad973e4",
          "members": [
            "ripgrep-15.2.0-aarch64-apple-darwin/rg"
          ]
        },
        "darwin-x64": {
          "url": "https://github.com/BurntSushi/ripgrep/releases/download/15.2.0/ripgrep-15.2.0-x86_64-apple-darwin.tar.gz",
          "sha256": "af7825fcc69a2afc7a7aea55fc9af90e26421d8f20fe59df32e233c0b8a231c1",
          "members": [
            "ripgrep-15.2.0-x86_64-apple-darwin/rg"
          ]
        },
        "linux-x64": {
          "url": "https://github.com/BurntSushi/ripgrep/releases/download/15.2.0/ripgrep-15.2.0-x86_64-unknown-linux-musl.tar.gz",
          "sha256": "33e15bcf1624b25cdd2a55813a47a2f95dbe126268203e76aa6a585d1e7b149c",
          "members": [
            "ripgrep-15.2.0-x86_64-unknown-linux-musl/rg"
          ]
        },
        "linux-arm64": {
          "url": "https://github.com/BurntSushi/ripgrep/releases/download/15.2.0/ripgrep-15.2.0-aarch64-unknown-linux-musl.tar.gz",
          "sha256": "800b1e7206afe799dfb5a6901f23147cfaabe0e52210538100f61e86e1740915",
          "members": [
            "ripgrep-15.2.0-aarch64-unknown-linux-musl/rg"
          ]
        }
      }
    },
    "fd": {
      "version": "10.5.0",
      "profiles": [
        "runner",
        "full",
        "dev"
      ],
      "into": "bin",
      "unpack": "members",
      "verification": "computed-sha256 (fd publishes no checksums; `rake install:bump` hashes the four tarballs)",
      "artifacts": {
        "darwin-arm64": {
          "url": "https://github.com/sharkdp/fd/releases/download/v10.5.0/fd-v10.5.0-aarch64-apple-darwin.tar.gz",
          "sha256": "b67e1836c468e42e411984b56e52fa7abec08c2bd22c867398e7cc134aac5e12",
          "members": [
            "fd-v10.5.0-aarch64-apple-darwin/fd"
          ]
        },
        "darwin-x64": {
          "url": "https://github.com/sharkdp/fd/releases/download/v10.5.0/fd-v10.5.0-x86_64-apple-darwin.tar.gz",
          "sha256": "7e31028c62c6955877735d0406807aa484c2a5e6f86235a59e26c29c301da590",
          "members": [
            "fd-v10.5.0-x86_64-apple-darwin/fd"
          ]
        },
        "linux-x64": {
          "url": "https://github.com/sharkdp/fd/releases/download/v10.5.0/fd-v10.5.0-x86_64-unknown-linux-musl.tar.gz",
          "sha256": "761c72dc8e120d85b22292063be8a796e2eeb20eb3e4f38b8fa2343ccf3514a7",
          "members": [
            "fd-v10.5.0-x86_64-unknown-linux-musl/fd"
          ]
        },
        "linux-arm64": {
          "url": "https://github.com/sharkdp/fd/releases/download/v10.5.0/fd-v10.5.0-aarch64-unknown-linux-musl.tar.gz",
          "sha256": "d76c4317f7d5dba69f8a2a15856c90c777e7f0dd4e85f0de8c76de6992c374d4",
          "members": [
            "fd-v10.5.0-aarch64-unknown-linux-musl/fd"
          ]
        }
      }
    },
    "jq": {
      "version": "1.8.2",
      "profiles": [
        "full",
        "dev"
      ],
      "into": "bin",
      "unpack": "binary",
      "verification": "publisher-sha256 (the release's sha256sum.txt, copied at bump)",
      "artifacts": {
        "darwin-arm64": {
          "url": "https://github.com/jqlang/jq/releases/download/jq-1.8.2/jq-macos-arm64",
          "sha256": "2d75340ba57a4b4b4c8708a21c2dc8e958a48aaa8bba13b27f77f6e4c0eca07e",
          "members": [
            "jq"
          ]
        },
        "darwin-x64": {
          "url": "https://github.com/jqlang/jq/releases/download/jq-1.8.2/jq-macos-amd64",
          "sha256": "e94b266e3c26690550006abe63152b782280f4e14374accdf04cbde844f00bc0",
          "members": [
            "jq"
          ]
        },
        "linux-x64": {
          "url": "https://github.com/jqlang/jq/releases/download/jq-1.8.2/jq-linux-amd64",
          "sha256": "b1c22172dd303f3be49e935aa56aa48a8b7a46e0bc838b4997d3bb451495870f",
          "members": [
            "jq"
          ]
        },
        "linux-arm64": {
          "url": "https://github.com/jqlang/jq/releases/download/jq-1.8.2/jq-linux-arm64",
          "sha256": "8b85c817833814ddca00a144c33705546355afccf0cf39b188f3cdb48b852309",
          "members": [
            "jq"
          ]
        }
      }
    },
    "uv": {
      "version": "0.12.13",
      "profiles": [
        "full",
        "dev"
      ],
      "into": "bin",
      "unpack": "members",
      "verification": "publisher-sha256 (each release asset's .sha256 sidecar, copied at bump)",
      "note": "uv and uvx into bin/; no UV_* variable is exported anywhere — Pythons land where uv puts them by default, shared with the person's own uv",
      "artifacts": {
        "darwin-arm64": {
          "url": "https://github.com/astral-sh/uv/releases/download/0.12.13/uv-aarch64-apple-darwin.tar.gz",
          "sha256": "7e6ddb9316acc00f2296c82ff4d99977870ee34b2f0ddcae9444d714db9364ed",
          "members": [
            "uv-aarch64-apple-darwin/uv",
            "uv-aarch64-apple-darwin/uvx"
          ]
        },
        "darwin-x64": {
          "url": "https://github.com/astral-sh/uv/releases/download/0.12.13/uv-x86_64-apple-darwin.tar.gz",
          "sha256": "5e287ef61cb6a9b61b3a83fef124fd143e400468a7dac794230147a810e17119",
          "members": [
            "uv-x86_64-apple-darwin/uv",
            "uv-x86_64-apple-darwin/uvx"
          ]
        },
        "linux-x64": {
          "url": "https://github.com/astral-sh/uv/releases/download/0.12.13/uv-x86_64-unknown-linux-gnu.tar.gz",
          "sha256": "745765a3b6e360ad76743599ae5c42e9278c7edf8bbff9fc76d05bf2623a04dd",
          "members": [
            "uv-x86_64-unknown-linux-gnu/uv",
            "uv-x86_64-unknown-linux-gnu/uvx"
          ]
        },
        "linux-arm64": {
          "url": "https://github.com/astral-sh/uv/releases/download/0.12.13/uv-aarch64-unknown-linux-gnu.tar.gz",
          "sha256": "2eaa5d94f5db7b3a1a092156b9420459e42ab0217d917fe74a876309cef9b5e9",
          "members": [
            "uv-aarch64-unknown-linux-gnu/uv",
            "uv-aarch64-unknown-linux-gnu/uvx"
          ]
        }
      }
    },
    "node": {
      "version": "24.21.0",
      "profiles": [
        "dev"
      ],
      "into": "lib/playwright/node",
      "unpack": "tree",
      "verification": "publisher-sha256 (nodejs.org/dist/v24.21.0/SHASUMS256.txt, copied at bump; its GPG signature is the ceremony skipped)",
      "note": "the Playwright driver's Node, inside the prefix and never in bin/: a project's Node is untouched; glibc >= 2.28 on Linux",
      "artifacts": {
        "darwin-arm64": {
          "url": "https://nodejs.org/dist/v24.21.0/node-v24.21.0-darwin-arm64.tar.gz",
          "sha256": "bed7eea5325e1108f32ce5228ddd6a5f0f08a499ee42aa7442aea583702f6057",
          "members": []
        },
        "darwin-x64": {
          "url": "https://nodejs.org/dist/v24.21.0/node-v24.21.0-darwin-x64.tar.gz",
          "sha256": "1462cb3b3046b815cf8ea436d3da450ec1a9f11dac7e5a46b0ada5305d7e8097",
          "members": []
        },
        "linux-x64": {
          "url": "https://nodejs.org/dist/v24.21.0/node-v24.21.0-linux-x64.tar.xz",
          "sha256": "fd8e59d5a511510f6a298afb548f18c7d2b1be404d8b4a27d94fbe49f56cb2d6",
          "members": []
        },
        "linux-arm64": {
          "url": "https://nodejs.org/dist/v24.21.0/node-v24.21.0-linux-arm64.tar.xz",
          "sha256": "6ad1325edbdb5649c379b75a237147a666c95d4f9ae8d340fef2d1575d289ad2",
          "members": []
        }
      }
    },
    "playwright-core": {
      "version": "1.62.1",
      "profiles": [
        "dev"
      ],
      "into": "lib/playwright/package",
      "unpack": "tree",
      "derived_from": {
        "value": "1.62.1",
        "provenance": "playwright-ruby-client 1.62.x Playwright::COMPATIBLE_PLAYWRIGHT_VERSION (agents/rho/rho-browser); the gem and the driver move in lock-step, upstream latest is not followed"
      },
      "verification": "computed-sha256 (the registry document carries only a sha1 shasum and a sha512 integrity; `rake install:bump` hashes the tarball)",
      "artifacts": {
        "all": {
          "url": "https://registry.npmjs.org/playwright-core/-/playwright-core-1.62.1.tgz",
          "sha256": "954be1e183d0ddb9748fe0d2d08b0b66a9210c74dd75c397aeb70303b9f08a00",
          "members": []
        }
      }
    },
    "chromium": {
      "version": "headless-shell",
      "profiles": [
        "dev"
      ],
      "into": "browsers",
      "unpack": "command",
      "verification": "https-only (playwright-core's downloader verifies no hash; the one unpinned row, named)",
      "command": [
        "install",
        "--only-shell",
        "chromium"
      ],
      "note": "run through bin/rho-playwright, which scopes PLAYWRIGHT_BROWSERS_PATH to its own process; RHO_BROWSER_FULL_CHROMIUM=1 at install time drops --only-shell"
    }
  },
  "wrapper_env": {
    "LANG": "C.UTF-8 when none of LC_ALL LC_CTYPE LANG is set (Rho::Locale's rule)",
    "RHO_PREFIX": "the prefix, baked at install; joins Rho.protected_roots",
    "PATH": "$RHO_PREFIX/bin prepended for rho and every tool child: rg, fd, jq, uv, uvx, rho-playwright (and the python3 shim when the host had none) shadow the person's copies inside the model's shell",
    "RHO_BOOTSNAP_CACHE_DIR": "baked when the installer was given one (the image), else $RHO_HOME/cache/bootsnap at run time",
    "BUNDLE_GEMFILE, BUNDLE_PATH, BUNDLE_DEPLOYMENT, BUNDLE_WITHOUT": "Ruby's spelling of 'load the app from the prefix'; ChildEnv strips them from every tool child",
    "SSL_CERT_FILE": "the host's CA bundle (/etc/ssl/certs/ca-certificates.crt, /etc/pki/tls/certs/ca-bundle.crt, /etc/ssl/ca-bundle.pem, /etc/pki/tls/cacert.pem, /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem, /etc/ssl/cert.pem — the first readable), baked when the portable Ruby's static OpenSSL points at its builder's absent cert path; a person's own value wins; every tool child inherits it; `rho doctor`'s tls row reports the store",
    "not exported": "RHO_BROWSER_PLAYWRIGHT_CLI, PLAYWRIGHT_BROWSERS_PATH, UV_* — the driver is found at rho's own spawn site from RHO_PREFIX; the browsers dir is set inside bin/rho-playwright"
  },
  "prerequisites": {
    "all": [
      "git>=2.7",
      "/bin/bash",
      "curl|wget",
      "tar",
      "shasum|sha256sum|openssl"
    ],
    "install": [
      "cc",
      "make"
    ],
    "linux": [
      "glibc>=2.17 (2.28 for the dev profile's Node)",
      "xz (dev profile: Node ships as tar.xz)",
      "poppler-utils, ffmpeg (optional local PDF/video tools for rho; Nexus previews require dependencies in the Nexus environment)"
    ],
    "darwin": [
      "macOS>=11"
    ]
  },
  "apt": {
    "prerequisites": [
      "bash",
      "ca-certificates",
      "curl",
      "git",
      "build-essential",
      "pkg-config",
      "libssl-dev",
      "xz-utils"
    ],
    "prerequisites_note": "libssl-dev + pkg-config support a locked openssl gem version that the portable Ruby does not ship. `bundle install --prefer-local` uses the Ruby's own default gem when its version matches the lock, avoiding a second extension beside the statically linked OpenSSL whose conflicting symbols can break TLS. `rho doctor` refuses a prefix that loads a separately bundled openssl extension",
    "image": {
      "provenance": "codex-universal's apt core brought current, minus sudo and the Codex-web breadth, plus the references' consensus core (bash tini procps less unzip); no jq here — the installer's full profile puts the manifest's jq into /opt/rho/bin; poppler-utils and ffmpeg provide local PDF/video tools in the rho image; Nexus preview dependencies must be installed in the Nexus environment",
      "packages": [
        "bash",
        "tini",
        "ca-certificates",
        "curl",
        "git",
        "git-lfs",
        "build-essential",
        "pkg-config",
        "unzip",
        "zip",
        "xz-utils",
        "rsync",
        "openssh-client",
        "sqlite3",
        "procps",
        "less",
        "libssl-dev",
        "libyaml-dev",
        "libffi-dev",
        "zlib1g-dev",
        "libreadline-dev",
        "libsqlite3-dev",
        "libpq-dev",
        "clang",
        "clang-format",
        "clang-tidy",
        "cmake",
        "ninja-build",
        "ccache",
        "dnsutils",
        "iputils-ping",
        "netcat-openbsd",
        "tzdata",
        "moreutils",
        "gnupg",
        "poppler-utils",
        "ffmpeg"
      ]
    },
    "chromium": {
      "provenance": "playwright-core 1.62.1 lib/coreBundle.js native dependency table, the `chromium` list per distro, read at bump",
      "ubuntu26.04": [
        "libasound2t64",
        "libatk-bridge2.0-0t64",
        "libatk1.0-0t64",
        "libatspi2.0-0t64",
        "libcairo2",
        "libcups2t64",
        "libdbus-1-3",
        "libdrm2",
        "libgbm1",
        "libglib2.0-0t64",
        "libnspr4",
        "libnss3",
        "libpango-1.0-0",
        "libx11-6",
        "libxcb1",
        "libxcomposite1",
        "libxdamage1",
        "libxext6",
        "libxfixes3",
        "libxkbcommon0",
        "libxrandr2"
      ],
      "ubuntu24.04": [
        "libasound2t64",
        "libatk-bridge2.0-0t64",
        "libatk1.0-0t64",
        "libatspi2.0-0t64",
        "libcairo2",
        "libcups2t64",
        "libdbus-1-3",
        "libdrm2",
        "libgbm1",
        "libglib2.0-0t64",
        "libnspr4",
        "libnss3",
        "libpango-1.0-0",
        "libx11-6",
        "libxcb1",
        "libxcomposite1",
        "libxdamage1",
        "libxext6",
        "libxfixes3",
        "libxkbcommon0",
        "libxrandr2"
      ],
      "debian13": [
        "libasound2t64",
        "libatk-bridge2.0-0t64",
        "libatk1.0-0t64",
        "libatspi2.0-0t64",
        "libcairo2",
        "libcups2t64",
        "libdbus-1-3",
        "libdrm2",
        "libgbm1",
        "libglib2.0-0t64",
        "libnspr4",
        "libnss3",
        "libpango-1.0-0",
        "libx11-6",
        "libxcb1",
        "libxcomposite1",
        "libxdamage1",
        "libxext6",
        "libxfixes3",
        "libxkbcommon0",
        "libxrandr2"
      ],
      "debian12": [
        "libasound2",
        "libatk-bridge2.0-0",
        "libatk1.0-0",
        "libatspi2.0-0",
        "libcairo2",
        "libcups2",
        "libdbus-1-3",
        "libdrm2",
        "libgbm1",
        "libglib2.0-0",
        "libnspr4",
        "libnss3",
        "libpango-1.0-0",
        "libx11-6",
        "libxcb1",
        "libxcomposite1",
        "libxdamage1",
        "libxext6",
        "libxfixes3",
        "libxkbcommon0",
        "libxrandr2"
      ]
    },
    "cowork": {
      "provenance": "Ubuntu archive packages for headless DOCX/XLSX/PPTX rendering and Latin/CJK fonts; image-only, installed without recommended packages",
      "packages": [
        "libreoffice-writer",
        "libreoffice-calc",
        "libreoffice-impress",
        "fontconfig",
        "fonts-dejavu-core",
        "fonts-liberation",
        "fonts-noto-core",
        "fonts-noto-cjk"
      ]
    }
  },
  "brew": {
    "prerequisites": [
      "git"
    ],
    "note": "Xcode Command Line Tools (`xcode-select --install`) give git, cc and make; printed, never run"
  },
  "toolchains": {
    "note": "the image's project-toolchain layer, walked by install/docker/Dockerfile and never by the host installer; mise and gh are manifest-pinned tarballs (their apt repos pin nothing by version), what mise installs is manager-verified",
    "base": "ubuntu:26.04",
    "mise": {
      "version": "2026.9.5",
      "ruby_compile": false,
      "into": "/usr/local/bin",
      "tools": [
        "node@24.21.0",
        "go@1.27.1",
        "rust@1.98.1"
      ],
      "rust_profile": "minimal",
      "rust_components": [
        "rustfmt",
        "clippy"
      ],
      "npm_default_packages": [
        "pnpm",
        "prettier",
        "eslint",
        "typescript"
      ],
      "verification": "publisher-sha256 (the release's SHASUMS256.txt, copied at bump)",
      "artifacts": {
        "linux-x64": {
          "url": "https://github.com/jdx/mise/releases/download/v2026.9.5/mise-v2026.9.5-linux-x64.tar.gz",
          "sha256": "d71e94e1ed59d4d0ca4ac847fa321d6d6615a8e613e9b468c9fb39f0dddd06d5",
          "members": [
            "mise/bin/mise"
          ]
        },
        "linux-arm64": {
          "url": "https://github.com/jdx/mise/releases/download/v2026.9.5/mise-v2026.9.5-linux-arm64.tar.gz",
          "sha256": "3a52c7c7c58d21a0791516950ebf4bc915f403277b49c93d657fc585259625ec",
          "members": [
            "mise/bin/mise"
          ]
        }
      }
    },
    "uv_python": [
      "3.14"
    ],
    "uv_tools": [
      "ruff",
      "pyright",
      "mypy"
    ],
    "gh": {
      "version": "2.100.0",
      "into": "/usr/local/bin",
      "verification": "publisher-sha256 (the release's gh_<v>_checksums.txt, copied at bump)",
      "artifacts": {
        "linux-x64": {
          "url": "https://github.com/cli/cli/releases/download/v2.100.0/gh_2.100.0_linux_amd64.tar.gz",
          "sha256": "e4d4bb4498e8d007abe545b6568926793ace1b6447da598294a610018cb164be",
          "members": [
            "gh_2.100.0_linux_amd64/bin/gh"
          ]
        },
        "linux-arm64": {
          "url": "https://github.com/cli/cli/releases/download/v2.100.0/gh_2.100.0_linux_arm64.tar.gz",
          "sha256": "ea4e7a581a32ccad6cc7923cb1576ac5859ba4b9a16ab22eb8f8a96e78e2e961",
          "members": [
            "gh_2.100.0_linux_arm64/bin/gh"
          ]
        }
      }
    },
    "tini": {
      "version": "0.19.0",
      "provenance": "ubuntu:26.04's apt (tini 0.19.0-6); upstream has not moved since 2020"
    },
    "cowork_python": "3.14",
    "native_coding": {
      "packages": [
        "t3@0.0.46-nightly.20261006.2752",
        "@openai/codex@0.160.1",
        "@anthropic-ai/claude-code@2.1.292"
      ],
      "verification": "npm registry integrity, exact package versions; native platform packages are selected by npm",
      "note": "T3 is deliberately pinned to orchestration protocol 2. Stable 0.0.45 speaks protocol 1. Update this group only after rho-t3 protocol validation."
    }
  }
}
RHO_MANIFEST_JSON_EOF
)
# <<< rho manifest.json

# ---------------------------------------------------------------------------
# Arguments and the environment knobs (the flag wins over the variable).
MODE="install"
DRY_RUN=""
PURGE=""
RESTART=""
FORCE=""
PROFILE="${RHO_PROFILE:-}"
PREFIX="${RHO_PREFIX:-}"
SOURCE="${RHO_SOURCE:-}"
MODIFY_PATH="${RHO_MODIFY_PATH:-}"
LAUNCHER_DIR="${RHO_LAUNCHER_DIR:-$HOME/.local/bin}"
ARTIFACT_DOMAIN="${RHO_ARTIFACT_DOMAIN:-}"
BAKED_BOOTSNAP_CACHE="${RHO_BOOTSNAP_CACHE_DIR:-}"

usage() {
  # The header comment up to the first code line (`set -u`), the directive line dropped.
  sed -n '2,/^set -u$/p' "$0" | sed '$d' | grep -v '^# shellcheck' | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --update) MODE="update" ;;
    --apply-update) MODE="apply-update" ;;
    --rollback) MODE="rollback" ;;
    --add-rows) MODE="add-rows" ;;
    --uninstall) MODE="uninstall" ;;
    --purge) PURGE=1 ;;
    --restart) RESTART=1 ;;
    --force) FORCE=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --non-interactive) NONINTERACTIVE=1 ;;
    --modify-path) MODIFY_PATH=1 ;;
    --profile) shift; PROFILE="${1:-}" ;;
    --profile=*) PROFILE="${1#--profile=}" ;;
    --prefix) shift; PREFIX="${1:-}" ;;
    --prefix=*) PREFIX="${1#--prefix=}" ;;
    --from-checkout) shift; SOURCE="${1:-}" ;;
    --from-checkout=*) SOURCE="${1#--from-checkout=}" ;;
    -h|--help) usage; exit 0 ;;
    *) abort "rho install: unknown argument $1 (see --help)" ;;
  esac
  shift
done

RECEIPT_PROFILE_DEFAULT=""
if [ -z "$PROFILE" ] && [ -f "${PREFIX:-${XDG_DATA_HOME:-$HOME/.local/share}/rho}/receipt.sh" ]; then
  RECEIPT_PROFILE_DEFAULT=$(sed -n 's/^RHO_RECEIPT_PROFILE="\(.*\)"$/\1/p' "${PREFIX:-${XDG_DATA_HOME:-$HOME/.local/share}/rho}/receipt.sh")
fi
PROFILE="${PROFILE:-${RECEIPT_PROFILE_DEFAULT:-full}}"
case " $RHO_PROFILES " in
  *" $PROFILE "*) ;;
  *) abort "rho install: unknown profile '$PROFILE' (one of: $RHO_PROFILES)" ;;
esac

# Non-interactive as Homebrew: CI, or stdin not a terminal.
if [ -z "${NONINTERACTIVE-}" ]; then
  if [ -n "${CI-}" ]; then
    warn "Running in non-interactive mode because \$CI is set."
    NONINTERACTIVE=1
  elif [ ! -t 0 ] && [ -z "${INTERACTIVE-}" ]; then
    warn "Running in non-interactive mode because stdin is not a TTY."
    NONINTERACTIVE=1
  fi
fi

wait_for_user() {
  local c
  printf "\nPress %sRETURN%s/%sEnter%s to continue or any other key to abort: " "$tty_bold" "$tty_reset" "$tty_bold" "$tty_reset"
  IFS= read -r -s -n 1 c
  printf "\n"
  if ! [ "$c" = "" ]; then
    abort "Aborted."
  fi
}

# ---------------------------------------------------------------------------
# Platform: darwin|linux × arm64|x64 → one of the manifest's four tags.
in_container() {
  [ -f /.dockerenv ] || [ -f /run/.containerenv ] || { [ -r /proc/1/cgroup ] && grep -qE "azpl_job|actions_job|docker|garden|kubepods" /proc/1/cgroup; }
}

if [ "${EUID:-$(id -u)}" = "0" ] && ! in_container; then
  abort "rho install: don't run this as root — the prefix is yours, no sudo is ever needed (a container or CI may run it as root)."
fi

OS=$(uname -s)
case "$OS" in
  Darwin) OS="darwin" ;;
  Linux) OS="linux" ;;
  *) abort "rho install: only macOS and Linux are supported (this is $OS)." ;;
esac
ARCH=$(uname -m)
case "$ARCH" in
  arm64|aarch64) ARCH="arm64" ;;
  x86_64|amd64) ARCH="x64" ;;
  *) abort "rho install: only arm64 and x86_64 are supported (this is $ARCH)." ;;
esac
PLATFORM="$OS-$ARCH"
PLATFORM_KEY="${OS}_${ARCH}"
case " $RHO_PLATFORMS " in
  *" $PLATFORM "*) ;;
  *) abort "rho install: the manifest has no rows for $PLATFORM." ;;
esac

version_ge() {
  # version_ge 2.17 2.13 → true when $1 >= $2 (dotted numbers only)
  [ "$(printf '%s\n%s\n' "$2" "$1" | sort -t. -k1,1n -k2,2n -k3,3n | head -n1)" = "$2" ]
}

if [ "$OS" = "darwin" ]; then
  macos_version=$(sw_vers -productVersion 2>/dev/null || echo 0)
  if ! version_ge "$macos_version" 11; then
    abort "rho install: macOS $macos_version is older than 11 (the portable Ruby's floor is Big Sur)."
  fi
else
  if ldd --version 2>&1 | grep -qi musl; then
    abort "rho install: this is a musl libc system; the portable Ruby has no musl build — use the rho image, or a distro Ruby >= 4.0 with a checkout."
  fi
  glibc_version=$(ldd --version 2>/dev/null | head -n1 | grep -oE '[0-9]+\.[0-9]+$' || echo 0)
  if ! version_ge "$glibc_version" 2.17; then
    abort "rho install: glibc $glibc_version is older than 2.17."
  fi
  if [ "$PROFILE" = "dev" ] && ! version_ge "$glibc_version" 2.28; then
    abort "rho install: the dev profile's Node needs glibc >= 2.28 (this is $glibc_version); choose --profile full."
  fi
fi

# ---------------------------------------------------------------------------
# Prefix, home, launcher.
if [ -z "$PREFIX" ]; then
  PREFIX="${XDG_DATA_HOME:-$HOME/.local/share}/rho"
fi
case "$PREFIX" in
  /*) ;;
  *) PREFIX="$PWD/$PREFIX" ;;
esac
HOME_DIR="${RHO_HOME:-$HOME/.rho}"
DOWNLOADS="${RHO_DOWNLOAD_CACHE:-$PREFIX/cache/downloads}"
LAUNCHER="$LAUNCHER_DIR/rho"
RECEIPT_SH="$PREFIX/receipt.sh"
RECEIPT_JSON="$PREFIX/receipt.json"

# The receipt (shell form) when the prefix has one: what is there now.
RHO_RECEIPT_SOURCE_PATH=""; RHO_RECEIPT_PROFILE=""; RHO_RECEIPT_CURRENT=""; RHO_RECEIPT_PREVIOUS=""
RHO_RECEIPT_RUBY_VERSION=""; RHO_RECEIPT_APP_COMMIT=""; RHO_RECEIPT_APP_VERSION=""; RHO_RECEIPT_LAUNCHER=""
RHO_RECEIPT_RC_FILE=""; RHO_RECEIPT_RC_LINE=""; RHO_RECEIPT_TOOLS=""; RHO_RECEIPT_BOOTSNAP_CACHE=""
if [ -f "$RECEIPT_SH" ]; then
  # shellcheck disable=SC1090
  . "$RECEIPT_SH"
fi
# An update keeps the cache root the first install was given (the image's)
# and the launcher the first install linked — never the environment's default.
BAKED_BOOTSNAP_CACHE="${BAKED_BOOTSNAP_CACHE:-$RHO_RECEIPT_BOOTSNAP_CACHE}"
case "$MODE" in
  apply-update|add-rows|rollback|uninstall)
    if [ -n "$RHO_RECEIPT_LAUNCHER" ]; then
      LAUNCHER="$RHO_RECEIPT_LAUNCHER"
      LAUNCHER_DIR=$(dirname "$LAUNCHER")
    fi ;;
esac

# ---------------------------------------------------------------------------
# Prerequisites: checked, never installed; the line to run is printed.
have() { command -v "$1" >/dev/null 2>&1; }

prerequisite_line() {
  if [ "$OS" = "darwin" ]; then
    printf "xcode-select --install   (Xcode Command Line Tools: git, cc, c++, make)"
  elif have apt-get; then
    printf "sudo apt-get install -y %s" "$RHO_APT_PREREQUISITES"
  elif have dnf; then
    printf "sudo dnf install -y bash ca-certificates curl git gcc gcc-c++ make pkgconf-pkg-config openssl-devel xz"
  elif have pacman; then
    printf "sudo pacman -S bash ca-certificates curl git base-devel pkgconf openssl xz"
  else
    printf "install: bash, git, curl, tar, C and C++ compilers and make"
  fi
}

require_tool() {
  have "$1" || abort "rho install: '$1' is required and was not found on PATH." "Run:  $(prerequisite_line)" "then re-run this script."
}

check_prerequisites() {
  local git_version
  [ -x /bin/bash ] || abort "rho install: /bin/bash is missing (the bash tool's shell)." "Run:  $(prerequisite_line)"
  have curl || have wget || abort "rho install: curl (or wget) is required." "Run:  $(prerequisite_line)"
  require_tool tar
  require_tool git
  git_version=$(git --version | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1)
  version_ge "$git_version" 2.7 || abort "rho install: git $git_version is older than 2.7."
  have shasum || have sha256sum || have openssl || abort "rho install: shasum, sha256sum or openssl is required to verify downloads."
  # The gems' native extensions are built against the portable Ruby on
  # this machine; mini_racer also needs the C++ compiler. Printed,
  # never run (per-platform rho bottles are the
  # follow-up that removes it).
  if ! { have cc || have gcc || have clang; } || ! { have c++ || have g++ || have clang++; } || ! have make; then
    abort "rho install: C and C++ compilers and make are required to build rho's native gems." "Run:  $(prerequisite_line)" "then re-run this script."
  fi
  if [ "$OS" = "linux" ] && [ "$PROFILE" = "dev" ] && ! have xz; then
    abort "rho install: xz is required to unpack Node (the dev profile)." "Run:  $(prerequisite_line)"
  fi
}

# ---------------------------------------------------------------------------
# Downloads: mirror first, resumable, sha256 against the manifest.
sha256_of() {
  if have shasum; then
    shasum -a 256 "$1" | cut -d' ' -f1
  elif have sha256sum; then
    sha256sum "$1" | cut -d' ' -f1
  else
    openssl dgst -sha256 "$1" | sed 's/^.*= //'
  fi
}

# fetch_url URL DESTINATION [HEADER] — one attempt, resumable.
fetch_url() {
  local url="$1" destination="$2" header="${3:-}" status
  if have curl; then
    if [ -n "$header" ]; then
      curl --fail --location --remote-time --silent --show-error -C - --header "$header" -o "$destination" "$url"
    else
      curl --fail --location --remote-time --silent --show-error -C - -o "$destination" "$url"
    fi
    status=$?
    if [ "$status" = "33" ]; then
      rm -f "$destination"
      if [ -n "$header" ]; then
        curl --fail --location --remote-time --silent --show-error --header "$header" -o "$destination" "$url"
      else
        curl --fail --location --remote-time --silent --show-error -o "$destination" "$url"
      fi
      status=$?
    fi
    return "$status"
  else
    if [ -n "$header" ]; then
      wget -q --header="$header" -O "$destination" "$url"
    else
      wget -q -O "$destination" "$url"
    fi
  fi
}

# The mirror serves the same path under its own domain.
mirror_url() {
  local url="$1" path
  path="${url#https://}"
  path="${path#*/}"
  printf "%s/%s" "${ARTIFACT_DOMAIN%/}" "$path"
}

# fetch_artifact URL SHA256 FILENAME [HEADER] → the verified file in the
# download cache; a cached file with the right sha is not fetched again.
fetch_artifact() {
  local url="$1" expected="$2" filename="$3" header="${4:-}" target actual
  target="$DOWNLOADS/$filename"
  if [ -f "$target" ] && [ "$(sha256_of "$target")" = "$expected" ]; then
    ohai "Cached $filename (sha256 verified)"
    return 0
  fi
  mkdir -p "$DOWNLOADS"
  rm -f "$target"
  if [ -n "$ARTIFACT_DOMAIN" ]; then
    ohai "Downloading $(mirror_url "$url")"
    fetch_url "$(mirror_url "$url")" "$target.incomplete" "$header" || rm -f "$target.incomplete"
  fi
  # Without a mirror, an existing .incomplete file must reach curl to resume.
  if [ -z "$ARTIFACT_DOMAIN" ] || [ ! -f "$target.incomplete" ]; then
    ohai "Downloading $url"
    fetch_url "$url" "$target.incomplete" "$header" || abort "rho install: could not download $url"
  fi
  actual=$(sha256_of "$target.incomplete")
  if [ "$actual" != "$expected" ]; then
    rm -f "$target.incomplete"
    abort "rho install: checksum mismatch for $filename" "  expected: $expected" "  actual:   $actual" "The download is deleted; re-run to retry."
  fi
  mv -f "$target.incomplete" "$target"
}

# ---------------------------------------------------------------------------
# The atomic link swap. `mv -f new current` on a link-to-directory moves
# the new link INTO the directory (both mv's); GNU needs -T, BSD needs -h.
# Probed, never assumed.
MV_LINK_FLAG=""
probe_mv() {
  if mv -T /nonexistent/rho-probe-a /nonexistent/rho-probe-b 2>&1 | grep -q "illegal option"; then
    MV_LINK_FLAG="-hf"
  else
    MV_LINK_FLAG="-Tf"
  fi
}
# swap_link TARGET LINK — LINK ends up pointing at TARGET (relative to LINK's directory).
swap_link() {
  local target="$1" link="$2" temporary
  [ -n "$MV_LINK_FLAG" ] || probe_mv
  temporary="$link.tmp.$$"
  rm -f "$temporary"
  ln -s "$target" "$temporary" || abort "rho install: could not link $link"
  # shellcheck disable=SC2086
  if ! mv $MV_LINK_FLAG "$temporary" "$link" 2>/dev/null; then
    rm -f "$temporary" "$link"
    ln -sfn "$target" "$link" || abort "rho install: could not repoint $link"
  fi
  [ "$(readlink "$link")" = "$target" ] || abort "rho install: $link points at $(readlink "$link"), not $target"
}

# ---------------------------------------------------------------------------
# Manifest lookups (bash 3.2: indirect expansion instead of associative arrays).
lookup() { local name="$1"; printf "%s" "${!name:-}"; }
tool_field() { lookup "RHO_TOOL_${1}_${2}"; }
tool_artifact() {
  # tool_artifact TOOL FIELD → the platform's artifact field, or the "all" one
  local value
  value=$(lookup "RHO_TOOL_${1}_${PLATFORM_KEY}_${2}")
  [ -n "$value" ] || value=$(lookup "RHO_TOOL_${1}_all_${2}")
  printf "%s" "$value"
}
tool_in_profile() {
  case " $(tool_field "$1" PROFILES) " in
    *" $PROFILE "*) return 0 ;;
    *) return 1 ;;
  esac
}
profile_tools() {
  local tool
  for tool in $RHO_TOOLS; do
    tool_in_profile "$tool" && printf "%s " "$tool"
  done
}

RUBY_VERSION="$RHO_RUBY_VERSION"
RUBY_DIR="$PREFIX/ruby/$RUBY_VERSION"
RUBY_SHA=$(lookup "RHO_RUBY_${PLATFORM_KEY}_SHA256")
RUBY_URL=$(lookup "RHO_RUBY_${PLATFORM_KEY}_URL")
RUBY_FILENAME=$(lookup "RHO_RUBY_${PLATFORM_KEY}_FILENAME")
RUBY_BYTES=$(lookup "RHO_RUBY_${PLATFORM_KEY}_BYTES")

# ---------------------------------------------------------------------------
# The lock (codex's pattern: a mkdir lock, stale after 600 s) and cleanup.
LOCK_DIR="$PREFIX/.install.lock"
LOCKED=""
STAGING=""
cleanup() {
  [ -n "$STAGING" ] && [ -d "$STAGING" ] && rm -rf "$STAGING"
  [ -n "$LOCKED" ] && rm -rf "$LOCK_DIR"
}
lock_prefix() {
  [ -n "$DRY_RUN" ] && return 0
  mkdir -p "$PREFIX"
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    local age
    age=$(( $(date +%s) - $(stat -f %m "$LOCK_DIR" 2>/dev/null || stat -c %Y "$LOCK_DIR" 2>/dev/null || echo 0) ))
    if [ "$age" -gt 600 ]; then
      warn "removing a stale install lock (${age}s old)"
      rm -rf "$LOCK_DIR"
      mkdir "$LOCK_DIR" || abort "rho install: could not take $LOCK_DIR"
    else
      abort "rho install: another install is running ($LOCK_DIR, ${age}s old); wait, or remove it if that install died."
    fi
  fi
  printf "%s\n" "$$" > "$LOCK_DIR/pid"
  LOCKED=1
  trap cleanup EXIT
}

# ---------------------------------------------------------------------------
# The app's source: a checkout — the one this script sits in, unless
# --from-checkout / RHO_SOURCE names another. APP_VERSION (the gem's) and
# APP_COMMIT (`git rev-parse HEAD`; "" for an unpacked tree, which still
# installs) are set here.
APP_VERSION=""
APP_COMMIT=""
APP_SOURCE_PATH=""
VERSION_NAME=""

# checkout_commit DIR → HEAD when DIR is the root of a git checkout, else nothing.
checkout_commit() {
  local top
  top=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) || return 0
  [ "$top" -ef "$1" ] || return 0
  git -C "$1" rev-parse HEAD 2>/dev/null || true
}

if [ -z "$SOURCE" ]; then
  # BASH_SOURCE, not $0: the shell tests source this file.
  script_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)
  [ -f "$script_root/agents/rho/rho/rho.gemspec" ] && SOURCE="$script_root"
fi
if [ -n "$SOURCE" ]; then
  SOURCE=$(cd "$SOURCE" 2>/dev/null && pwd) || abort "rho install: $SOURCE is not a directory."
  [ -f "$SOURCE/agents/rho/rho/rho.gemspec" ] || abort "rho install: $SOURCE is not a cybros.ai checkout (no agents/rho/rho/rho.gemspec)."
  APP_VERSION=$(sed -n 's/.*VERSION = "\([^"]*\)".*/\1/p' "$SOURCE/agents/rho/rho/lib/rho/version.rb")
  APP_COMMIT=$(checkout_commit "$SOURCE")
  APP_SOURCE_PATH="$SOURCE"
  VERSION_NAME="$APP_VERSION-checkout-r$RUBY_VERSION"
elif [ "$MODE" = "install" ] || [ "$MODE" = "apply-update" ]; then
  abort "rho install: no checkout to install from — run install/install.sh inside a clone (git clone https://github.com/jasl/cybros.ai.git), or pass --from-checkout DIR."
fi
VERSION_DIR="$PREFIX/versions/$VERSION_NAME"
# ---------------------------------------------------------------------------
# The plan (Homebrew's "This script will install:"), then RETURN.
plan() {
  local tool
  printf "%sThis script will install rho %s (profile %s, %s) into:%s\n" "$tty_bold" "$APP_VERSION" "$PROFILE" "$PLATFORM" "$tty_reset"
  printf "  %s\n" "$PREFIX"
  printf "    ruby/%s        Homebrew's portable Ruby (%s bytes, sha256 %s…)\n" "$RUBY_VERSION" "$RUBY_BYTES" "${RUBY_SHA:0:12}"
  printf "    versions/%s   the rho gems (bundle install --deployment), from %s%s\n" "$VERSION_NAME" "$APP_SOURCE_PATH" "${APP_COMMIT:+ at ${APP_COMMIT:0:7}}"
  for tool in $(profile_tools); do
    printf "    %-22s %s %s\n" "$(tool_field "$tool" INTO)/" "$(tool_field "$tool" NAME)" "$(tool_field "$tool" VERSION)"
  done
  printf "    bin/rho              the wrapper\n"
  printf "  %s -> %s/bin/rho   the launcher\n" "$LAUNCHER" "$PREFIX"
  if [ -n "$MODIFY_PATH" ]; then
    printf "  %s   gets one PATH line\n" "$(rc_file)"
  else
    printf "  your shell rc file is not touched; the PATH line is printed at the end\n"
  fi
  printf "  RHO_HOME stays %s (state; interactive setup saves your chosen configuration)\n" "$HOME_DIR"
  if [ -n "$DRY_RUN" ]; then
    printf "\nURLs:\n  %s\n" "$RUBY_URL"
    for tool in $(profile_tools); do
      [ -n "$(tool_artifact "$tool" URL)" ] && printf "  %s\n" "$(tool_artifact "$tool" URL)"
    done
  fi
}
# ---------------------------------------------------------------------------
# Step: the portable Ruby (Homebrew's vendor-install, re-cut for the prefix).
scrub_ruby_env() {
  local name
  unset RUBYOPT RUBYLIB GEM_HOME GEM_PATH BUNDLER_VERSION BUNDLE_BIN_PATH BUNDLER_SETUP RBENV_VERSION
  # shellcheck disable=SC2046
  for name in $(compgen -v BUNDLE_ 2>/dev/null); do unset "$name"; done
}

install_ruby() {
  if [ -x "$RUBY_DIR/bin/ruby" ] && "$RUBY_DIR/bin/ruby" --version >/dev/null 2>&1; then
    ohai "Portable Ruby $RUBY_VERSION is already installed"
    return 0
  fi
  fetch_artifact "$RUBY_URL" "$RUBY_SHA" "$RUBY_FILENAME" "$RHO_RUBY_HEADER"
  ohai "Unpacking $RUBY_FILENAME"
  rm -rf "$PREFIX/ruby/.staging" "$RUBY_DIR"
  mkdir -p "$PREFIX/ruby/.staging"
  execute tar -xzf "$DOWNLOADS/$RUBY_FILENAME" -C "$PREFIX/ruby/.staging"
  [ -d "$PREFIX/ruby/.staging/portable-ruby/$RUBY_VERSION" ] || abort "rho install: the bottle did not unpack as portable-ruby/$RUBY_VERSION"
  trap '' INT
  execute mv "$PREFIX/ruby/.staging/portable-ruby/$RUBY_VERSION" "$RUBY_DIR"
  trap - INT
  rm -rf "$PREFIX/ruby/.staging"
  ohai "$RUBY_DIR/bin/ruby" --version
  "$RUBY_DIR/bin/ruby" --version || { rm -rf "$RUBY_DIR"; abort "rho install: the portable Ruby does not run on this machine"; }
}

# The lock's bundler, into the portable Ruby, always (`bundle install`
# would otherwise fetch a different version from the lock silently and
# `-rbundler/setup` would run on the wrong one without a word).
install_bundler() {
  (
    scrub_ruby_env
    if "$RUBY_DIR/bin/gem" list -i -e bundler -v "$RHO_RUBY_BUNDLER" >/dev/null 2>&1; then
      ohai "bundler $RHO_RUBY_BUNDLER is already in the portable Ruby"
      exit 0
    fi
    # --force: the bottle's bin/bundle is the default gem's own binstub, and
    # RubyGems refuses to overwrite one it did not write without it.
    run "$RUBY_DIR/bin/gem" install bundler -v "$RHO_RUBY_BUNDLER" --no-document --force
  ) || exit 1
}

# ---------------------------------------------------------------------------
# Step: the gems. Stage the manifest's trees, bundle install --deployment into
# versions/<app>-r<ruby>, then activate (swap both links together).
stage_app() {
  STAGING="$PREFIX/versions/.staging.$$"
  rm -rf "$STAGING"
  mkdir -p "$STAGING"
  ohai "Copying the packaged trees from $SOURCE${APP_COMMIT:+ (commit ${APP_COMMIT:0:7})}"
  # shellcheck disable=SC2086
  ( cd "$SOURCE" && tar -cf - --exclude=.git --exclude=tmp --exclude=log --exclude=coverage --exclude=node_modules \
      --exclude=vendor/bundle --exclude=.bundle --exclude=pkg $RHO_APP_TREES ) | tar -xf - -C "$STAGING" \
    || abort "rho install: could not copy the checkout"
  [ -f "$STAGING/agents/rho/rho/Gemfile.lock" ] || abort "rho install: the source carries no agents/rho/rho/Gemfile.lock"
  printf "%s\n" "$RUBY_VERSION" > "$STAGING/.ruby"
  printf "%s\n" "$APP_COMMIT" > "$STAGING/.commit"
}

# A previous version built against the same Ruby seeds vendor/bundle:
# bundler then verifies instead of compiling.
seed_bundle() {
  local previous_dir="$PREFIX/current"
  [ -d "$previous_dir/vendor/bundle" ] || return 0
  [ "$(cat "$previous_dir/.ruby" 2>/dev/null)" = "$RUBY_VERSION" ] || return 0
  ohai "Seeding vendor/bundle from $(readlink "$previous_dir") (same Ruby)"
  mkdir -p "$STAGING/vendor"
  cp -R "$previous_dir/vendor/bundle" "$STAGING/vendor/bundle"
}

# THE PORTABLE RUBY'S OWN OPENSSL: the bottle links
# OpenSSL statically into bin/ruby, and bundler 4 fetches and builds every
# default gem the lock pins into vendor/bundle whenever a remote serves it
# (bundler/source/rubygems.rb `install`: a default gem is "Using" only
# when `cached_built_in_gem` may not fetch, i.e. under `local`) — a second
# openssl extension whose symbols bind to the static copy at load time, so
# TLS verification fails or the process segfaults. `--prefer-local` is
# bundler's own switch for exactly this: the Ruby's default specs take
# precedence over the remote index and every install runs `local`
# (bundler/installer.rb `local = options[:local] || options[:"prefer-local"]`),
# so a default gem at the lock's version is used from the Ruby, never
# fetched; a gem the Ruby lacks is fetched as before. Under the frozen
# lock it changes no resolution: the lock stays byte-for-byte.
bundle_app() {
  seed_bundle
  (
    scrub_ruby_env
    # shellcheck disable=SC2030
    export PATH="$RUBY_DIR/bin:$PATH"
    export BUNDLE_GEMFILE="$STAGING/$RHO_APP_GEMFILE"
    export BUNDLE_PATH="$STAGING/vendor/bundle"
    export BUNDLE_DEPLOYMENT=1
    export BUNDLE_WITHOUT="$RHO_APP_BUNDLE_WITHOUT"
    export BUNDLE_JOBS=4
    if [ -z "${LC_ALL:-}${LC_CTYPE:-}${LANG:-}" ]; then export LANG=C.UTF-8; fi
    cd "$STAGING/agents/rho/rho" || exit 1
    run "$RUBY_DIR/bin/bundle" install --prefer-local
  ) || abort "rho install: bundle install failed (a missing compiler or header is the usual cause: $(prerequisite_line))"
}

# Activate: versions/<name> in place, `current` and `ruby/current` swapped
# together (the pair), the old pair recorded as previous.
activate_app() {
  local old_current
  old_current="$RHO_RECEIPT_CURRENT"
  trap '' INT
  if [ -d "$VERSION_DIR" ]; then
    if [ "$old_current" = "$VERSION_NAME" ]; then
      rm -rf "$VERSION_DIR.old"
      execute mv "$VERSION_DIR" "$VERSION_DIR.old"
      old_current="$VERSION_NAME.old"
    else
      rm -rf "$VERSION_DIR"
    fi
  fi
  execute mv "$STAGING" "$VERSION_DIR"
  STAGING=""
  swap_link "versions/$VERSION_NAME" "$PREFIX/current"
  swap_link "$RUBY_VERSION" "$PREFIX/ruby/current"
  trap - INT
  if [ -n "$old_current" ] && [ "$old_current" != "$VERSION_NAME" ] && [ -d "$PREFIX/versions/$old_current" ]; then
    PREVIOUS="$old_current"
  else
    PREVIOUS=""
  fi
  # Only current and previous stay (rollback is one step deep).
  local entry name
  for entry in "$PREFIX"/versions/*; do
    [ -d "$entry" ] || continue
    name=$(basename "$entry")
    case "$name" in
      "$VERSION_NAME"|"$PREVIOUS"|.staging.*) ;;
      *) rm -rf "$entry" ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Step: the tool rows. Each is skipped when the receipt's sha equals the
# manifest's and the file is there (content-addressed, idempotent).
RECEIPT_TOOLS_JSON=""
RECEIPT_TOOLS_SH=""
record_tool() {
  # record_tool KEY NAME VERSION SHA
  RECEIPT_TOOLS_JSON="$RECEIPT_TOOLS_JSON${RECEIPT_TOOLS_JSON:+, }\"$2\": {\"version\": \"$3\", \"sha256\": \"$4\"}"
  RECEIPT_TOOLS_SH="$RECEIPT_TOOLS_SH
RHO_RECEIPT_TOOL_${1}_VERSION=\"$3\"
RHO_RECEIPT_TOOL_${1}_SHA256=\"$4\""
  RECORDED_TOOLS="${RECORDED_TOOLS:-}$1 "
}

tool_present() {
  local tool="$1" into member
  into="$PREFIX/$(tool_field "$tool" INTO)"
  case "$(tool_field "$tool" UNPACK)" in
    members|binary)
      for member in $(tool_artifact "$tool" MEMBERS); do
        [ -x "$into/$(basename "$member")" ] || return 1
      done
      return 0 ;;
    tree) [ -d "$into" ] && [ -n "$(ls -A "$into" 2>/dev/null)" ] ;;
    command) ls -d "$into"/chromium* >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

install_tool() {
  local tool="$1" name version sha url into filename unpack member recorded
  name=$(tool_field "$tool" NAME); version=$(tool_field "$tool" VERSION)
  sha=$(tool_artifact "$tool" SHA256); url=$(tool_artifact "$tool" URL)
  into="$PREFIX/$(tool_field "$tool" INTO)"; unpack=$(tool_field "$tool" UNPACK)
  recorded=$(lookup "RHO_RECEIPT_TOOL_${tool}_SHA256")
  if tool_present "$tool" && [ "$recorded" = "$sha" ]; then
    ohai "$name $version is already installed"
    record_tool "$tool" "$name" "$version" "$sha"
    return 0
  fi
  case "$unpack" in
    members|tree)
      filename=$(basename "$url")
      fetch_artifact "$url" "$sha" "$filename"
      mkdir -p "$into"
      if [ "$unpack" = "members" ]; then
        ohai "Unpacking $name $version into $into"
        rm -rf "$PREFIX/.unpack"
        mkdir -p "$PREFIX/.unpack"
        # shellcheck disable=SC2046
        execute tar -xzf "$DOWNLOADS/$filename" -C "$PREFIX/.unpack" $(tool_artifact "$tool" MEMBERS)
        for member in $(tool_artifact "$tool" MEMBERS); do
          execute mv -f "$PREFIX/.unpack/$member" "$into/$(basename "$member")"
          chmod 755 "$into/$(basename "$member")"
        done
        rm -rf "$PREFIX/.unpack"
      else
        ohai "Unpacking $name $version into $into"
        rm -rf "$into.staging"
        mkdir -p "$into.staging"
        case "$filename" in
          *.tar.xz) execute tar -xJf "$DOWNLOADS/$filename" --strip-components=1 -C "$into.staging" ;;
          *) execute tar -xzf "$DOWNLOADS/$filename" --strip-components=1 -C "$into.staging" ;;
        esac
        rm -rf "$into"
        execute mv "$into.staging" "$into"
        [ "$tool" = "playwright_core" ] && write_playwright_wrapper
      fi ;;
    binary)
      filename=$(basename "$url")
      fetch_artifact "$url" "$sha" "$filename"
      mkdir -p "$into"
      for member in $(tool_artifact "$tool" MEMBERS); do
        ohai "Installing $name $version as $into/$member"
        execute cp -f "$DOWNLOADS/$filename" "$into/$member"
        chmod 755 "$into/$member"
      done ;;
    command)
      # The Chromium shell: playwright-core downloads it (HTTPS-only; it
      # verifies no hash — the one row the manifest cannot pin).
      local command
      command=$(tool_field "$tool" COMMAND)
      if [ -n "${RHO_BROWSER_FULL_CHROMIUM:-}" ]; then command="${command// --only-shell/}"; fi
      # shellcheck disable=SC2086
      run "$PREFIX/bin/rho-playwright" $command
      if [ "$OS" = "linux" ] && [ -z "$DRY_RUN" ]; then
        CHROMIUM_APT_LINE="sudo apt-get install -y $(chromium_apt_packages)"
      fi ;;
    *) abort "rho install: unknown unpack kind '$unpack' for $name" ;;
  esac
  record_tool "$tool" "$name" "$version" "$sha"
}

chromium_apt_packages() {
  local id version key
  id=$(sed -n 's/^ID=//p' /etc/os-release 2>/dev/null | tr -d '"')
  version=$(sed -n 's/^VERSION_ID=//p' /etc/os-release 2>/dev/null | tr -d '"')
  key="${id}${version}"
  key="${key//./_}"
  case " $RHO_APT_CHROMIUM_DISTROS " in
    *" $key "*) lookup "RHO_APT_CHROMIUM_${key}" ;;
    *) lookup "RHO_APT_CHROMIUM_ubuntu26_04" ;;
  esac
}
# ---------------------------------------------------------------------------
# Step: the wrapper and the shims. The environment is rho's own process's:
# PATH (the toolchain, for rho and every tool child — rg, fd, jq, uv shadow
# the person's inside the model's shell, by design), the prefix, the locale
# rule, the bootsnap cache root, and Ruby's spelling of "load the app from
# the prefix". Nothing Playwright- or uv-specific: the driver is found from
# RHO_PREFIX at rho's own spawn site, the browsers dir is set inside
# bin/rho-playwright, uv is unconfigured.
# THE TRUST STORE: the portable Ruby's
# OpenSSL is static and reads its roots from the path its builder had
# (/home/linuxbrew/.linuxbrew/Cellar/portable-openssl/…/cert.pem), absent
# on every other machine — so a Ruby-side HTTPS (rho-web-tools' fetch, an http
# MCP server, MCP OAuth, `rho update`'s own fetches) verifies nothing.
# When that compiled path is absent the host's bundle is probed here — the
# distros' spellings, Go's crypto/x509 list — and baked into the wrapper
# as SSL_CERT_FILE (OpenSSL's own override, read by every build), which
# the daemon and every tool child inherit; a person's own value wins.
# Prints the path, or nothing: `rho doctor`'s tls row says what came of it.
trust_store_file() {
  local compiled candidate
  compiled=$( ( scrub_ruby_env; exec "$RUBY_DIR/bin/ruby" -ropenssl -e 'print OpenSSL::X509::DEFAULT_CERT_FILE' ) 2>/dev/null )
  [ -n "$compiled" ] && [ -r "$compiled" ] && return 0
  for candidate in /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt /etc/ssl/ca-bundle.pem \
      /etc/pki/tls/cacert.pem /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem /etc/ssl/cert.pem; do
    if [ -r "$candidate" ]; then printf "%s" "$candidate"; return 0; fi
  done
  warn "no CA bundle found on this host (the portable OpenSSL's own path ${compiled:-is unknown and} is absent): Ruby-side HTTPS cannot verify certificates until one is installed (ca-certificates) — rho doctor reports it"
}

write_wrapper() {
  local name="$1" entry="$2" bootsnap_default trust_store trust_store_line=""
  if [ -n "$BAKED_BOOTSNAP_CACHE" ]; then
    bootsnap_default="$BAKED_BOOTSNAP_CACHE"
  else
    # shellcheck disable=SC2016
    bootsnap_default='${RHO_HOME:-$HOME/.rho}/cache/bootsnap'
  fi
  ohai "Writing $PREFIX/bin/$name"
  [ -n "$DRY_RUN" ] && return 0
  trust_store=$(trust_store_file)
  if [ -n "$trust_store" ]; then
    ohai "Naming the trust store $trust_store in bin/$name (the portable OpenSSL's compiled path is absent)"
    # shellcheck disable=SC2016
    trust_store_line='export SSL_CERT_FILE="${SSL_CERT_FILE:-'"$trust_store"'}"'
  fi
  mkdir -p "$PREFIX/bin"
  cat > "$PREFIX/bin/$name.new" <<WRAPPER
#!/bin/bash
# generated by rho's install.sh — RHO_PREFIX is baked in; \`rho update\` rewrites this file.
RHO_PREFIX="$PREFIX"
export RHO_PREFIX
# UTF-8 before Ruby starts, only when nothing governs (Rho::Locale's rule):
# ARGV is tagged with the locale encoding before exe/rho's first line runs.
if [ -z "\${LC_ALL:-}\${LC_CTYPE:-}\${LANG:-}" ]; then export LANG=C.UTF-8; fi
export PATH="\$RHO_PREFIX/bin:\$PATH"
export RHO_BOOTSNAP_CACHE_DIR="\${RHO_BOOTSNAP_CACHE_DIR:-$bootsnap_default}"
$trust_store_line
unset RUBYOPT RUBYLIB GEM_HOME GEM_PATH BUNDLER_VERSION BUNDLE_BIN_PATH BUNDLER_SETUP
# shellcheck disable=SC2046
for rho_name in \$(compgen -v BUNDLE_ 2>/dev/null); do unset "\$rho_name"; done
unset rho_name
export BUNDLE_GEMFILE="\$RHO_PREFIX/current/$RHO_APP_GEMFILE"
export BUNDLE_PATH="\$RHO_PREFIX/current/vendor/bundle"
export BUNDLE_DEPLOYMENT=1
export BUNDLE_WITHOUT="$RHO_APP_BUNDLE_WITHOUT"
exec "\$RHO_PREFIX/ruby/current/bin/ruby" -rbundler/setup "\$RHO_PREFIX/current/$entry" "\$@"
WRAPPER
  chmod 755 "$PREFIX/bin/$name.new"
  mv -f "$PREFIX/bin/$name.new" "$PREFIX/bin/$name"
}

# The driver: Node + playwright-core pinned to the gem's version; the
# browsers directory scoped to THIS process and its Chromium, never to a
# tool child.
write_playwright_wrapper() {
  ohai "Writing $PREFIX/bin/rho-playwright"
  [ -n "$DRY_RUN" ] && return 0
  mkdir -p "$PREFIX/bin"
  cat > "$PREFIX/bin/rho-playwright" <<WRAPPER
#!/bin/bash
# generated by rho's install.sh: the Playwright driver rho's browser extension speaks to.
RHO_PREFIX="$PREFIX"
export PLAYWRIGHT_BROWSERS_PATH="\${PLAYWRIGHT_BROWSERS_PATH:-\$RHO_PREFIX/browsers}"
exec "\$RHO_PREFIX/lib/playwright/node/bin/node" "\$RHO_PREFIX/lib/playwright/package/cli.js" "\$@"
WRAPPER
  chmod 755 "$PREFIX/bin/rho-playwright"
}

# `python3` for a model's `python3 -m http.server`, only when the host has
# none: uv runs (and, once, downloads) a CPython into uv's own default dir.
write_python_shim() {
  [ -x "$PREFIX/bin/uv" ] || return 0
  if have python3 && [ "$(command -v python3)" != "$PREFIX/bin/python3" ]; then
    rm -f "$PREFIX/bin/python3"
    return 0
  fi
  ohai "Writing $PREFIX/bin/python3 (this host has no python3; uv provides one on first use)"
  [ -n "$DRY_RUN" ] && return 0
  cat > "$PREFIX/bin/python3" <<SHIM
#!/bin/bash
# generated by rho's install.sh: a python3 for the model's shell, from uv, because this host had none.
exec "$PREFIX/bin/uv" run --no-project --python 3.13 python "\$@"
SHIM
  chmod 755 "$PREFIX/bin/python3"
}

# ---------------------------------------------------------------------------
# Step: the launcher and the PATH line (printed unless --modify-path).
# shellcheck disable=SC2016
RC_LINE='export PATH="$HOME/.local/bin:$PATH"   # rho'
rc_file() {
  case "${SHELL:-}" in
    */zsh) printf "%s" "$HOME/.zprofile" ;;
    */bash) if [ "$OS" = "darwin" ]; then printf "%s" "$HOME/.bash_profile"; else printf "%s" "$HOME/.bashrc"; fi ;;
    */fish) printf "%s" "$HOME/.config/fish/config.fish" ;;
    *) printf "%s" "$HOME/.profile" ;;
  esac
}

link_launcher() {
  local name launcher
  [ -n "$DRY_RUN" ] && return 0
  mkdir -p "$LAUNCHER_DIR"
  for name in rho cmctl; do
    launcher="$LAUNCHER_DIR/$name"
    ohai "Linking $launcher -> $PREFIX/bin/$name"
    if [ -e "$launcher" ] && [ ! -L "$launcher" ]; then
      warn "$launcher exists and is not a symlink; leaving it alone (run $PREFIX/bin/$name directly, or remove it and re-run)"
      continue
    fi
    ln -sfn "$PREFIX/bin/$name" "$launcher" || abort "rho install: could not link $launcher"
  done
}

RC_WRITTEN=""
launcher_on_path() {
  # shellcheck disable=SC2031
  case ":$PATH:" in
    *":$LAUNCHER_DIR:"*) return 0 ;;
    *) return 1 ;;
  esac
}
offer_path_line() {
  local file line
  if launcher_on_path; then
    return 0
  fi
  file=$(rc_file)
  if [ "${SHELL:-}" != "${SHELL%fish}" ]; then
    line="fish_add_path $LAUNCHER_DIR   # rho"
  else
    line="export PATH=\"$LAUNCHER_DIR:\$PATH\"   # rho"
  fi
  if [ -n "$MODIFY_PATH" ]; then
    ohai "Adding the PATH line to $file"
    [ -n "$DRY_RUN" ] && return 0
    mkdir -p "$(dirname "$file")"
    touch "$file"
    if ! grep -qxF "$line" "$file"; then
      printf "\n%s\n" "$line" >> "$file"
    fi
    RC_WRITTEN="$file"
    RC_LINE="$line"
  else
    RC_LINE="$line"
  fi
}

# ---------------------------------------------------------------------------
# Step: the receipts — receipt.json for rho (`doctor`, `Rho::Install`) and
# receipt.sh for this script (bash 3.2 reads no JSON) — and the copies.
write_receipts() {
  local now rc_file_recorded rc_line_recorded
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  [ -n "$DRY_RUN" ] && return 0
  # The rc line this run wrote, else the one a previous run recorded.
  if [ -n "$RC_WRITTEN" ]; then
    rc_file_recorded="$RC_WRITTEN"; rc_line_recorded="$RC_LINE"
  else
    rc_file_recorded="$RHO_RECEIPT_RC_FILE"; rc_line_recorded="$RHO_RECEIPT_RC_LINE"
  fi
  mkdir -p "$PREFIX/libexec"
  if ! [ "$0" -ef "$PREFIX/libexec/install.sh" ]; then
    cp -f "$0" "$PREFIX/libexec/install.sh"
    chmod 755 "$PREFIX/libexec/install.sh"
  fi
  if [ -f "$(dirname "$0")/docker-entrypoint" ] && ! [ "$(dirname "$0")/docker-entrypoint" -ef "$PREFIX/libexec/docker-entrypoint" ]; then
    cp -f "$(dirname "$0")/docker-entrypoint" "$PREFIX/libexec/docker-entrypoint"
    chmod 755 "$PREFIX/libexec/docker-entrypoint"
  fi
  if [ -f "$(dirname "$0")/t3-setup" ] && ! [ "$(dirname "$0")/t3-setup" -ef "$PREFIX/libexec/t3-setup" ]; then
    cp -f "$(dirname "$0")/t3-setup" "$PREFIX/libexec/t3-setup"
    chmod 755 "$PREFIX/libexec/t3-setup"
  fi
  printf "%s\n" "$RHO_MANIFEST_JSON" > "$PREFIX/manifest.json"
  cat > "$RECEIPT_JSON.new" <<RECEIPT
{
  "receipt_version": 1,
  "installed_at": "$now",
  "manifest_generated": "$RHO_MANIFEST_GENERATED",
  "profile": "$PROFILE",
  "platform": "$PLATFORM",
  "prefix": "$PREFIX",
  "source_path": "$APP_SOURCE_PATH",
  "app": { "version": "$APP_VERSION", "commit": "$APP_COMMIT" },
  "ruby": { "version": "$RUBY_VERSION", "sha256": "$RUBY_SHA", "bundler": "$RHO_RUBY_BUNDLER" },
  "current": "$VERSION_NAME",
  "previous": "$PREVIOUS",
  "launcher": "$LAUNCHER",
  "rc_file": "$rc_file_recorded",
  "rc_line": "$(printf "%s" "$rc_line_recorded" | sed 's/"/\\"/g')",
  "bootsnap_cache": "$BAKED_BOOTSNAP_CACHE",
  "tools": { $RECEIPT_TOOLS_JSON }
}
RECEIPT
  mv -f "$RECEIPT_JSON.new" "$RECEIPT_JSON"
  {
    printf "# written by install.sh; the same facts as receipt.json, for bash\n"
    printf "RHO_RECEIPT_VERSION=1\nRHO_RECEIPT_INSTALLED_AT=\"%s\"\nRHO_RECEIPT_PROFILE=\"%s\"\nRHO_RECEIPT_PLATFORM=\"%s\"\n" "$now" "$PROFILE" "$PLATFORM"
    printf "RHO_RECEIPT_SOURCE_PATH=\"%s\"\n" "$APP_SOURCE_PATH"
    printf "RHO_RECEIPT_APP_VERSION=\"%s\"\nRHO_RECEIPT_APP_COMMIT=\"%s\"\n" "$APP_VERSION" "$APP_COMMIT"
    printf "RHO_RECEIPT_RUBY_VERSION=\"%s\"\nRHO_RECEIPT_RUBY_SHA256=\"%s\"\nRHO_RECEIPT_BUNDLER=\"%s\"\n" "$RUBY_VERSION" "$RUBY_SHA" "$RHO_RUBY_BUNDLER"
    printf "RHO_RECEIPT_CURRENT=\"%s\"\nRHO_RECEIPT_PREVIOUS=\"%s\"\nRHO_RECEIPT_LAUNCHER=\"%s\"\n" "$VERSION_NAME" "$PREVIOUS" "$LAUNCHER"
    printf "RHO_RECEIPT_RC_FILE=\"%s\"\nRHO_RECEIPT_RC_LINE='%s'\n" "$rc_file_recorded" "$rc_line_recorded"
    printf "RHO_RECEIPT_BOOTSNAP_CACHE=\"%s\"\n" "$BAKED_BOOTSNAP_CACHE"
    printf "RHO_RECEIPT_TOOLS=\"%s\"%s\n" "${RECORDED_TOOLS:-}" "$RECEIPT_TOOLS_SH"
  } > "$RECEIPT_SH.new"
  mv -f "$RECEIPT_SH.new" "$RECEIPT_SH"
}

# ---------------------------------------------------------------------------
# Step: prewarm (the bootsnap cold boot lands here, not in the first verb),
# then the doctor.
prewarm() {
  ohai "$PREFIX/bin/rho" version
  [ -n "$DRY_RUN" ] && return 0
  "$PREFIX/bin/rho" version || abort "rho install: the installed rho does not run"
  "$PREFIX/bin/rho" help >/dev/null 2>&1 || warn "rho help did not run cleanly"
}

run_doctor() {
  ohai "$PREFIX/bin/rho" doctor
  [ -n "$DRY_RUN" ] && return 0
  "$PREFIX/bin/rho" doctor || true
}

CHROMIUM_APT_LINE=""
epilogue() {
  printf "\n%sInstallation successful!%s\n\n" "$tty_bold" "$tty_reset"
  if ! launcher_on_path; then
    printf "Add rho to your PATH by running (or add the line to %s):\n  %s\n\n" "$(rc_file)" "$RC_LINE"
  fi
  if [ -n "$CHROMIUM_APT_LINE" ]; then
    printf "The Chromium shell needs shared libraries this script cannot install (root):\n  %s\n\n" "$CHROMIUM_APT_LINE"
  fi
  if [ "${RHO_MODE:-full}" = runner ]; then
    printf "Next: pair this runner with a Nexus:\n  rho connect --nexus-url https://nexus.example\n"
  else
    printf "Next: configure your model and optional Telegram connection:\n  rho setup --nexus-url https://nexus.example\n"
  fi
  printf "Then: rho server   (the daemon); rho doctor at any time; rho update; rho uninstall\n"
  if [ "$MODE" = install ] && [ -z "${NONINTERACTIVE-}" ] && [ "${RHO_MODE:-full}" != runner ]; then
    "$PREFIX/bin/rho" setup </dev/tty || warn "Setup did not finish; saved settings were retained. Run rho setup to continue."
  fi
}
# ---------------------------------------------------------------------------
# The daemon, for --restart and --uninstall: the announcement's pid.
announced_pid() {
  local file="$HOME_DIR/tmp/announcement.json"
  [ -f "$file" ] || return 1
  sed -n 's/.*"pid": *\([0-9][0-9]*\).*/\1/p' "$file" | head -n1
}
daemon_alive() {
  local pid
  pid=$(announced_pid) || return 1
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}
# `rho server` is a foreground process with no supervisor of rho's: the
# only definable restart is stop + print the start line.
stop_daemon() {
  local pid waited=0
  pid=$(announced_pid) || { ohai "No daemon announced under $HOME_DIR; nothing to stop"; return 0; }
  if ! kill -0 "$pid" 2>/dev/null; then
    ohai "The announced daemon (pid $pid) is not running"
    return 0
  fi
  ohai "Stopping the daemon (pid $pid, TERM)"
  kill -TERM "$pid" 2>/dev/null || true
  while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 30 ]; do
    sleep 1
    waited=$((waited + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    warn "the daemon (pid $pid) is still stopping after 30 s (a stop Nexus could not confirm is retried); start it again when it is gone"
  fi
  printf "\nStart it again with:\n  rho server\n"
}

# Tool rows carried over from the receipt untouched (rollback).
carry_tools() {
  local tool
  for tool in $RHO_RECEIPT_TOOLS; do
    record_tool "$tool" "$(tool_field "$tool" NAME)" "$(lookup "RHO_RECEIPT_TOOL_${tool}_VERSION")" "$(lookup "RHO_RECEIPT_TOOL_${tool}_SHA256")"
  done
}

# ---------------------------------------------------------------------------
# The modes.
# `rho update` with nothing new pulled: the receipt's commit is the
# checkout's and the pair is in place — nothing to rebuild. A direct run of
# the installer always restages (a developer's edited tree, an unpacked
# tree with no commit).
app_installed() {
  [ "$MODE" = "apply-update" ] || return 1
  [ -n "$APP_COMMIT" ] && [ "$RHO_RECEIPT_APP_COMMIT" = "$APP_COMMIT" ] || return 1
  [ "$RHO_RECEIPT_CURRENT" = "$VERSION_NAME" ] || return 1
  [ -d "$VERSION_DIR" ] && [ -L "$PREFIX/current" ] || return 1
  return 0
}

install_flow() {
  local tool
  check_prerequisites
  plan
  if [ -n "$DRY_RUN" ]; then
    printf "\n(dry run: nothing was changed)\n"
    exit 0
  fi
  [ -z "${NONINTERACTIVE-}" ] && wait_for_user
  lock_prefix
  mkdir -p "$PREFIX/bin" "$PREFIX/ruby" "$PREFIX/versions" "$PREFIX/libexec" "$PREFIX/cache"
  chmod 755 "$PREFIX"
  install_ruby
  install_bundler
  if [ "$MODE" = "add-rows" ] || app_installed; then
    ohai "rho $APP_VERSION ($VERSION_NAME${APP_COMMIT:+, commit ${APP_COMMIT:0:7}}) is already installed"
    PREVIOUS="$RHO_RECEIPT_PREVIOUS"
    [ -L "$PREFIX/ruby/current" ] || swap_link "$RUBY_VERSION" "$PREFIX/ruby/current"
  else
    stage_app
    bundle_app
    activate_app
  fi
  for tool in $(profile_tools); do
    install_tool "$tool"
  done
  write_wrapper rho "$RHO_APP_ENTRY"
  write_wrapper cmctl cmctl/exe/cmctl
  write_python_shim
  link_launcher
  offer_path_line
  write_receipts
  prewarm
  run_doctor
  [ -n "$RESTART" ] && stop_daemon
  epilogue
}

# The markers git leaves while a merge, rebase, cherry-pick, revert or
# bisect is unfinished (pi-web's dev_git_operation list); prints the first.
git_operation_in_progress() {
  local marker path
  for marker in MERGE_HEAD rebase-merge rebase-apply CHERRY_PICK_HEAD REVERT_HEAD sequencer BISECT_LOG; do
    path=$(git -C "$1" rev-parse --git-path "$marker" 2>/dev/null) || continue
    case "$path" in /*) ;; *) path="$1/$path" ;; esac
    if [ -e "$path" ]; then printf "%s" "$marker"; return 0; fi
  done
  return 1
}

# `rho update`: the checkout this install came from is pulled (fast-forward
# only, never a branch switch), then ITS install/install.sh runs in
# apply-update mode — the pulled script is the new truth. Two prints come
# first, the commit range and the script path, and `--dry-run` stops after
# them (a fetch stands in for the pull, so the tree is untouched).
update_mode() {
  [ -f "$RECEIPT_SH" ] || abort "rho install: nothing is installed at $PREFIX (no receipt)."
  if in_container; then
    abort "rho update: inside a container the image rolls, not the prefix:" "  docker compose pull && docker compose up -d" "(\`rho update --add-rows\` adds a profile's tool rows in place)."
  fi
  local source old new marker script verb
  source="$RHO_RECEIPT_SOURCE_PATH"
  if [ ! -f "$source/agents/rho/rho/rho.gemspec" ] || [ -z "$(checkout_commit "$source")" ]; then
    abort "rho update: this rho was installed from $source, which is gone or is not a git checkout; re-install from a clone:" \
      "  git clone https://github.com/jasl/cybros.ai.git && bash cybros.ai/install/install.sh --profile $PROFILE"
  fi
  if marker=$(git_operation_in_progress "$source"); then
    abort "rho update: a git operation is in progress in $source ($marker); finish or abort it, then re-run."
  fi
  old=$(git -C "$source" rev-parse HEAD)
  if [ -n "$DRY_RUN" ]; then
    ohai git -C "$source" fetch
    GIT_TERMINAL_PROMPT=0 git -C "$source" fetch || abort "rho update: git fetch failed in $source (git's line above)."
    new=$(git -C "$source" rev-parse '@{u}' 2>/dev/null) || abort "rho update: the branch checked out in $source tracks no upstream; \`git branch --set-upstream-to\` it, or pull by hand."
  else
    ohai git -C "$source" pull --ff-only
    GIT_TERMINAL_PROMPT=0 git -C "$source" pull --ff-only || abort "rho update: git pull --ff-only failed in $source (git's line above; a diverged or conflicting tree is yours to reconcile)."
    new=$(git -C "$source" rev-parse HEAD)
  fi
  if [ "$old" = "$new" ]; then
    ohai "Nothing new: $source is at ${new:0:7}"
  else
    verb="Pulled"; [ -n "$DRY_RUN" ] && verb="Would pull"
    ohai "$verb ${old:0:7}..${new:0:7}:"
    git -C "$source" log --oneline "$old..$new"
  fi
  script="$source/install/install.sh"
  [ -f "$script" ] || abort "rho update: $script is missing from the checkout."
  set -- --apply-update --from-checkout "$source" --profile "$PROFILE" --non-interactive
  [ -n "$RESTART" ] && set -- "$@" --restart
  [ -n "$MODIFY_PATH" ] && set -- "$@" --modify-path
  if [ -n "$DRY_RUN" ]; then
    ohai "Would run: /bin/bash $script $*"
    printf "\n(dry run: nothing was changed; the checkout was fetched, not pulled)\n"
    exit 0
  fi
  ohai "Running: /bin/bash $script $*"
  RHO_PREFIX="$PREFIX" exec /bin/bash "$script" "$@"
}
rollback_mode() {
  local previous ruby old_current
  previous="$RHO_RECEIPT_PREVIOUS"
  [[ -n "$previous" && -d "$PREFIX/versions/$previous" ]] || abort "rho update --rollback: nothing to roll back to (the receipt names no previous version)."
  ruby=$(cat "$PREFIX/versions/$previous/.ruby" 2>/dev/null)
  [[ -n "$ruby" && -x "$PREFIX/ruby/$ruby/bin/ruby" ]] || abort "rho update --rollback: $previous was built against Ruby '$ruby', which is gone."
  ohai "Rolling back: current $RHO_RECEIPT_CURRENT -> $previous (ruby $ruby)"
  [ -n "$DRY_RUN" ] && exit 0
  lock_prefix
  old_current="$RHO_RECEIPT_CURRENT"
  trap '' INT
  swap_link "versions/$previous" "$PREFIX/current"
  swap_link "$ruby" "$PREFIX/ruby/current"
  trap - INT
  VERSION_NAME="$previous"
  PREVIOUS="$old_current"
  RUBY_VERSION="$ruby"
  RUBY_SHA=""
  APP_VERSION="${previous%%-*}"
  APP_COMMIT=$(cat "$PREFIX/versions/$previous/.commit")
  APP_SOURCE_PATH="$RHO_RECEIPT_SOURCE_PATH"
  carry_tools
  write_receipts
  prewarm
  [ -n "$RESTART" ] && stop_daemon
  printf "\nRolled back to %s. Restart the daemon (rho server) to run it.\n" "$previous"
}

uninstall_mode() {
  local cmctl_launcher
  [ -d "$PREFIX" ] || abort "rho uninstall: nothing at $PREFIX."
  if daemon_alive && [ -z "$FORCE" ]; then
    abort "rho uninstall: a daemon is running (pid $(announced_pid)); stop it first (kill -TERM $(announced_pid)), or pass --force."
  fi
  printf "%sThis will remove:%s\n  %s\n" "$tty_bold" "$tty_reset" "$PREFIX"
  [ -L "$RHO_RECEIPT_LAUNCHER" ] && printf "  %s (the launcher)\n" "$RHO_RECEIPT_LAUNCHER"
  [ -n "$RHO_RECEIPT_RC_FILE" ] && printf "  the line '%s' from %s\n" "$RHO_RECEIPT_RC_LINE" "$RHO_RECEIPT_RC_FILE"
  if [ -n "$PURGE" ]; then
    printf "  %s (RHO_HOME: credentials, the instance, logs — after disconnecting from Nexus)\n" "$HOME_DIR"
  else
    printf "  (RHO_HOME %s is kept; --purge removes it)\n" "$HOME_DIR"
  fi
  [ -n "$DRY_RUN" ] && exit 0
  [ -z "${NONINTERACTIVE-}" ] && wait_for_user
  if [ -n "$PURGE" ] && [ -f "$HOME_DIR/nexus.json" ] && [ -x "$PREFIX/bin/rho" ]; then
    ohai "Disconnecting from Nexus first (a deleted home without a disconnect leaves a live row only an operator can revoke)"
    "$PREFIX/bin/rho" disconnect || warn "disconnect did not succeed; the row on Nexus may need an operator's revoke"
  fi
  if [ -L "$RHO_RECEIPT_LAUNCHER" ]; then
    case "$(readlink "$RHO_RECEIPT_LAUNCHER")" in
      "$PREFIX"/*) ohai "Removing $RHO_RECEIPT_LAUNCHER"; rm -f "$RHO_RECEIPT_LAUNCHER" ;;
      *) warn "$RHO_RECEIPT_LAUNCHER points elsewhere; left alone" ;;
    esac
  fi
  cmctl_launcher="$(dirname "$RHO_RECEIPT_LAUNCHER")/cmctl"
  if [ -L "$cmctl_launcher" ]; then
    case "$(readlink "$cmctl_launcher")" in
      "$PREFIX"/*) ohai "Removing $cmctl_launcher"; rm -f "$cmctl_launcher" ;;
      *) warn "$cmctl_launcher points elsewhere; left alone" ;;
    esac
  fi
  if [ -n "$RHO_RECEIPT_RC_FILE" ] && [ -f "$RHO_RECEIPT_RC_FILE" ] && grep -qxF "$RHO_RECEIPT_RC_LINE" "$RHO_RECEIPT_RC_FILE"; then
    ohai "Removing the PATH line from $RHO_RECEIPT_RC_FILE"
    grep -vxF "$RHO_RECEIPT_RC_LINE" "$RHO_RECEIPT_RC_FILE" > "$RHO_RECEIPT_RC_FILE.rho-uninstall" && mv -f "$RHO_RECEIPT_RC_FILE.rho-uninstall" "$RHO_RECEIPT_RC_FILE"
  fi
  ohai "Removing $PREFIX"
  rm -rf "$PREFIX"
  if [ -n "$PURGE" ]; then
    ohai "Removing $HOME_DIR"
    rm -rf "$HOME_DIR"
  else
    printf "\nKept: %s (RHO_HOME). Remove it yourself, or re-run with --purge.\n" "$HOME_DIR"
  fi
  case "$DOWNLOADS" in
    "$PREFIX"/*) ;;
    *) printf "Kept: %s (the download cache).\n" "$DOWNLOADS" ;;
  esac
  printf "rho is uninstalled.\n"
}

# ---------------------------------------------------------------------------
main() {
  [ -n "$DRY_RUN" ] && [ "$MODE" != "install" ] && [ "$MODE" != "apply-update" ] && [ "$MODE" != "add-rows" ] && NONINTERACTIVE=1
  case "$MODE" in
    install|apply-update|add-rows)
      if [ "$MODE" = "add-rows" ]; then
        [ -f "$RECEIPT_SH" ] || abort "rho install --add-rows: nothing is installed at $PREFIX."
        VERSION_NAME="$RHO_RECEIPT_CURRENT"; VERSION_DIR="$PREFIX/versions/$VERSION_NAME"
        APP_VERSION="$RHO_RECEIPT_APP_VERSION"; APP_COMMIT="$RHO_RECEIPT_APP_COMMIT"; APP_SOURCE_PATH="$RHO_RECEIPT_SOURCE_PATH"
        RUBY_VERSION="$RHO_RECEIPT_RUBY_VERSION"; RUBY_DIR="$PREFIX/ruby/$RUBY_VERSION"
        NONINTERACTIVE=1
      fi
      if [ "$MODE" = "apply-update" ]; then
        [ -f "$RECEIPT_SH" ] || abort "rho update: nothing is installed at $PREFIX."
        NONINTERACTIVE=1
      fi
      install_flow ;;
    update) update_mode ;;
    rollback) rollback_mode ;;
    uninstall) uninstall_mode ;;
  esac
}

# Sourced (the shell tests load the functions): nothing runs.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main
fi
