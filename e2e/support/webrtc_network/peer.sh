#!/bin/sh
set -eu

# docker exec client termination closes stdin but does not signal its process.
# Preserve the native helper's lifetime contract across that test-only proxy.
directory=$(mktemp -d)
trap 'rm -rf "$directory"' EXIT
mkfifo "$directory/input"
/transport < "$directory/input" &
transport_pid=$!
cat > "$directory/input" || true
kill -KILL "$transport_pid" 2>/dev/null || true
wait "$transport_pid" 2>/dev/null || true
