require_relative "rho/version"
require "socket"

# The flagship agent application: the daemon body lives here as a
# library — lifecycle, vault, connection, and the local protocol surface — and
# `exe/rho` is the one human entry point dispatching onto it. "rho-server" is
# a process mode (`rho server`), never a separate artifact.
module Rho
  AGENT_IDENTIFIER = "rho".freeze
  # TWO RUNNER IDENTIFIERS: full mode's in-process runner is
  # named for the agent — a different key column from the agent's
  # (`task_executors.registration_identifier` beside `users.agent_identifier`), so
  # one manager holds one of each — and runner mode presents its own, or
  # a full rho and a runner-mode rho under one manager would fence each
  # other on the one live row per (account, manager, registration_identifier).
  REGISTRATION_IDENTIFIER = "rho".freeze
  STANDALONE_REGISTRATION_IDENTIFIER = "rho-runner".freeze

  def self.default_display_name = "rho on #{Socket.gethostname}"

  # THE PROGRAM'S ROOT: the directory the running process loads this file from — a bundler
  # checkout in development, the installed gem in production — which `__dir__` answers for
  # both without a Gem dependency. A running agent never edits it; a successor is a
  # separate install.
  def self.root = File.expand_path("..", __dir__)

  # THE ROOTS rho's self-modification deny rules protect, each resolved
  # (the rules anchor on the resolved spelling): this checkout, the
  # runner gem's when it sits elsewhere (the toolset is the program too),
  # the installed prefix when the wrapper exported one (the wrapper, the portable Ruby, `vendor/bundle` and `libexec/install.sh` are the program too), and the home's PROTECTED
  # MEMBERS (`Home#protected_members`): every
  # entry of the home's layout except the work root — settings,
  # credentials, the binding, the pointers, the extension code… — each
  # its own root, so a deny per member is one the kernel's glob can
  # express (a glob cannot carve a subtree out of a root), and the work
  # root (`Home#work_root`, by default `<RHO_HOME>/work`), where the
  # default environment root and the default checkpoint store sit, is
  # simply not in the list: the model's own project by absolute path
  # passes, `<home>/settings.json` and every vault are refused BEFORE
  # ANY RUNNER, wherever the work root is placed. A root under another
  # is that other's — an install's `versions/<v>/…` checkout is the
  # prefix's, a home under the checkout is the checkout's. THE SAME LIST
  # IS THE GUARD'S FLOOR and the
  # checkpoint store's exclusions (a store on a root enclosing the home
  # carries no member's bytes): a handle with no home — the runner's own
  # loader, a standalone runner — protects the program roots alone, and
  # a member not yet on disk is named by its resolved spelling.
  def self.protected_roots(home)
    candidates = [root, Rho::Runner.root, Rho::Install.protected_root, *home&.protected_members]
      .compact.map { |path| spelled(path) }.uniq
    candidates.reject { |path| candidates.any? { |other| other != path && path.start_with?("#{other}/") } }
  end

  def self.under?(path, root) = path == root || path.start_with?("#{root}/")

  # THE RESOLVED SPELLING of a path, as the roots are spelled: realpath
  # through the nearest existing ancestor, so a symlinked spelling
  # (macOS's /var → /private/var), `~`, and a path not yet on disk all
  # land on the root's spelling. ONE RULE, the runner gem's
  # (`ToolEnv.spelled`): the placement memo keys on it and the door and
  # the Guard judge on it, so the two must never drift.
  def self.spelled(path) = Rho::Runner::ToolEnv.spelled(path)
end

require_relative "rho/errors"
require_relative "rho/locale"
require_relative "rho/install"
require_relative "rho/doctor"
require_relative "rho/adaptations"
require_relative "rho/configuration"
require_relative "rho/config"
require_relative "rho/settings"
require_relative "rho/log"
require_relative "rho/state_file"
require_relative "rho/packages"
require_relative "rho/host"
require_relative "rho/host_store"
require_relative "rho/host_policy"
require_relative "rho/remote_runners"
require_relative "rho/runner_slot"
require_relative "rho/environment_store"
require_relative "rho/lock"
require_relative "rho/home"
require_relative "rho/identity"
require_relative "rho/credentials"
require_relative "rho/application_connection"
require_relative "rho/connection"
require_relative "rho/oauth_login"
require_relative "rho/disconnect"
require_relative "rho/authority"
require_relative "rho/renewal"
require_relative "rho/static_files"
require_relative "rho/control_server"
require_relative "rho/inference_request_run"
require_relative "rho/host_follower"
require_relative "rho/follower_stream"
require_relative "rho/stream_printer"
# COMPOSED, NOT CONTAINED. The runner is its own gem because a runner must
# also be able to run alone — on a machine with no daemon, no control
# server and no webui. rho builds one and spawns it; it does not own it.
require "rho/runner"
require_relative "rho/processes"
require_relative "rho/extensions/guard"
require_relative "rho/extensions/processes"
require_relative "rho/extensions/conventions"
require_relative "rho/extensions/until"
require_relative "rho/extensions/environment"
require_relative "rho/extensions/console_link"
require_relative "rho/extensions/ops"
require_relative "rho/extensions/compaction"
require_relative "rho/extensions/todo"
require_relative "rho/extensions/schedules"
require_relative "rho/extensions/default_runner"
require_relative "rho/agents"
require_relative "rho/extensions/agents"
require_relative "rho/extensions/images"
require_relative "rho/extensions/setup"
require_relative "rho/settings/control"
require_relative "rho/extensions/packages"
require_relative "rho/extensions/memory_review"
require_relative "rho/conventions"
require_relative "rho/extensions"
require_relative "rho/extension_catalog"
require_relative "rho/plugin_manager"
require_relative "rho/memory_policy"
require_relative "rho/run_declaration"
require_relative "rho/daemon"
require_relative "rho/core"
require_relative "rho/cli/terminal"
