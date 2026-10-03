#!/bin/bash
# The real thing (on this host; the rolling update): a checkout install into a temporary prefix with a
# temporary home and launcher dir — the checkout a clone of a bare upstream
# seeded from THIS working tree — then `rho version`, `rho doctor --strict`,
# a second run that keeps the previous version, a rollback, the update lane
# (one upstream commit; `rho update --dry-run`; `rho update`; nothing new;
# the rollback; the in-progress refusal; the no-remote answer),
# `--modify-path`, the uninstalls. Needs the network (the portable Ruby, the
# tool rows, the gems); RHO_INSTALL_TEST_CACHE keeps the downloads between
# runs. The ladder alone, offline, is update_test.sh.
# shellcheck disable=SC1091
. "$(dirname "$0")/helpers.sh"

export RHO_PREFIX="$TEST_TMP/prefix" RHO_HOME="$TEST_TMP/home" RHO_LAUNCHER_DIR="$TEST_TMP/bin" NONINTERACTIVE=1
export RHO_DOWNLOAD_CACHE="${RHO_INSTALL_TEST_CACHE:-$TEST_TMP/cache}"
unset RHO_NO_BOOTSNAP RHO_BOOTSNAP_CACHE_DIR RHO_MODIFY_PATH RHO_SOURCE RHO_PROFILE || true

upstream="$TEST_TMP/upstream.git"
checkout="$TEST_TMP/checkout"
seed_upstream "$upstream"
git_quiet clone -q "$upstream" "$checkout"
first=$(git -C "$checkout" rev-parse HEAD)

# Expected release values come from this checkout's manifest and gem. The
# same integration test runs on every platform the installer supports.
manifest_value() {
  ruby -rjson -e 'data = JSON.parse(File.read(ARGV.shift)); puts ARGV.reduce(data) { |row, key| row.fetch(key) }' \
    "$checkout/install/manifest.json" "$@"
}
expected_ruby=$(manifest_value runtime version)
expected_bundler=$(manifest_value runtime bundler)
expected_rg=$(manifest_value tools rg version)
expected_uv=$(manifest_value tools uv version)
expected_app=$(ruby -r "$checkout/agents/rho/rho/lib/rho/version" -e 'puts Rho::VERSION')
expected_pair="$expected_app-checkout-r$expected_ruby"
case "$(uname -s):$(uname -m)" in
  Darwin:arm64|Darwin:aarch64) expected_platform=darwin-arm64 ;;
  Darwin:x86_64|Darwin:amd64) expected_platform=darwin-x64 ;;
  Linux:arm64|Linux:aarch64) expected_platform=linux-arm64 ;;
  Linux:x86_64|Linux:amd64) expected_platform=linux-x64 ;;
  *) fail "the integration test requires a supported installer platform" ;;
esac
expected_rg_sha=$(manifest_value tools rg artifacts "$expected_platform" sha256)

# --- 1. a full-profile install from the checkout: the script's own repo root is the default source
assert_exit 0 "install from the checkout" -- /bin/bash "$checkout/install/install.sh" --profile full
assert_contains "$LAST_OUTPUT" "Installation successful" "the epilogue"
assert_contains "$LAST_OUTPUT" "Copying the packaged trees from $checkout (commit ${first:0:7})" "the default source is the checkout the script sits in"
assert_contains "$LAST_OUTPUT" "export PATH=\"$TEST_TMP/bin:\$PATH\"" "the PATH line is printed, not written"
pass "install from the checkout"

for path in bin/rho bin/cmctl bin/rg bin/fd bin/jq bin/uv bin/uvx libexec/install.sh manifest.json receipt.json receipt.sh; do
  [ -e "$RHO_PREFIX/$path" ] || fail "$path is missing from the prefix"
done
[[ -L "$RHO_PREFIX/current" && -L "$RHO_PREFIX/ruby/current" ]] || fail "the two current links are missing"
assert_eq "$(readlink "$RHO_PREFIX/ruby/current")" "${expected_ruby}" "ruby/current"
assert_eq "$(cat "$RHO_PREFIX/current/.ruby")" "${expected_ruby}" "the pair marker"
assert_eq "$(cat "$RHO_PREFIX/current/.commit")" "$first" "the version dir's .commit"
assert_eq "$(readlink "$RHO_LAUNCHER_DIR/rho")" "$RHO_PREFIX/bin/rho" "the launcher"
assert_eq "$(readlink "$RHO_LAUNCHER_DIR/cmctl")" "$RHO_PREFIX/bin/cmctl" "the operator CLI launcher"
[ ! -e "$RHO_PREFIX/lib/playwright" ] || fail "the full profile installed the dev rows"
pass "the layout"

