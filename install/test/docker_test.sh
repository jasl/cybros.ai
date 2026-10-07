#!/bin/bash
# The published image, on the host's arch: `--target browser` builds, the smoke verbs run through the one
# door, tini is PID 1 and reaps an orphan a killed group leader leaves,
# `rho doctor --strict` is green inside, `docker run --init` on top is
# harmless, the compose file validates, the evals leg's Dockerfile parses.
# Needs docker; runs only under RHO_INSTALL_TEST_DOCKER=1 (minutes and the
# network). RHO_INSTALL_TEST_IMAGE names an already-built image to skip the
# build; RHO_INSTALL_TEST_TARGETS="rho toolchains" adds the smaller
# targets (the timings are printed).
# shellcheck disable=SC1091
. "$(dirname "$0")/helpers.sh"

command -v docker >/dev/null 2>&1 || fail "docker is not on PATH"
docker info >/dev/null 2>&1 || fail "docker is not running"

DOCKERFILE="$INSTALL_DIR/docker/Dockerfile"
IMAGE="${RHO_INSTALL_TEST_IMAGE:-rho-install-test:browser}"
NAME="rho-install-test-$$"
cleanup_docker() { docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap 'cleanup_docker; rm -rf "$TEST_TMP"' EXIT

timed() {
  # timed LABEL -- command…: prints the wall seconds of a build step.
  local label="$1" start end
  shift; [ "$1" = "--" ] && shift
  start=$(date +%s)
  "$@" || fail "$label failed"
  end=$(date +%s)
  printf "  ok  %s in %ss\n" "$label" "$((end - start))"
}

if [ -z "${RHO_INSTALL_TEST_IMAGE:-}" ]; then
  timed "docker build --target base" -- docker build -q -f "$DOCKERFILE" --target base -t rho-install-test:base "$REPO_ROOT"
  timed "docker build --target browser" -- docker build -q -f "$DOCKERFILE" --target browser -t "$IMAGE" "$REPO_ROOT"
fi

# --- the one door: `version` through the ENTRYPOINT, `doctor --strict` inside
out=$(docker run --rm "$IMAGE" version 2>&1) || fail "rho version through the entrypoint: $out"
case "$out" in [0-9]*.[0-9]*.[0-9]*) ;; *) fail "rho version through the entrypoint answered: $out" ;; esac
pass "version through the entrypoint: $out"
out=$(docker run --rm "$IMAGE" doctor --strict 2>&1) || fail "rho doctor --strict inside the image: $out"
assert_contains "$out" "0 failures" "doctor --strict is green in the image"
assert_contains "$out" "profile dev" "the published image carries the browser profile"
pass "doctor --strict inside the image"

# --- the container's runtime environment
# Probes bypass the door (`--entrypoint`): the door hands every argument to
# rho, so `docker run IMAGE /bin/bash` is "no such verb" — by design.
out=$(docker run --rm --entrypoint /usr/bin/tini "$IMAGE" -- /bin/bash -c 'echo "$RHO_MODE $RHO_HOME $HOME $RHO_TOOLS_ROOT $PWD $LANG $(id -u) $(readlink -f /proc/1/exe)"; test -w "$RHO_TOOLS_ROOT"' 2>&1)
assert_eq "$out" "runner /var/lib/rho /home/rho /home/runner /home/runner C.UTF-8 1000 /usr/bin/tini" "runner mode, separate state and work directories, unchanged HOME, UTF-8, uid 1000, tini as PID 1"
pass "RHO_HOME=/var/lib/rho HOME=/home/rho writable RHO_TOOLS_ROOT=WORKDIR=/home/runner uid 1000 tini PID 1"
out=$(docker run --rm --init "$IMAGE" version 2>&1) || fail "docker run --init on top of tini: $out"
pass "docker run --init on top of the image's tini is harmless"
out=$(docker run --rm "$IMAGE" /bin/bash 2>&1) && fail "the door ran /bin/bash as a verb"
assert_contains "$out" 'Could not find command "/bin/bash"' "every argument through the door is a rho verb"
pass "the door is rho's alone: /bin/bash is no verb"
out=$(docker run --rm --entrypoint /bin/bash "$IMAGE" -c 'command -v rg fd jq uv gh mise && rg --version | head -1' 2>&1) || fail "the tool rows: $out"
assert_contains "$out" "/opt/rho/bin/rg" "rg is the prefix's"
assert_contains "$out" "/usr/local/bin/mise" "mise is in the base"
pass "rg fd jq uv on the prefix's PATH; gh and mise in the base"
docker run --rm --network none --entrypoint /bin/bash \
  -v "$INSTALL_DIR/test:/runtime-test:ro" "$IMAGE" /runtime-test/runtime_smoke.sh \
  || fail "coding, browser and Cowork runtime smoke"
