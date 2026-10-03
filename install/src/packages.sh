# ---------------------------------------------------------------------------
# Step: the portable Ruby (Homebrew's vendor-install, re-cut for the prefix).
scrub_ruby_env() {
  local name
  unset RUBYOPT RUBYLIB GEM_HOME GEM_PATH BUNDLER_VERSION BUNDLE_BIN_PATH BUNDLER_SETUP RBENV_VERSION
  # shellcheck disable=SC2046
  for name in $(compgen -v BUNDLE_ 2>/dev/null); do unset "$name"; done
}

install_ruby() {
  if [ -x "$RUBY_DIR/bin/ruby" ] && "$RUBY_DIR/bin/ruby" --version >/dev/null 2>&1; then
    ohai "Portable Ruby $RUBY_VERSION is already installed"
    return 0
  fi
  fetch_artifact "$RUBY_URL" "$RUBY_SHA" "$RUBY_FILENAME" "$RHO_RUBY_HEADER"
  ohai "Unpacking $RUBY_FILENAME"
  rm -rf "$PREFIX/ruby/.staging" "$RUBY_DIR"
  mkdir -p "$PREFIX/ruby/.staging"
  execute tar -xzf "$DOWNLOADS/$RUBY_FILENAME" -C "$PREFIX/ruby/.staging"
  [ -d "$PREFIX/ruby/.staging/portable-ruby/$RUBY_VERSION" ] || abort "rho install: the bottle did not unpack as portable-ruby/$RUBY_VERSION"
  trap '' INT
  execute mv "$PREFIX/ruby/.staging/portable-ruby/$RUBY_VERSION" "$RUBY_DIR"
  trap - INT
  rm -rf "$PREFIX/ruby/.staging"
  ohai "$RUBY_DIR/bin/ruby" --version
  "$RUBY_DIR/bin/ruby" --version || { rm -rf "$RUBY_DIR"; abort "rho install: the portable Ruby does not run on this machine"; }
}

# The lock's bundler, into the portable Ruby, always (`bundle install`
# would otherwise fetch a different version from the lock silently and
# `-rbundler/setup` would run on the wrong one without a word).
install_bundler() {
  (
    scrub_ruby_env
    if "$RUBY_DIR/bin/gem" list -i -e bundler -v "$RHO_RUBY_BUNDLER" >/dev/null 2>&1; then
      ohai "bundler $RHO_RUBY_BUNDLER is already in the portable Ruby"
      exit 0
    fi
    # --force: the bottle's bin/bundle is the default gem's own binstub, and
    # RubyGems refuses to overwrite one it did not write without it.
    run "$RUBY_DIR/bin/gem" install bundler -v "$RHO_RUBY_BUNDLER" --no-document --force
  ) || exit 1
}

# ---------------------------------------------------------------------------
# Step: the gems. Stage the manifest's trees, bundle install --deployment into
# versions/<app>-r<ruby>, then activate (swap both links together).
stage_app() {
  STAGING="$PREFIX/versions/.staging.$$"
  rm -rf "$STAGING"
  mkdir -p "$STAGING"
  ohai "Copying the packaged trees from $SOURCE${APP_COMMIT:+ (commit ${APP_COMMIT:0:7})}"
  # shellcheck disable=SC2086
  ( cd "$SOURCE" && tar -cf - --exclude=.git --exclude=tmp --exclude=log --exclude=coverage --exclude=node_modules \
      --exclude=vendor/bundle --exclude=.bundle --exclude=pkg $RHO_APP_TREES ) | tar -xf - -C "$STAGING" \
    || abort "rho install: could not copy the checkout"
  [ -f "$STAGING/agents/rho/rho/Gemfile.lock" ] || abort "rho install: the source carries no agents/rho/rho/Gemfile.lock"
  printf "%s\n" "$RUBY_VERSION" > "$STAGING/.ruby"
  printf "%s\n" "$APP_COMMIT" > "$STAGING/.commit"
}

# A previous version built against the same Ruby seeds vendor/bundle:
# bundler then verifies instead of compiling.
seed_bundle() {
  local previous_dir="$PREFIX/current"
  [ -d "$previous_dir/vendor/bundle" ] || return 0
  [ "$(cat "$previous_dir/.ruby" 2>/dev/null)" = "$RUBY_VERSION" ] || return 0
  ohai "Seeding vendor/bundle from $(readlink "$previous_dir") (same Ruby)"
  mkdir -p "$STAGING/vendor"
  cp -R "$previous_dir/vendor/bundle" "$STAGING/vendor/bundle"
}

