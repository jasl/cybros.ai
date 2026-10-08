#!/bin/sh
# Publish committed source after native image checks on both Docker Engines.
set -eu

usage() {
  printf '%s\n' 'Usage: install/docker/publish.sh [yyMMddHHmm]' \
    'Defaults: jasl123/cybros-{nexus,rho,updater}; UTC tag from date -u +%y%m%d%H%M.' \
    'Set CYBROS_NEXUS_IMAGE_REPOSITORY, CYBROS_RHO_IMAGE_REPOSITORY and CYBROS_UPDATER_IMAGE_REPOSITORY to change repositories.' \
    'Set CYBROS_AMD64_DOCKER_CONTEXT and CYBROS_ARM64_DOCKER_CONTEXT to native Docker contexts or ssh:// URLs.' \
    'Requires a clean Git checkout. Builds, checks and pushes both native architectures before promoting latest.'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac
if [ "$#" -gt 1 ]; then
  usage >&2
  exit 2
fi

release_tag=${1-$(date -u +%y%m%d%H%M)}
nexus_image=${CYBROS_NEXUS_IMAGE_REPOSITORY:-jasl123/cybros-nexus}
rho_image=${CYBROS_RHO_IMAGE_REPOSITORY:-jasl123/cybros-rho}
updater_image=${CYBROS_UPDATER_IMAGE_REPOSITORY:-jasl123/cybros-updater}
for repository in "$nexus_image" "$rho_image" "$updater_image"; do
  case "$repository" in
    ''|*[!a-z0-9_./:-]*|/*|*/|*..*|*://*) printf '%s\n' 'Image repositories must be complete repository paths, without a URL scheme, tag or digest.' >&2; exit 2 ;;
  esac
  case "${repository##*/}" in
    *:*) printf '%s\n' 'Image repositories must not include a tag.' >&2; exit 2 ;;
  esac
done
case "$release_tag" in
  ''|*[!0-9]*) printf '%s\n' 'The release tag must be a valid UTC yyMMddHHmm date and time (2000-2099).' >&2; exit 2 ;;
esac
if [ "${#release_tag}" -ne 10 ] || ! awk -v tag="$release_tag" 'BEGIN {
  year = 2000 + substr(tag, 1, 2)
  month = substr(tag, 3, 2) + 0
  day = substr(tag, 5, 2) + 0
  hour = substr(tag, 7, 2) + 0
  minute = substr(tag, 9, 2) + 0
  split("31 28 31 30 31 30 31 31 30 31 30 31", days)
  if (year % 4 == 0) days[2] = 29
  exit !(month >= 1 && month <= 12 && day >= 1 && day <= days[month] && hour < 24 && minute < 60)
}'; then
  printf '%s\n' 'The release tag must be a valid UTC yyMMddHHmm date and time (2000-2099).' >&2
  exit 2
fi

repo_root=$(CDPATH='' cd "$(dirname "$0")/../.." && pwd)
source_url=https://github.com/jasl/cybros.ai
verify="$repo_root/install/docker/verify-release.rb"
for program in docker git ruby tar mktemp; do
  command -v "$program" >/dev/null 2>&1 || { printf 'Required command is missing: %s\n' "$program" >&2; exit 2; }
done
if [ -z "${CYBROS_AMD64_DOCKER_CONTEXT:-}" ] || [ -z "${CYBROS_ARM64_DOCKER_CONTEXT:-}" ]; then
  printf '%s\n' 'Set both CYBROS_AMD64_DOCKER_CONTEXT and CYBROS_ARM64_DOCKER_CONTEXT to native Docker contexts or ssh:// URLs.' >&2
  exit 2
fi
revision=$(git -C "$repo_root" rev-parse HEAD)
if [ -n "$(git -C "$repo_root" status --porcelain --untracked-files=normal)" ]; then
  printf '%s\n' 'Publishing requires a clean Git checkout; commit the intended source first.' >&2
  exit 2
fi

