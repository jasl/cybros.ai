#!/bin/bash
# The guards: the shell, POSIX mode, the two
# interactivity flags, the profile, unknown arguments, an unsupported
# platform, and what --dry-run prints.
# shellcheck disable=SC1091
. "$(dirname "$0")/helpers.sh"

export RHO_PREFIX="$TEST_TMP/prefix" RHO_HOME="$TEST_TMP/home" RHO_LAUNCHER_DIR="$TEST_TMP/bin" NONINTERACTIVE=1
unset INTERACTIVE CI || true

assert_exit 1 "POSIXLY_CORRECT aborts" -- env POSIXLY_CORRECT=1 /bin/bash "$INSTALLER" --dry-run
assert_contains "$LAST_OUTPUT" "POSIX mode" "the POSIX abort names it"
pass "POSIXLY_CORRECT"

assert_exit 1 "INTERACTIVE with NONINTERACTIVE aborts" -- env INTERACTIVE=1 NONINTERACTIVE=1 /bin/bash "$INSTALLER" --dry-run
assert_contains "$LAST_OUTPUT" "both INTERACTIVE and NONINTERACTIVE" "the flag abort names both"
pass "INTERACTIVE + NONINTERACTIVE"

assert_exit 1 "an unknown profile aborts" -- /bin/bash "$INSTALLER" --dry-run --profile wide
assert_contains "$LAST_OUTPUT" "unknown profile 'wide'" "the profile abort names it and the choices"
assert_contains "$LAST_OUTPUT" "runner full dev" "the profile abort lists the profiles"
pass "unknown profile"

assert_exit 1 "an unknown argument aborts" -- /bin/bash "$INSTALLER" --frobnicate
assert_contains "$LAST_OUTPUT" "unknown argument --frobnicate" "the argument abort names it"
pass "unknown argument"

mkdir -p "$TEST_TMP/fakebin"
# shellcheck disable=SC2016
printf '#!/bin/sh\ncase "$1" in -s) echo SunOS ;; *) echo sparc ;; esac\n' > "$TEST_TMP/fakebin/uname"
chmod 755 "$TEST_TMP/fakebin/uname"
assert_exit 1 "an unsupported OS aborts" -- env PATH="$TEST_TMP/fakebin:$PATH" /bin/bash "$INSTALLER" --dry-run
assert_contains "$LAST_OUTPUT" "only macOS and Linux are supported" "the platform abort"
pass "unsupported platform"

assert_exit 0 "--help exits 0" -- /bin/bash "$INSTALLER" --help
assert_contains "$LAST_OUTPUT" "git clone https://github.com/jasl/cybros.ai.git" "--help prints the clone-and-run line"
pass "--help"

assert_exit 0 "--dry-run from a checkout exits 0" -- /bin/bash "$INSTALLER" --dry-run --profile dev --from-checkout "$REPO_ROOT"
assert_contains "$LAST_OUTPUT" "This script will install rho" "the plan header"
assert_contains "$LAST_OUTPUT" "ghcr.io/v2/homebrew/core/portable-ruby/blobs/sha256:" "the Ruby URL is printed"
assert_contains "$LAST_OUTPUT" "nodejs.org/dist/" "the dev profile's Node URL is printed"
assert_contains "$LAST_OUTPUT" "registry.npmjs.org/playwright-core" "the driver URL is printed"
assert_contains "$LAST_OUTPUT" "nothing was changed" "dry run says so"
[ ! -e "$TEST_TMP/prefix" ] || fail "--dry-run created the prefix"
pass "--dry-run prints the plan and the URLs, changes nothing"

assert_exit 0 "--dry-run runner profile" -- /bin/bash "$INSTALLER" --dry-run --profile runner --from-checkout "$REPO_ROOT"
assert_not_contains "$LAST_OUTPUT" "jq 1" "the runner profile has no jq"
assert_not_contains "$LAST_OUTPUT" "uv 0" "the runner profile has no uv"
assert_contains "$LAST_OUTPUT" "rg 15" "the runner profile has rg"
pass "profiles select rows"

assert_exit 1 "--from-checkout on a non-checkout aborts" -- /bin/bash "$INSTALLER" --dry-run --from-checkout "$TEST_TMP"
assert_contains "$LAST_OUTPUT" "is not a cybros.ai checkout" "the checkout abort"
pass "--from-checkout validates the tree"
