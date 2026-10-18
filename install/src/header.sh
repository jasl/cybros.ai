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
