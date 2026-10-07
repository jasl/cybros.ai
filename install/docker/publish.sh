#!/bin/sh
# Publish the current checkout; run the relevant tests before invoking this script.
set -eu

usage() {
  printf '%s\n' 'Usage: install/docker/publish.sh [NAMESPACE [UNIX_SECONDS]]' \
    'Defaults: namespace jasl123; tag from date +%s.' \
    'Pushes both amd64/arm64 images, then promotes both timestamp tags to latest.'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac
if [ "$#" -gt 2 ]; then
  usage >&2
  exit 2
fi

namespace=${1:-jasl123}
timestamp=${2:-$(date +%s)}
case "$namespace" in
  ''|*[!a-z0-9_-]*) printf '%s\n' 'Namespace must be a Docker Hub user or organization name.' >&2; exit 2 ;;
esac
case "$timestamp" in
  ''|*[!0-9]*) printf '%s\n' 'The release tag must be Unix seconds.' >&2; exit 2 ;;
esac

repo_root=$(CDPATH='' cd "$(dirname "$0")/../.." && pwd)
source_url=https://github.com/jasl/cybros.ai
nexus_image=docker.io/$namespace/cybros-nexus
rho_image=docker.io/$namespace/cybros-rho

set -- --platform linux/amd64,linux/arm64 --push --label "org.opencontainers.image.source=$source_url"
if command -v git >/dev/null 2>&1; then
  revision=$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || :)
  if [ -n "$revision" ]; then
    set -- "$@" --label "org.opencontainers.image.revision=$revision"
  fi
fi

printf 'Publishing %s and %s with tag %s\n' "$nexus_image" "$rho_image" "$timestamp"
docker buildx build "$@" -f "$repo_root/nexus/Dockerfile" \
  -t "$nexus_image:$timestamp" "$repo_root/nexus"
docker buildx build "$@" -f "$repo_root/install/docker/Dockerfile" --target browser \
  -t "$rho_image:$timestamp" "$repo_root"

# Do not move either rolling tag when one of the two builds fails.
docker buildx imagetools create --tag "$nexus_image:latest" "$nexus_image:$timestamp"
docker buildx imagetools create --tag "$rho_image:latest" "$rho_image:$timestamp"
printf 'Published both images as :%s and :latest\n' "$timestamp"