wrapper=$(cat "$RHO_PREFIX/bin/rho")
assert_contains "$wrapper" "-rbundler/setup" "the wrapper loads the app without bundle exec"
assert_not_contains "$wrapper" "PLAYWRIGHT" "nothing Playwright-specific is exported"
assert_not_contains "$wrapper" "UV_" "nothing uv-specific is exported"
assert_not_contains "$wrapper" "RUBYOPT=" "no RUBYOPT"
# shellcheck disable=SC2016
assert_contains "$wrapper" 'export PATH="$RHO_PREFIX/bin:$PATH"' "PATH is prepended for rho and its children"
pass "the wrapper's environment is scoped"

assert_exit 0 "rho version" -- "$RHO_PREFIX/bin/rho" version
assert_eq "$LAST_OUTPUT" "${expected_app}" "rho version through the wrapper"
assert_exit 0 "rho version through the launcher" -- "$RHO_LAUNCHER_DIR/rho" version
pass "rho version"

assert_exit 0 "cmctl through the portable launcher" -- "$RHO_LAUNCHER_DIR/cmctl" --help
assert_contains "$LAST_OUTPUT" "cmctl" "the operator CLI is in the same bundle"
pass "cmctl shares the installed portable runtime"

assert_exit 0 "rho doctor --strict" -- "$RHO_PREFIX/bin/rho" doctor --strict
# The trust store: the row is green through the wrapper —
# the bundle's roots trusted by the default store, the openssl extension
# the portable Ruby's own, never a copy bundler built beside its static OpenSSL.
assert_contains "$LAST_OUTPUT" "ok    tls" "the tls row is green through the wrapper"
assert_contains "$LAST_OUTPUT" "(the Ruby's own)" "the openssl extension is the portable Ruby's own"
for copy in "$RHO_PREFIX"/current/vendor/bundle/ruby/*/gems/openssl-[0-9]*; do
  [ ! -e "$copy" ] || fail "vendor/bundle carries $copy (bundle install ran without --prefer-local)"
done
pass "the trust store is trusted, no openssl copy in vendor/bundle: $(printf '%s\n' "$LAST_OUTPUT" | grep ' tls ' | sed 's/^ *ok *tls *//')"
assert_contains "$LAST_OUTPUT" "rho ${expected_app} at ${first:0:7}, installed" "the heading names the commit"
assert_contains "$LAST_OUTPUT" "ok    bundler          ${expected_bundler} (the lock's)" "the lock's bundler loaded, no version flip"
assert_contains "$LAST_OUTPUT" "ok    current          ${expected_pair} on ruby ${expected_ruby}" "the pair"
assert_contains "$LAST_OUTPUT" "ok    rg               ${expected_rg}" "rg row"
assert_contains "$LAST_OUTPUT" "ok    uv               ${expected_uv}" "uv row"
assert_contains "$LAST_OUTPUT" "0 failures" "no red row"
pass "rho doctor --strict"

[ -d "$RHO_HOME/cache/bootsnap" ] || fail "no bootsnap cache under RHO_HOME after the prewarm"
mode=$(stat -f %Lp "$RHO_HOME" 2>/dev/null || stat -c %a "$RHO_HOME")
assert_eq "$mode" "700" "RHO_HOME was created private by the boot"
assert_exit 0 "rho version with bootsnap off" -- env RHO_NO_BOOTSNAP=1 "$RHO_PREFIX/bin/rho" version
pass "bootsnap cache under RHO_HOME, off switch honoured"

