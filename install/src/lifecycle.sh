# ---------------------------------------------------------------------------
# The daemon, for --restart and --uninstall: the announcement's pid.
announced_pid() {
  local file="$HOME_DIR/tmp/announcement.json"
  [ -f "$file" ] || return 1
  sed -n 's/.*"pid": *\([0-9][0-9]*\).*/\1/p' "$file" | head -n1
}
daemon_alive() {
  local pid
  pid=$(announced_pid) || return 1
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}
# `rho server` is a foreground process with no supervisor of rho's: the
# only definable restart is stop + print the start line.
stop_daemon() {
  local pid waited=0
  pid=$(announced_pid) || { ohai "No daemon announced under $HOME_DIR; nothing to stop"; return 0; }
  if ! kill -0 "$pid" 2>/dev/null; then
    ohai "The announced daemon (pid $pid) is not running"
    return 0
  fi
  ohai "Stopping the daemon (pid $pid, TERM)"
  kill -TERM "$pid" 2>/dev/null || true
  while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 30 ]; do
    sleep 1
    waited=$((waited + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    warn "the daemon (pid $pid) is still stopping after 30 s (a stop Nexus could not confirm is retried); start it again when it is gone"
  fi
  printf "\nStart it again with:\n  rho server\n"
}

# Tool rows carried over from the receipt untouched (rollback).
carry_tools() {
  local tool
  for tool in $RHO_RECEIPT_TOOLS; do
    record_tool "$tool" "$(tool_field "$tool" NAME)" "$(lookup "RHO_RECEIPT_TOOL_${tool}_VERSION")" "$(lookup "RHO_RECEIPT_TOOL_${tool}_SHA256")"
  done
}

# ---------------------------------------------------------------------------
# The modes.
# `rho update` with nothing new pulled: the receipt's commit is the
# checkout's and the pair is in place — nothing to rebuild. A direct run of
# the installer always restages (a developer's edited tree, an unpacked
# tree with no commit).
app_installed() {
  [ "$MODE" = "apply-update" ] || return 1
  [ -n "$APP_COMMIT" ] && [ "$RHO_RECEIPT_APP_COMMIT" = "$APP_COMMIT" ] || return 1
  [ "$RHO_RECEIPT_CURRENT" = "$VERSION_NAME" ] || return 1
  [ -d "$VERSION_DIR" ] && [ -L "$PREFIX/current" ] || return 1
  return 0
}

install_flow() {
  local tool
  check_prerequisites
  plan
  if [ -n "$DRY_RUN" ]; then
    printf "\n(dry run: nothing was changed)\n"
    exit 0
  fi
  [ -z "${NONINTERACTIVE-}" ] && wait_for_user
  lock_prefix
  mkdir -p "$PREFIX/bin" "$PREFIX/ruby" "$PREFIX/versions" "$PREFIX/libexec" "$PREFIX/cache"
  chmod 755 "$PREFIX"
  install_ruby
  install_bundler
  if [ "$MODE" = "add-rows" ] || app_installed; then
    ohai "rho $APP_VERSION ($VERSION_NAME${APP_COMMIT:+, commit ${APP_COMMIT:0:7}}) is already installed"
    PREVIOUS="$RHO_RECEIPT_PREVIOUS"
    [ -L "$PREFIX/ruby/current" ] || swap_link "$RUBY_VERSION" "$PREFIX/ruby/current"
  else
    stage_app
    bundle_app
    activate_app
  fi
  for tool in $(profile_tools); do
    install_tool "$tool"
  done
  write_wrapper rho "$RHO_APP_ENTRY"
  write_wrapper cmctl cmctl/exe/cmctl
  write_python_shim
  link_launcher
  offer_path_line
  write_receipts
  prewarm
  run_doctor
  [ -n "$RESTART" ] && stop_daemon
  epilogue
}

# The markers git leaves while a merge, rebase, cherry-pick, revert or
# bisect is unfinished (pi-web's dev_git_operation list); prints the first.
git_operation_in_progress() {
  local marker path
  for marker in MERGE_HEAD rebase-merge rebase-apply CHERRY_PICK_HEAD REVERT_HEAD sequencer BISECT_LOG; do
    path=$(git -C "$1" rev-parse --git-path "$marker" 2>/dev/null) || continue
    case "$path" in /*) ;; *) path="$1/$path" ;; esac
    if [ -e "$path" ]; then printf "%s" "$marker"; return 0; fi
  done
  return 1
}

# `rho update`: the checkout this install came from is pulled (fast-forward
# only, never a branch switch), then ITS install/install.sh runs in
# apply-update mode — the pulled script is the new truth. Two prints come
# first, the commit range and the script path, and `--dry-run` stops after
# them (a fetch stands in for the pull, so the tree is untouched).
update_mode() {
  [ -f "$RECEIPT_SH" ] || abort "rho install: nothing is installed at $PREFIX (no receipt)."
  if in_container; then
    abort "rho update: inside a container the image rolls, not the prefix:" "  docker compose pull && docker compose up -d" "(\`rho update --add-rows\` adds a profile's tool rows in place)."
  fi
  local source old new marker script verb
  source="$RHO_RECEIPT_SOURCE_PATH"
  if [ ! -f "$source/agents/rho/rho/rho.gemspec" ] || [ -z "$(checkout_commit "$source")" ]; then
    abort "rho update: this rho was installed from $source, which is gone or is not a git checkout; re-install from a clone:" \
      "  git clone https://github.com/jasl/cybros-ai.git && bash cybros-ai/install/install.sh --profile $PROFILE"
  fi
  if marker=$(git_operation_in_progress "$source"); then
    abort "rho update: a git operation is in progress in $source ($marker); finish or abort it, then re-run."
  fi
  old=$(git -C "$source" rev-parse HEAD)
  if [ -n "$DRY_RUN" ]; then
    ohai git -C "$source" fetch
    GIT_TERMINAL_PROMPT=0 git -C "$source" fetch || abort "rho update: git fetch failed in $source (git's line above)."
    new=$(git -C "$source" rev-parse '@{u}' 2>/dev/null) || abort "rho update: the branch checked out in $source tracks no upstream; \`git branch --set-upstream-to\` it, or pull by hand."
  else
    ohai git -C "$source" pull --ff-only
    GIT_TERMINAL_PROMPT=0 git -C "$source" pull --ff-only || abort "rho update: git pull --ff-only failed in $source (git's line above; a diverged or conflicting tree is yours to reconcile)."
    new=$(git -C "$source" rev-parse HEAD)
  fi
  if [ "$old" = "$new" ]; then
    ohai "Nothing new: $source is at ${new:0:7}"
  else
    verb="Pulled"; [ -n "$DRY_RUN" ] && verb="Would pull"
    ohai "$verb ${old:0:7}..${new:0:7}:"
    git -C "$source" log --oneline "$old..$new"
  fi
  script="$source/install/install.sh"
  [ -f "$script" ] || abort "rho update: $script is missing from the checkout."
  set -- --apply-update --from-checkout "$source" --profile "$PROFILE" --non-interactive
  [ -n "$RESTART" ] && set -- "$@" --restart
  [ -n "$MODIFY_PATH" ] && set -- "$@" --modify-path
  if [ -n "$DRY_RUN" ]; then
    ohai "Would run: /bin/bash $script $*"
    printf "\n(dry run: nothing was changed; the checkout was fetched, not pulled)\n"
    exit 0
  fi
  ohai "Running: /bin/bash $script $*"
  RHO_PREFIX="$PREFIX" exec /bin/bash "$script" "$@"
}
rollback_mode() {
  local previous ruby old_current
  previous="$RHO_RECEIPT_PREVIOUS"
  [[ -n "$previous" && -d "$PREFIX/versions/$previous" ]] || abort "rho update --rollback: nothing to roll back to (the receipt names no previous version)."
  ruby=$(cat "$PREFIX/versions/$previous/.ruby" 2>/dev/null)
  [[ -n "$ruby" && -x "$PREFIX/ruby/$ruby/bin/ruby" ]] || abort "rho update --rollback: $previous was built against Ruby '$ruby', which is gone."
  ohai "Rolling back: current $RHO_RECEIPT_CURRENT -> $previous (ruby $ruby)"
  [ -n "$DRY_RUN" ] && exit 0
  lock_prefix
  old_current="$RHO_RECEIPT_CURRENT"
  trap '' INT
  swap_link "versions/$previous" "$PREFIX/current"
  swap_link "$ruby" "$PREFIX/ruby/current"
  trap - INT
  VERSION_NAME="$previous"
  PREVIOUS="$old_current"
  RUBY_VERSION="$ruby"
  RUBY_SHA=""
  APP_VERSION="${previous%%-*}"
  APP_COMMIT=$(cat "$PREFIX/versions/$previous/.commit")
  APP_SOURCE_PATH="$RHO_RECEIPT_SOURCE_PATH"
  carry_tools
  write_receipts
  prewarm
  [ -n "$RESTART" ] && stop_daemon
  printf "\nRolled back to %s. Restart the daemon (rho server) to run it.\n" "$previous"
}

uninstall_mode() {
  local cmctl_launcher
  [ -d "$PREFIX" ] || abort "rho uninstall: nothing at $PREFIX."
  if daemon_alive && [ -z "$FORCE" ]; then
    abort "rho uninstall: a daemon is running (pid $(announced_pid)); stop it first (kill -TERM $(announced_pid)), or pass --force."
  fi
  printf "%sThis will remove:%s\n  %s\n" "$tty_bold" "$tty_reset" "$PREFIX"
  [ -L "$RHO_RECEIPT_LAUNCHER" ] && printf "  %s (the launcher)\n" "$RHO_RECEIPT_LAUNCHER"
  [ -n "$RHO_RECEIPT_RC_FILE" ] && printf "  the line '%s' from %s\n" "$RHO_RECEIPT_RC_LINE" "$RHO_RECEIPT_RC_FILE"
  if [ -n "$PURGE" ]; then
    printf "  %s (RHO_HOME: credentials, the instance, logs — after disconnecting from Nexus)\n" "$HOME_DIR"
  else
    printf "  (RHO_HOME %s is kept; --purge removes it)\n" "$HOME_DIR"
  fi
  [ -n "$DRY_RUN" ] && exit 0
  [ -z "${NONINTERACTIVE-}" ] && wait_for_user
  if [ -n "$PURGE" ] && [ -f "$HOME_DIR/nexus.json" ] && [ -x "$PREFIX/bin/rho" ]; then
    ohai "Disconnecting from Nexus first (a deleted home without a disconnect leaves a live row only an operator can revoke)"
    "$PREFIX/bin/rho" disconnect || warn "disconnect did not succeed; the row on Nexus may need an operator's revoke"
  fi
  if [ -L "$RHO_RECEIPT_LAUNCHER" ]; then
    case "$(readlink "$RHO_RECEIPT_LAUNCHER")" in
      "$PREFIX"/*) ohai "Removing $RHO_RECEIPT_LAUNCHER"; rm -f "$RHO_RECEIPT_LAUNCHER" ;;
      *) warn "$RHO_RECEIPT_LAUNCHER points elsewhere; left alone" ;;
    esac
  fi
  cmctl_launcher="$(dirname "$RHO_RECEIPT_LAUNCHER")/cmctl"
  if [ -L "$cmctl_launcher" ]; then
    case "$(readlink "$cmctl_launcher")" in
      "$PREFIX"/*) ohai "Removing $cmctl_launcher"; rm -f "$cmctl_launcher" ;;
      *) warn "$cmctl_launcher points elsewhere; left alone" ;;
    esac
  fi
  if [ -n "$RHO_RECEIPT_RC_FILE" ] && [ -f "$RHO_RECEIPT_RC_FILE" ] && grep -qxF "$RHO_RECEIPT_RC_LINE" "$RHO_RECEIPT_RC_FILE"; then
    ohai "Removing the PATH line from $RHO_RECEIPT_RC_FILE"
    grep -vxF "$RHO_RECEIPT_RC_LINE" "$RHO_RECEIPT_RC_FILE" > "$RHO_RECEIPT_RC_FILE.rho-uninstall" && mv -f "$RHO_RECEIPT_RC_FILE.rho-uninstall" "$RHO_RECEIPT_RC_FILE"
  fi
  ohai "Removing $PREFIX"
  rm -rf "$PREFIX"
  if [ -n "$PURGE" ]; then
    ohai "Removing $HOME_DIR"
    rm -rf "$HOME_DIR"
  else
    printf "\nKept: %s (RHO_HOME). Remove it yourself, or re-run with --purge.\n" "$HOME_DIR"
  fi
  case "$DOWNLOADS" in
    "$PREFIX"/*) ;;
    *) printf "Kept: %s (the download cache).\n" "$DOWNLOADS" ;;
  esac
  printf "rho is uninstalled.\n"
}

# ---------------------------------------------------------------------------
main() {
  [ -n "$DRY_RUN" ] && [ "$MODE" != "install" ] && [ "$MODE" != "apply-update" ] && [ "$MODE" != "add-rows" ] && NONINTERACTIVE=1
  case "$MODE" in
    install|apply-update|add-rows)
      if [ "$MODE" = "add-rows" ]; then
        [ -f "$RECEIPT_SH" ] || abort "rho install --add-rows: nothing is installed at $PREFIX."
        VERSION_NAME="$RHO_RECEIPT_CURRENT"; VERSION_DIR="$PREFIX/versions/$VERSION_NAME"
        APP_VERSION="$RHO_RECEIPT_APP_VERSION"; APP_COMMIT="$RHO_RECEIPT_APP_COMMIT"; APP_SOURCE_PATH="$RHO_RECEIPT_SOURCE_PATH"
        RUBY_VERSION="$RHO_RECEIPT_RUBY_VERSION"; RUBY_DIR="$PREFIX/ruby/$RUBY_VERSION"
        NONINTERACTIVE=1
      fi
      if [ "$MODE" = "apply-update" ]; then
        [ -f "$RECEIPT_SH" ] || abort "rho update: nothing is installed at $PREFIX."
        NONINTERACTIVE=1
      fi
      install_flow ;;
    update) update_mode ;;
    rollback) rollback_mode ;;
    uninstall) uninstall_mode ;;
  esac
}

# Sourced (the shell tests load the functions): nothing runs.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main
fi
