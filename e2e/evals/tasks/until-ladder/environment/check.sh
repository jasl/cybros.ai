#!/bin/sh
# Fails on its first run, passes from the second: a ladder, not a coin.
n=$(cat .check-count 2>/dev/null || echo 0)
n=$((n + 1))
echo "$n" > .check-count
if [ ! -f note.txt ]; then echo "note.txt is missing"; exit 2; fi
if [ "$n" -lt 2 ]; then echo "not yet: run $n"; exit 1; fi
echo "ok on run $n"
