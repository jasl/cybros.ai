#!/bin/bash
# `rho update`'s ladder and its dry run, OFFLINE (the rolling update): a bare upstream seeded from this
# working tree, a clone of it as the install's source, a fabricated receipt
# in a temp prefix — no portable Ruby, no gems, nothing downloaded, so CI's
# offline set runs it. The refusals in their order (no receipt; the source
# gone, or not a git checkout; an unfinished git operation), then
# `--update --dry-run` (a fetch, the two prints — the commit range and the
# script that would run — and nothing pulled), the flags carried onto that
# line, "nothing new", and the no-remote answer (git's own line, before any
# exec). The container refusal cannot be faked without /.dockerenv; the real
# pull and re-install are install_test.sh's (network).
# shellcheck disable=SC1091
. "$(dirname "$0")/helpers.sh"

export RHO_PREFIX="$TEST_TMP/prefix" RHO_HOME="$TEST_TMP/home" RHO_LAUNCHER_DIR="$TEST_TMP/bin" NONINTERACTIVE=1
unset RHO_MODIFY_PATH RHO_SOURCE RHO_PROFILE || true

upstream="$TEST_TMP/upstream.git"
checkout="$TEST_TMP/checkout"
seed_upstream "$upstream"
git_quiet clone -q "$upstream" "$checkout"
old=$(git -C "$checkout" rev-parse HEAD)

# The receipt as `install.sh --update` reads it (receipt.sh; every other row defaults).
receipt() {
  mkdir -p "$RHO_PREFIX"
  printf 'RHO_RECEIPT_PROFILE="full"\nRHO_RECEIPT_SOURCE_PATH="%s"\nRHO_RECEIPT_LAUNCHER="%s/rho"\n' "$1" "$RHO_LAUNCHER_DIR" > "$RHO_PREFIX/receipt.sh"
}

# --- 1. no receipt
assert_exit 1 "update without a receipt" -- env RHO_PREFIX="$TEST_TMP/nowhere" /bin/bash "$INSTALLER" --update
assert_contains "$LAST_OUTPUT" "nothing is installed at $TEST_TMP/nowhere" "the first rung"
pass "no receipt: refused"

# --- 2. the source gone, or not a git checkout
receipt "$TEST_TMP/gone"
assert_exit 1 "update with the source gone" -- /bin/bash "$INSTALLER" --update
assert_contains "$LAST_OUTPUT" "gone or is not a git checkout" "the reason"
assert_contains "$LAST_OUTPUT" "git clone https://github.com/jasl/cybros.ai.git && bash cybros.ai/install/install.sh --profile full" "the re-install line"
unpacked="$TEST_TMP/unpacked"
mkdir -p "$unpacked"
( cd "$checkout" && tar -cf - --exclude=.git . ) | tar -xf - -C "$unpacked"
receipt "$unpacked"
assert_exit 1 "update from an unpacked tree" -- /bin/bash "$INSTALLER" --update
assert_contains "$LAST_OUTPUT" "gone or is not a git checkout" "an unpacked tree installs but never updates"
pass "source gone / not a checkout: refused, the clone line printed"

# --- 3. an unfinished git operation
receipt "$checkout"
for marker in MERGE_HEAD CHERRY_PICK_HEAD rebase-merge; do
  case "$marker" in rebase-merge) mkdir "$checkout/.git/$marker" ;; *) touch "$checkout/.git/$marker" ;; esac
  assert_exit 1 "update under $marker" -- /bin/bash "$INSTALLER" --update
  assert_contains "$LAST_OUTPUT" "a git operation is in progress in $checkout ($marker)" "the marker is named"
  rm -rf "${checkout:?}/.git/$marker"
done
pass "an unfinished merge / cherry-pick / rebase: refused"

# --- 4. --dry-run: a fetch, the two prints, nothing pulled, nothing run
new=$(upstream_commit "$upstream" "one upstream commit")
assert_exit 0 "update --dry-run" -- /bin/bash "$INSTALLER" --update --dry-run
assert_contains "$LAST_OUTPUT" "Would pull ${old:0:7}..${new:0:7}:" "the first print: the commit range"
assert_contains "$LAST_OUTPUT" "${new:0:7} one upstream commit" "git log --oneline of the range"
assert_contains "$LAST_OUTPUT" "Would run: /bin/bash $checkout/install/install.sh --apply-update --from-checkout $checkout --profile full --non-interactive" "the second print: the script"
assert_contains "$LAST_OUTPUT" "nothing was changed" "dry run says so"
assert_eq "$(git -C "$checkout" rev-parse HEAD)" "$old" "the checkout was fetched, not pulled"
[ ! -e "$RHO_PREFIX/versions" ] || fail "--dry-run touched the prefix"
pass "--dry-run prints the range and the script, pulls nothing"

assert_exit 0 "update --dry-run with the flags" -- /bin/bash "$INSTALLER" --update --dry-run --restart --modify-path --profile dev
assert_contains "$LAST_OUTPUT" "--profile dev --non-interactive --restart --modify-path" "the flags reach the script's line"
pass "--restart / --modify-path / --profile ride the exec line"

# --- 5. nothing new
git_quiet -C "$checkout" pull -q --ff-only
assert_exit 0 "update --dry-run with nothing new" -- /bin/bash "$INSTALLER" --update --dry-run
assert_contains "$LAST_OUTPUT" "Nothing new: $checkout is at ${new:0:7}" "an up-to-date checkout says so"
assert_contains "$LAST_OUTPUT" "Would run:" "and the script would still run (its manifest rows may have moved)"
pass "nothing new"

# --- 6. no remote: git's own line, before any exec
git -C "$checkout" remote remove origin
assert_exit 1 "update with no remote" -- /bin/bash "$INSTALLER" --update
assert_contains "$LAST_OUTPUT" "git pull --ff-only failed in $checkout" "the pull's failure is named"
assert_not_contains "$LAST_OUTPUT" "Running:" "nothing was run"
assert_exit 1 "update --dry-run with no remote" -- /bin/bash "$INSTALLER" --update --dry-run
assert_contains "$LAST_OUTPUT" "tracks no upstream" "a branch with no upstream has nothing to fetch and says so"
pass "no remote: git's answer, nothing run"
