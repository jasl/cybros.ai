#!/bin/bash
# Channel selection is release policy: resolve Node LTS and Rust Stable to
# exact versions at bump time, while preserving other already-pinned tools.
# shellcheck disable=SC1091
. "$(dirname "$0")/helpers.sh"

mkdir -p "$TEST_TMP/bin"
export BUMP_MISE_LOG="$TEST_TMP/mise.log"
cat > "$TEST_TMP/bin/mise" <<'MISE'
#!/bin/bash
printf '%s\n' "$*" >> "$BUMP_MISE_LOG"
case "$*" in
  'latest node@lts') printf '24.99.1\n' ;;
  'latest node') printf '26.99.1\n' ;;
  'latest rust@latest') printf '%s\n' "${BUMP_RUST_RESPONSE-1.99.1}" ;;
  'latest rust@stable') printf 'stable\n' ;;
  'latest go@1.27') printf '1.27.9\n' ;;
  'latest python@3.14') ;;
  *) printf 'unexpected mise request: %s\n' "$*" >&2; exit 1 ;;
esac
MISE
chmod +x "$TEST_TMP/bin/mise"
export PATH="$TEST_TMP/bin:$PATH"

assert_exit 0 "a bump resolves approved channels and keeps unrelated full pins" -- \
  ruby -r "$INSTALL_DIR/lib/rho_install/bump" -rstringio -e '
    manifest = RhoInstall::Manifest.new({ "toolchains" => { "mise" => {
      "tools" => %w[node@24.20.0 rust@1.97.0 go@1.27.1 go@1.27],
    } } })
    RhoInstall::Bump.new(manifest, out: StringIO.new).send(:bump_toolchain_tools)
    expected = %w[node@24.99.1 rust@1.99.1 go@1.27.1 go@1.27.9]
    actual = manifest.data.fetch("toolchains").fetch("mise").fetch("tools")
    abort "expected #{expected.inspect}, got #{actual.inspect}" unless actual == expected
  '
assert_eq "$(cat "$BUMP_MISE_LOG")" "$(printf '%s\n' 'latest node@lts' 'latest rust@latest' 'latest go@1.27')" \
  "Node must use LTS, Rust must use Stable, and full Go pins must not query mise"
pass "Node LTS and Rust Stable become exact pins; other full pins stay fixed"

assert_exit 1 "an unresolved Rust alias cannot become a release pin" -- \
  env BUMP_RUST_RESPONSE=stable ruby -r "$INSTALL_DIR/lib/rho_install/bump" \
    -e 'RhoInstall::Bump.new.send(:pinned_tool, "rust@1.97.0")'
assert_contains "$LAST_OUTPUT" "did not return a concrete release" "floating Rust aliases stay a failure"
pass "a floating Rust alias is refused"

assert_exit 1 "an empty resolver response cannot become a release pin" -- \
  ruby -r "$INSTALL_DIR/lib/rho_install/bump" -e 'RhoInstall::Bump.new.send(:pinned_tool, "python@3.14")'
assert_contains "$LAST_OUTPUT" "did not return a concrete release" "empty toolchain resolution stays a failure"
pass "an empty mise result is refused"
