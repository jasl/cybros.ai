# Appended to the embedded templates by render.sh. Questions use /dev/tty,
# leaving stdin available for a piped installer.
install_fail() { printf 'Installer: %s\n' "$*" >&2; exit 1; }
install_cancel() { printf '\nInstallation cancelled. No files were changed.\n' >&2; exit 1; }

install_prompt() {
  printf '%s' "$1" >&3
  IFS= read -r answer <&3 || install_cancel
  [ -n "$answer" ] || answer=$2
}

install_port_valid() {
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  [ "${#1}" -le 5 ] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

install_port() {
  while :; do
    install_prompt "$1 port [$2]: " "$2"
    if install_port_valid "$answer"; then
      # Decimal output avoids leading-zero interpretations in other tools.
      answer=$(printf '%s' "$answer" | sed 's/^0*//')
      return
    fi
    printf 'Enter a port from 1 to 65535.\n' >&3
  done
}

install_hostname() {
  while :; do
    install_prompt 'Server hostname or IPv4 address: ' ''
    case "$answer" in
      ''|*[!a-zA-Z0-9.-]*|[.-]*|*[.-]|0.0.0.0) printf 'Enter a hostname or IPv4 address, without a scheme, port or path.\n' >&3 ;;
      *) server_host=$answer; return ;;
    esac
  done
}