publish_tmp=$(mktemp -d "${TMPDIR:-/tmp}/cybros-publish.XXXXXX")
owned_amd64_context=
owned_arm64_context=
smoke_context=
smoke_container=
cleanup() {
  cleanup_status=$?
  trap - EXIT HUP INT TERM
  if [ -n "$smoke_container" ]; then
    if ! docker --context "$smoke_context" rm -f -v "$smoke_container" >/dev/null; then
      printf 'Could not remove smoke container %s on %s.\n' "$smoke_container" "$smoke_context" >&2
      if [ "$cleanup_status" -eq 0 ]; then cleanup_status=1; fi
    fi
  fi
  for cleanup_context in "$owned_amd64_context" "$owned_arm64_context"; do
    if [ -n "$cleanup_context" ]; then
      if ! docker context rm "$cleanup_context" >/dev/null; then
        printf 'Could not remove temporary context %s.\n' "$cleanup_context" >&2
        if [ "$cleanup_status" -eq 0 ]; then cleanup_status=1; fi
      fi
    fi
  done
  rm -rf "$publish_tmp"
  exit "$cleanup_status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# One local archive excludes ignored files and freezes the same commit for every
# build. Docker streams each context to its Engine; no remote checkout is needed.
git -C "$repo_root" archive --format=tar "$revision" > "$publish_tmp/source.tar"
mkdir "$publish_tmp/source"
tar -xf "$publish_tmp/source.tar" -C "$publish_tmp/source"
build_root="$publish_tmp/source"

prepare_context() {
  prepared_context=$2
  case "$prepared_context" in
    ssh://*)
      prepared_context="$(basename "$publish_tmp")-$1"
      docker context create "$prepared_context" --docker "host=$2" >/dev/null
      case "$1" in
        amd64) owned_amd64_context=$prepared_context ;;
        arm64) owned_arm64_context=$prepared_context ;;
      esac
      ;;
  esac
  native_platform=$(docker --context "$prepared_context" info --format '{{.OSType}}/{{.Architecture}}')
  case "$native_platform" in
    linux/x86_64) native_platform=linux/amd64 ;;
    linux/aarch64) native_platform=linux/arm64 ;;
  esac
  if [ "$native_platform" != "linux/$1" ]; then
    printf 'Context %s runs %s; native linux/%s is required.\n' "$prepared_context" "$native_platform" "$1" >&2
    exit 2
  fi
  # A context has a same-named Engine builder. An explicitly named "default"
  # builder can refer to another context, and a selected custom builder has its
  # own cache and load destination, so neither is used here.
  builder_driver=$(docker --context "$prepared_context" buildx inspect "$prepared_context" | awk '/^Driver:/ { print $2 }')
  if [ "$builder_driver" != docker ]; then
    printf 'Context %s must use its Docker Engine builder.\n' "$prepared_context" >&2
    exit 2
  fi
}
prepare_context amd64 "$CYBROS_AMD64_DOCKER_CONTEXT"
amd64_context=$prepared_context
prepare_context arm64 "$CYBROS_ARM64_DOCKER_CONTEXT"
arm64_context=$prepared_context

# A release tag is immutable. Authentication/network failures are not evidence
# that a tag is absent, and a failed run uses another minute for its next build.
ruby "$verify" absent "$nexus_image:$release_tag" "$rho_image:$release_tag" "$updater_image:$release_tag" \
  "$nexus_image:$release_tag-amd64" "$nexus_image:$release_tag-arm64" \
  "$rho_image:$release_tag-amd64" "$rho_image:$release_tag-arm64" \
  "$updater_image:$release_tag-amd64" "$updater_image:$release_tag-arm64"

