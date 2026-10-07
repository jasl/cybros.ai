
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
