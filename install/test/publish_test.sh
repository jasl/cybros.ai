#!/bin/bash
# Exercise publishing order and failure boundaries without Docker or a registry.
set -eu
# shellcheck disable=SC1091
. "$(dirname "$0")/helpers.sh"

mkdir -p "$TEST_TMP/bin" "$TEST_TMP/source with spaces/install/docker" "$TEST_TMP/source with spaces/install/test" \
  "$TEST_TMP/source with spaces/nexus" "$TEST_TMP/source with spaces/install/stack/updater"
source_root="$TEST_TMP/source with spaces"
cp "$INSTALL_DIR/docker/publish.sh" "$INSTALL_DIR/docker/verify-release.rb" "$source_root/install/docker/"
cp "$INSTALL_DIR/test/runtime_smoke.sh" "$source_root/install/test/"
printf '%s\n' 'FROM scratch' > "$source_root/nexus/Dockerfile"
printf '%s\n' 'FROM scratch' > "$source_root/install/docker/Dockerfile"
printf '%s\n' 'FROM scratch' > "$source_root/install/stack/updater/Dockerfile"
printf '%s\n' 'ignored-local.txt' > "$source_root/.gitignore"
printf '%s\n' 'must not enter the image' > "$source_root/ignored-local.txt"
git_quiet -C "$source_root" init -q -b main
git_quiet -C "$source_root" add -A
git_quiet -C "$source_root" commit -q -m 'publisher fixture'
export MOCK_REVISION
MOCK_REVISION=$(git -C "$source_root" rev-parse HEAD)
publisher="$source_root/install/docker/publish.sh"
cp "$INSTALL_DIR/test/publish_docker.rb" "$TEST_TMP/bin/docker"
chmod 755 "$TEST_TMP/bin/docker"
cat > "$TEST_TMP/bin/date" <<'MOCK'
#!/bin/sh
set -eu
printf '%s\n' "$*" >> "$MOCK_DATE_CALLS"
if [ "$*" = '-u +%y%m%d%H%M' ]; then printf '%s\n' 2610080750; else printf '%s\n' 2610081550; fi
MOCK
chmod 755 "$TEST_TMP/bin/date"
export PATH="$TEST_TMP/bin:$PATH"
export MOCK_DOCKER_ROOT="$TEST_TMP/docker"
export MOCK_DATE_CALLS="$TEST_TMP/date.calls"
export MOCK_RELEASE_TAG=2610080750
export CYBROS_AMD64_DOCKER_CONTEXT=ssh://builder@example.invalid
export CYBROS_ARM64_DOCKER_CONTEXT=native-arm64
export CYBROS_NEXUS_IMAGE_REPOSITORY=docker.io/test-publisher/cybros-nexus
export CYBROS_RHO_IMAGE_REPOSITORY=docker.io/test-publisher/cybros-rho
export CYBROS_UPDATER_IMAGE_REPOSITORY=docker.io/test-publisher/cybros-updater

reset_docker() { rm -rf "$MOCK_DOCKER_ROOT"; }
assert_no_latest() {
  ruby -rjson -e 'calls = File.readlines(ARGV.fetch(0)).map { |line| JSON.parse(line) }; abort "latest was changed" if calls.any? { |call| call.include?("create") && call.any? { |value| value.end_with?(":latest") } }' "$MOCK_DOCKER_ROOT/calls.jsonl"
}
assert_no_build() {
  ruby -rjson -e 'calls = File.readlines(ARGV.fetch(0)).map { |line| JSON.parse(line) }; abort "unexpected build or push" if calls.any? { |call| call.include?("build") || call.include?("push") }' "$MOCK_DOCKER_ROOT/calls.jsonl"
}
assert_cleaned() {
  ruby -rjson -e 'state = JSON.parse(File.read(ARGV.fetch(0))); abort "owned context leaked" unless state.fetch("contexts").empty?; abort "smoke container leaked" unless state.fetch("containers").empty?' "$MOCK_DOCKER_ROOT/state.json"
}

