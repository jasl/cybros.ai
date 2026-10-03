#!/bin/sh
# Offline installer behavior: no real Docker calls, downloads or provider credentials.
set -eu
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
real_docker=$(command -v docker || true)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/cybros-stack-test.XXXXXX")
trap 'rm -rf "$test_root"' 0 HUP INT TERM
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
check() { printf 'ok: %s\n' "$*"; }
mkdir -p "$test_root/bin"
cat > "$test_root/bin/docker" <<'DOCKER'
#!/bin/sh
set -eu
printf '%s\n' "$*" >> "$TEST_DOCKER_LOG"
case "$*" in
  'compose version') [ "${TEST_NO_COMPOSE:-0}" = 0 ] ;;
  info) [ "${TEST_NO_DAEMON:-0}" = 0 ] ;;
  'compose up --help') printf '%s\n' --wait-timeout ;;
  *' config --quiet') [ "${TEST_BAD_CONFIG:-0}" = 0 ] ;;
  *' pull') [ "${TEST_PULL_FAIL:-0}" = 0 ] ;;
  *' --profile setup up -d setup') [ "${TEST_SETUP_SERVICE_FAIL:-0}" = 0 ] ;;
  *' exec -T rho rho console')
    [ "${TEST_CONSOLE_FAIL:-0}" = 0 ] || exit 1
    printf '%s\n' 'console: http://0.0.0.0:7777#code=synthetic-console-code' 'home: /var/lib/rho' 'code: synthetic-console-code' 'expires: 90s, single use'
    ;;
  *' exec -e CMCTL_HOME=/var/lib/rho/cmctl rho rho setup telegram --finish')
    [ -t 0 ] && [ -t 1 ] || { printf 'setup has no TTY\n' >&2; exit 1; }
    printf 'Your Telegram numeric user ID: '
    IFS= read -r answer
    printf '%s\n' "$answer" > "$TEST_SETUP_STDIN.finish"
    ;;
  *' exec -e CMCTL_HOME=/var/lib/rho/cmctl rho rho setup '*)
    [ -t 0 ] && [ -t 1 ] || { printf 'setup has no TTY\n' >&2; exit 1; }
    printf 'Configure test model [Y/n]: '
    IFS= read -r answer
    printf '%s\n' "$answer" > "$TEST_SETUP_STDIN"
    [ "${TEST_SETUP_FAIL:-0}" = 0 ]
    ;;
  *' up -d --wait '*) [ "${TEST_UP_FAIL:-0}" = 0 ] ;;
  *' exec -T -e CMCTL_HOME=/var/lib/rho/cmctl rho cmctl '*) cat > "$TEST_CMCTL_STDIN" ;;
  *) exit 0 ;;
esac
DOCKER
chmod 700 "$test_root/bin/docker"
for opener in open xdg-open; do
  cat > "$test_root/bin/$opener" <<'BROWSER'
#!/bin/sh
printf '%s\n' "$*" >> "$TEST_DOCKER_LOG.browser"
BROWSER
  chmod 700 "$test_root/bin/$opener"
done
PATH="$test_root/bin:$PATH"
export PATH
TEST_DOCKER_LOG="$test_root/docker.log"
export TEST_DOCKER_LOG
TEST_CMCTL_STDIN="$test_root/cmctl.stdin"
export TEST_CMCTL_STDIN
install_dir="$test_root/install with spaces"
export CYBROS_INSTALL_DIR="$install_dir"
export CYBROS_IMAGE_NAMESPACE=example-test CYBROS_IMAGE_TAG=1234567890
export CYBROS_BIND=0.0.0.0 CYBROS_NEXUS_URL=http://home.local:3300 CYBROS_RHO_URL=http://home.local:7777

sh "$here/render.sh" --check
shellcheck -s sh "$here/cybros" "$here/bootstrap.sh" "$here/render.sh" "$here/install.sh" "$here/test.sh"
for file in "$here/cybros" "$here/bootstrap.sh" "$here/render.sh" "$here/install.sh" "$here/test.sh"; do sh -n "$file"; done

if TEST_NO_DAEMON=1 sh "$here/install.sh" --yes > "$test_root/failure.log" 2>&1; then fail 'daemon check accepted a stopped Docker'; fi
[ ! -e "$install_dir" ] || fail 'failed prerequisites created installation'
if TEST_NO_COMPOSE=1 sh "$here/install.sh" --yes > "$test_root/failure.log" 2>&1; then fail 'missing Compose accepted'; fi
check 'prerequisites fail before writing configuration'