pass "offline coding, browser and Cowork generation/rendering as uid 1000"
out=$(docker run --rm --entrypoint /bin/bash "$IMAGE" -c 'ls /opt/rho/cache/bootsnap | wc -l; stat -c %a /opt/rho/cache/bootsnap' 2>&1)
assert_contains "$out" "700" "the bootsnap cache is 0700 on the layer"
pass "the bootsnap cache is prewarmed on the image layer"
out=$(docker run --rm --entrypoint /bin/bash "$IMAGE" -c 'ls /rho /opt/rho/cache/downloads 2>&1 | head -2; ls /var/lib/rho | wc -l')
assert_not_contains "$out" "src" "the checkout copy is gone from the layer"
assert_contains "$out" "0" "the home is empty: no instance was baked in"
pass "no source tree, no downloads, no baked home in the layer"

# --- the process-group rule: tini reaps an orphan whose group leader died.
# A double-forked sleep (a dev server's child after its parent is killed)
# re-parents to PID 1; counted BEFORE any stop (after a stop the namespace
# is gone and zero is trivial).
docker run -d --name "$NAME" --entrypoint /usr/bin/tini "$IMAGE" -- /bin/bash -c 'sleep 300' >/dev/null || fail "docker run -d"
docker exec "$NAME" /bin/bash -c 'setsid bash -c "sleep 1 & exec sleep 0.2" >/dev/null 2>&1 & sleep 2; ps -eo pid,ppid,stat,comm' > "$TEST_TMP/ps.out" 2>&1 || fail "the orphan probe: $(cat "$TEST_TMP/ps.out")"
zombies=$(grep -c ' Z' "$TEST_TMP/ps.out" || true)
assert_eq "$zombies" "0" "no zombie under tini after a killed group leader"
pass "tini reaps the orphan a killed group leader leaves ($(grep -c sleep "$TEST_TMP/ps.out" || true) sleeps live, 0 zombies)"
start=$(date +%s)
docker stop -t 30 "$NAME" >/dev/null || fail "docker stop"
end=$(date +%s)
[ $((end - start)) -lt 15 ] || fail "docker stop took $((end - start))s: TERM did not reach the command through tini"
pass "docker stop: TERM through tini in $((end - start))s"
cleanup_docker

await_announcement() {
  # await_announcement NAME — the announcement through docker exec, or the
  # container's stdout and rho.log when it exited instead.
  local _i
  for _i in $(seq 1 60); do
    docker exec "$1" cat /var/lib/rho/tmp/announcement.json >"$TEST_TMP/announcement.json" 2>/dev/null && return 0
    [ "$(docker inspect --format '{{.State.Running}}' "$1")" = "true" ] || fail "$1 exited before announcing: $(docker logs "$1" 2>&1 | tail -5)"
    sleep 0.5
  done
  fail "$1 never announced itself"
}