# THE PORTABLE RUBY'S OWN OPENSSL: the bottle links
# OpenSSL statically into bin/ruby, and bundler 4 fetches and builds every
# default gem the lock pins into vendor/bundle whenever a remote serves it
# (bundler/source/rubygems.rb `install`: a default gem is "Using" only
# when `cached_built_in_gem` may not fetch, i.e. under `local`) — a second
# openssl extension whose symbols bind to the static copy at load time, so
# TLS verification fails or the process segfaults. `--prefer-local` is
# bundler's own switch for exactly this: the Ruby's default specs take
# precedence over the remote index and every install runs `local`
# (bundler/installer.rb `local = options[:local] || options[:"prefer-local"]`),
# so a default gem at the lock's version is used from the Ruby, never
# fetched; a gem the Ruby lacks is fetched as before. Under the frozen
# lock it changes no resolution: the lock stays byte-for-byte.
bundle_app() {
  seed_bundle
  (
    scrub_ruby_env
    # shellcheck disable=SC2030
    export PATH="$RUBY_DIR/bin:$PATH"
    export BUNDLE_GEMFILE="$STAGING/$RHO_APP_GEMFILE"
    export BUNDLE_PATH="$STAGING/vendor/bundle"
    export BUNDLE_DEPLOYMENT=1
    export BUNDLE_WITHOUT="$RHO_APP_BUNDLE_WITHOUT"
    export BUNDLE_JOBS=4
    if [ -z "${LC_ALL:-}${LC_CTYPE:-}${LANG:-}" ]; then export LANG=C.UTF-8; fi
    cd "$STAGING/agents/rho/rho" || exit 1
    run "$RUBY_DIR/bin/bundle" install --prefer-local
  ) || abort "rho install: bundle install failed (a missing compiler or header is the usual cause: $(prerequisite_line))"
}

