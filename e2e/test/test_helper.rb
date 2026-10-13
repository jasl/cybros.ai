$LOAD_PATH.unshift File.expand_path("..", __dir__)

require "json"
require "minitest/autorun"
require "cybros_agent"
require "support/nexus_server"
require "support/browser_actor"
require "support/device_authorization_budget"
require "support/session_sign_in_budget"

module E2E
  NEXUS_ROOT = File.expand_path("../../nexus", __dir__)

  # The Rake `e2e` task boots the server and exports its URL. Running a test
  # file directly (without the Rake task) boots an inline server as a
  # fallback so a single case stays runnable.
  def self.base_url
    ENV["E2E_BASE_URL"] || inline_server.base_url
  end

  def self.inline_server
    unless @inline_server
      @inline_server = NexusServer.new(nexus_root: NEXUS_ROOT)
      @inline_server.start
    end
    @inline_server
  rescue StandardError, SystemExit, SignalException
    begin
      shutdown
    rescue StandardError => cleanup_error
      warn "E2E inline server cleanup also failed: #{cleanup_error.class}: #{cleanup_error.message}"
    end
    raise
  end

  # The dev provider lane is refused at selection until an operator enables
  # it, and there is no screen for that yet, so the harness does what an
  # operator does. Idempotent: a lane calls it in setup without caring who ran
  # first. Under the Rake task the journey is a CHILD process, so the handle
  # it needs was written down by the server and named in the environment.
  def self.enable_dev_lane!
    return if @dev_lane_enabled

    operator.enable_dev_lane!
    @dev_lane_enabled = true
  end

  # Cuts every cable this user holds, the way the deployment does on a signed
  # -out session or a rolling restart. A journey that claims the socket is
  # opportunistic has to break it for real to mean anything.
  def self.disconnect_cable!(user_public_id)
    operator.disconnect_cable!(user_public_id)
  end

  def self.operator
    require "support/nexus_operator"
    NexusOperator.new(nexus_root: handle.fetch("nexus_root"), env: handle.fetch("env"))
  end

  # THE EXECUTION HOSTS ARE THE JOURNEY'S, because pinning one is the only way
  # to assert which host ran a turn: `Wake` wakes both for a text lane and
  # gives neither a tiebreaker. A lane calls `E2E.hosts.pin(:runner)` or
  # `.pin(:jobs)`; the plain lane calls `.start` for the deployment shape.
  def self.hosts
    require "support/nexus_hosts"
    @hosts ||= NexusHosts.new(
      nexus_root: handle.fetch("nexus_root"), env: handle.fetch("env"),
      log_dir: handle.fetch("log_dir")
    )
  end

  def self.handle
    @handle ||= JSON.parse(
      File.read(ENV["E2E_NEXUS_OPERATOR"] || inline_server.operator_handle_path)
    )
  end

  def self.shutdown
    @hosts&.stop
    @hosts = nil
    server = @inline_server
    @inline_server = nil
    server&.stop
  end
end

Minitest.after_run { E2E.shutdown }
# The run's unmeasured costs, measured: the two per-IP ledgers' waits and
# the process-group stops (the ledgers' LIMIT/WINDOW/PAD are product
# mirrors and stay; this line says whether they bound).
Minitest.after_run do
  puts format("e2e ledgers: device-flow slept %.1f s, sign-in slept %.1f s; terminate: %d calls %.1f s",
    E2E::DeviceAuthorizationBudget.slept_seconds, E2E::SessionSignInBudget.slept_seconds,
    E2E::ProcessRunner.terminate_calls, E2E::ProcessRunner.terminate_seconds)
end
