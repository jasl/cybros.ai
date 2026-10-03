#!/bin/bash
# Stage the real package trees without downloading a runtime or gems. This
# catches a plugin or its static files being left out of the portable install.
# shellcheck disable=SC1091
. "$(dirname "$0")/helpers.sh"

export RHO_PREFIX="$TEST_TMP/prefix" RHO_HOME="$TEST_TMP/home" RHO_LAUNCHER_DIR="$TEST_TMP/bin" NONINTERACTIVE=1
set -- --from-checkout "$REPO_ROOT"
# shellcheck disable=SC1090,SC1091
. "$INSTALLER"

stage_app > "$TEST_TMP/stage.out" 2>&1 || fail "stage_app failed: $(cat "$TEST_TMP/stage.out")"

for path in \
  cmctl/cmctl.gemspec \
  cmctl/lib/cybros_control.rb \
  cmctl/exe/cmctl \
  agents/rho/rho-web-tools/rho-web-tools.gemspec \
  agents/rho/rho-web-tools/lib/rho/web-tools.rb \
  agents/rho/rho-ingress-telegram/rho-ingress-telegram.gemspec \
  agents/rho/rho-ingress-telegram/lib/rho/ingress-telegram.rb \
  agents/rho/rho-ingress-telegram/lib/rho/ingress-telegram/client.rb \
  agents/rho/rho-ingress-telegram/lib/rho/ingress-telegram/render.rb \
  agents/rho/rho-ingress-telegram/lib/rho/ingress-telegram/rate_limit.rb \
  agents/rho/rho-webui/rho-webui.gemspec \
  agents/rho/rho-webui/lib/rho/webui.rb \
  agents/rho/rho-webui/webui/index.html \
  agents/rho/rho-webui/webui/console.js \
  agents/rho/rho-webui/webui/api.js \
  agents/rho/rho-webui/webui/views.js \
  agents/rho/rho-webui/webui/console.css; do
  cmp "$SOURCE/$path" "$STAGING/$path" || fail "the staged package lost or changed $path"
done
[ ! -e "$STAGING/agents/rho/rho-web" ] || fail "the retired rho-web package was staged"
[ ! -e "$STAGING/agents/rho/rho/webui" ] || fail "the rho gem still carries the page"
pass "cmctl, the web tools, Telegram ingress and independent WebUI ship with their runtime files unchanged"

assert_eq "$(cat "$STAGING/.ruby")" "$RUBY_VERSION" "the staged Ruby pair"
assert_eq "$(cat "$STAGING/.commit")" "$APP_COMMIT" "the staged checkout commit"
pass "staging records the runtime pair and checkout"