grep -q "^RHO_RECEIPT_SOURCE_PATH=\"$checkout\"$" "$RHO_PREFIX/receipt.sh" || fail "the receipt does not name the checkout"
grep -q "^RHO_RECEIPT_APP_COMMIT=\"$first\"$" "$RHO_PREFIX/receipt.sh" || fail "the receipt does not carry the checkout's commit"
grep -q "\"app\": { \"version\": \"${expected_app}\", \"commit\": \"$first\" }" "$RHO_PREFIX/receipt.json" || fail "receipt.json has no app.commit"
grep -q '"profile": "full"' "$RHO_PREFIX/receipt.json" || fail "receipt.json has no profile"
installed_platform=$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV.fetch(0))).fetch("platform")' "$RHO_PREFIX/receipt.json")
assert_eq "$installed_platform" "$expected_platform" "the receipt's platform matches this host"
ruby -rjson -e '
  receipt = JSON.parse(File.read(ARGV.fetch(0)))
  rg = receipt.fetch("tools").fetch("rg")
  abort "receipt.json has the wrong rg version or platform digest" unless
    rg.fetch("version") == ARGV.fetch(1) && rg.fetch("sha256") == ARGV.fetch(2)
' "$RHO_PREFIX/receipt.json" "$expected_rg" "$expected_rg_sha"
ruby -rjson -e 'JSON.parse(File.read(ARGV[0], encoding: "UTF-8"))' "$RHO_PREFIX/receipt.json" || fail "receipt.json is not JSON"
ruby -rjson -e 'JSON.parse(File.read(ARGV[0], encoding: "UTF-8"))' "$RHO_PREFIX/manifest.json" || fail "manifest.json is not JSON"
pass "the receipts"

# --- 2. the refusal a fresh install has (the update ladder's are update_test.sh's)
assert_exit 1 "rollback with no previous refuses" -- "$RHO_PREFIX/bin/rho" update --rollback
assert_contains "$LAST_OUTPUT" "nothing to roll back to" "rollback names the reason"
pass "rho update --rollback refuses with no previous"

# --- 3. a second run (a direct run always restages): idempotent rows, the previous version kept
assert_exit 0 "second install" -- /bin/bash "$checkout/install/install.sh"
assert_contains "$LAST_OUTPUT" "Portable Ruby ${expected_ruby} is already installed" "the Ruby row is skipped"
assert_contains "$LAST_OUTPUT" "bundler ${expected_bundler} is already in the portable Ruby" "the bundler row is skipped"
assert_contains "$LAST_OUTPUT" "rg ${expected_rg} is already installed" "the rg row is skipped"
assert_contains "$LAST_OUTPUT" "Seeding vendor/bundle" "the bundle is seeded from the same-Ruby version"
assert_not_contains "$LAST_OUTPUT" "with native extensions" "nothing recompiled on the second run"
grep -q '^RHO_RECEIPT_PROFILE="full"$' "$RHO_PREFIX/receipt.sh" || fail "the profile did not default to the receipt's"
grep -q "^RHO_RECEIPT_PREVIOUS=\"${expected_pair}.old\"$" "$RHO_PREFIX/receipt.sh" || fail "the previous version was not kept"
[ -d "$RHO_PREFIX/versions/${expected_pair}.old" ] || fail "the previous versions dir is gone"
pass "a re-run skips the rows at the manifest's sha and keeps the previous version"

# --- 4. rollback moves the pair back
assert_exit 0 "rollback" -- "$RHO_PREFIX/bin/rho" update --rollback
assert_eq "$(readlink "$RHO_PREFIX/current")" "versions/${expected_pair}.old" "current after rollback"
assert_eq "$(readlink "$RHO_PREFIX/ruby/current")" "${expected_ruby}" "ruby/current after rollback"
grep -q "^RHO_RECEIPT_CURRENT=\"${expected_pair}.old\"$" "$RHO_PREFIX/receipt.sh" || fail "the receipt's current did not move"
grep -q "^RHO_RECEIPT_PREVIOUS=\"${expected_pair}\"$" "$RHO_PREFIX/receipt.sh" || fail "the receipt's previous did not move"
grep -q "^RHO_RECEIPT_APP_COMMIT=\"$first\"$" "$RHO_PREFIX/receipt.sh" || fail "app.commit is not the rolled-back dir's"
grep -qxF "RHO_RECEIPT_TOOL_rg_SHA256=\"$expected_rg_sha\"" "$RHO_PREFIX/receipt.sh" || fail "the tool rows were not carried over the rollback"
assert_exit 0 "rho version after rollback" -- "$RHO_PREFIX/bin/rho" version
assert_exit 0 "rho doctor --strict after rollback" -- "$RHO_PREFIX/bin/rho" doctor --strict
pass "rollback moves current and ruby/current together"