# Activate: versions/<name> in place, `current` and `ruby/current` swapped
# together (the pair), the old pair recorded as previous.
activate_app() {
  local old_current
  old_current="$RHO_RECEIPT_CURRENT"
  trap '' INT
  if [ -d "$VERSION_DIR" ]; then
    if [ "$old_current" = "$VERSION_NAME" ]; then
      rm -rf "$VERSION_DIR.old"
      execute mv "$VERSION_DIR" "$VERSION_DIR.old"
      old_current="$VERSION_NAME.old"
    else
      rm -rf "$VERSION_DIR"
    fi
  fi
  execute mv "$STAGING" "$VERSION_DIR"
  STAGING=""
  swap_link "versions/$VERSION_NAME" "$PREFIX/current"
  swap_link "$RUBY_VERSION" "$PREFIX/ruby/current"
  trap - INT
  if [ -n "$old_current" ] && [ "$old_current" != "$VERSION_NAME" ] && [ -d "$PREFIX/versions/$old_current" ]; then
    PREVIOUS="$old_current"
  else
    PREVIOUS=""
  fi
  # Only current and previous stay (rollback is one step deep).
  local entry name
  for entry in "$PREFIX"/versions/*; do
    [ -d "$entry" ] || continue
    name=$(basename "$entry")
    case "$name" in
      "$VERSION_NAME"|"$PREVIOUS"|.staging.*) ;;
      *) rm -rf "$entry" ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Step: the tool rows. Each is skipped when the receipt's sha equals the
# manifest's and the file is there (content-addressed, idempotent).
RECEIPT_TOOLS_JSON=""
RECEIPT_TOOLS_SH=""
record_tool() {
  # record_tool KEY NAME VERSION SHA
  RECEIPT_TOOLS_JSON="$RECEIPT_TOOLS_JSON${RECEIPT_TOOLS_JSON:+, }\"$2\": {\"version\": \"$3\", \"sha256\": \"$4\"}"
  RECEIPT_TOOLS_SH="$RECEIPT_TOOLS_SH
RHO_RECEIPT_TOOL_${1}_VERSION=\"$3\"
RHO_RECEIPT_TOOL_${1}_SHA256=\"$4\""
  RECORDED_TOOLS="${RECORDED_TOOLS:-}$1 "
}

tool_present() {
  local tool="$1" into member
  into="$PREFIX/$(tool_field "$tool" INTO)"
  case "$(tool_field "$tool" UNPACK)" in
    members|binary)
      for member in $(tool_artifact "$tool" MEMBERS); do
        [ -x "$into/$(basename "$member")" ] || return 1
      done
      return 0 ;;
    tree) [ -d "$into" ] && [ -n "$(ls -A "$into" 2>/dev/null)" ] ;;
    command) ls -d "$into"/chromium* >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

install_tool() {
  local tool="$1" name version sha url into filename unpack member recorded
  name=$(tool_field "$tool" NAME); version=$(tool_field "$tool" VERSION)
  sha=$(tool_artifact "$tool" SHA256); url=$(tool_artifact "$tool" URL)
  into="$PREFIX/$(tool_field "$tool" INTO)"; unpack=$(tool_field "$tool" UNPACK)
  recorded=$(lookup "RHO_RECEIPT_TOOL_${tool}_SHA256")
  if tool_present "$tool" && [ "$recorded" = "$sha" ]; then
    ohai "$name $version is already installed"
    record_tool "$tool" "$name" "$version" "$sha"
    return 0
  fi
  case "$unpack" in
    members|tree)
      filename=$(basename "$url")
      fetch_artifact "$url" "$sha" "$filename"
      mkdir -p "$into"
      if [ "$unpack" = "members" ]; then
        ohai "Unpacking $name $version into $into"
        rm -rf "$PREFIX/.unpack"
        mkdir -p "$PREFIX/.unpack"
        # shellcheck disable=SC2046
        execute tar -xzf "$DOWNLOADS/$filename" -C "$PREFIX/.unpack" $(tool_artifact "$tool" MEMBERS)
        for member in $(tool_artifact "$tool" MEMBERS); do
          execute mv -f "$PREFIX/.unpack/$member" "$into/$(basename "$member")"
          chmod 755 "$into/$(basename "$member")"
        done
        rm -rf "$PREFIX/.unpack"
      else
        ohai "Unpacking $name $version into $into"
        rm -rf "$into.staging"
        mkdir -p "$into.staging"
        case "$filename" in
          *.tar.xz) execute tar -xJf "$DOWNLOADS/$filename" --strip-components=1 -C "$into.staging" ;;
          *) execute tar -xzf "$DOWNLOADS/$filename" --strip-components=1 -C "$into.staging" ;;
        esac
        rm -rf "$into"
        execute mv "$into.staging" "$into"
        [ "$tool" = "playwright_core" ] && write_playwright_wrapper
      fi ;;
    binary)
      filename=$(basename "$url")
      fetch_artifact "$url" "$sha" "$filename"
      mkdir -p "$into"
      for member in $(tool_artifact "$tool" MEMBERS); do
        ohai "Installing $name $version as $into/$member"
        execute cp -f "$DOWNLOADS/$filename" "$into/$member"
        chmod 755 "$into/$member"
      done ;;
    command)
      # The Chromium shell: playwright-core downloads it (HTTPS-only; it
      # verifies no hash — the one row the manifest cannot pin).
      local command
      command=$(tool_field "$tool" COMMAND)
      if [ -n "${RHO_BROWSER_FULL_CHROMIUM:-}" ]; then command="${command// --only-shell/}"; fi
      # shellcheck disable=SC2086
      run "$PREFIX/bin/rho-playwright" $command
      if [ "$OS" = "linux" ] && [ -z "$DRY_RUN" ]; then
        CHROMIUM_APT_LINE="sudo apt-get install -y $(chromium_apt_packages)"
      fi ;;
    *) abort "rho install: unknown unpack kind '$unpack' for $name" ;;
  esac
  record_tool "$tool" "$name" "$version" "$sha"
}

chromium_apt_packages() {
  local id version key
  id=$(sed -n 's/^ID=//p' /etc/os-release 2>/dev/null | tr -d '"')
  version=$(sed -n 's/^VERSION_ID=//p' /etc/os-release 2>/dev/null | tr -d '"')
  key="${id}${version}"
  key="${key//./_}"
  case " $RHO_APT_CHROMIUM_DISTROS " in
    *" $key "*) lookup "RHO_APT_CHROMIUM_${key}" ;;
    *) lookup "RHO_APT_CHROMIUM_ubuntu26_04" ;;
  esac
}
