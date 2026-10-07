#!/bin/bash
# Shared by install/test/*_test.sh: plain assertions under `set -e` (bats is
# not a prerequisite here), a temp root removed on exit, the paths.
# shellcheck disable=SC2034  # the paths are the test scripts' to read
set -eu

INSTALL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
REPO_ROOT=$(cd "$INSTALL_DIR/.." && pwd)
INSTALLER="$INSTALL_DIR/install.sh"
# Spelled as `pwd` spells it (a TMPDIR with a trailing slash would give
# `T//…`, and the installer records its paths through `cd && pwd`).
TEST_TMP=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/rho-install-test.XXXXXX")" && pwd)
trap 'rm -rf "$TEST_TMP"' EXIT

# Maintenance must not outlive these short-lived repositories and race cleanup.
# A local push's receive-pack inherits this file, but not Git's -c options.
export GIT_CONFIG_GLOBAL="$TEST_TMP/gitconfig"
git config --global maintenance.auto false
git config --global gc.auto 0

fail() { printf "FAIL: %s\n" "$*" >&2; exit 1; }
pass() { printf "  ok  %s\n" "$*"; }

assert_eq() { [ "$1" = "$2" ] || fail "$3: expected '$2', got '$1'"; }
assert_contains() { case "$1" in *"$2"*) ;; *) fail "$3: '$2' not found in: $1" ;; esac; }
assert_not_contains() { case "$1" in *"$2"*) fail "$3: '$2' found in: $1" ;; esac; }
assert_exit() {
  # assert_exit EXPECTED DESCRIPTION -- command…
  local expected="$1" description="$2" status
  shift 2
  [ "$1" = "--" ] && shift
  set +e
  "$@" >"$TEST_TMP/last.out" 2>&1
  status=$?
  set -e
  LAST_OUTPUT=$(cat "$TEST_TMP/last.out")
  [ "$status" = "$expected" ] || fail "$description: exit $status, expected $expected; output: $LAST_OUTPUT"
}

# git without the machine's identity or signing in the way.
git_quiet() { git -c user.name=rho-install-test -c user.email=rho-install-test@example.invalid -c commit.gpgsign=false -c gc.auto=0 "$@"; }

# seed_upstream BARE_DIR — a bare repository whose one commit is THIS working
# tree's installer and gem trees (uncommitted edits included: the tests test
# the code under test, never yesterday's HEAD). A clone of it is a checkout
# `rho update` can pull; no network, nothing of the real repository touched.
seed_upstream() {
  local stage="$TEST_TMP/seed"
  rm -rf "$stage"
  mkdir -p "$stage"
  ( cd "$REPO_ROOT" && tar -cf - --exclude=.git --exclude=tmp --exclude=log --exclude=coverage --exclude=node_modules \
      --exclude=vendor/bundle --exclude=.bundle --exclude=pkg install sdks/ruby cmctl agents/rho/rho-runner agents/rho/rho-browser agents/rho/rho-mcp agents/rho/rho-web-tools agents/rho/rho-codemode agents/rho/rho-webui agents/rho/rho-ingress-telegram agents/rho/rho-acp agents/rho/rho-acp-client agents/rho/rho-t3 agents/rho/rho ) \
    | tar -xf - -C "$stage"
  git_quiet -C "$stage" init -q -b main
  git_quiet -C "$stage" add -A
  git_quiet -C "$stage" commit -q -m "the working tree"
  git_quiet clone -q --bare "$stage" "$1"
}

# upstream_commit BARE_DIR MESSAGE — one commit pushed to the upstream by a
# second clone (a line appended to the rho README), the way a release lands.
upstream_commit() {
  local author="$TEST_TMP/author"
  rm -rf "$author"
  git_quiet clone -q "$1" "$author"
  printf "\n%s\n" "$2" >> "$author/agents/rho/rho/README.md"
  git_quiet -C "$author" commit -q -am "$2"
  git_quiet -C "$author" push -q origin main
  git_quiet -C "$author" rev-parse HEAD
}
