#!/bin/bash
# Observe Docker arguments and failures without contacting a registry.
set -eu
# shellcheck disable=SC1091 # Shared helpers are resolved relative to this test.
. "$(dirname "$0")/helpers.sh"

mkdir -p "$TEST_TMP/bin" "$TEST_TMP/calls"
export MOCK_CALLS="$TEST_TMP/calls"
cat > "$TEST_TMP/bin/docker" <<'MOCK'
#!/bin/sh
set -eu
index=1
while [ -f "$MOCK_CALLS/$index" ]; do index=$((index + 1)); done
printf '%s\n' "$@" > "$MOCK_CALLS/$index"
if [ "${MOCK_FAIL_CALL:-}" = "$index" ]; then exit 19; fi
MOCK
chmod 755 "$TEST_TMP/bin/docker"
export PATH="$TEST_TMP/bin:$PATH"
cd "$TEST_TMP"

assert_exit 0 'publish both images' -- sh "$INSTALL_DIR/docker/publish.sh" test-publisher 1790630000
for index in 1 2; do
  call=$(cat "$MOCK_CALLS/$index")
  assert_contains "$call" $'buildx\nbuild' 'build command'
  assert_contains "$call" $'--platform\nlinux/amd64,linux/arm64' 'both architectures'
  assert_contains "$call" '--push' 'push timestamp build'
  assert_not_contains "$call" ':latest' 'builds do not move latest'
done
assert_contains "$(cat "$MOCK_CALLS/1")" 'docker.io/test-publisher/cybros-nexus:1790630000' 'Nexus timestamp'
assert_contains "$(cat "$MOCK_CALLS/2")" 'docker.io/test-publisher/cybros-rho:1790630000' 'rho shares timestamp'
assert_contains "$(cat "$MOCK_CALLS/2")" $'--target\nbrowser' 'release includes coding, browser and Cowork dependencies'
assert_eq "$(tail -n 1 "$MOCK_CALLS/1")" "$REPO_ROOT/nexus" 'Nexus current-checkout context'
assert_eq "$(tail -n 1 "$MOCK_CALLS/2")" "$REPO_ROOT" 'rho current-checkout context'
pass 'timestamp builds use both architectures and the browser target from this checkout'

for entry in '3 nexus' '4 rho'; do
  read -r index name <<< "$entry"
  expected=$(printf '%s\n' buildx imagetools create --tag \
    "docker.io/test-publisher/cybros-$name:latest" "docker.io/test-publisher/cybros-$name:1790630000")
  assert_eq "$(cat "$MOCK_CALLS/$index")" "$expected" 'latest follows both successful builds'
done
[ ! -e "$MOCK_CALLS/5" ] || fail 'unexpected Docker call'
pass 'latest promotions use the same completed timestamp images'

rm "$MOCK_CALLS/1" "$MOCK_CALLS/2" "$MOCK_CALLS/3" "$MOCK_CALLS/4"
export MOCK_FAIL_CALL=2
assert_exit 19 'second build failure propagates' -- sh "$INSTALL_DIR/docker/publish.sh" test-publisher 1790630000
[[ -e "$MOCK_CALLS/2" && ! -e "$MOCK_CALLS/3" ]] || fail 'latest changed after a failed build'
pass 'a failed second build leaves both latest tags unchanged'
