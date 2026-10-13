#!/bin/bash
# Native setup and the container environment door, with no provider requests.
# shellcheck disable=SC1091
. "$(dirname "$0")/helpers.sh"
task_prefix="$TEST_TMP/prefix"
mkdir -p "$task_prefix/bin" "$task_prefix/libexec"
cp "$INSTALL_DIR/t3-setup" "$INSTALL_DIR/docker-entrypoint" "$task_prefix/libexec/"
chmod 755 "$task_prefix/libexec/"*
export RHO_HOME="$TEST_TMP/rho-home" T3_TEST_CALLS="$TEST_TMP/calls" T3_TEST_IMPORTED="$TEST_TMP/imported" T3_TEST_BEARER="$TEST_TMP/bearer"
# The fake rho: `t3 token` saves what it issues or is given on stdin (never
# printing it), `t3 status` reports whether one is saved.
cat > "$task_prefix/bin/rho" <<'RHO'
#!/bin/sh
set -eu
printf '%s\n' "$*" >> "$T3_TEST_CALLS"
case "$*" in
  't3 token')
    given=''
    [ -t 0 ] || IFS= read -r given || true
    printf '%s\n' "${given:-fixture-native-bearer}" > "$T3_TEST_BEARER"
    printf '%s\n' '{"bearer":"saved","saved":true,"applied":false,"restart_required":true}'
    ;;
  't3 status')
    if [ -f "$T3_TEST_BEARER" ]; then printf '%s\n' '{"bearer":"saved"}'; else printf '%s\n' '{"bearer":"none"}'; fi
    ;;
  status) printf '%s\n' "${RHO_T3_TOKEN:-}" "${OPENAI_API_KEY:-}" > "$T3_TEST_IMPORTED" ;;
  'extensions configure rho.t3 '*|'extensions enable rho.t3')
    [ "${T3_TEST_SAVE_FAIL:-0}" = 0 ] || exit 1
    printf '%s\n' '{"saved":true,"applied":false,"published":false,"restart_required":true}'
    ;;
  *) ;;
esac
RHO
chmod 755 "$task_prefix/bin/rho"

assert_exit 0 'local native setup' -- "$task_prefix/libexec/t3-setup" local < /dev/null
assert_not_contains "$LAST_OUTPUT" fixture-native-bearer 'local setup never displays the bearer'
assert_eq "$(grep -c '^t3 token$' "$T3_TEST_CALLS")" 1 'local setup has rho issue and save its own bearer'
[ ! -e "$RHO_HOME/plugins/rho.t3/rho.env" ] || fail 'the bearer is not written to the environment file'
assert_contains "$(cat "$T3_TEST_CALLS")" 'extensions configure rho.t3' 'setup uses the settings owner'
assert_exit 0 'repeat local native setup' -- "$task_prefix/libexec/t3-setup" local < /dev/null
assert_eq "$(grep -c '^t3 token$' "$T3_TEST_CALLS")" 1 'repeat setup keeps the saved bearer'

# shellcheck disable=SC2016 # These metacharacters must remain literal data.
literal='fixture-$dollar-`backtick`-$(command)-space value'
printf '%s\n' "$literal" | "$task_prefix/libexec/t3-setup" secret OPENAI_API_KEY > "$TEST_TMP/secret.out"
assert_not_contains "$(cat "$TEST_TMP/secret.out")" "$literal" 'provider key is never displayed'
assert_eq "$(cat "$RHO_HOME/plugins/rho.t3/rho.env")" "OPENAI_API_KEY=$literal" 'the provider key has one persisted owner'
assert_exit 0 'entrypoint imports literal native environment' -- "$task_prefix/libexec/docker-entrypoint" status
assert_eq "$(sed -n '1p' "$T3_TEST_IMPORTED")" '' 'no bearer rides the environment into a recreated process'
assert_eq "$(sed -n '2p' "$T3_TEST_IMPORTED")" "$literal" 'provider key is data, never evaluated'
ruby -e 'abort "private mode" unless (File.stat(ARGV.fetch(0)).mode & 0777) == 0600' "$RHO_HOME/plugins/rho.t3/rho.env"
pass 'native secrets remain private, literal, silent and persisted across process recreation'

assert_exit 1 'a refused save aborts setup' -- env T3_TEST_SAVE_FAIL=1 "$task_prefix/libexec/t3-setup" local < /dev/null

