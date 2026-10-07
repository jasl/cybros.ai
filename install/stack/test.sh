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
  *' exec -T rho /opt/rho/libexec/t3-setup '*|*' exec -T rho /opt/rho/libexec/docker-entrypoint t3 project '*|*' exec -T rho /opt/rho/libexec/docker-entrypoint t3 create '*)
    [ "${TEST_T3_SAVE_FAIL:-0}" = 0 ] || exit 1
    printf '%s\n' '{"saved":true,"applied":false,"published":false,"restart_required":true}'
    ;;
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
grep -q "CYBROS_IMAGE_TAG='1234567890'" "$install_dir/.env" || fail 'tag not captured'
grep -q "CYBROS_NEXUS_URL='http://home.local:3300'" "$install_dir/.env" || fail 'browser URL not captured'
[ "$(grep -c "='[a-f0-9]\{64\}'$" "$install_dir/secrets.env")" = 5 ] || fail 'secrets missing or malformed'
[ "$(cut -d= -f2 "$install_dir/secrets.env" | sort -u | wc -l | tr -d ' ')" = 6 ] || fail 'secrets are not independent'
python3 - "$install_dir/secrets.env" "$test_root/install.log" "$TEST_DOCKER_LOG" <<'PY'
from pathlib import Path
import sys
from urllib.parse import unquote

secrets = dict(
    (name, value.strip("'"))
    for line in Path(sys.argv[1]).read_text().splitlines() if line and not line.startswith("#")
    for name, value in [line.split("=", 1)]
)
output = Path(sys.argv[2]).read_text()
calls = Path(sys.argv[3]).read_text().splitlines()
assert "http://home.local:7777" in output, "missing public rho URL"
assert "NEXUS_SETUP_SECRET" not in secrets, "fresh installation generated a setup gate"
assert "Setup secret" not in output and "setup_secret=" not in output, "default instructions require a setup credential"
assert "Create your administrator account" in output, "missing first-account setup step"
assert "0.0.0.0:7777" not in output, "installer printed rho's internal bind address"
for value in secrets.values():
    assert value not in unquote(output), "deployment secret printed in default instructions"
    assert all(value not in call for call in calls), "secret passed in Docker arguments"
assert any(" up -d --wait " in call for call in calls), "services were not checked for health"
assert not any("--profile setup" in call or "rho console" in call for call in calls), "installer started a separate approval or browser credential ceremony"

PY
[ "$(find "$install_dir" -prune -perm 700 -print)" = "$install_dir" ] || fail 'directory mode'
[ "$(find "$install_dir/secrets.env" -perm 600 -print)" = "$install_dir/secrets.env" ] || fail 'secret mode'
check 'piped installation starts direct account setup without a setup secret or automatic connection approval'
if grep -q ' rho setup ' "$TEST_DOCKER_LOG"; then fail '--yes started an interactive wizard'; fi

cp "$install_dir/.env" "$test_root/env.before"
cp "$install_dir/secrets.env" "$test_root/secrets.before"
printf '\n# user customization\n' >> "$install_dir/compose.yaml"
CYBROS_IMAGE_TAG=999 sh "$here/install.sh" --yes > "$test_root/reinstall.log"
cmp "$test_root/env.before" "$install_dir/.env"
cmp "$test_root/secrets.before" "$install_dir/secrets.env"
grep -q 'user customization' "$install_dir/compose.yaml" || fail 'compose overwritten'
check 'reinstall preserves configuration, secrets and Compose edits'
"$install_dir/cybros" instructions > "$test_root/instructions.log"
grep -q 'http://home.local:7777' "$test_root/instructions.log" || fail 'instructions lost the saved public rho URL'
grep -q 'Create your administrator account' "$test_root/instructions.log" || fail 'instructions omitted first-account setup'
if grep -q 'Setup secret\|setup_secret=' "$test_root/instructions.log"; then fail 'default instructions prompted for a setup secret'; fi
cmp "$test_root/secrets.before" "$install_dir/secrets.env"
check 'instructions preserves the browser URLs and deployment secrets'

"$install_dir/cybros" status > /dev/null
"$install_dir/cybros" logs nexus > /dev/null
"$install_dir/cybros" connect > /dev/null
"$install_dir/cybros" rho models > /dev/null
printf '%s\n' 'synthetic-test-key' | "$install_dir/cybros" cmctl provider key set openai_api --stdin > /dev/null
[ "$(cat "$TEST_CMCTL_STDIN")" = synthetic-test-key ] || fail 'cmctl did not retain stdin'
grep -q 'exec -T -e CMCTL_HOME=/var/lib/rho/cmctl rho cmctl provider key set openai_api --stdin$' "$TEST_DOCKER_LOG" || fail 'cmctl missing persistent home'
"$install_dir/cybros" stop > /dev/null
grep -q ' stop$' "$TEST_DOCKER_LOG" || fail 'stop did not stop services'
grep -q 'exec -T rho rho connect$' "$TEST_DOCKER_LOG" || fail 'device login bypassed public CLI'
grep -q ' logs --tail 100 nexus$' "$TEST_DOCKER_LOG" || fail 'logs missing'
if grep -q 'down\|volume rm' "$TEST_DOCKER_LOG"; then fail 'destructive cleanup invoked'; fi
check 'management uses existing CLIs, preserves piped secrets and retains data'

