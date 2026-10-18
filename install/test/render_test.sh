#!/bin/bash
# The render/check pair: manifest.sh and the standalone install.sh match
# their manifest and source fragments, and a stale copy is
# refused. Run against a copy of install/ so the repo is never touched.
# shellcheck disable=SC1091
. "$(dirname "$0")/helpers.sh"

manifest_bundler=$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV.fetch(0))).fetch("runtime").fetch("bundler")' "$INSTALL_DIR/manifest.json")
locked_bundler=$(ruby -e 'puts File.read(ARGV.fetch(0)).match(/^BUNDLED WITH\n\s+(\S+)/).captures.fetch(0)' "$REPO_ROOT/agents/rho/rho/Gemfile.lock")
assert_eq "$manifest_bundler" "$locked_bundler" "the installer must install the app lock's Bundler before boot"
pass "the portable runtime's Bundler matches the app lock"

copy="$TEST_TMP/install"
mkdir -p "$copy"
cp -R "$INSTALL_DIR/lib" "$INSTALL_DIR/src" "$INSTALL_DIR/manifest.json" "$INSTALL_DIR/manifest.sh" "$INSTALL_DIR/install.sh" "$copy/"
export RHO_INSTALL_ROOT="$copy"
check() { ruby -r "$copy/lib/rho_install/render" -e 'stale = RhoInstall::Render.stale; abort "stale: #{stale.join(", ")}" unless stale.empty?'; }
render() { ruby -r "$copy/lib/rho_install/render" -e 'RhoInstall::Render.run'; }

assert_exit 0 "a fresh copy passes the check" -- check
pass "check passes on the committed rendering"

# Exercise manifest edits with local values so a release bump does not
# require changing this generic renderer test.
ruby -rjson -e '
  path = ARGV.fetch(0)
  data = JSON.parse(File.read(path))
  data.fetch("runtime")["version"] = "9.8.7"
  data.fetch("tools").fetch("rg").fetch("artifacts").fetch("darwin-arm64")["sha256"] = "f" * 64
  File.write(path, JSON.pretty_generate(data) + "\n")
' "$copy/manifest.json"
assert_exit 1 "manifest edits require rendering" -- check
assert_contains "$LAST_OUTPUT" "install/manifest.sh" "the stale manifest is named"
assert_contains "$LAST_OUTPUT" "install/install.sh" "the stale installer is named"
render
assert_exit 0 "render carries the edited manifest" -- check
pass "manifest values can change independently of the renderer"

printf '\nRHO_STALE=1\n' >> "$copy/manifest.sh"
assert_exit 1 "an edited manifest.sh fails the check" -- check
assert_contains "$LAST_OUTPUT" "install/manifest.sh" "the stale file is named"
pass "check refuses a stale manifest.sh"

render
assert_exit 0 "render restores it" -- check
pass "render rewrites manifest.sh"

sed -i.bak 's/^RHO_RUBY_VERSION=.*/RHO_RUBY_VERSION="9.9.9"/' "$copy/install.sh"
assert_exit 1 "an edited block in install.sh fails the check" -- check
assert_contains "$LAST_OUTPUT" "install/install.sh" "the stale file is named"
render
assert_exit 0 "render restores the block" -- check
grep -q '^RHO_RUBY_VERSION="9.8.7"$' "$copy/install.sh" || fail "the rendered block does not carry the manifest's Ruby"
pass "check refuses a stale install.sh block; render restores it"

printf '\n# source edit\n' >> "$copy/src/launchers.sh"
assert_exit 1 "an edited source fragment requires rendering" -- check
assert_contains "$LAST_OUTPUT" "install/install.sh" "the stale distribution is named"
render
assert_exit 0 "render includes the source edit" -- check
grep -q '^# source edit$' "$copy/install.sh" || fail "the source edit was not rendered"
pass "check covers handwritten source changes as well as the manifest"

grep -q "^RHO_MANIFEST_JSON=\$(cat <<'RHO_MANIFEST_JSON_EOF'" "$copy/install.sh" || fail "the JSON block is missing"
/bin/bash -n "$copy/install.sh" || fail "the rendered install.sh does not parse under bash 3.2"
digest=$(/bin/bash -c '. "$1"; printf "%s" "$RHO_TOOL_rg_darwin_arm64_SHA256"' _ "$copy/manifest.sh")
assert_eq "$digest" "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" "manifest.sh sources and carries the authored sha"
pass "manifest.sh is a sourceable rendering"