# The installed page is served by Ruby, including in an agent-only home
# server. No pairing or model provider is needed to serve static files.
assert_webui() {
  local mode="$1" api_only="$2" expected="$3" actual
  docker run -d --name "$NAME" -e RHO_MODE="$mode" -e RHO_API_ONLY="$api_only" \
    "$IMAGE" server --nexus-url http://127.0.0.1:1 >/dev/null || fail "docker run $mode server"
  await_announcement "$NAME"
  actual=$(docker exec "$NAME" /bin/bash -c \
    'endpoint=$(jq -r .endpoint /var/lib/rho/tmp/announcement.json); curl -sS -o /tmp/rho-page.html -w "%{http_code}" "$endpoint/"') \
    || fail "GET / in $mode mode"
  assert_eq "$actual" "$expected" "WebUI in $mode mode (api_only=$api_only)"
  if [ "$expected" = 200 ]; then
    docker exec "$NAME" /bin/bash -c '
      set -eu
      root=/opt/rho/current/agents/rho/rho-webui/webui
      cmp /tmp/rho-page.html "$root/index.html"
      endpoint=$(jq -r .endpoint /var/lib/rho/tmp/announcement.json)
      for asset in console.js api.js views.js console.css; do
        curl -fsS "$endpoint/$asset" -o /tmp/rho-asset
        cmp /tmp/rho-asset "$root/$asset"
      done
    ' || fail "the packaged WebUI assets are not served intact in $mode mode"
  fi
  cleanup_docker
  pass "WebUI in $mode mode, api_only=$api_only: HTTP $expected"
}
assert_webui full 0 200
assert_webui agent 0 200
assert_webui runner 0 404
assert_webui full 1 404