# --- 5. the update lane: one upstream commit, the dry run, the real pull, nothing new, rollback, the refusals
second=$(upstream_commit "$upstream" "one upstream commit")

assert_exit 0 "rho update --dry-run" -- "$RHO_PREFIX/bin/rho" update --dry-run
assert_contains "$LAST_OUTPUT" "Would pull ${first:0:7}..${second:0:7}:" "the first print: the commit range"
assert_contains "$LAST_OUTPUT" "${second:0:7} one upstream commit" "git log --oneline of the range"
assert_contains "$LAST_OUTPUT" "Would run: /bin/bash $checkout/install/install.sh --apply-update --from-checkout $checkout --profile full --non-interactive" "the second print: the script"
assert_eq "$(git -C "$checkout" rev-parse HEAD)" "$first" "the checkout was fetched, not pulled"
assert_eq "$(readlink "$RHO_PREFIX/current")" "versions/${expected_pair}.old" "current untouched by the dry run"
pass "rho update --dry-run: the two prints, nothing run"

assert_exit 0 "rho update" -- "$RHO_PREFIX/bin/rho" update
assert_contains "$LAST_OUTPUT" "Pulled ${first:0:7}..${second:0:7}:" "the range pulled"
assert_contains "$LAST_OUTPUT" "Running: /bin/bash $checkout/install/install.sh --apply-update --from-checkout $checkout" "the checkout's script runs"
assert_contains "$LAST_OUTPUT" "Copying the packaged trees from $checkout (commit ${second:0:7})" "the pulled tree is restaged"
assert_contains "$LAST_OUTPUT" "Seeding vendor/bundle" "seeded from the previous pair"
assert_contains "$LAST_OUTPUT" "Installation successful" "update completes"
assert_eq "$(git -C "$checkout" rev-parse HEAD)" "$second" "the checkout was pulled"
assert_eq "$(readlink "$RHO_PREFIX/current")" "versions/${expected_pair}" "current re-pointed"
grep -q "^RHO_RECEIPT_APP_COMMIT=\"$second\"$" "$RHO_PREFIX/receipt.sh" || fail "app.commit did not move"
grep -q "^RHO_RECEIPT_PREVIOUS=\"${expected_pair}.old\"$" "$RHO_PREFIX/receipt.sh" || fail "the previous pair is not recorded"
[ -d "$RHO_PREFIX/versions/${expected_pair}.old" ] || fail ".old is gone after the update"
assert_eq "$(cat "$RHO_PREFIX/current/.commit")" "$second" "the new dir's .commit"
assert_eq "$(tail -n1 "$RHO_PREFIX/current/agents/rho/rho/README.md")" "one upstream commit" "the pulled content is what runs"
assert_exit 0 "rho doctor --strict after the update" -- "$RHO_PREFIX/bin/rho" doctor --strict
assert_contains "$LAST_OUTPUT" "rho ${expected_app} at ${second:0:7}, installed" "the doctor names the new commit"
pass "rho update pulls, restages, re-points, keeps the previous pair"

assert_exit 0 "rho update with nothing new" -- "$RHO_PREFIX/bin/rho" update
assert_contains "$LAST_OUTPUT" "Nothing new: $checkout is at ${second:0:7}" "an up-to-date checkout says so"
assert_contains "$LAST_OUTPUT" "rho ${expected_app} (${expected_pair}, commit ${second:0:7}) is already installed" "no rebuild"
assert_contains "$LAST_OUTPUT" "rg ${expected_rg} is already installed" "the tool rows are skipped"
assert_contains "$LAST_OUTPUT" "Installation successful" "a no-op update completes"
assert_eq "$(readlink "$RHO_PREFIX/current")" "versions/${expected_pair}" "current unchanged by a no-op update"
pass "a no-op update re-bundles nothing"

