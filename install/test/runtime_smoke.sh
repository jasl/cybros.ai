#!/bin/bash
# Runs inside the published image as its normal user, without network access.
set -euo pipefail

test "$(id -u)" = 1000
for tool in git rg fd jq zip unzip cc cmake ninja mise node npm pnpm go cargo rustc rustfmt rustup uv ruff pyright mypy python python3; do
  command -v "$tool" >/dev/null
done
for tool in ruby java bun; do
  if command -v "$tool" >/dev/null; then
    printf 'project %s must be installed on demand through mise\n' "$tool" >&2
    exit 1
  fi
done
# Check the shipped footprint before package-manager commands can create caches.
for cache in "$HOME/.npm" /opt/rho/current/vendor/bundle/ruby/*/cache; do
  if [ -d "$cache" ] && [ -n "$(find "$cache" -mindepth 1 -print -quit)" ]; then
    printf 'the image retained download cache %s\n' "$cache" >&2
    exit 1
  fi
done
mise ls --installed --json | jq -e 'keys == ["go", "node", "rust"] and all(.[]; length == 1)' >/dev/null
node_version=$(jq -r '.toolchains.mise.tools[] | select(startswith("node@")) | split("@")[1]' /opt/rho/manifest.json)
rust_version=$(jq -r '.toolchains.mise.tools[] | select(startswith("rust@")) | split("@")[1]' /opt/rho/manifest.json)
test "$(node -p 'process.versions.node')" = "$node_version"
npm list --global --depth=0 --json |
  jq -e --slurpfile manifest /opt/rho/manifest.json \
    '.dependencies as $installed | all($manifest[0].toolchains.mise.npm_default_packages[]; $installed[.] != null)' >/dev/null
test "$(rustc --version | cut -d' ' -f2)" = "$rust_version"
components=$(rustup component list --toolchain "$rust_version" --installed)
for component in cargo rustc rust-std rustfmt clippy; do
  printf '%s\n' "$components" | grep -q "^$component-"
done
test "$(printf '%s\n' "$components" | wc -l | tr -d ' ')" = 5
test ! -d "$(rustc --print sysroot)/share/doc/rust/html"
/opt/rho/ruby/current/bin/ruby -rrubygems -e 'abort "RubyGems must default to --no-document" unless Gem.configuration[:gem].to_s.split.include?("--no-document")'

test "$(command -v python3)" = /opt/cowork/bin/python3
test -z "${VIRTUAL_ENV:-}${PYTHONPATH:-}"
uv python list --only-installed --managed-python --output-format json |
  jq -e 'length > 0 and all(.[]; .version_parts.major == 3 and .version_parts.minor == 14)' >/dev/null
uv_tools=$(uv tool dir)
for python in /opt/cowork/bin/python "$uv_tools"/ruff/bin/python "$uv_tools"/pyright/bin/python "$uv_tools"/mypy/bin/python; do
  "$python" -c 'import sys; assert sys.version_info[:2] == (3, 14), (sys.executable, sys.version)'
done
work=${1:-$(mktemp -d)}
if [ "$#" = 0 ]; then trap 'rm -rf "$work"' EXIT; fi

printf 'int main(void) { return 0; }\n' > "$work/smoke.c"
cc "$work/smoke.c" -o "$work/smoke"
"$work/smoke"
printf '{"private":true}\n' > "$work/package.json"
pnpm --dir "$work" exec node -e 'if (1 + 1 !== 2) process.exit(1)'
printf 'package main\nfunc main() { if 1 + 1 != 2 { panic("arithmetic") } }\n' > "$work/smoke.go"
GOCACHE="$work/go-cache" GOTOOLCHAIN=local go build -o "$work/go-smoke" "$work/smoke.go"
"$work/go-smoke"
cargo init --quiet --vcs none --bin --name rho-runtime-smoke "$work/rust-smoke"
printf 'fn main() { let answer = "42".parse::<u32>().expect("integer"); assert_eq!(answer, 42); }\n' > "$work/rust-smoke/src/main.rs"
cargo fmt --manifest-path "$work/rust-smoke/Cargo.toml"
cargo fmt --manifest-path "$work/rust-smoke/Cargo.toml" --check
cargo clippy --offline --manifest-path "$work/rust-smoke/Cargo.toml" -- -D warnings
cargo run --offline --quiet --manifest-path "$work/rust-smoke/Cargo.toml"
printf 'answer: int = 42\nassert answer == 42\n' > "$work/smoke.py"
ruff check --no-cache "$work/smoke.py"
pyright "$work/smoke.py"
mypy --cache-dir "$work/mypy-cache" "$work/smoke.py"
python3 "$work/smoke.py"
python3 -m venv "$work/project-env"
# Explicit project activation wins over the image's default Python.
(
  # shellcheck disable=SC1091
  . "$work/project-env/bin/activate"
  test "$(command -v python3)" = "$work/project-env/bin/python3"
)
rm -rf "$work/project-env"
python3 "$(dirname "$0")/cowork_smoke.py" "$work"

export BUNDLE_GEMFILE=/opt/rho/current/agents/rho/rho/Gemfile
export BUNDLE_PATH=/opt/rho/current/vendor/bundle
export BUNDLE_DEPLOYMENT=1
export BUNDLE_WITHOUT=development:test
export RHO_PREFIX=/opt/rho
# rho's installed wrapper prepends its prefix before Bundler takes its snapshot.
export PATH="$RHO_PREFIX/bin:$PATH"
/opt/rho/ruby/current/bin/ruby -rbundler/setup "$(dirname "$0")/workspace_tools_smoke.rb" "$work"
/opt/rho/ruby/current/bin/ruby -rbundler/setup "$(dirname "$0")/browser_smoke.rb" "$work"
printf '%s\n' 'coding, Cowork and rho-browser runtime smoke passed'