# --- THE ROOT DOOR: `--user 0` over a home another uid owns (the box's
# chess run: rho's floor refused the harness's uid-1000 bind mount as root).
# The door chowns $RHO_HOME to root before rho boots, so `server` — the
# verb that prepares the home — boots and announces itself, and the home
# reads as root's from INSIDE. The bind mount is this user's dir, not
# root's; Docker Desktop maps a bind mount's owner to the container's user,
# so the chown is ALSO proved on a named volume, where ownership is real:
# a default boot populates the volume as uid 1000 (the image's user; the
# populated home is the box's shape), a `--user 0` boot over it leaves it
# root's, read from a THIRD container. The volume must be populated first:
# docker copies the image's directory — its uid-1000 owner included — over
# an EMPTY volume on every mount, which would erase the chown between
# containers and prove nothing.
mkdir -p "$TEST_TMP/root-home"
docker run -d --name "$NAME" --user 0 -v "$TEST_TMP/root-home:/var/lib/rho" "$IMAGE" server --nexus-url http://127.0.0.1:1 >/dev/null || fail "docker run -d --user 0 server"
await_announcement "$NAME"
assert_contains "$(cat "$TEST_TMP/announcement.json")" '"endpoint"' "the --user 0 server announced itself over the bind-mounted home"
out=$(docker exec "$NAME" /bin/bash -c 'id -u; stat -c %u /var/lib/rho; grep -c daemon.boot_failed /var/lib/rho/log/rho.log || true' 2>&1)
assert_eq "$out" "$(printf '0\n0\n0')" "root inside, the home root's from inside, no boot refused"
out=$(docker exec "$NAME" rho status --nexus-url http://127.0.0.1:1 2>&1) || fail "rho status through docker exec as root: $out"
assert_contains "$out" "mode:      runner" "the root-run daemon answers status"
pass "the door chowns a bind-mounted home to root for a --user 0 boot: server announced, status answers"
docker exec -u 0 "$NAME" chmod -R a+rwX /var/lib/rho >/dev/null || fail "the release chmod"
cleanup_docker
rm -rf "$TEST_TMP/root-home"
vol="rho-install-test-vol-$$"
cleanup_volume() { docker volume rm -f "$vol" >/dev/null 2>&1 || true; }
trap 'cleanup_docker; cleanup_volume; rm -rf "$TEST_TMP"' EXIT
docker volume create "$vol" >/dev/null || fail "docker volume create"
docker run -d --name "$NAME" -v "$vol:/var/lib/rho" "$IMAGE" server --nexus-url http://127.0.0.1:1 >/dev/null || fail "docker run -d server over the volume"
await_announcement "$NAME"
out=$(docker exec "$NAME" /bin/bash -c 'id -u; stat -c %u /var/lib/rho /var/lib/rho/log/rho.log' 2>&1)
assert_eq "$out" "$(printf '1000\n1000\n1000')" "the default boot populates the volume as uid 1000"
cleanup_docker
docker run -d --name "$NAME" --user 0 -v "$vol:/var/lib/rho" "$IMAGE" server --nexus-url http://127.0.0.1:1 >/dev/null || fail "docker run -d --user 0 server over the uid-1000 volume"
await_announcement "$NAME"
out=$(docker exec "$NAME" /bin/bash -c 'id -u; stat -c %u /var/lib/rho /var/lib/rho/log/rho.log; grep -c daemon.boot_failed /var/lib/rho/log/rho.log || true' 2>&1)
assert_eq "$out" "$(printf '0\n0\n0\n0')" "the --user 0 boot over the populated uid-1000 volume: root's inside, no boot refused"
cleanup_docker
out=$(docker run --rm --user 0 -v "$vol:/var/lib/rho" --entrypoint /bin/bash "$IMAGE" -c 'stat -c %u /var/lib/rho /var/lib/rho/log/rho.log' 2>&1) || fail "the third container's read: $out"
assert_eq "$out" "$(printf '0\n0')" "the chown persisted: a third container reads the volume as root's"
# The ownership is real: uid 1000 cannot open root's 0600 log in root's
# 0700 log/ — the box's shape (why the harness reads through the container).
out=$(docker run --rm -v "$vol:/var/lib/rho" --entrypoint /bin/bash "$IMAGE" -c 'cat /var/lib/rho/log/rho.log' 2>&1) && fail "uid 1000 read root's log"
assert_contains "$out" "Permission denied" "root's log is closed to uid 1000 on the volume"
out=$(docker run --rm --user 0 -v "$vol:/var/lib/rho" "$IMAGE" version 2>&1) || fail "a second --user 0 boot over the root-owned volume: $out"
cleanup_volume
pass "the door's chown is real on a populated named volume (1000 -> 0 under --user 0; a second root boot is a no-op)"

# --- the compose file and the evals leg's Dockerfile
if docker compose version >/dev/null 2>&1; then
  ( cd "$INSTALL_DIR/docker" && RHO_NEXUS_URL=https://nexus.example docker compose -f compose.yml config -q ) || fail "compose.yml does not validate"
  # Browser addresses remain separate from the container's API address.
  ( cd "$INSTALL_DIR/docker" && RHO_NEXUS_URL=http://nexus RHO_NEXUS_PUBLIC_URL=https://nexus.example RHO_PUBLIC_URL=https://rho.example docker compose -f compose.yml --profile full config | grep -q 'RHO_PUBLIC_URL: https://rho.example' ) || fail "compose.yml's rho-full does not pass its browser origin through"
  pass "install/docker/compose.yml passes the browser origin to rho-full"
  pass "install/docker/compose.yml validates"
fi
# shellcheck disable=SC2016
grep -q '^FROM --platform=linux/amd64 \${BASE}$' "$REPO_ROOT/e2e/evals/docker/Dockerfile" || fail "the evals Dockerfile does not pin its base's platform"
pass "the evals leg pins linux/amd64"

# --- the long targets, on request, with their timings
for target in ${RHO_INSTALL_TEST_TARGETS:-}; do
  timed "docker build --target $target" -- docker build -q -f "$DOCKERFILE" --target "$target" -t "rho-install-test:$target" "$REPO_ROOT"
  out=$(docker run --rm "rho-install-test:$target" doctor --strict 2>&1) || fail "doctor --strict in $target: $out"
  pass "doctor --strict in the $target target"
  docker image inspect "rho-install-test:$target" --format '  size  {{.Size}} bytes ({{.Architecture}})'
done

printf "docker test passed\n"