# The real curl|sh interpretation: the installer itself occupies stdin.
cat "$here/install.sh" | sh -s -- --yes > "$test_root/install.log"
cmp "$here/compose.yaml" "$install_dir/compose.yaml"
cmp "$here/cybros" "$install_dir/cybros"
cmp "$here/setup.rb" "$install_dir/setup.rb"
grep -q "CYBROS_IMAGE_TAG='1234567890'" "$install_dir/.env" || fail 'tag not captured'
grep -q "CYBROS_NEXUS_URL='http://home.local:3300'" "$install_dir/.env" || fail 'browser URL not captured'
[ "$(grep -c "='[a-f0-9]\{64\}'$" "$install_dir/secrets.env")" = 7 ] || fail 'secrets missing or malformed'
[ "$(cut -d= -f2 "$install_dir/secrets.env" | sort -u | wc -l | tr -d ' ')" = 8 ] || fail 'secrets are not independent'
python3 - "$install_dir/secrets.env" "$test_root/install.log" "$TEST_DOCKER_LOG" <<'PY'
from pathlib import Path
import re
import sys
from urllib.parse import parse_qs, unquote, urlsplit

secrets = dict(
    (name, value.strip("'"))
    for line in Path(sys.argv[1]).read_text().splitlines() if line and not line.startswith("#")
    for name, value in [line.split("=", 1)]
)
output = Path(sys.argv[2]).read_text()
calls = Path(sys.argv[3]).read_text().splitlines()
links = re.findall(r"http://home\.local:7777#[^\s]+", output)
assert links, "missing private rho link"
for link in links:
    assert parse_qs(urlsplit(link).fragment) == {"code": ["synthetic-console-code"]}
    output = output.replace(link, "")
assert "/setup#" not in output, "installer printed a Nexus setup link"
assert "0.0.0.0:7777" not in output, "installer printed rho's internal bind address"
assert "synthetic-console-code" not in output, "console code printed outside its private link"
for value in secrets.values():
    assert value not in unquote(output), "deployment secret printed"
    assert all(value not in call for call in calls), "secret passed in Docker arguments"
core = next(i for i, call in enumerate(calls) if " up -d --wait " in call)
setup = [i for i, call in enumerate(calls) if call.endswith(" --profile setup up -d setup")]
assert len(setup) == 1 and core < setup[0], "automatic pairing must start once after core health"
console = next(i for i, call in enumerate(calls) if call.endswith(" exec -T rho rho console"))
assert setup[0] < console, "rho link must be issued after core health and helper startup"
PY
[ "$(find "$install_dir" -prune -perm 700 -print)" = "$install_dir" ] || fail 'directory mode'
[ "$(find "$install_dir/secrets.env" -perm 600 -print)" = "$install_dir/secrets.env" ] || fail 'secret mode'
[ "$(find "$install_dir/setup.rb" -perm -004 -print)" = "$install_dir/setup.rb" ] || fail 'container cannot read setup helper'
check 'piped installation prints a private rho link and starts automatic pairing after core health'
if grep -q ' rho setup ' "$TEST_DOCKER_LOG"; then fail '--yes started an interactive wizard'; fi

cp "$install_dir/.env" "$test_root/env.before"
cp "$install_dir/secrets.env" "$test_root/secrets.before"
printf '\n# user customization\n' >> "$install_dir/compose.yaml"
printf '\n# user customization\n' >> "$install_dir/setup.rb"
CYBROS_IMAGE_TAG=999 sh "$here/install.sh" --yes > "$test_root/reinstall.log"
cmp "$test_root/env.before" "$install_dir/.env"
cmp "$test_root/secrets.before" "$install_dir/secrets.env"
grep -q 'user customization' "$install_dir/compose.yaml" || fail 'compose overwritten'
grep -q 'user customization' "$install_dir/setup.rb" || fail 'setup helper overwritten'
check 'reinstall preserves configuration, secrets, Compose and setup helper edits'
"$install_dir/cybros" instructions > "$test_root/instructions.log"
grep -q 'http://home.local:7777#code=synthetic-console-code' "$test_root/instructions.log" || fail 'fresh instructions lost the saved public rho URL'
if TEST_CONSOLE_FAIL=1 "$install_dir/cybros" instructions > "$test_root/failure.log" 2>&1; then fail 'console-link failure swallowed'; fi
grep -q './cybros up, then ./cybros instructions' "$test_root/failure.log" || fail 'console-link failure has no recovery command'
cmp "$test_root/secrets.before" "$install_dir/secrets.env"
check 'instructions regenerates a console link and failures retain deployment secrets'

