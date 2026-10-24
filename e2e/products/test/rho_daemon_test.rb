require "test_helper"
require "cgi/escape"
require "fileutils"
require "json"
require "net/http"
require "tmpdir"
require "support/actor_provisioning"
require "support/ceremony"
require "support/process_registry"
require "support/process_runner"
require "support/rho_daemon"
require "support/steward_session"
require "support/secret_hygiene"
require "support/nexus_operator"

# The rho shell as a product, against a real Nexus.
#
# Every other test in this repository drives rho's code. This one drives the
# executable a person installs: a real subprocess, its own bundle, its own
# RHO_HOME, talking to a booted Nexus over HTTP while a human confirms the
# ceremony in a browser. What it proves cannot be proved anywhere else —
# that the three pieces built separately (the kernel's device flow, the gem's
# credential stack, the daemon) actually meet.
class RhoDaemonTest < Minitest::Test
  RHO_ROOT = File.expand_path("../../../agents/rho/rho", __dir__)
  READY_TIMEOUT = 60
  POLL = 0.2

  def setup
    @base_url = E2E.base_url
    # THE OWNER'S BROWSER IS THE WORLD'S (`ActorProvisioning#owner_browser`):
    # founded or signed in once per process, never once per test — the
    # founding /setup branch lives there, beside the member reads.
    @actor = E2E::ActorProvisioning.world(@base_url).owner_browser
    @page = @actor.page
    @home = Dir.mktmpdir("rho-e2e")
    @log = File.join(@home, "daemon.log")
    @daemon_pid = nil
    @cli_pid = nil
    @steward_daemon = nil
    @steward_actor = nil
    @steward_home = nil
    found_installation
  end

  def teardown
    # Capture first, and each step on its own: a failing stop must not be able
    # to swallow the log that explains why the daemon was not there to stop.
    unless passed?
      warn "rho daemon stdout:\n#{E2E::SecretHygiene.redact(File.read(@log))}" if File.file?(@log)
      # The structured log is where the daemon says what it actually did; a
      # failure here is exactly when someone needs it.
      structured = File.join(@home, "log", "rho.log")
      warn "rho structured log:\n#{E2E::SecretHygiene.redact(File.read(structured))}" if File.file?(structured)
      warn "steward's rho daemon stdout:\n#{E2E::SecretHygiene.redact(File.read(@steward_daemon.log_path, encoding: Encoding::UTF_8))}" if
        @steward_daemon && File.file?(@steward_daemon.log_path)
      E2E::SecretHygiene.save_screenshot(
        @actor,
        File.expand_path("../artifacts/screenshots/rho_daemon-#{Process.pid}.png", __dir__)
      )
    end
  rescue StandardError => error
    warn "Could not capture rho E2E capture: #{error.class}: #{error.message}"
  ensure
    begin
      E2E::ProcessRegistry.terminate(@cli_pid) if @cli_pid
      stop_daemon
      @steward_daemon&.stop
    rescue StandardError => error
      warn "Could not stop the rho daemon: #{error.class}: #{error.message}"
    end
    daemons = [@steward_daemon]
    daemons << E2E::RhoDaemon.new(base_url: @base_url, home: @home) if @home
    daemons.compact.each do |daemon|
      if (result = daemon.dispose_connection)
        output, status = result
        assert_predicate status, :success?, output
      end
    end
    # Both browsers are the process's (the world's owner, `StewardSession`),
    # closed when the run ends.
    FileUtils.remove_entry(@home) if @home && File.directory?(@home)
    FileUtils.remove_entry(@steward_home) if @steward_home && File.directory?(@steward_home)
    # A lane that pinned a host restores the pair, or whichever runs next
    # inherits a composition it never asked for.
    E2E.hosts.start
  end

  def test_a_human_connects_rho_restores_a_removed_agent_restarts_and_revokes_it
    start_daemon
    assert_equal "disconnected", status.fetch("state"), "a fresh installation holds no credentials"

    abandoned = start_ceremony
    # Two clients, one ceremony: a second surface clicking connect while the
    # first ceremony is pending is answered with the SAME ceremony, and the
    # real kernel must have minted exactly one device authorization — the
    # unit suite pins the daemon's half; only this proves Nexus saw one code.
    assert_equal abandoned.fetch("user_code"), start_connection.fetch("user_code"),
      "a second connect click mid-ceremony must not mint a second code"

    # A human who forgot this ceremony cancels it, and the next click gets a
    # genuinely new one. No member, executor or credential consequence exists;
    # the machine cancellation command atomically marks the short-lived
    # DeviceAuthorization canceled before rho kills the local poll.
    assert_equal true, control(:post, "/device/cancel").fetch("canceled")
    assert_nil status["connection"], "a canceled ceremony must be gone from status"
    started = start_ceremony
    refute_equal abandoned.fetch("user_code"), started.fetch("user_code"),
      "the ceremony after a cancel is a new one, not the abandoned one resold"
    # One application ceremony installs member and executor transport planes.
    assert_equal "agent", started.fetch("branch"), started.inspect
    E2E::Ceremony.confirm(actor: @actor, started: started, status: -> { status })
    connected = await_state("active")

    identity = connected.fetch("identity")
    agent_public_id = identity.fetch("user_public_id")
    address = identity.fetch("executor_public_id")
    runner = identity.fetch("runner_executor_public_id")
    refute_nil agent_public_id
    refute_nil address
    refute_nil runner
    assert_equal address, runner, "Local uses the application executor UUID"
    assert_equal "signed_in", connected.dig("authority", "signed")
    assert_equal "live", connected.dig("authority", "planes", "member")
    assert_equal "live", connected.dig("authority", "planes", "executor_transport")
    refute connected.fetch("authority").fetch("planes").key?("runner_transport")

    # A restart is invisible: the daemon resumes the connection it already has.
    # Under single-instance addressing a second ceremony would re-pair this
    # same address rather than mint a new one, so the public id alone can no
    # longer prove no ceremony ran — the authority read is what proves it,
    # since a re-pair would have fenced the credential this daemon holds.
    stop_daemon
    start_daemon
    restarted = await_state("active")
    assert_equal agent_public_id, restarted.dig("identity", "user_public_id")
    assert_equal address, restarted.dig("identity", "executor_public_id")
    assert_equal runner, restarted.dig("identity", "runner_executor_public_id")
    assert_equal "live", restarted.dig("authority", "planes", "executor_transport"),
      "a fenced transport plane means the daemon re-ran a ceremony it should have resumed"
    refute restarted.fetch("authority").fetch("planes").key?("runner_transport")

    # Agent removal fences both Agent planes. Recovery keeps the independently
    # managed Runner and re-pairs the Agent's original address.
    remove_agent_in_console(agent_public_id)
    stop_daemon
    start_daemon
    degraded = await_signed("expired")
    assert_equal agent_public_id, degraded.dig("identity", "user_public_id")
    assert_equal address, degraded.dig("identity", "executor_public_id")
    assert_equal "active", degraded.fetch("state")
    assert_equal "unauthorized", degraded.dig("authority", "planes", "member")
    assert_equal "unauthorized", degraded.dig("authority", "planes", "executor_transport")
    # The runner plane is the MANAGER's credential, not the Agent's:
    # removing the Agent leaves it live.
    refute degraded.fetch("authority").fetch("planes").key?("runner_transport")

    restoring = start_ceremony
    # A refusal here is a document with an `error`, not a `phase`; a bare
    # fetch turned a readable refusal into KeyError once, on a daemon that
    # had just restarted. Say what came back instead.
    assert_equal "pending", restoring.fetch("phase") { flunk "the ceremony did not start: #{restoring.inspect}" }
    # Restoring the member connection preserves the application executor address.
    assert_equal "agent", restoring.fetch("branch"), restoring.inspect

    E2E::Ceremony.confirm(actor: @actor, started: restoring, status: -> { status })
    restored = await_signed("signed_in")
    assert_equal agent_public_id, restored.dig("identity", "user_public_id")
    assert_equal address, restored.dig("identity", "executor_public_id"),
      "restore re-pairs the Agent's stable logical address instead of creating a sibling"
    assert_equal runner, restored.dig("identity", "runner_executor_public_id"),
      "the restore kept the runner it had; it did not pair a second one"
    assert_equal "live", restored.dig("authority", "planes", "member")
    assert_equal "live", restored.dig("authority", "planes", "executor_transport")
    refute restored.fetch("authority").fetch("planes").key?("runner_transport")

    # The steward ends the session from the console. rho must notice, say so in
    # the ordinary words, and stay up rather than pretending nothing happened.
    # The agent's registration is what the console revokes; the runner row is
    # the manager's and its plane stays live.
    revoke_registration_in_console(agent_public_id)
    revoked = await_signed("expired")
    assert_equal "active", revoked.fetch("state"), "rho stays up and reports; it does not fall over"
    assert_equal "unauthorized", revoked.dig("authority", "planes", "member")
    refute revoked.fetch("authority").fetch("planes").key?("runner_transport")
  end

  private

    # ---- the daemon as a subprocess, in its own bundle ----

    # The child runs in rho's bundle, and BOTH halves of that bundle have to be
    # named. Overriding only the Gemfile leaves the child comparing rho's
    # dependencies against the harness's lockfile, because it inherits `bundle
    # exec`'s RUBYOPT and resolves against a mixture of the two — which is how
    # this journey silently rewrote `e2e/Gemfile.lock` on every run before the
    # lockfile was pinned too. Frozen mode is the belt: a test may not edit a
    # tracked file, and frozen makes that impossible rather than unlikely.
    # Clearing RUBYOPT instead does not work — bundler's own exec needs it, and
    # the daemon simply never starts.
    CHILD_BUNDLE_ENV = {
      "BUNDLE_GEMFILE" => File.join(RHO_ROOT, "Gemfile"),
      "BUNDLE_LOCKFILE" => File.join(RHO_ROOT, "Gemfile.lock"),
      "BUNDLE_FROZEN" => "true",
    }.freeze

    # This lane spawns the daemon by hand (the connect subprocess is the
    # thing under test), so the bare home's dev settings and the gem's
    # lib are written and handed over here, as `E2E::RhoDaemon` does.
    def start_daemon
      E2E::RhoDaemon.new(base_url: @base_url, home: @home).send(:write_settings_if_absent!)
      @daemon_pid = E2E::ProcessRegistry.spawn(
        CHILD_BUNDLE_ENV.merge(E2E::RhoDaemon::CHILD_DEV_ENV).merge("RHO_HOME" => @home),
        Gem.ruby, Gem.bin_path("bundler", "bundle"), "exec", "ruby", "exe/rho",
        "server", "--nexus-url", @base_url,
        chdir: RHO_ROOT, out: [@log, "a"], err: [@log, "a"], pgroup: true
      )
      await_announcement
    end

    def stop_daemon
      return if @daemon_pid.nil?

      E2E::ProcessRegistry.terminate(@daemon_pid)
      @daemon_pid = nil
    end

    # The announcement is how any client finds this daemon — the same file the
    # CLI reads. Waiting on it is waiting for a real readiness signal rather
    # than for a sleep to elapse.
    def await_announcement
      until_ready("the daemon never announced itself") do
        document = announcement
        document && document["endpoint"] ? document : nil
      end
    end

    # One RHO_HOME is one Nexus, so the announcement has one fixed path under
    # `tmp/` — no glob, and nothing to disambiguate.
    def announcement
      JSON.parse(File.read(File.join(@home, "tmp", "announcement.json")))
    rescue JSON::ParserError, Errno::ENOENT
      nil
    end

    # ---- the control surface, exactly as the webui will use it ----

    def control(verb, path, body: nil) = JSON.parse(control_response(verb, path, body: body).body)

    # THE STATUS IS ITSELF AN ASSERTION on this surface, so a caller that needs
    # it can have the response rather than the parsed body alone.
    def control_response(verb, path, body: nil)
      document = announcement
      uri = URI.join(document.fetch("endpoint"), path)
      request = (verb == :post ? Net::HTTP::Post : Net::HTTP::Get).new(uri)
      request["Authorization"] = "Bearer #{document.fetch("bearer")}"
      if body
        request["Content-Type"] = "application/json"
        request.body = JSON.generate(body)
      end
      Net::HTTP.start(uri.host, uri.port) { |http| http.request(request) }
    end

    def status = control(:get, "/status")
    def start_connection = control(:post, "/device/start")

    # The first `/device/start` on a disconnected daemon reaches Nexus's
    # rate-limited device-authorization endpoint; later clicks are answered
    # from the daemon's memory and cost nothing. Consume only for the first.
    #
    # A start that lands while the daemon is re-reading its own authority —
    # for one moment after a removal signal the credential object is mid-swap
    # — gets the honest 503 the daemon promises for exactly that window. The
    # harness takes "try again" at its word and repeats the click; every
    # other answer returns as-is, so a real refusal still fails loudly.
    # `connection_bootstrapping` is the same window seen from a restarted
    # daemon still checking the connection it stored — the shipped CLI's
    # own `start_ceremony` waits it out, and so does this.
    RETRYABLE_START_CODES = %w[authority_unknown connection_changed connection_bootstrapping].freeze

    def start_ceremony
      E2E::DeviceAuthorizationBudget.consume
      until_ready("the daemon never accepted the ceremony start") do
        document = start_connection
        document unless RETRYABLE_START_CODES.include?(document.dig("error", "code"))
      end
    end

    def inference_request(public_id)
      control(:get, "/inference_requests").fetch("inference_requests").find { _1.fetch("public_id") == public_id }
    end

    def await_state(state)
      until_ready("the daemon never reached #{state}") do
        document = status
        document["state"] == state ? document : nil
      end
    end

    def await_signed(signed)
      until_ready("the daemon never reported #{signed}") do
        document = status
        document.dig("authority", "signed") == signed ? document : nil
      end
    end

    def until_ready(message)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + READY_TIMEOUT
      loop do
        result = yield
        return result if result
        flunk(message) if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep POLL
      end
    end

    # ---- the human's half ----

    # A freshly booted Nexus has no owner at all — there is nobody to sign in
    # as until the installation is founded, which is itself part of what a
    # person does before rho can ever connect. The world did both once
    # (`found_or_sign_in_owner`); here the memoised session is asserted,
    # never re-made — a test that broke it fails the next setup loudly.
    def found_installation
      @actor.visit("/")
      assert @page.has_text?("Overview"), "the owner's session did not reach the dashboard"
    end

    def remove_agent_in_console(agent_public_id)
      @actor.visit("/agents/#{agent_public_id}")
      @page.click_button "Remove"
      @page.find("#turbo-confirm button[value='confirm']").click

      assert @page.has_text?("Agent removed.")
      assert @page.has_text?("This Agent is removed")
    end

    # The registration is member-owned: a steward ends it from their own console, and there is
    # deliberately no administrator counterpart. An Agent is single-instance, so the page offers
    # exactly one revoke.
    def revoke_registration_in_console(agent_public_id)
      @actor.visit("/agents/#{agent_public_id}")
      assert @page.has_css?("[data-address-id]", count: 1),
        "one Agent, one address — the console must not offer a list to choose from"
      button = @page.find("button[aria-label^='Revoke credentials'], input[aria-label^='Revoke credentials']")
      button.click
      # Turbo's confirmation is a DOM dialog here, not window.confirm, and its
      # confirm branch repeats the verb of the button that opened it — so it is
      # found by value rather than by text.
      @page.find("#turbo-confirm button[value='confirm']").click

      assert @page.has_text?("No application connected"), "the revoked address must be gone from the console"
      assert @page.has_no_css?("[data-address-id]"), "the revoked application address is no longer shown"
    end
end
