#!/bin/bash
# Offline download recovery through the real installer. A recording curl
# supplies interrupted, mirrored and corrupt responses without network IO.
# shellcheck disable=SC2034 # ARTIFACT_DOMAIN is read by the sourced installer.
# shellcheck disable=SC1091
. "$(dirname "$0")/helpers.sh"

export RHO_PREFIX="$TEST_TMP/prefix" RHO_HOME="$TEST_TMP/home" RHO_LAUNCHER_DIR="$TEST_TMP/bin" NONINTERACTIVE=1
set -- --from-checkout "$REPO_ROOT"
# shellcheck disable=SC1090,SC1091
. "$INSTALLER"

origin="https://publisher.example/artifact"
mirror="https://mirror.example/artifact"
artifact_sha="58285418baaedef853036c652664d5bfa466a136376be999d772b20b37da909d"

start_case() {
  DOWNLOADS="$TEST_TMP/$1"
  response="$1"
  ARTIFACT_DOMAIN=""
  mkdir -p "$DOWNLOADS"
  requests="$DOWNLOADS/requests"
  : > "$requests"
}

curl() {
  local destination="" resume="" url=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -o) shift; destination="$1" ;;
      -C) shift; resume="$1" ;;
      *) url="$1" ;;
    esac
    shift
  done
  printf '%s\n' "$url" >> "$requests"
  case "$response" in
    interrupted)
      if [ "$(wc -l < "$requests" | tr -d ' ')" = "1" ]; then
        printf 'verified' > "$destination"
        return 92
      fi
      assert_eq "$resume" "-" "the retry requests a resumed transfer"
      assert_eq "$(cat "$destination")" "verified" "the retry retains the downloaded prefix"
      printf ' artifact payload\n' >> "$destination" ;;
    mirror)
      assert_eq "$url" "$mirror" "a successful mirror needs no origin request"
      printf 'verified artifact payload\n' > "$destination" ;;
    mirror_fallback)
      if [ "$url" = "$mirror" ]; then
        printf 'mirror partial' > "$destination"
        return 92
      fi
      assert_eq "$url" "$origin" "a failed mirror falls back to the origin"
      [ ! -e "$destination" ] || fail "the origin received the failed mirror's bytes"
      printf 'verified artifact payload\n' > "$destination" ;;
    range_restart)
      if [ "$resume" = "-" ]; then
        assert_eq "$(cat "$destination")" "verified" "the range request keeps the partial download"
        return 33
      fi
      [ ! -e "$destination" ] || fail "the full restart retained the rejected partial download"
      printf 'verified artifact payload\n' > "$destination" ;;
    corrupt) printf 'wrong artifact\n' > "$destination" ;;
    *) fail "unknown response $response" ;;
  esac
}

# An installer abort must exit the invocation, not this test process.
download() ( fetch_artifact "$origin" "$artifact_sha" artifact; )

start_case interrupted
assert_exit 1 "an interrupted origin download" -- download
assert_contains "$LAST_OUTPUT" "could not download" "the transfer failure is reported"
assert_eq "$(cat "$DOWNLOADS/artifact.incomplete")" "verified" "the partial download survives"
[ ! -e "$DOWNLOADS/artifact" ] || fail "an interrupted download was promoted"

assert_exit 0 "the next invocation resumes the interrupted download" -- download
assert_eq "$(sha256_of "$DOWNLOADS/artifact")" "$artifact_sha" "only the complete verified download is promoted"
[ ! -e "$DOWNLOADS/artifact.incomplete" ] || fail "the promoted download retained its partial file"
assert_eq "$(wc -l < "$requests" | tr -d ' ')" "2" "the retry downloads the remaining bytes"

assert_exit 0 "a verified cache hit" -- download
assert_contains "$LAST_OUTPUT" "Cached artifact (sha256 verified)" "the verified cache is reused"
assert_eq "$(wc -l < "$requests" | tr -d ' ')" "2" "a verified cache hit makes no download request"
pass "interrupted origin downloads resume on the next invocation and remain checksum-verified"

start_case mirror
ARTIFACT_DOMAIN="https://mirror.example"
assert_exit 0 "a successful mirror download" -- download
assert_eq "$(cat "$requests")" "$mirror" "only the mirror is contacted"
assert_eq "$(sha256_of "$DOWNLOADS/artifact")" "$artifact_sha" "the mirror result is verified"
pass "a successful mirror avoids the origin"

start_case mirror_fallback
ARTIFACT_DOMAIN="https://mirror.example"
assert_exit 0 "an interrupted mirror falls back to the origin" -- download
assert_eq "$(cat "$requests")" "$(printf '%s\n%s' "$mirror" "$origin")" "the mirror precedes the origin"
assert_eq "$(sha256_of "$DOWNLOADS/artifact")" "$artifact_sha" "the origin fallback is verified"
pass "a failed mirror is discarded before the origin download"

start_case range_restart
printf 'verified' > "$DOWNLOADS/artifact.incomplete"
assert_exit 0 "a rejected range restarts the transfer" -- download
assert_eq "$(wc -l < "$requests" | tr -d ' ')" "2" "the rejected range causes one full restart"
assert_eq "$(sha256_of "$DOWNLOADS/artifact")" "$artifact_sha" "the full restart is verified"
pass "curl exit 33 restarts without the partial download"

start_case corrupt
assert_exit 1 "a corrupt successful response" -- download
assert_contains "$LAST_OUTPUT" "checksum mismatch" "the checksum failure is reported"
[ ! -e "$DOWNLOADS/artifact" ] || fail "a corrupt download was promoted"
[ ! -e "$DOWNLOADS/artifact.incomplete" ] || fail "a corrupt download was retained"
pass "a successful transfer with the wrong checksum is discarded"
