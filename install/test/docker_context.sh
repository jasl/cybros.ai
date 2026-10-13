#!/bin/bash
# Verify Docker's actual context filtering without downloading a base image.
# shellcheck disable=SC1091
. "$(dirname "$0")/helpers.sh"

docker build --network none -f - --output "type=local,dest=$TEST_TMP/context" "$REPO_ROOT" <<'DOCKERFILE'
FROM scratch
COPY install/stack/updater /updater
COPY install/stack/install.sh /install.sh
DOCKERFILE

test -s "$TEST_TMP/context/updater/updater.rb"
test -s "$TEST_TMP/context/updater/lib/cybros_updater/transport.rb"
test ! -e "$TEST_TMP/context/updater/test"
test ! -e "$TEST_TMP/context/updater/README.md"
sh -n "$TEST_TMP/context/install.sh"
pass "Docker context includes the deployment client and installer without updater tests"