printf '%s\n' host-fixture | "$task_prefix/libexec/t3-setup" host http://host.docker.internal:3773 > "$TEST_TMP/host.out"
assert_eq "$(grep -c '^t3 token$' "$T3_TEST_CALLS")" 2 'host mode hands the bearer to rho on stdin'
assert_eq "$(cat "$T3_TEST_BEARER")" host-fixture 'the host bearer reaches rho unchanged'
assert_not_contains "$(cat "$TEST_TMP/host.out")" host-fixture 'host setup never displays the bearer'
assert_eq "$(cat "$RHO_HOME/plugins/rho.t3/rho.env")" "OPENAI_API_KEY=$literal" 'the environment file holds provider keys alone'
assert_exit 1 'the environment file refuses the T3 bearer' -- "$task_prefix/libexec/t3-setup" secret RHO_T3_TOKEN <<< replacement-fixture
assert_contains "$LAST_OUTPUT" 't3 token' 'the refusal names the way to save a bearer'

private_env="$RHO_HOME/plugins/rho.t3/rho.env"
saved_env=$(cat "$private_env")
chmod 644 "$private_env"
rm "$T3_TEST_IMPORTED"
assert_exit 1 'entrypoint refuses an exposed native credential file' -- "$task_prefix/libexec/docker-entrypoint" status
[ ! -e "$T3_TEST_IMPORTED" ] || fail 'exposed credentials reached rho'
assert_exit 1 'setup refuses to overwrite exposed native credentials' -- "$task_prefix/libexec/t3-setup" secret ANTHROPIC_API_KEY <<< replacement-fixture
assert_exit 1 'repeat local setup refuses exposed native credentials' -- "$task_prefix/libexec/t3-setup" local < /dev/null
assert_eq "$(cat "$private_env")" "$saved_env" 'a widened file is neither replaced nor silently repaired'
ruby -e 'abort "widened mode was hidden" unless (File.stat(ARGV.fetch(0)).mode & 0777) == 0644' "$private_env"
chmod 400 "$private_env"
assert_exit 0 'entrypoint accepts stricter owner-only credentials' -- "$task_prefix/libexec/docker-entrypoint" status
printf '%s\n' anthropic-fixture | "$task_prefix/libexec/t3-setup" secret ANTHROPIC_API_KEY > "$TEST_TMP/strict.out"
assert_contains "$(cat "$private_env")" "OPENAI_API_KEY=$literal" 'a private replacement preserves unrelated credentials'
assert_contains "$(cat "$private_env")" 'ANTHROPIC_API_KEY=anthropic-fixture' 'a private replacement adds its own row'
pass 'credential reads and writes refuse widened modes without hiding the exposure'

mkdir "$TEST_TMP/stat-bin"
cat > "$TEST_TMP/stat-bin/stat" <<'STAT'
#!/bin/sh
case "$*" in
  '-c %u %a '*) printf '%s 600\n' "$T3_TEST_OTHER_UID" ;;
  *) exec "$T3_TEST_REAL_STAT" "$@" ;;
esac
STAT
chmod 755 "$TEST_TMP/stat-bin/stat"
stat_binary=$(command -v stat)
other_uid=$(( $(id -u) + 1 ))
saved_env=$(cat "$private_env")
assert_exit 1 'entrypoint refuses another owners credentials' -- env PATH="$TEST_TMP/stat-bin:$PATH" T3_TEST_REAL_STAT="$stat_binary" T3_TEST_OTHER_UID="$other_uid" "$task_prefix/libexec/docker-entrypoint" status
assert_exit 1 'setup refuses another owners credentials' -- env PATH="$TEST_TMP/stat-bin:$PATH" T3_TEST_REAL_STAT="$stat_binary" T3_TEST_OTHER_UID="$other_uid" "$task_prefix/libexec/t3-setup" secret ANTHROPIC_API_KEY <<< replacement-fixture
assert_eq "$(cat "$private_env")" "$saved_env" 'wrong ownership leaves the saved credentials unchanged'
pass 'native credential reads and writes require the runtime owner'

chmod 600 "$private_env"
printf '%s\n' 'RHO_T3_TOKEN=stale-fixture' >> "$private_env"
assert_exit 1 'a bearer row in the environment file is refused' -- "$task_prefix/libexec/docker-entrypoint" status
pass 'host setup uses explicit URL and bearer; environment import is a closed allowlist without the bearer'
