require "test_helper"
require "net/http"
require "socket"

# THE DAEMON'S OWN LIFE: claiming the
# home, announcing where it listens, the bind and its transport assertion, the
# log it leaves behind, the extension plane's lifetime, and the order
# it stops in. Every route an extension serves is proven in that
# extension's file.
class DaemonBootTest < Minitest::Test
  include RhoTest::DaemonHarness

  def test_a_booted_daemon_announces_where_it_listens
    daemon = boot

    document = announcement(daemon)
    assert_equal daemon.endpoint, document["endpoint"]
    assert_equal Process.pid, document["pid"]
    assert_equal "disconnected", document["state"]
    refute document.key?("mode")
    assert_match(%r{\Ahttp://127\.0\.0\.1:\d+\z}, document["endpoint"])
  end

  # The announcement carries a credential, so it is as private as the vault.
  def test_the_announcement_is_private
    daemon = boot

    assert_equal 0o600, File.stat(daemon.home.announcement_path).mode & 0o777
  end

  # The readiness probe the e2e harness uses. It answers before
  # any connection exists and takes no credential — a probe that needed one
  # could not tell "not ready" from "not authorized".
  def test_healthz_answers_without_a_credential
    daemon = boot

    response = get(daemon, "/healthz")
    assert_equal "200", response.code
    body = JSON.parse(response.body)
    assert_equal "ok", body["status"]
    assert_equal "disconnected", body["state"]
    refute body.key?("mode")
    assert_equal Rho::VERSION, body["version"]
    assert_equal Rho::Daemon::ANNOUNCEMENT_VERSION, body["control_version"]
  end

  # WITH A PAGE MOUNTED, A ROUTE-SHAPED UNKNOWN IS A DEEP LINK — the gem ships
  # one now, so `/nope` is the console answering for its own router. An
  # asset-shaped miss is still nothing, which is the rule that keeps the
  # document from being served to any path a stranger invents.
  def test_an_unknown_path_is_the_page_and_a_missing_asset_is_a_404
    daemon = boot

    assert_equal "200", get(daemon, "/nope").code
    missing = get(daemon, "/nope.js")
    assert_equal "404", missing.code
    assert_equal "not_found", JSON.parse(missing.body).dig("error", "code")
  end

  # …and with no page there is nothing to fall back to.
  def test_an_unknown_path_is_a_json_404_when_no_page_is_mounted
    daemon = boot(config: Rho::Config.from_hash({ "api_only" => true }))

    response = get(daemon, "/nope")
    assert_equal "404", response.code
    assert_equal "not_found", JSON.parse(response.body).dig("error", "code")
  end

  # The local bearer authorizes only this surface and never a kernel request,
  # so it is minted per boot and never reused.
  def test_the_local_bearer_is_rotated_every_boot
    first = announcement(boot)["bearer"]
    @daemons.pop.stop
    second = announcement(boot)["bearer"]

    refute_nil first
    refute_equal first, second
  end

  # The whole reason the boot lock exists: two daemons on one home would both
  # write the same vault and both redeem the same rotating token.
  def test_a_second_daemon_on_one_home_refuses_to_start
    running = boot
    before = announcement(running)

    error = assert_raises(Rho::AlreadyRunning) { boot }
    assert_includes error.message, running.home.root
    assert_includes error.message, running.endpoint, "the hint must name the running daemon, not the loser"
    assert_equal "200", get(running, "/healthz").code, "the running daemon is undisturbed"

    # The home is claimed before a byte is written. A loser that got as
    # far as announcing would publish its own endpoint and its own bearer over
    # the running daemon's, and every client reading state.json would then dial
    # a dead port with a bearer nobody honours.
    after = announcement(running)
    assert_equal running.endpoint, after["endpoint"]
    assert_equal before["bearer"], after["bearer"]
  end

  # ...and before a port is bound: with an explicit port the loser must refuse
  # on the lock rather than collide on the socket.
  def test_a_second_daemon_refuses_before_it_touches_the_port
    port = URI.parse(boot.endpoint).port
    @daemons.pop.stop
    running = boot(port: port)

    assert_raises(Rho::AlreadyRunning) { boot(port: port) }
    assert_equal "200", get(running, "/healthz").code
  end

  # A readiness probe is often a HEAD (`curl -I`). The router answers HEAD by
  # running the GET handler and dropping the body, so a verb-exact route table
  # has to say so or the probe reads as "no such endpoint".
  def test_healthz_answers_a_head_probe
    daemon = boot

    response = Net::HTTP.start(URI.parse(daemon.endpoint).host, URI.parse(daemon.endpoint).port) do |http|
      http.head("/healthz")
    end
    assert_equal "200", response.code
  end

  # A stalled local client must not be able to hold the installation. Shutdown
  # interrupts the reactor and then waits a bounded time for it to unwind, so
  # an unbounded wait would keep the boot lock while the announced port is
  # already free for anyone else to take — and would defeat SIGTERM.
  def test_a_stalled_client_cannot_hold_shutdown_open
    daemon = boot
    uri = URI.parse(daemon.endpoint)
    socket = TCPSocket.new(uri.host, uri.port)
    socket.write("GET /healthz HT")

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    @daemons.pop.stop
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_operator elapsed, :<, Rho::ControlServer::DRAIN_DEADLINE + 5
    refute File.exist?(daemon.home.announcement_path), "the announcement must not outlive the drain"
    assert_equal "200", get(boot, "/healthz").code, "the installation must be claimable again"
  ensure
    socket&.close
  end

  # A control server that dies on the way up must fail the boot. Spinning on a
  # callback that can never fire would burn a core forever while holding the
  # installation's boot lock, with no announcement for the next daemon to name.
  def test_a_control_server_that_never_starts_fails_the_boot_and_frees_the_lock
    home = Rho::Home.resolve(base_url: "https://nexus.example", root: @root)

    assert_raises(Errno::EMFILE) do
      Rho::Daemon.boot(home: home, server_class: StillbornServer)
    end

    assert_equal "200", get(boot, "/healthz").code, "the lock must not be left behind"
  end

  # A server whose accept loop dies before it ever signals that it started.
  # An accept loop that dies on the way up. It answers async-http's own
  # constructor shape so the failure under test is the one the test names,
  # not an arity mismatch with the double.
  class StillbornServer
    def initialize(_app, _endpoint, **) = nil
    def run = raise(Errno::EMFILE)
  end

  # A daemon whose only output is stdout has no recoverable scene: the process
  # that could explain a failure is the one that is gone. The log outlives it,
  # under RHO_HOME/log so it is not among the files a person deletes to
  # reclaim space.
  def test_a_boot_leaves_a_readable_scene_behind_the_process
    daemon = boot
    endpoint = daemon.endpoint
    daemon.stop
    @daemons.clear

    log = File.read(File.join(@root, "log", "rho.log"))
    assert_match(/event=daemon\.boot .*home=/, log)
    assert_includes log, "event=daemon.listening endpoint=#{endpoint}"
    assert_includes log, "event=daemon.phase from=stopped to=disconnected"
    assert_includes log, "event=daemon.stopped"
    assert_equal 0o600, File.stat(File.join(@root, "log", "rho.log")).mode & 0o777
  end

  # The local bearer authorizes every rho/v1 call, and a log is read by more
  # people than a memory dump ever is.
  def test_the_local_bearer_never_reaches_the_log
    daemon = boot
    bearer = daemon.bearer
    daemon.stop
    @daemons.clear

    refute_includes File.read(File.join(@root, "log", "rho.log")), bearer
  end

  # A hand-edited or half-written announcement must not turn "another daemon is
  # running" into an unrelated crash.
  def test_an_unreadable_announcement_still_produces_a_clean_refusal
    running = boot
    File.write(running.home.announcement_path, "[1,2]")

    assert_raises(Rho::AlreadyRunning) { boot }
  end

  # One RHO_HOME is one Nexus, so two Nexuses means two homes — which is
  # exactly how an operator separates development from production, and the
  # daemons must not contend for anything.
  def test_two_homes_run_side_by_side
    other = Dir.mktmpdir("rho-daemon-other")
    first = boot(base_url: "https://nexus.example")
    second = boot(base_url: "https://other.example", root: other)

    refute_equal first.endpoint, second.endpoint
    assert_equal "200", get(first, "/healthz").code
    assert_equal "200", get(second, "/healthz").code
  ensure
    FileUtils.remove_entry(other) if other && File.directory?(other)
  end

  # The guard that replaces the deleted per-Nexus layer: pointing one home at
  # a second Nexus is a mistake, not a second connection.
  def test_a_home_bound_to_one_nexus_refuses_another
    boot(base_url: "https://nexus.example")

    error = assert_raises(Rho::ConfigurationError) do
      Rho::Home.resolve(base_url: "https://other.example", root: @root)
    end
    assert_includes error.message, "different RHO_HOME"
  end

  def test_a_stopped_daemon_releases_the_home
    boot
    @daemons.pop.stop

    assert_equal "200", get(boot, "/healthz").code
  end

  # Shutdown passes through draining before the announcement disappears, so a
  # client that reads the file mid-shutdown is told what is happening rather
  # than finding a file pointing at a dead port.
  def test_shutdown_drains_before_it_disappears
    home = Rho::Home.resolve(base_url: "https://nexus.example", root: @root)
    path = home.announcement_path
    phases = []

    daemon = Rho::Daemon.boot(home: home, on_phase: ->(phase) { phases << [phase, File.exist?(path)] })
    daemon.stop

    assert_equal %i[disconnected draining stopped], phases.map(&:first)
    assert_equal [true, true, false], phases.map(&:last), "draining must be visible while the file is still there"
  end

  # A daemon that was killed leaves its announcement behind. It must not block
  # the next boot, and it must not survive it either — a stale endpoint is how
  # a client ends up dialling a port somebody else now owns.
  def test_a_stale_announcement_from_a_killed_daemon_is_replaced
    home = Rho::Home.resolve(base_url: "https://nexus.example", root: @root)
    home.prepare
    Rho::StateFile.new(home.announcement_path).write(
      "version" => 1, "state" => "disconnected", "endpoint" => "http://127.0.0.1:9", "pid" => 999_999,
      "generation" => 50
    )

    daemon = boot
    document = announcement(daemon)
    assert_equal daemon.endpoint, document["endpoint"]
    assert_equal Process.pid, document["pid"]
  end

  def test_the_daemon_binds_loopback_only
    daemon = boot

    assert_equal "127.0.0.1", URI.parse(daemon.endpoint).host
  end

  # A wider bind requires the operator to state whether TLS or a VPN fronts the socket;
  # the daemon cannot detect external encryption.
  def test_a_wider_bind_needs_one_explicit_transport_assertion
    error = assert_raises(Rho::ConfigurationError) { boot(bind: "0.0.0.0") }
    assert_match(/--expect-external-encryption/, error.message)
    assert_match(/--unsafe-plaintext/, error.message)

    assert_raises(Rho::ConfigurationError) { boot(bind: "not-an-address") }
  end

  def test_loopback_needs_no_assertion_at_all
    Rho::Daemon.verify_bind("127.0.0.1")
    Rho::Daemon.verify_bind("::1")
  end

  # The SPA fallback answers navigation only. An unrouted POST must return not_found,
  # rather than the HTML index falsely implying that a write succeeded.
  def test_the_spa_fallback_answers_navigation_and_not_unrouted_writes
    bundle = File.join(@root, "spa")
    FileUtils.mkdir_p(bundle)
    File.write(File.join(bundle, "index.html"), "<!doctype html><!--rho:bootstrap-->")
    daemon = boot(webui_root: bundle)
    token = bearer(daemon)

    deep_link = request(daemon, :get, "/conversations/abc", token: token)
    assert_equal 200, deep_link.code.to_i
    assert_includes deep_link["content-type"].to_s, "text/html"

    write = request(daemon, :post, "/nowhere", token: token)
    assert_equal 404, write.code.to_i, "an unrouted write must not read as success"
    assert_equal "not_found", JSON.parse(write.body).dig("error", "code")
  end

  # Browser authority comes from Nexus OAuth. LAN HTTP remains an explicit
  # operator choice and does not require a second browser password.
  def test_a_wider_bind_accepts_either_explicit_transport_assertion
    assert_nil Rho::Daemon.verify_bind("0.0.0.0", transport_assertion: :plaintext)
    assert_nil Rho::Daemon.verify_bind("0.0.0.0", transport_assertion: :external_encryption)
  end

  # Recorded as an assertion, not as a verified fact — and a plaintext boot
  # carries a standing warning, because anyone on the path reads every byte.
  def test_a_plaintext_boot_records_the_assertion_and_says_it_is_unsafe
    daemon = boot(bind: "0.0.0.0", transport_assertion: :plaintext,
      webui_root: File.join(@root, "absent"))

    document = announcement(daemon)
    assert_equal "plaintext", document["transport_assertion"]
    assert_match(/anyone on the path/, document["warning"])
  end

  def test_an_encrypted_front_is_recorded_without_a_warning
    daemon = boot(
      bind: "0.0.0.0", transport_assertion: :external_encryption,
      webui_root: File.join(@root, "absent")
    )

    document = announcement(daemon)
    assert_equal "external_encryption", document["transport_assertion"]
    refute document.key?("warning")
  end

  def test_a_loopback_boot_asserts_nothing
    refute announcement(boot).key?("transport_assertion")
  end

  # The announced endpoint must be a URL a client can actually dial, which for
  # an IPv6 literal means brackets.
  def test_an_ipv6_loopback_bind_announces_a_dialable_endpoint
    daemon = boot(bind: "::1")

    assert_equal "http://[::1]:#{URI.parse(daemon.endpoint).port}", daemon.endpoint
    assert_equal "200", get(daemon, "/healthz").code
    assert_equal daemon.endpoint, announcement(daemon)["endpoint"]
  end

  # A public page cannot carry the shell-capable local control credential.
  def test_the_page_carries_no_credential_in_either_browser_mode
    %w[full agent].each do |mode|
      bundle = File.join(@root, "bundle-#{mode}")
      FileUtils.mkdir_p(bundle)
      File.write(File.join(bundle, "index.html"), "<!doctype html><p>rho</p>")
      daemon = boot(config: Rho::Config.from_hash({ "mode" => mode }), webui_root: bundle,
        root: File.join(@root, "home-#{mode}"))

      page = get(daemon, "/").body
      refute_includes page, bearer(daemon)
      refute_includes page, Rho::Daemon::LOCAL_BEARER_PREFIX
      assert_includes page, "<p>rho</p>", "and it is still the page"
    end
  end

  # NOTHING IS PRINTED AT BOOT. A supervisor merges every process's stdout
  # into one stream and developers tee it to a file whose mode the daemon does
  # not own — which is exactly the read this whole mechanism closes.
  def test_a_booted_daemon_publishes_no_credential_where_a_supervisor_can_read_it
    daemon = boot(webui_root: console_bundle("boot-bundle"))
    document = announcement(daemon)

    refute_includes JSON.generate(document.reject { |key, _| key == "bearer" }),
      Rho::Daemon::LOCAL_BEARER_PREFIX
    assert daemon.page?, "a hint is only honest when a page exists"
    refute boot(config: Rho::Config.from_hash({ "api_only" => true }),
      root: File.join(@root, "pageless")).page?
  end

  def test_public_health_and_login_status_expose_no_local_credential_or_home
    daemon = boot(webui_root: console_bundle)
    ["/healthz", "/auth/status"].each do |path|
      response = request(daemon, :get, path)
      assert_equal "200", response.code
      refute_includes response.body, bearer(daemon)
      refute_includes response.body, daemon.home.root
    end
    status = JSON.parse(request(daemon, :get, "/auth/status").body)
    assert_equal false, status.fetch("authenticated")
    assert_equal %w[authorization_code device_code], status.fetch("flows")
  end

  def test_status_reports_a_disconnected_daemon_honestly
    daemon = boot

    body = JSON.parse(request(daemon, :get, "/status", token: bearer(daemon)).body)
    assert_equal "disconnected", body["state"]
    assert_equal "full", body["mode"], "the mode is a boot fact, said before any connection exists"
    refute body.key?("identity"), "a daemon with no credentials must not describe an identity"
    assert_equal({ "state" => "pending" }, body["workspace"],
      "a live daemon always carries one workspace block, and before adoption it is pending")
  end

  # A BACKGROUND TASK IS WHAT A 24/7 DEPLOYMENT IS FOR, and it is what an
  # extension holding an OS resource needs — a browser, a language server,
  # a watcher. Registering one was possible before this and STARTING one
  # was not: the daemon collected them and never ran any, which is
  # machinery with no reachable consumer.
  def test_a_background_task_runs_for_the_daemons_lifetime
    started = Queue.new
    stopped = []
    path = write_extension(<<~RUBY, id: "rho.lifecycle")
      module LifecycleExtension
        NAME = "rho.lifecycle"
        def self.register(api)
          api.on(:startup) { $rho_test_events << :startup }
          api.on(:shutdown) { $rho_test_events << :shutdown }
          api.background("watcher") { $rho_test_started << :running }
        end
      end
    RUBY
    $rho_test_events = stopped
    $rho_test_started = started

    daemon = boot(config: Rho::Config.from_hash({ "plugins" => { "rho.lifecycle" => path } }))

    # BOUNDED, because an unbounded `pop` turns "the task never ran" into a
    # hung suite rather than a failure anybody can read.
    assert_equal :running, pop_within(started, 5), "the task never ran"
    assert_includes stopped, :startup, "the startup hook never fired"

    daemon.stop
    assert_includes stopped, :shutdown,
      "shutdown must fire while the reactor still turns — a task holding a " \
      "browser needs the chance to close it"
  ensure
    $rho_test_events = nil
    $rho_test_started = nil
  end

  # ONE TASK'S FAILURE IS ITS OWN, for the same reason one extension's load
  # failure costs only its own tools.
  def test_a_raising_background_task_does_not_take_the_daemon_down
    path = write_extension(<<~RUBY, id: "rho.boom")
      module BoomExtension
        NAME = "rho.boom"
        def self.register(api)
          api.on(:startup) { raise "boom" }
          api.background("bad") { raise "boom" }
        end
      end
    RUBY

    daemon = boot(config: Rho::Config.from_hash({ "plugins" => { "rho.boom" => path } }))

    assert_predicate daemon, :running?
    assert_equal "200", get(daemon, "/healthz").code, "the daemon still serves"
  end

  def pop_within(queue, seconds)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
    until queue.closed? || !queue.empty?
      flunk "nothing arrived within #{seconds}s" if
        Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.02
    end
    queue.pop
  end

  def write_extension(body, id:)
    dir = File.join(@root, "ext")
    FileUtils.mkdir_p(dir)
    path = File.join(dir, "ext-#{SecureRandom.hex(4)}.rb")
    File.write(path, body)
    RhoTest.described_extension(path, id: id)
  end

  # The executable a person actually runs, stopped the way a person actually
  # stops it. Shutdown releases locks, which takes a mutex, and Ruby forbids a
  # mutex in trap context — so a handler that did the work inline would turn
  # every SIGTERM into a crash, leaving the announcement behind pointing at a
  # dead port.
  def test_the_executable_shuts_down_cleanly_on_a_signal
    home = Rho::Home.resolve(base_url: "https://nexus.example", root: @root)
    root = File.expand_path("../../..", __dir__)
    log = File.join(@root, "signal.log")
    pid = Process.spawn(
      { "RHO_HOME" => @root },
      RbConfig.ruby, File.join(root, "rho", "exe", "rho"), "server", "--nexus-url", "https://nexus.example",
      out: [log, "w"], err: [log, "w"]
    )

    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 15
    sleep 0.05 until File.exist?(home.announcement_path) ||
      Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    assert File.exist?(home.announcement_path), "the daemon never came up: #{File.read(log)}"

    Process.kill("TERM", pid)
    _, status = Process.waitpid2(pid)

    assert_predicate status, :success?, "SIGTERM must be a clean stop: #{File.read(log)}"
    refute File.exist?(home.announcement_path), "a clean stop takes its announcement with it"
  end
end
