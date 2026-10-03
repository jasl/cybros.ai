#!/bin/bash
# The `current` symlink swap: `mv -f new current` on a
# link-to-directory moves the new link INTO the directory on both mv's;
# the script probes which flag this mv takes (-T GNU, -h BSD) and the swap
# must leave `current` pointing at the NEW target, with nothing moved
# into the old one.
# shellcheck disable=SC1091
. "$(dirname "$0")/helpers.sh"

export RHO_PREFIX="$TEST_TMP/prefix" RHO_HOME="$TEST_TMP/home" RHO_LAUNCHER_DIR="$TEST_TMP/bin" NONINTERACTIVE=1
set --
# shellcheck disable=SC1090,SC1091
. "$INSTALLER"

probe_mv
case "$(uname -s)" in
  Darwin) assert_eq "$MV_LINK_FLAG" "-hf" "BSD mv takes -h" ;;
  *) assert_eq "$MV_LINK_FLAG" "-Tf" "GNU mv takes -T" ;;
esac
pass "probe_mv chose $MV_LINK_FLAG for $(uname -s)"

root="$TEST_TMP/swap"
mkdir -p "$root/versions/v1" "$root/versions/v2"
touch "$root/versions/v1/marker-v1" "$root/versions/v2/marker-v2"
ln -s versions/v1 "$root/current"

swap_link "versions/v2" "$root/current"
assert_eq "$(readlink "$root/current")" "versions/v2" "current points at v2 after the swap"
for stray in "$root/versions/v1/current" "$root/versions/v1"/current.tmp* "$root"/current.tmp*; do
  [[ ! -e "$stray" && ! -L "$stray" ]] || fail "the swap left $stray behind (the mv -f failure)"
done
[ -f "$root/current/marker-v2" ] || fail "current does not resolve to v2's contents"
pass "swap replaces a link-to-directory atomically"

swap_link "versions/v1" "$root/current"
assert_eq "$(readlink "$root/current")" "versions/v1" "a second swap goes back"
pass "swap is repeatable (rollback shape)"

ln -s 4.0.6_2 "$root/ruby-current"
swap_link "4.0.7_1" "$root/ruby-current"
assert_eq "$(readlink "$root/ruby-current")" "4.0.7_1" "a link to a missing target still swaps (ruby/current before the dir exists)"
pass "swap does not require the target to exist"

# A plain `mv -f` would have failed the first assertion; prove the premise
# on this machine so the guard is not a tautology.
mkdir -p "$root/premise/versions/v1"
ln -s versions/v1 "$root/premise/current"
ln -s versions/v2 "$root/premise/current.tmp"
mv -f "$root/premise/current.tmp" "$root/premise/current" 2>/dev/null || true
if [ -L "$root/premise/versions/v1/current.tmp" ]; then
  pass "premise holds: plain mv -f moved the new link INTO versions/v1"
else
  assert_eq "$(readlink "$root/premise/current")" "versions/v1" "premise: plain mv -f left current on v1"
  pass "premise holds: plain mv -f left current on v1"
fi
