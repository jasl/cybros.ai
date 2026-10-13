#!/bin/bash
# The seed: `seed_bundle` copies the previous version's vendor/bundle into
# the staging dir when that version was built against the same Ruby, so
# bundler verifies instead of compiling, and it leaves the previous
# version's own bundle untouched. A previous version built against another
# Ruby seeds nothing. Offline: a fabricated gem stands in for a built bundle.
# shellcheck disable=SC1091
. "$(dirname "$0")/helpers.sh"

export RHO_PREFIX="$TEST_TMP/prefix" RHO_HOME="$TEST_TMP/home" RHO_LAUNCHER_DIR="$TEST_TMP/bin" NONINTERACTIVE=1
set --
# shellcheck disable=SC1090,SC1091
. "$INSTALLER"

ordinary="io-event-1.21.1"
previous="$PREFIX/versions/0.1.0-checkout-r$RUBY_VERSION"
bundle="$previous/vendor/bundle/ruby/4.0.0"
mkdir -p "$bundle/gems/$ordinary/lib" "$bundle/specifications" "$bundle/cache" "$bundle/extensions/x86_64-linux/4.0.0-static/$ordinary" "$bundle/build_info"
touch "$bundle/gems/$ordinary/lib/a.rb" "$bundle/specifications/$ordinary.gemspec" "$bundle/cache/$ordinary.gem" \
  "$bundle/extensions/x86_64-linux/4.0.0-static/$ordinary/gem.build_complete" "$bundle/build_info/$ordinary.info"
printf "%s\n" "$RUBY_VERSION" > "$previous/.ruby"
mkdir -p "$PREFIX"
ln -s "versions/$(basename "$previous")" "$PREFIX/current"

STAGING="$TEST_TMP/staging"
mkdir -p "$STAGING"
seed_bundle > "$TEST_TMP/seed.out" 2>&1 || fail "seed_bundle failed: $(cat "$TEST_TMP/seed.out")"
staged="$STAGING/vendor/bundle/ruby/4.0.0"

for footprint in "gems/$ordinary/lib/a.rb" "specifications/$ordinary.gemspec" "cache/$ordinary.gem" "extensions/x86_64-linux/4.0.0-static/$ordinary/gem.build_complete" "build_info/$ordinary.info"; do
  [ -e "$staged/$footprint" ] || fail "the seed lost $footprint"
done
pass "the same Ruby's vendor/bundle is copied into the seed ($ordinary: gems, specifications, cache, extensions, build_info)"

[ -e "$bundle/gems/$ordinary/lib/a.rb" ] || fail "the previous version lost gems/$ordinary (the seed is a copy, never the original)"
pass "the previous version's vendor/bundle is untouched"

# A previous version built against another Ruby seeds nothing.
rm -rf "$STAGING"
mkdir -p "$STAGING"
printf "%s\n" "3.9.9_1" > "$previous/.ruby"
seed_bundle > "$TEST_TMP/seed2.out" 2>&1 || fail "seed_bundle failed on another Ruby: $(cat "$TEST_TMP/seed2.out")"
[ ! -e "$STAGING/vendor" ] || fail "a previous version on another Ruby seeded vendor/bundle"
pass "another Ruby's vendor/bundle seeds nothing"