"$install_dir/cybros" status > /dev/null
"$install_dir/cybros" logs nexus > /dev/null
"$install_dir/cybros" connect > /dev/null
"$install_dir/cybros" rho models > /dev/null
printf '%s\n' 'synthetic-test-key' | "$install_dir/cybros" cmctl provider key set openai_api --stdin > /dev/null
[ "$(cat "$TEST_CMCTL_STDIN")" = synthetic-test-key ] || fail 'cmctl did not retain stdin'
grep -q 'exec -T -e CMCTL_HOME=/var/lib/rho/cmctl rho cmctl provider key set openai_api --stdin$' "$TEST_DOCKER_LOG" || fail 'cmctl missing persistent home'
"$install_dir/cybros" stop > /dev/null
grep -q ' --profile setup stop$' "$TEST_DOCKER_LOG" || fail 'stop left the setup helper running'
grep -q 'exec -T rho rho connect$' "$TEST_DOCKER_LOG" || fail 'pairing bypassed public CLI'
grep -q ' logs --tail 100 nexus$' "$TEST_DOCKER_LOG" || fail 'logs missing'
if grep -q 'down\|volume rm' "$TEST_DOCKER_LOG"; then fail 'destructive cleanup invoked'; fi
check 'management uses existing CLIs, preserves piped secrets and retains data'

if TEST_PULL_FAIL=1 "$install_dir/cybros" update 1234567891 > "$test_root/failure.log" 2>&1; then fail 'pull failure swallowed'; fi
cmp "$test_root/env.before" "$install_dir/.env"
"$install_dir/cybros" update 1234567891 > /dev/null
grep -q "CYBROS_IMAGE_TAG='1234567891'" "$install_dir/.env" || fail 'update tag missing'
cmp "$test_root/secrets.before" "$install_dir/secrets.env"
if "$install_dir/cybros" update 'bad;tag' > "$test_root/failure.log" 2>&1; then fail 'invalid tag accepted'; fi
check 'upgrade changes the shared image tag only after a successful pull'

: > "$TEST_DOCKER_LOG"
if TEST_UP_FAIL=1 "$install_dir/cybros" up > "$test_root/failure.log" 2>&1; then fail 'health failure swallowed'; fi
grep -q 'Startup did not become healthy' "$test_root/failure.log" || fail 'missing health failure guidance'
if grep -q ' --profile setup up -d setup$' "$TEST_DOCKER_LOG"; then fail 'setup helper started after core health failed'; fi
cmp "$test_root/secrets.before" "$install_dir/secrets.env"
if TEST_SETUP_SERVICE_FAIL=1 "$install_dir/cybros" up > "$test_root/failure.log" 2>&1; then fail 'setup service startup failure swallowed'; fi
grep -q './cybros logs setup, then ./cybros up' "$test_root/failure.log" || fail 'missing setup service recovery guidance'
cmp "$test_root/secrets.before" "$install_dir/secrets.env"
mv "$install_dir/secrets.env" "$test_root/saved.secrets"
if sh "$here/install.sh" --yes > "$test_root/failure.log" 2>&1; then fail 'missing secrets regenerated'; fi
[ ! -e "$install_dir/secrets.env" ] || fail 'missing secrets regenerated'
check 'core and setup startup failures preserve state; missing existing secrets require restore'

: > "$TEST_DOCKER_LOG"
mkdir -p "$test_root/initialize only/data"
sh "$here/install.sh" --yes --dir "$test_root/initialize only" --no-start > "$test_root/no-start.log"
[ -f "$test_root/initialize only/secrets.env" ] || fail 'init did not create secrets'
if grep -q ' pull\| up -d' "$TEST_DOCKER_LOG"; then fail 'init pulled or started services'; fi
if grep -q ' rho console' "$TEST_DOCKER_LOG"; then fail 'init tried to mint a console link before services started'; fi
grep -q 'rho: http://home.local:7777' "$test_root/no-start.log" || fail 'init omitted plain rho URL'
grep -q './cybros instructions' "$test_root/no-start.log" || fail 'init omitted next browser step'
check 'init-only makes configuration without pulling or starting services'

mkdir -p "$test_root/restored/data/rho"
if sh "$here/install.sh" --yes --dir "$test_root/restored" --no-start > "$test_root/failure.log" 2>&1; then fail 'existing data accepted new encryption keys'; fi
[ ! -e "$test_root/restored/.env" ] && [ ! -e "$test_root/restored/secrets.env" ] || fail 'restore wrote new configuration'
grep -q 'Existing data has no secrets.env' "$test_root/failure.log" || fail 'missing restore guidance'
check 'a restored data tree without either environment file cannot regenerate secrets'

# Development-only Python drives a real controlling terminal while the installer
# consumes its source from a pipe. The shipped installer has no Python dependency.
python3 "$here/wizard_test.py"

