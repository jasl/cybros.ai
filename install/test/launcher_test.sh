#!/bin/bash
# Exercise the generated operator launcher without downloading a runtime.
# The fake portable Ruby records which interpreter, bundle and argv the
# wrapper actually selects, even in a shell polluted by another Ruby install.
# shellcheck disable=SC1091
. "$(dirname "$0")/helpers.sh"

export RHO_PREFIX="$TEST_TMP/prefix" RHO_HOME="$TEST_TMP/home" RHO_LAUNCHER_DIR="$TEST_TMP/bin" NONINTERACTIVE=1
set -- --from-checkout "$REPO_ROOT"
# shellcheck disable=SC1090,SC1091
. "$INSTALLER"

trust_store_file() { :; }
mkdir -p "$PREFIX/ruby/current/bin"
cat > "$PREFIX/ruby/current/bin/ruby" <<'RUBY'
#!/bin/sh
printf 'runtime=%s\nbundle=%s\n' "$0" "$BUNDLE_GEMFILE"
printf 'argv=%s\n' "$@"
[ -z "${RUBYOPT:-}${RUBYLIB:-}${GEM_HOME:-}${GEM_PATH:-}${BUNDLE_USER_CONFIG:-}" ]
RUBY
chmod 755 "$PREFIX/ruby/current/bin/ruby"
write_wrapper rho "$RHO_APP_ENTRY"
write_wrapper cmctl cmctl/exe/cmctl
link_launcher

assert_exit 0 "operator launcher isolates its portable runtime" -- env \
  RUBYOPT=-rbad RUBYLIB=/another/ruby GEM_HOME=/another/gems GEM_PATH=/another/gems \
  BUNDLE_GEMFILE=/another/Gemfile BUNDLE_USER_CONFIG=/another/config \
  "$RHO_LAUNCHER_DIR/cmctl" setup --url 'https://nexus.example/path with spaces'
assert_contains "$LAST_OUTPUT" "runtime=$PREFIX/ruby/current/bin/ruby" "uses the installed Ruby"
assert_contains "$LAST_OUTPUT" "bundle=$PREFIX/current/$RHO_APP_GEMFILE" "uses rho's bundle"
assert_contains "$LAST_OUTPUT" "argv=$PREFIX/current/cmctl/exe/cmctl" "uses the packaged cmctl executable"
assert_contains "$LAST_OUTPUT" 'argv=https://nexus.example/path with spaces' "preserves argument boundaries"
pass "cmctl runs through the portable Ruby and shared bundle without host Ruby"

# A pre-existing operator command is not replaced by the convenience symlink.
rm "$RHO_LAUNCHER_DIR/cmctl"
printf '#!/bin/sh\nexit 17\n' > "$RHO_LAUNCHER_DIR/cmctl"
chmod 755 "$RHO_LAUNCHER_DIR/cmctl"
link_launcher
assert_exit 17 "an existing standalone cmctl remains the user's" -- "$RHO_LAUNCHER_DIR/cmctl"
pass "a non-symlink command in the launcher directory is preserved"