install_directory() {
  case "$install_dir" in
    '~') install_dir=$HOME ;;
    \~/*) install_dir=$HOME/${install_dir#\~/} ;;
    /*) ;;
    *) install_dir=$PWD/$install_dir ;;
  esac
  [ ! -e "$install_dir" ] || [ -d "$install_dir" ] || install_fail 'The installation path exists and is not a directory.'
  if [ -d "$install_dir" ]; then install_dir=$(CDPATH='' cd -- "$install_dir" && pwd); fi
  case "$install_dir" in '/'|*'
'*) install_fail 'Choose an installation directory other than /, on a single line.' ;; esac
}

install_prerequisites() {
  if ! command -v docker >/dev/null 2>&1; then
    case "$(uname -s)" in
      Darwin) printf '%s\n' 'Install Docker Desktop for Mac, open it, then run this installer again.' 'https://docs.docker.com/desktop/setup/install/mac-install/' >&2 ;;
      Linux) printf '%s\n' 'Install Docker Engine and the Docker Compose plugin for your Linux distribution, then run this installer again.' 'https://docs.docker.com/engine/install/' >&2 ;;
      *) printf '%s\n' 'Install Docker with Compose v2, then run this installer again.' 'https://docs.docker.com/get-started/get-docker/' >&2 ;;
    esac
    install_fail 'Docker was not found. This installer does not install Docker or run sudo.'
  fi
  docker compose version >/dev/null 2>&1 || install_fail 'Docker Compose v2 is missing. Install the Compose plugin (https://docs.docker.com/compose/install/) or update Docker Desktop, then retry.'
  docker info >/dev/null 2>&1 || install_fail 'Docker is not ready. Start Docker Desktop or Docker Engine, check your Docker context and permissions with docker info, then retry.'
  docker compose up --help | grep -q -- --wait-timeout || install_fail 'Update Docker Compose or Docker Desktop: compose up --wait-timeout is required.'
}

install_main() {
  set -eu
  umask 077
  install_dir=${CYBROS_INSTALL_DIR:-"$HOME/.local/share/cybros"}
  directory_set=${CYBROS_INSTALL_DIR:+yes}
  action=install
  unattended=no
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --help|-h)
        printf '%s\n' 'Usage: sh install.sh [--dir DIRECTORY] [--no-start] [--yes]' 'Interactive setup uses /dev/tty, including when the script is piped to sh.' '--yes uses environment settings and defaults without questions.' '--no-start prepares configuration without pulling images or starting services.' 'Default directory: ~/.local/share/cybros. Requires Docker with Compose v2.'
        return 0
        ;;
      --dir) [ "$#" -ge 2 ] && [ -n "$2" ] || install_fail '--dir requires one nonempty directory'; install_dir=$2; directory_set=yes; shift 2 ;;
      --no-start) action=init; shift ;;
      --yes) unattended=yes; shift ;;
      *) install_fail 'Usage: sh install.sh [--dir DIRECTORY] [--no-start] [--yes]' ;;
    esac
  done

  printf '\nCybros setup\n\n[1/5] Checking Docker\n'
  install_prerequisites
  printf '\n[2/5] Installation directory\n'
  install_directory
  if [ ! -e "$install_dir/.env" ] && [ ! -e "$install_dir/secrets.env" ] && [ "$unattended" = no ]; then
    # Test in a subshell first: a failed special-builtin redirection can exit sh.
    (exec 3<>/dev/tty) 2>/dev/null || install_fail 'Interactive setup needs a terminal. Run with --yes to use environment settings and defaults.'
    exec 3<>/dev/tty
    trap 'install_cancel' HUP INT TERM
    if [ -z "$directory_set" ]; then
      install_prompt "Installation directory [$install_dir]: " "$install_dir"
      install_dir=$answer
      install_directory
    fi
  fi
  printf 'Directory: %s\n' "$install_dir"

  if [ -e "$install_dir/.env" ] || [ -e "$install_dir/secrets.env" ]; then
    printf '\n[3/5] Keeping existing configuration\n'
    printf '%s\n' 'Existing configuration, secrets and data will be preserved. Setup questions are skipped.'
  else
    printf '\n[3/5] Network access\n'
    server_host=localhost
    if [ "$unattended" = no ]; then
      if [ -n "${CYBROS_BIND:-}${CYBROS_NEXUS_URL:-}${CYBROS_RHO_URL:-}" ]; then
        printf '%s\n' 'Using the network settings supplied in the environment.'
        if [ -z "${CYBROS_NEXUS_URL:-}" ] || [ -z "${CYBROS_RHO_URL:-}" ]; then
          case "${CYBROS_BIND:-127.0.0.1}:${CYBROS_NEXUS_URL:-}${CYBROS_RHO_URL:-}" in
            127.0.0.1:) ;;
            *) printf '%s\n' 'Choose the browser hostname for any URL not supplied above.'; install_hostname ;;
          esac
        fi
      else
        printf '%s\n' '1) This computer only (default)' '2) Home server or LAN'
        while :; do
          install_prompt 'Access [1]: ' 1
          case "$answer" in 1|2) break ;; *) printf 'Choose 1 or 2.\n' >&3 ;; esac
        done
        if [ "$answer" = 2 ]; then
          install_hostname
          CYBROS_BIND=0.0.0.0
          printf '%s\n' 'Both services will listen on all interfaces. Use these HTTP addresses on your trusted LAN.'
        fi
      fi
      if [ -z "${CYBROS_NEXUS_PORT:-}" ]; then
        install_port Nexus 3300
        CYBROS_NEXUS_PORT=$answer
      fi
      if [ -z "${CYBROS_RHO_PORT:-}" ]; then
        while :; do
          install_port rho 7777
          [ "$answer" != "$CYBROS_NEXUS_PORT" ] && break
          printf 'Use a different port from Nexus.\n' >&3
        done
        CYBROS_RHO_PORT=$answer
      fi
    fi
    CYBROS_BIND=${CYBROS_BIND:-127.0.0.1}
    CYBROS_NEXUS_PORT=${CYBROS_NEXUS_PORT:-3300}
    CYBROS_RHO_PORT=${CYBROS_RHO_PORT:-7777}
    install_port_valid "$CYBROS_NEXUS_PORT" || install_fail 'CYBROS_NEXUS_PORT must be a port from 1 to 65535.'
    install_port_valid "$CYBROS_RHO_PORT" || install_fail 'CYBROS_RHO_PORT must be a port from 1 to 65535.'
    [ "$CYBROS_NEXUS_PORT" -ne "$CYBROS_RHO_PORT" ] || install_fail 'Nexus and rho need different ports.'
    CYBROS_NEXUS_URL=${CYBROS_NEXUS_URL:-http://$server_host:$CYBROS_NEXUS_PORT}
    CYBROS_RHO_URL=${CYBROS_RHO_URL:-http://$server_host:$CYBROS_RHO_PORT}
    export CYBROS_BIND CYBROS_NEXUS_PORT CYBROS_RHO_PORT CYBROS_NEXUS_URL CYBROS_RHO_URL
  fi

  printf '\n[4/5] Review installation\n'
  printf 'Directory: %s\nData:      %s/data\n' "$install_dir" "$install_dir"
  if [ ! -e "$install_dir/.env" ] && [ ! -e "$install_dir/secrets.env" ]; then
    printf 'Nexus:     %s\nrho:       %s\nBind:      %s\nImages:    %s/cybros-{nexus,rho}:%s\n' "$CYBROS_NEXUS_URL" "$CYBROS_RHO_URL" "$CYBROS_BIND" "${CYBROS_IMAGE_NAMESPACE:-jasl123}" "${CYBROS_IMAGE_TAG:-latest}"
    if [ "$unattended" = no ]; then
      if [ "$action" = init ]; then question='Create configuration? [Y/n]: '; else question='Install and start Cybros? [Y/n]: '; fi
      while :; do
        install_prompt "$question" y
        case "$answer" in y|Y|[Yy][Ee][Ss]) break ;; n|N|[Nn][Oo]) install_cancel ;; *) printf 'Answer yes or no.\n' >&3 ;; esac
      done
    fi
  fi
  trap - HUP INT TERM
  mkdir -p "$install_dir"
  install_dir=$(CDPATH='' cd -- "$install_dir" && pwd)
  [ "$install_dir" != / ] || install_fail 'Choose an installation directory other than /.'
  chmod 700 "$install_dir"
  if [ -e "$install_dir/cybros" ] || [ -e "$install_dir/compose.yaml" ]; then
    printf '%s\n' 'Keeping the existing cybros manager and Compose file, including local changes.'
  fi
  (
    cd "$install_dir"
    install_payload
  )
  if [ "$action" = init ]; then
    printf '\n[5/5] Preparing configuration\n'
  else
    printf '\n[5/5] Pulling images and waiting for healthy services\n'
  fi
  "$install_dir/cybros" "$action" </dev/null
  if [ "$action" = install ] && [ "$unattended" = no ] && (exec 3<> /dev/tty) 2>/dev/null; then
    "$install_dir/cybros" setup </dev/tty >/dev/tty 2>&1
  fi
}

install_main "$@"
