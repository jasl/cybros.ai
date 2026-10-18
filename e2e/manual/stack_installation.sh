#!/bin/bash
# An isolated installed-product upgrade journey on the local native Docker Engine.
set -euo pipefail
umask 077

fail() { printf 'stack e2e: %s\n' "$*" >&2; exit 1; }
if [ "${1:-}" = --help ]; then
  printf '%s\n' 'Usage: bash manual/stack_installation.sh UTC_RELEASE_TAG' \
    'Requires a published yyMMddHHmm release, a local Docker context, the E2E Ruby bundle and Chrome.' \
    'Creates a fresh installation; removes its containers on exit and retains its data and logs.'
  exit 0
fi
[ "$#" -eq 1 ] || fail 'Usage: bash manual/stack_installation.sh UTC_RELEASE_TAG'
release=$1
for command in docker ruby bundle; do command -v "$command" >/dev/null || fail "$command is required"; done

fixture_release=$(ruby -e '
tag = ARGV.fetch(0)
abort "Release must be a UTC yyMMddHHmm tag" unless tag.match?(/\A[0-9]{10}\z/)
begin
  instant = Time.utc(2000 + tag[0, 2].to_i, tag[2, 2].to_i, tag[4, 2].to_i, tag[6, 2].to_i, tag[8, 2].to_i)
rescue ArgumentError
  abort "Release must be a valid UTC yyMMddHHmm tag"
end
abort "Release must be a valid UTC yyMMddHHmm tag" unless instant.strftime("%y%m%d%H%M") == tag
previous = instant - 60
abort "Release needs an earlier fixture version within 2000-2099" if previous.year < 2000
puts previous.strftime("%y%m%d%H%M")
' "$release")

[ -z "${DOCKER_HOST:-}" ] || fail 'Select a local Docker context and unset DOCKER_HOST'
docker_context=$(docker context show)
endpoint=$(docker context inspect "$docker_context" --format '{{.Endpoints.docker.Host}}')
case "$endpoint" in unix://*) ;; *) fail 'This journey requires a local Unix-socket Docker context' ;; esac
export DOCKER_CONTEXT=$docker_context
unset DOCKER_DEFAULT_PLATFORM BUILDX_BUILDER COMPOSE_PROJECT_NAME COMPOSE_FILE
[ "$(docker info --format '{{.OSType}}')" = linux ] || fail 'A local Linux Docker Engine is required'
builder_driver=$(docker buildx inspect "$docker_context" | awk '/^Driver:/ { print $2 }')
[ "$builder_driver" = docker ] || fail 'Use the selected context native Docker builder'
docker compose version >/dev/null

e2e_dir=$(cd "$(dirname "$0")/.." && pwd -P)
cd "$e2e_dir"
bundle check >/dev/null || fail 'Run bundle install in e2e first'
run_dir=$(mktemp -d "${TMPDIR:-/tmp}/cybros-stack-e2e.XXXXXX")
run_dir=$(cd "$run_dir" && pwd -P)
stack=$run_dir/installation
logs=$run_dir/logs
mkdir "$logs" "$run_dir/image-context"
project="cybros-e2e-$(ruby -rsecurerandom -e 'puts SecureRandom.hex(6)')"

cleanup() {
  result=$?
  trap - EXIT HUP INT TERM
  set +e
  if [ -x "$stack/cybros" ] && [ -f "$stack/.env" ] && [ -f "$stack/secrets.env" ]; then
    "$stack/cybros" compose logs --no-color --tail 1000 > "$logs/application.log" 2>&1
    "$stack/cybros" manager logs --no-color --tail 1000 > "$logs/updater.log" 2>&1
    # Stop the manager first so it cannot recreate application services while
    # this disposable project's containers and networks are being removed.
    "$stack/cybros" manager down --remove-orphans > "$logs/cleanup.log" 2>&1
    manager_result=$?
    "$stack/cybros" compose down --remove-orphans >> "$logs/cleanup.log" 2>&1
    application_result=$?
    if [ "$manager_result" -ne 0 ] || [ "$application_result" -ne 0 ]; then
      printf 'stack e2e: Cleanup failed; inspect %s/cleanup.log\n' "$logs" >&2
      result=1
    fi
  fi
  printf '\nFixture data and logs retained at %s\nCompose project: %s\n' "$run_dir" "$project"
  exit "$result"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
printf 'Fixture: %s\nTarget release: %s\nInitial fixture version: %s\n' "$run_dir" "$release" "$fixture_release"

for product in nexus rho updater; do
  image="jasl123/cybros-$product:$release"
  docker pull "$image" > "$logs/pull-$product.log" 2>&1
  [ "$(docker image inspect "$image" --format '{{index .Config.Labels "org.opencontainers.image.version"}}')" = "$release" ] || fail "$image has a different release label"
done

for product in nexus rho; do
  # The bytes are the selected release; only the fixture's older version label
  # differs. This exercises replacement and continuity, not a schema migration.
  docker build --builder "$docker_context" --pull=false --network none \
    --build-arg "BASE=jasl123/cybros-$product:$release" \
    --build-arg "FIXTURE_RELEASE=$fixture_release" \
    -t "cybros-e2e/$product:$project" -f - "$run_dir/image-context" > "$logs/build-$product.log" 2>&1 <<'DOCKERFILE'
ARG BASE
FROM ${BASE}
ARG FIXTURE_RELEASE
LABEL org.opencontainers.image.version=${FIXTURE_RELEASE}
DOCKERFILE
done

# Holding both listeners until the process exits chooses distinct free ports.
ports=$(ruby -rsocket -e 'listeners = 2.times.map { TCPServer.new("127.0.0.1", 0) }; puts listeners.map { |socket| socket.addr[1] }.join(" ")')
read -r nexus_port rho_port <<< "$ports"
nexus_url="http://127.0.0.1:$nexus_port"
rho_url="http://127.0.0.1:$rho_port"
env -i PATH="$PATH" HOME="$HOME" DOCKER_CONTEXT="$docker_context" \
  CYBROS_PROJECT_NAME="$project" CYBROS_IMAGE_TAG="$release" CYBROS_UPDATER_TAG="$release" \
  CYBROS_BIND=127.0.0.1 CYBROS_NEXUS_PORT="$nexus_port" CYBROS_RHO_PORT="$rho_port" \
  CYBROS_NEXUS_URL="$nexus_url" CYBROS_RHO_URL="$rho_url" \
  sh "$e2e_dir/../install/stack/install.sh" --yes --no-start --dir "$stack" > "$logs/install.log" 2>&1
printf "CYBROS_NEXUS_IMAGE='cybros-e2e/nexus:%s'\nCYBROS_RHO_IMAGE='cybros-e2e/rho:%s'\n" "$project" "$project" > "$stack/images.env"
ruby -rsocket -e 'ARGV.map { |port| TCPServer.new("127.0.0.1", Integer(port)) }' "$nexus_port" "$rho_port"
"$stack/cybros" up > "$logs/start.log" 2>&1

E2E_STACK_DIR="$stack" E2E_BASE_URL="$nexus_url" E2E_STACK_UPGRADE_RELEASE="$release" \
  E2E_STACK_RESTORE_DIR='' E2E_LIVE='' \
  bundle exec ruby -Itest test/stack_installation_test.rb 2>&1 | tee "$logs/test.log"
