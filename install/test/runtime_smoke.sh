#!/bin/bash
# Runs inside the published image as its normal user, without network access.
set -eu

test "$(id -u)" = 1000
for tool in git rg fd jq zip unzip cc cmake ninja ruby node npm pnpm go java bun rustc python python3; do
  command -v "$tool" >/dev/null
done
test "$(command -v python3)" = /opt/cowork/bin/python3
test -z "${VIRTUAL_ENV:-}${PYTHONPATH:-}"
work=${1:-$(mktemp -d)}
if [ "$#" = 0 ]; then trap 'rm -rf "$work"' EXIT; fi

printf 'int main(void) { return 0; }\n' > "$work/smoke.c"
cc "$work/smoke.c" -o "$work/smoke"
"$work/smoke"
node -e 'if (1 + 1 !== 2) process.exit(1)'
bun -e 'if (!process.versions.bun) process.exit(1)'
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
