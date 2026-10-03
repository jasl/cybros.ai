#!/bin/bash
# The installer's test runner (`rake install:test`): shellcheck on every
# script, then each *_test.sh in order under its own `set -e`. The install
# test needs the network; RHO_INSTALL_TEST_OFFLINE=1 skips it (the update
# ladder still runs: update_test.sh is offline). The docker
# test builds the image; RHO_INSTALL_TEST_DOCKER=1 opts in.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
install_dir=$(cd "$here/.." && pwd)

printf "==> shellcheck\n"
shellcheck -s bash "$install_dir"/*.sh "$here"/*.sh
printf "  ok  shellcheck clean\n"

for test in "$here"/*_test.sh; do
  name=$(basename "$test")
  if [ "$name" = "install_test.sh" ] && [ -n "${RHO_INSTALL_TEST_OFFLINE:-}" ]; then
    printf "==> %s (skipped: RHO_INSTALL_TEST_OFFLINE)\n" "$name"
    continue
  fi
  if [ "$name" = "docker_test.sh" ] && [ -z "${RHO_INSTALL_TEST_DOCKER:-}" ]; then
    printf "==> %s (skipped: set RHO_INSTALL_TEST_DOCKER=1 to build the image)\n" "$name"
    continue
  fi
  printf "==> %s\n" "$name"
  /bin/bash "$test"
done
printf "all install tests passed\n"