if [ "${CYBROS_TEST_COMPOSE_CONFIG:-0}" = 1 ]; then
  [ -n "$real_docker" ] || fail 'real Docker Compose requested but not installed'
  (
    cd "$test_root/initialize only"
    unset CYBROS_IMAGE_NAMESPACE CYBROS_IMAGE_TAG CYBROS_BIND CYBROS_NEXUS_URL CYBROS_RHO_URL RHO_TELEGRAM_BOT_TOKEN
    "$real_docker" compose --env-file .env --env-file secrets.env config --quiet
    named_volumes=$("$real_docker" compose --env-file .env --env-file secrets.env config --volumes)
    [ -z "$named_volumes" ] || fail 'durable data unexpectedly uses named volumes'
    services=$("$real_docker" compose --env-file .env --env-file secrets.env config --services | wc -l | tr -d ' ')
    [ "$services" = 7 ] || fail 'missing joint-stack service'
    "$real_docker" compose --env-file .env --env-file secrets.env config --format json | python3 -c '
import json, os, sys
services = json.load(sys.stdin)["services"]
rho = services["rho"]
assert rho["environment"]["RHO_TELEGRAM_BOT_TOKEN"] == ""
assert all("RHO_TELEGRAM_BOT_TOKEN" not in row.get("environment", {}) for name, row in services.items() if name != "rho")
assert rho["environment"]["RHO_HOME"] == "/var/lib/rho"
assert rho["environment"]["RHO_TOOLS_ROOT"] == rho["working_dir"] == "/home/runner"
work = next(mount for mount in rho["volumes"] if mount["target"] == "/home/runner")
assert work["type"] == "bind" and os.path.realpath(work["source"]) == os.path.join(os.getcwd(), "data/rho/work")
'
    "$real_docker" compose --env-file .env --env-file secrets.env --profile setup config --format json | python3 -c '
import json, os, sys
services = json.load(sys.stdin)["services"]
assert len(services) == 8
setup = services["setup"]
assert setup["image"] == services["nexus"]["image"]
assert "setup" in setup["profiles"]
assert not setup.get("ports")
helper = next(mount for mount in setup["volumes"] if mount["target"] == "/rails/stack-setup.rb")
assert helper["type"] == "bind" and helper["read_only"]
assert os.path.realpath(helper["source"]) == os.path.join(os.getcwd(), "setup.rb")
assert "RHO_ACCESS_PASSPHRASE" not in setup["environment"]
rho = services["rho"]
assert rho["environment"]["RHO_INSTALLATION_FILE"] == "/var/lib/cybros-setup/status.json"
projection = next(mount for mount in rho["volumes"] if mount["target"] == "/var/lib/cybros-setup")
assert projection["read_only"]
writer = next(mount for mount in setup["volumes"] if mount["target"] == "/var/lib/cybros-setup")
assert not writer.get("read_only", False)
assert projection["source"] == writer["source"]
announcement = next(mount for mount in setup["volumes"] if mount["target"] == "/var/lib/rho-tmp")
assert announcement["read_only"]
assert os.path.realpath(announcement["source"]) == os.path.join(os.getcwd(), "data/rho/home/tmp")
assert "NEXUS_SETUP_SECRET" not in services["rho"]["environment"]
assert all("setup" not in row.get("depends_on", {}) for name, row in services.items() if name != "setup")
assert all(mount["target"] != "/var/run/docker.sock" for row in services.values() for mount in row.get("volumes", []))
'
    printf "RHO_TELEGRAM_BOT_TOKEN='synthetic-telegram-token'\n" >> .env
    # The installed wrapper must prefer its private dotenv file over another
    # deployment's token inherited from the calling shell.
    RHO_TELEGRAM_BOT_TOKEN=synthetic-other-bot PATH="$(dirname -- "$real_docker"):$PATH" \
      ./cybros compose config --format json | python3 -c '
import json, sys
services = json.load(sys.stdin)["services"]
assert services["rho"]["environment"]["RHO_TELEGRAM_BOT_TOKEN"] == "synthetic-telegram-token"
assert all("RHO_TELEGRAM_BOT_TOKEN" not in row.get("environment", {}) for name, row in services.items() if name != "rho")
'
    for telegram_token in '' synthetic-telegram-token; do
      RHO_TELEGRAM_BOT_TOKEN="$telegram_token" "$real_docker" compose --env-file /dev/null \
        -f "$here/../docker/compose.yml" --profile full config --format json | python3 -c '
import json, sys
services = json.load(sys.stdin)["services"]
assert services["rho-full"]["environment"]["RHO_TELEGRAM_BOT_TOKEN"] == sys.argv[1]
assert all("RHO_TELEGRAM_BOT_TOKEN" not in row.get("environment", {}) for name, row in services.items() if name != "rho-full")
' "$telegram_token"
    done
  )
  check 'optional Telegram token reaches only rho in both Compose templates'
  check 'real Docker Compose parses the generated bind-mount stack without starting services'
fi

printf '%s\n' 'All stack installer offline tests passed.'