assert_exit 0 'native images, registry verification and latest promotion complete' -- sh "$publisher" "$MOCK_RELEASE_TAG"
ruby -rjson - "$MOCK_DOCKER_ROOT/calls.jsonl" "$MOCK_DOCKER_ROOT/state.json" <<'RUBY'
calls = File.readlines(ARGV.fetch(0)).map { |line| JSON.parse(line) }
state = JSON.parse(File.read(ARGV.fetch(1)))
commands = calls.map { |call| call.first == "--context" ? call.drop(2) : call }
builds = calls.select { |call| call.include?("build") }
abort "expected six native builds" unless builds.length == 6
builds.each do |call|
  context = call.fetch(1)
  architecture = context.include?("arm64") ? "arm64" : "amd64"
  abort "wrong Engine builder" unless call.fetch(call.index("--builder") + 1) == context
  abort "build is not native" unless call.fetch(call.index("--platform") + 1) == "linux/#{architecture}"
  abort "native result not loaded for smoke" unless call.include?("--load")
  abort "build pushed before runtime checks" if call.include?("--push")
  %W[org.opencontainers.image.version=#{ENV.fetch("MOCK_RELEASE_TAG")} org.opencontainers.image.revision=#{ENV.fetch("MOCK_REVISION")} org.opencontainers.image.source=https://github.com/jasl/cybros.ai].each do |label|
    abort "missing release label" unless call.include?(label)
  end
  reference = call.fetch(call.index("-t") + 1)
  if reference.include?("cybros-rho:")
    abort "rho is not the browser target" unless call.fetch(call.index("--target") + 1) == "browser"
  end
end
first_push = commands.index { |call| call.first == "push" }
last_build = commands.rindex { |call| call[0, 2] == %w[buildx build] }
last_smoke = commands.rindex { |call| %w[run start].include?(call.first) }
abort "push preceded complete native QA" unless first_push > last_build && first_push > last_smoke
abort "expected six native pushes" unless commands.count { |call| call.first == "push" } == 6
first_latest = commands.index { |call| call.include?("create") && call.any? { |value| value.end_with?(":latest") } }
%w[nexus rho updater].each do |product|
  repository = ENV.fetch("CYBROS_#{product.upcase}_IMAGE_REPOSITORY")
  release = "#{repository}:#{ENV.fetch("MOCK_RELEASE_TAG")}"
  checked = commands[0...first_latest].any? { |call| call[0, 3] == %w[buildx imagetools inspect] && call.include?(release) }
  abort "latest preceded formal release verification" unless checked
  release_artifact = state.fetch("registry").fetch(release)
  abort "latest did not use the verified index" unless state.fetch("registry").fetch("#{repository}:latest") == release_artifact
end
abort "remote smoke used a host bind path" if commands.any? { |call| call.first == "run" && call.include?("-v") }
abort "runtime payload was not copied to both Engines" unless commands.count { |call| call.first == "cp" } == 2
abort "an existing context was removed" if commands.any? { |call| call[0, 2] == %w[context rm] && call.include?("native-arm64") }
RUBY
assert_cleaned
[ ! -e "$MOCK_DATE_CALLS" ] || fail 'explicit release consulted the clock'
pass 'six native builds and smoke finish before pushing; every release verifies before latest'

reset_docker
assert_exit 0 'default tag uses one UTC clock read' -- env TZ=Asia/Shanghai sh "$publisher"
assert_eq "$(cat "$MOCK_DATE_CALLS")" '-u +%y%m%d%H%M' 'one UTC clock read'
assert_cleaned
pass 'default release uses UTC even in another host timezone'

reset_docker
assert_exit 0 'valid leap day preserves leading zero year' -- sh "$publisher" 0002292359
assert_contains "$LAST_OUTPUT" 'as :0002292359 and :latest' 'tag remains a string'
pass 'explicit calendar tag is preserved'

for tag in '' 1791439200 20261008075000 261008750 2613000750 2602290750 2604310750 2610082400 2610080760 '26100807x0'; do
  reset_docker
  assert_exit 2 'invalid calendar tag is refused before Docker' -- sh "$publisher" "$tag"
  assert_contains "$LAST_OUTPUT" 'yyMMddHHmm' 'tag format guidance'
  [ ! -e "$MOCK_DOCKER_ROOT/calls.jsonl" ] || fail 'invalid release reached Docker'
done
pass 'invalid calendar dates and time fields never reach Docker'

reset_docker
printf '\n# dirty\n' >> "$source_root/nexus/Dockerfile"
assert_exit 2 'uncommitted source cannot receive a commit revision label' -- sh "$publisher" "$MOCK_RELEASE_TAG"
[ ! -e "$MOCK_DOCKER_ROOT/calls.jsonl" ] || fail 'dirty source reached Docker'
git -C "$source_root" checkout -- nexus/Dockerfile
assert_exit 2 'both native contexts are required' -- env CYBROS_ARM64_DOCKER_CONTEXT= sh "$publisher" "$MOCK_RELEASE_TAG"
[ ! -e "$MOCK_DOCKER_ROOT/calls.jsonl" ] || fail 'missing context reached Docker'
pass 'clean source and explicit native Engines are required'

for scenario in 'MOCK_NON_NATIVE=amd64' 'MOCK_DRIVER=docker-container'; do
  reset_docker
  assert_exit 2 'incorrect native Engine is refused' -- env "$scenario" sh "$publisher" "$MOCK_RELEASE_TAG"
  assert_no_latest
  assert_no_build
  assert_cleaned
done
pass 'wrong architecture and custom builder refuse before building'

for scenario in 'MOCK_EXISTING_TAG=2610080750' 'MOCK_EXISTING_TAG=2610080750-arm64'; do
  reset_docker
  assert_exit 1 'release tag reuse refuses' -- env "$scenario" sh "$publisher" "$MOCK_RELEASE_TAG"
  assert_no_latest
  assert_no_build
  assert_cleaned
done
# shellcheck disable=SC2016 # Docker reports the literal variable name in this error.
for error in 'connection timed out' 'unauthorized: authentication required' 'ERROR: other/image:wrong-tag: not found' 'ERROR: error getting credentials - err: exec: docker-credential-missing: executable file not found in $PATH'; do
  reset_docker
  assert_exit 1 'registry or credential error is not an absent manifest' -- env MOCK_REGISTRY_ERROR="$error" sh "$publisher" "$MOCK_RELEASE_TAG"
  assert_contains "$LAST_OUTPUT" "$error" 'original registry failure is reported'
  assert_no_latest
  assert_no_build
  assert_cleaned
done
pass 'existing tags remain immutable; auth, network and credential-helper errors refuse before build'

reset_docker
assert_exit 0 'Docker Hub canonical missing reference is recognized' -- \
  env MOCK_REGISTRY_ERROR='ERROR: docker.io/test-publisher/cybros-nexus:2610080750: not found' \
  ruby "$INSTALL_DIR/docker/verify-release.rb" absent test-publisher/cybros-nexus:2610080750
assert_exit 0 'Docker Hub library reference is recognized' -- \
  env MOCK_REGISTRY_ERROR='ERROR: docker.io/library/nexus:2610080750: not found' \
  ruby "$INSTALL_DIR/docker/verify-release.rb" absent nexus:2610080750
pass 'Docker Hub canonical references preserve a real missing-manifest result'

for stage in build-rho-amd64 build-updater-arm64 run-amd64 smoke-arm64 push-arm64 index; do
  reset_docker
  assert_exit 19 'failed image preparation or upload propagates' -- env MOCK_FAIL_AT="$stage" sh "$publisher" "$MOCK_RELEASE_TAG"
  assert_no_latest
  assert_cleaned
done
reset_docker
assert_exit 1 'nonzero container exit is a failed smoke even when attach succeeds' -- env MOCK_SMOKE_EXIT=23 sh "$publisher" "$MOCK_RELEASE_TAG"
assert_no_latest
assert_cleaned
pass 'build, smoke, push and index failures preserve latest and clean owned resources'

reset_docker
assert_exit 143 'interrupt during smoke cleans owned container and context' -- env MOCK_FAIL_AT=interrupt-smoke sh "$publisher" "$MOCK_RELEASE_TAG"
assert_no_latest
assert_cleaned
pass 'interrupted native smoke cleans its container and temporary context'

reset_docker
assert_exit 0 'single native manifest can be wrapped in an index with an attestation' -- env MOCK_NATIVE_INDEX=1 sh "$publisher" "$MOCK_RELEASE_TAG"
assert_cleaned
pass 'native config verification follows its image digest through an architecture index'

for scenario in 'MOCK_BAD_LABEL=arm64' 'MOCK_BAD_CONFIG_ARCH=amd64' 'MOCK_BAD_RELEASE=1' 'MOCK_WRONG_RELEASE_CHILD=1'; do
  reset_docker
  assert_exit 1 'native config or formal index mismatch blocks promotion' -- env "$scenario" sh "$publisher" "$MOCK_RELEASE_TAG"
  assert_no_latest
  assert_cleaned
done
pass 'native labels, config platforms and exact formal image digests gate latest'

reset_docker
assert_exit 19 'a partial promotion is reported as failure' -- env MOCK_FAIL_AT=promote-cybros-rho sh "$publisher" "$MOCK_RELEASE_TAG"
assert_cleaned
reset_docker
assert_exit 1 'post-promotion latest digest mismatch fails verification' -- env MOCK_BAD_LATEST=1 sh "$publisher" "$MOCK_RELEASE_TAG"
assert_cleaned
pass 'promotion failure and wrong latest digest cannot report success'

reset_docker
assert_exit 0 'custom repository registry port is retained' -- env CYBROS_NEXUS_IMAGE_REPOSITORY=registry.example:5443/team/cybros-nexus CYBROS_UPDATER_IMAGE_REPOSITORY=ghcr.io/example/manager sh "$publisher" "$MOCK_RELEASE_TAG"
assert_contains "$LAST_OUTPUT" 'Verified registry.example:5443/team/cybros-nexus:' 'custom registry with port'
assert_contains "$LAST_OUTPUT" 'Verified ghcr.io/example/manager:' 'independent updater repository'
assert_cleaned
pass 'repository overrides preserve registry ports and independent image names'