select_architecture() {
  architecture=$1
  case "$architecture" in
    amd64) context=$amd64_context ;;
    arm64) context=$arm64_context ;;
  esac
}
select_product() {
  product=$1
  case "$product" in
    nexus) repository=$nexus_image; dockerfile="$build_root/nexus/Dockerfile"; build_context="$build_root/nexus" ;;
    rho) repository=$rho_image; dockerfile="$build_root/install/docker/Dockerfile"; build_context=$build_root ;;
    updater) repository=$updater_image; dockerfile="$build_root/install/stack/updater/Dockerfile"; build_context="$build_root/install/stack/updater" ;;
  esac
  image="$repository:$release_tag-$architecture"
}
smoke_image() {
  printf 'Checking %s on native linux/%s\n' "$product" "$architecture"
  case "$product" in
    nexus)
      docker --context "$context" run --rm --network none --entrypoint /bin/sh \
        -e SECRET_KEY_BASE_DUMMY=1 "$image" -ec \
        'bundle check && bundle exec rails runner '\''puts "Nexus runtime booted"'\'
      ;;
    rho)
      docker --context "$context" run --rm --network none "$image" version
      docker --context "$context" run --rm --network none "$image" doctor --strict
      smoke_context=$context
      smoke_container=$(docker --context "$context" create --network none --entrypoint /bin/bash \
        "$image" /runtime-test/runtime_smoke.sh)
      # Bind mounts resolve on the daemon host. Copy the existing test payload
      # through the Docker API so an SSH Engine needs no local source paths.
      docker --context "$context" cp "$build_root/install/test/." "$smoke_container:/runtime-test"
      docker --context "$context" start --attach "$smoke_container"
      smoke_status=$(docker --context "$context" inspect --format '{{.State.ExitCode}}' "$smoke_container")
      if [ "$smoke_status" != 0 ]; then
        printf 'rho runtime smoke failed on %s with exit %s.\n' "$context" "$smoke_status" >&2
        exit 1
      fi
      docker --context "$context" rm -v "$smoke_container" >/dev/null
      smoke_container=
      ;;
    updater)
      docker --context "$context" run --rm --network none --entrypoint /bin/sh "$image" -ec \
        'ruby -r /app/lib/cybros_updater -e '\''abort unless CybrosUpdater::Engine && CybrosUpdater::Docker; puts "Updater runtime loaded"'\''; docker --version; docker compose version'
      ;;
  esac
}

printf 'Publishing commit %s as %s\n' "$revision" "$release_tag"
for selected_architecture in amd64 arm64; do
  select_architecture "$selected_architecture"
  for selected_product in nexus rho updater; do
    select_product "$selected_product"
    set -- --builder "$context" --platform "linux/$architecture" --load --provenance=false \
      --label "org.opencontainers.image.source=$source_url" \
      --label "org.opencontainers.image.version=$release_tag" \
      --label "org.opencontainers.image.revision=$revision" -f "$dockerfile" -t "$image"
    if [ "$product" = rho ]; then set -- "$@" --target browser; fi
    docker --context "$context" buildx build "$@" "$build_context"
    smoke_image
  done
done

# No registry write occurs until all six images have passed their native smoke.
for selected_architecture in amd64 arm64; do
  select_architecture "$selected_architecture"
  for selected_product in nexus rho updater; do
    select_product "$selected_product"
    docker --context "$context" push "$image"
    ruby "$verify" native "$image" "$architecture" "$release_tag" "$revision" "$source_url" \
      > "$publish_tmp/$product-$architecture.digest"
  done
done

for selected_product in nexus rho updater; do
  select_product "$selected_product"
  docker buildx imagetools create --tag "$repository:$release_tag" \
    "$repository@$(cat "$publish_tmp/$product-amd64.digest")" \
    "$repository@$(cat "$publish_tmp/$product-arm64.digest")"
done
for selected_product in nexus rho updater; do
  select_product "$selected_product"
  ruby "$verify" release "$repository:$release_tag" "$release_tag" "$revision" "$source_url" \
    "$(cat "$publish_tmp/$product-amd64.digest")" "$(cat "$publish_tmp/$product-arm64.digest")" \
    > "$publish_tmp/$product.digest"
done

# Registry tag writes are separate operations. Verify the whole release first,
# then promote the exact indexes read above and verify every rolling tag again.
for selected_product in nexus rho updater; do
  select_product "$selected_product"
  docker buildx imagetools create --tag "$repository:latest" "$repository@$(cat "$publish_tmp/$product.digest")"
done
for selected_product in nexus rho updater; do
  select_product "$selected_product"
  latest_digest=$(ruby "$verify" release "$repository:latest" "$release_tag" "$revision" "$source_url" \
    "$(cat "$publish_tmp/$product-amd64.digest")" "$(cat "$publish_tmp/$product-arm64.digest")" \
    "$(cat "$publish_tmp/$product.digest")")
  printf 'Verified %s:%s and :latest at %s\n' "$repository" "$release_tag" "$latest_digest"
done
printf 'Published all three images as :%s and :latest; native architecture tags are retained.\n' "$release_tag"