: > "$TEST_DOCKER_LOG"
{
  "$install_dir/cybros" t3 local
  "$install_dir/cybros" t3 host http://host.docker.internal:3773
  "$install_dir/cybros" t3 project fixture-project
  "$install_dir/cybros" t3 create /home/runner
} > "$test_root/t3.log"
[ "$(grep -c ' restart rho$' "$TEST_DOCKER_LOG")" = 4 ] || fail 'saved T3 configuration did not restart rho'
grep -q '"saved":true,"applied":false' "$test_root/t3.log" || fail 'saved pending settings were reported as applied'
: > "$TEST_DOCKER_LOG"
if TEST_T3_SAVE_FAIL=1 "$install_dir/cybros" t3 project invalid > "$test_root/failure.log" 2>&1; then fail 'refused T3 project save was swallowed'; fi
if grep -q ' restart rho$' "$TEST_DOCKER_LOG"; then fail 'rho restarted after refused T3 configuration'; fi
"$install_dir/cybros" t3 status > /dev/null
if grep -q ' restart rho$' "$TEST_DOCKER_LOG"; then fail 'offline T3 status restarted rho'; fi
check 'T3 setup and project saves restart rho; refused saves and status preserve the running process'

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
mv "$install_dir/secrets.env" "$test_root/saved.secrets"
if sh "$here/install.sh" --yes > "$test_root/failure.log" 2>&1; then fail 'missing secrets regenerated'; fi
[ ! -e "$install_dir/secrets.env" ] || fail 'missing secrets regenerated'
check 'startup failures preserve state; missing existing secrets require restore'

: > "$TEST_DOCKER_LOG"
mkdir -p "$test_root/initialize only/data"
sh "$here/install.sh" --yes --dir "$test_root/initialize only" --no-start > "$test_root/no-start.log"
[ -f "$test_root/initialize only/secrets.env" ] || fail 'init did not create secrets'
if grep -q ' pull\| up -d' "$TEST_DOCKER_LOG"; then fail 'init pulled or started services'; fi
if grep -q ' rho console' "$TEST_DOCKER_LOG"; then fail 'init tried to mint a console link before services started'; fi
grep -q 'rho: http://home.local:7777' "$test_root/no-start.log" || fail 'init omitted plain rho URL'
grep -q './cybros instructions' "$test_root/no-start.log" || fail 'init omitted next browser step'
check 'init-only makes configuration without pulling or starting services'

sh "$here/install.sh" --yes --dir "$test_root/optional setup secret" --no-start > /dev/null
printf "NEXUS_SETUP_SECRET='synthetic+operator&setup=secret #片段'\n" >> "$test_root/optional setup secret/secrets.env"
"$test_root/optional setup secret/cybros" instructions > "$test_root/optional-secret.log"
python3 - "$test_root/optional-secret.log" <<'PY'
from pathlib import Path
import re
import sys
from urllib.parse import parse_qs, urlsplit

output = Path(sys.argv[1]).read_text()
secret = "synthetic+operator&setup=secret #片段"
assert "Setup secret: " + secret in output, "explicit setup secret omitted"
link = re.search(r"Private setup link: (\S+)", output)
assert link, "explicit private setup link omitted"
url = urlsplit(link.group(1))
assert url.scheme == "http" and url.netloc == "home.local:3300" and url.path == "/setup"
assert not url.query, "setup secret was sent in the query"
assert parse_qs(url.fragment) == {"setup_secret": [secret]}, "private link changed the configured secret"
PY
check 'an explicitly configured setup secret retains its private operator instructions'

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
    unset CYBROS_IMAGE_NAMESPACE CYBROS_IMAGE_TAG CYBROS_BIND CYBROS_NEXUS_URL CYBROS_RHO_URL RHO_TELEGRAM_BOT_TOKEN NEXUS_SETUP_SECRET
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
    "$real_docker" compose --env-file .env --env-file secrets.env config --format json | python3 -c '
import json, sys
services = json.load(sys.stdin)["services"]
assert len(services) == 7
assert "setup" not in services
rho = services["rho"]
assert rho["environment"]["RHO_PUBLIC_URL"] == "http://home.local:7777"
assert rho["environment"]["RHO_NEXUS_PUBLIC_URL"] == "http://home.local:3300"
assert rho["environment"]["RHO_NEXUS_URL"] == "http://nexus"
assert "RHO_INSTALLATION_FILE" not in rho["environment"]
assert "RHO_ACCESS_PASSPHRASE" not in rho["environment"]
assert "NEXUS_SETUP_SECRET" not in rho["environment"]
nexus = services["nexus"]["environment"]
assert nexus["NEXUS_SETUP_SECRET"] == ""
assert json.loads(nexus["NEXUS_OAUTH_REDIRECT_URIS"]) == ["http://home.local:7777/auth/callback"]
assert nexus["NEXUS_OAUTH_ALLOW_HTTP"] == "true"
assert all(mount["target"] != "/var/run/docker.sock" for row in services.values() for mount in row.get("volumes", []))
'
    printf "NEXUS_SETUP_SECRET='synthetic-operator-setup-secret'\n" >> secrets.env
    NEXUS_SETUP_SECRET=synthetic-other-deployment PATH="$(dirname -- "$real_docker"):$PATH" \
      ./cybros compose config --format json | python3 -c '
import json, sys
services = json.load(sys.stdin)["services"]
assert services["nexus"]["environment"]["NEXUS_SETUP_SECRET"] == "synthetic-operator-setup-secret"
assert "NEXUS_SETUP_SECRET" not in services["rho"]["environment"]
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