assert_exit 0 "rollback after the update" -- "$RHO_PREFIX/bin/rho" update --rollback
assert_eq "$(readlink "$RHO_PREFIX/current")" "versions/${expected_pair}.old" "current after the rollback"
grep -q "^RHO_RECEIPT_APP_COMMIT=\"$first\"$" "$RHO_PREFIX/receipt.sh" || fail "app.commit did not follow the rollback"
assert_exit 0 "rho version after the rollback" -- "$RHO_PREFIX/bin/rho" version
pass "rollback restores the previous pair and its commit"

touch "$checkout/.git/MERGE_HEAD"
assert_exit 1 "rho update under MERGE_HEAD" -- "$RHO_PREFIX/bin/rho" update
assert_contains "$LAST_OUTPUT" "a git operation is in progress in $checkout (MERGE_HEAD)" "the marker is named"
rm -f "$checkout/.git/MERGE_HEAD"
pass "an unfinished merge refuses the update"

git -C "$checkout" remote remove origin
assert_exit 1 "rho update with no remote" -- "$RHO_PREFIX/bin/rho" update
assert_contains "$LAST_OUTPUT" "git pull --ff-only failed in $checkout" "the pull's failure is named"
assert_not_contains "$LAST_OUTPUT" "Running:" "nothing was run"
pass "no remote: git's own line, nothing run"

# --- 6. --modify-path on a second prefix (the runner profile), --add-rows without an install
second_prefix="$TEST_TMP/prefix2"
fakehome="$TEST_TMP/fakehome"
mkdir -p "$fakehome"
assert_exit 0 "install --modify-path" -- env RHO_PREFIX="$second_prefix" RHO_HOME="$TEST_TMP/home2" RHO_LAUNCHER_DIR="$TEST_TMP/bin2" \
  HOME="$fakehome" SHELL=/bin/zsh /bin/bash "$checkout/install/install.sh" --profile runner --modify-path
assert_contains "$LAST_OUTPUT" "Adding the PATH line to $fakehome/.zprofile" "--modify-path names the rc file"
grep -qxF "export PATH=\"$TEST_TMP/bin2:\$PATH\"   # rho" "$fakehome/.zprofile" || fail "the rc line was not written"
assert_eq "$(grep -c "# rho" "$fakehome/.zprofile")" "1" "one rc line"
assert_eq "$(readlink "$second_prefix/current")" "versions/${expected_pair}" "the second prefix's version dir"
[[ -x "$second_prefix/bin/rg" && ! -e "$second_prefix/bin/jq" ]] || fail "the runner profile rows"
assert_exit 0 "rho version from the second prefix" -- env RHO_HOME="$TEST_TMP/home2" "$second_prefix/bin/rho" version
assert_eq "$LAST_OUTPUT" "${expected_app}" "the second prefix runs"
pass "--modify-path writes the one rc line; the runner profile"

assert_exit 1 "rho update --add-rows needs a receipt" -- env RHO_PREFIX="$TEST_TMP/nowhere" /bin/bash "$checkout/install/install.sh" --add-rows
assert_contains "$LAST_OUTPUT" "nothing is installed" "add-rows names the reason"
pass "--add-rows refuses without an install"

# --- 7. uninstall
assert_exit 0 "uninstall" -- "$RHO_PREFIX/bin/rho" uninstall
[ ! -e "$RHO_PREFIX" ] || fail "the prefix survived uninstall"
[ ! -e "$RHO_LAUNCHER_DIR/rho" ] || fail "the launcher survived uninstall"
[ ! -e "$RHO_LAUNCHER_DIR/cmctl" ] || fail "the cmctl launcher survived uninstall"
[ -d "$RHO_HOME" ] || fail "uninstall removed RHO_HOME without --purge"
assert_contains "$LAST_OUTPUT" "Kept: $RHO_HOME" "uninstall says what it kept"
pass "uninstall removes the prefix and the launcher, keeps RHO_HOME"

assert_exit 0 "uninstall --purge" -- env RHO_PREFIX="$second_prefix" RHO_HOME="$TEST_TMP/home2" /bin/bash "$second_prefix/libexec/install.sh" --uninstall --purge
[[ ! -e "$second_prefix" && ! -e "$TEST_TMP/home2" ]] || fail "--purge left something"
grep -q "# rho" "$fakehome/.zprofile" && fail "the rc line survived uninstall"
pass "uninstall --purge removes RHO_HOME and the rc line too"
