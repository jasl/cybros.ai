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
  RHO_ROOT = File.expand_path("../../agents/rho/rho", __dir__)
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
    # Both browsers are the process's (the world's owner, `StewardSession`),
    # closed when the run ends.
    FileUtils.remove_entry(@home) if @home && File.directory?(@home)
    FileUtils.remove_entry(@steward_home) if @steward_home && File.directory?(@steward_home)
    # A lane that pinned a host restores the pair, or whichever runs next
    # inherits a composition it never asked for.
    E2E.hosts.start
  end

  def test_a_human_connects_rho_restores_a_removed_profile_restarts_and_revokes_it
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
    # FULL MODE PAIRS ONCE (r-modes M2): the daemon published the combined
    # shape, the person approved ONE page carrying the runner sentence, and
    # the grant minted the agent address AND a private runner row — three
    # planes on one connection.
    assert_equal "combined", started.fetch("branch"), started.inspect
    E2E::Ceremony.confirm(actor: @actor, started: started, status: -> { status })
    connected = await_state("active")

    identity = connected.fetch("identity")
    profile = identity.fetch("user_public_id")
    address = identity.fetch("executor_public_id")
    runner = identity.fetch("runner_executor_public_id")
    refute_nil profile
    refute_nil address
    refute_nil runner, "the combined grant registered this machine's runner: #{identity.inspect}"
    refute_equal address, runner, "the runner is a second executor row, never the agent address"
    assert_equal "signed_in", connected.dig("authority", "signed")
    assert_equal "live", connected.dig("authority", "planes", "member")
    assert_equal "live", connected.dig("authority", "planes", "executor_transport")
    assert_equal "live", connected.dig("authority", "planes", "runner_transport")

    # A restart is invisible: the daemon resumes the connection it already has.
    # Under single-instance addressing a second ceremony would re-pair this
    # same address rather than mint a new one, so the public id alone can no
    # longer prove no ceremony ran — the authority read is what proves it,
    # since a re-pair would have fenced the credential this daemon holds.
    stop_daemon
    start_daemon
    restarted = await_state("active")
    assert_equal profile, restarted.dig("identity", "user_public_id")
    assert_equal address, restarted.dig("identity", "executor_public_id")
    assert_equal runner, restarted.dig("identity", "runner_executor_public_id")
    assert_equal "live", restarted.dig("authority", "planes", "executor_transport"),
      "a fenced transport plane means the daemon re-ran a ceremony it should have resumed"
    assert_equal "live", restarted.dig("authority", "planes", "runner_transport"),
      "the runner lineage resumed from its own vault beside the agent's"

    # Profile removal fences both Agent planes. Recovery keeps the independently
    # managed Runner and re-pairs the Agent's original address.
    remove_profile_in_console(profile)
    stop_daemon
    start_daemon
    degraded = await_signed("expired")
    assert_equal profile, degraded.dig("identity", "user_public_id")
    assert_equal address, degraded.dig("identity", "executor_public_id")
    assert_equal "active", degraded.fetch("state")
    assert_equal "unauthorized", degraded.dig("authority", "planes", "member")
    assert_equal "unauthorized", degraded.dig("authority", "planes", "executor_transport")
    # The runner plane is the MANAGER's credential, not the Profile's:
    # removing the Profile leaves it live.
    assert_equal "live", degraded.dig("authority", "planes", "runner_transport")

    restoring = start_ceremony
    # A refusal here is a document with an `error`, not a `phase`; a bare
    # fetch turned a readable refusal into KeyError once, on a daemon that
    # had just restarted. Say what came back instead.
    assert_equal "pending", restoring.fetch("phase") { flunk "the ceremony did not start: #{restoring.inspect}" }
    # A RESTORE NEVER FENCES A LIVE RUNNER PLANE (r-modes M2′): with the
    # runner plane live the daemon opens branch A ALONE — one page, no
    # runner sentence — because a combined re-consume would re-pair the
    # runner row and fence the credential its runner loop is claiming with.
    assert_equal "agent", restoring.fetch("branch"), restoring.inspect

    E2E::Ceremony.confirm(actor: @actor, started: restoring, status: -> { status })
    restored = await_signed("signed_in")
    assert_equal profile, restored.dig("identity", "user_public_id")
    assert_equal address, restored.dig("identity", "executor_public_id"),
      "restore re-pairs the Profile's stable logical address instead of creating a sibling"
    assert_equal runner, restored.dig("identity", "runner_executor_public_id"),
      "the restore kept the runner it had; it did not pair a second one"
    assert_equal "live", restored.dig("authority", "planes", "member")
    assert_equal "live", restored.dig("authority", "planes", "executor_transport")
    assert_equal "live", restored.dig("authority", "planes", "runner_transport"),
      "a fenced runner plane means the restore re-consumed the runner half"

    # The steward ends the session from the console. rho must notice, say so in
    # the ordinary words, and stay up rather than pretending nothing happened.
    # The agent's registration is what the console revokes; the runner row is
    # the manager's and its plane stays live.
    revoke_registration_in_console(profile)
    revoked = await_signed("expired")
    assert_equal "active", revoked.fetch("state"), "rho stays up and reports; it does not fall over"
    assert_equal "unauthorized", revoked.dig("authority", "planes", "member")
    assert_equal "live", revoked.dig("authority", "planes", "runner_transport")
  end

  # The CLI a person actually types, driven end to end: `rho connect` prints
  # the code, blocks through the ceremony, and reports who this machine
  # became; `rho status` reads it back. Only here do the shipped binary, the
  # live daemon, and the real kernel meet — the unit suite drives `Rho::Core`
  # and `Rho::Cli::Terminal` as libraries against doubles.
  # LLM API → NEXUS → RHO, end to end and in one process each.
  #
  # Every other lane proves a leg. This one is the whole chain: a daemon that
  # holds its own connection places a model call in its own dedicated
  # workspace, a fake provider answers over a real socket in another process,
  # the model runner streams the answer into durable events, and RHO ASSEMBLES
  # THEM BACK INTO THE ANSWER by following the stream.
  #
  # The live feed provides the preview; REST provides the terminal result
  # even while the job that publishes the final notification has not run.
  def test_rho_places_a_model_call_and_assembles_the_answer_from_the_event_stream
    start_daemon
    E2E::Ceremony.confirm(actor: @actor, started: start_ceremony, status: -> { status })
    await_state("active")
    workspace = await_workspace("adopted")
    refute_nil workspace["public_id"], "the daemon must own a workspace before it can place work"

    E2E.enable_dev_lane!
    # THE RUNNER ALONE, so the host that runs this is a named one: `Wake`
    # gives neither host a tiebreaker, and this lane's subject is what rho
    # assembles from one host's stream. The queue host stays stopped until
    # rho has finished, so no terminal notification can wake the follower.
    E2E.hosts.pin(:runner)

    # THE CONTROL CROSSES THE DAEMON. rho used to read four members off this
    # body and drop the rest, so `configuration` reached Nexus from every
    # consumer except the one an operator actually runs. The key is the
    # caller's own: rho mints none, because a retry it invented a key for is a
    # second run and a second bill.
    prompt = "say hi in several streamed fragments"
    answer = "Mock: #{prompt}"
    accepted = control(:post, "/one_shots", body: {
      model: "dev/mock-text", input: "!mock usage=4:6 stream_chunk_delay=2 -- #{prompt}",
      idempotency_key: "rho-e2e-#{SecureRandom.uuid}",
      configuration: { temperature: 0.25, max_output_tokens: 64 },
    })
    public_id = accepted.dig("one_shot", "public_id")
    refute_nil public_id, "rho answered #{accepted.inspect}"
    assert_equal "queued", accepted.dig("one_shot", "status")
    assert_equal "", accepted.dig("one_shot", "text"),
      "the answer is assembled as it arrives, so there is none yet"

    # THE ANSWER ARRIVES BEFORE THE RUN IS OVER, which is the whole reason a
    # daemon follows a stream instead of polling for a result. rho has the
    # complete text here while the provider pauses before its final frame.
    narrated = until_ready("rho never assembled the answer") do
      found = one_shot(public_id)
      found if found && found.fetch("text") == answer
    end
    refute narrated.fetch("complete"),
      "the provider has narrated the text but has not finished yet"

    # The terminal item is a queued job's to write. REST must finish the run
    # in rho even though that job has not run and its live socket stays open.
    followed = until_ready("rho never read the result without a terminal notification") do
      found = one_shot(public_id)
      found if found && found.fetch("complete")
    end

    assert_equal "completed", followed.fetch("status")
    assert_equal answer, followed.fetch("text"),
      "what rho assembled from the deltas must be the answer the provider composed"
    assert_equal "completed", followed.dig("result", "status")
    assert_operator followed.fetch("sequence"), :>, 1,
      "a followed run advances through the stream rather than reading one item"
    assert_equal narrated.fetch("sequence"), followed.fetch("sequence"),
      "REST completion must not invent a terminal event or advance the feed cursor"

    # WHOSE MISTAKE WAS IT, end to end. Nexus refuses an unknown generation
    # parameter with a 422 it can attribute to the request; rho used to relabel
    # every one of those a 502, telling the operator their own typo was a
    # gateway failure. The daemon is up and adopted here, so both refusals cost
    # nothing but the round trip.
    refused = control_response(:post, "/one_shots", body: {
      model: "dev/mock-text", input: "say hi", idempotency_key: SecureRandom.uuid,
      configuration: { nonesuch: 1 },
    })
    assert_equal "422", refused.code,
      "a refusal Nexus attributed to the request must not arrive as a gateway failure"
    assert_equal "unsupported_generation_parameter",
      JSON.parse(refused.body).dig("error", "code")

    keyless = control_response(:post, "/one_shots", body: {
      model: "dev/mock-text", input: "say hi",
    })
    assert_equal "400", keyless.code,
      "rho asks for the caller's own key rather than inventing one"
    assert_equal "parameter_missing", JSON.parse(keyless.body).dig("error", "code")
  end

  # THE LOOP DOOR, from the shipped binary: a STANDALONE loop authored through Ops's `POST /loops` —
  # the core authors conversations now, so this case lives on the shipped default set — and `rho
  # say`, the core's one verb, on it while it runs: a steer lands as `input_materialized{task_key}`
  # on the LOOP's own feed and in the continuation's echo; a `--mode queue` word arrives as a
  # planted follow-up round after the deliverable answered, BEFORE the turn-shaped `completed`, and
  # then the loop completes with an empty queue.
  def test_rho_say_reaches_a_running_loop_through_its_own_door
    daemon, steward, workspace_public_id = steward_daemon!
    E2E.enable_dev_lane!
    E2E.hosts.start

    project = File.join(@steward_home, "project")
    FileUtils.mkdir_p(project)
    # Round 1 calls one SLOW tool, which is the window a steer lands in:
    # bound while the tool runs, drained into the continuation's request.
    arguments = CGI.escape(JSON.generate({ "command" => "sleep 15" }))
    authored = daemon.control(:post, "/loops", body: {
      prompt: "!mock tool_call=bash tool_args=#{arguments} -- wait, then report",
      model: "dev/mock-text", working_directory: project,
    })
    loop_id = authored.dig("loop", "public_id")
    refute_nil loop_id, "Ops's author answered #{authored.inspect}"
    loop_path = "/agent_api/v1/workspaces/#{workspace_public_id}/agent_loops/#{loop_id}"

    member_poll("the slow tool never started") do
      row = member_read(steward, loop_path)["agent_loop"]
      row if row && row.fetch("tasks").any? { |task| task["kind"] == "tool_task" && %w[dispatched running].include?(task["status"]) }
    end
    said, status = daemon.cli("say", loop_id, "also print the sum")
    assert_predicate status, :success?, "rho say failed:\n#{said}"
    assert_match(/^queued:\s+\S+ \(steering\)$/, said, "a steer binds to the loop's one running turn")
    queued, status = daemon.cli("say", loop_id, "and then one more thing", "--mode", "queue")
    assert_predicate status, :success?, "rho say --mode queue failed:\n#{queued}"
    assert_match(/^queued:\s+\S+ \(pending\)$/, queued, "a queued word waits for the turn boundary")

    completed = member_poll("the loop never completed") do
      row = member_read(steward, loop_path)["agent_loop"]
      row if row && row["status"] == "completed"
    end
    assert_equal "completed", completed.dig("turn", "status"), completed.inspect
    assert_equal 0, completed.dig("input_queue", "held"), "the loop completed only once its queue was empty"

    events = member_read(steward, "#{loop_path}/events?limit=200").fetch("events")
    assert(events.all? { |item| item.dig("resource", "type") == "agent_loop" }, "a standalone loop is its own host")
    landed = events.select { |item| item["type"] == "input_materialized" }
    assert_equal 2, landed.length, "both words landed: #{events.map { |item| item["type"] }.inspect}"
    steer, follow_up = landed
    assert_equal loop_id, steer.dig("payload", "agent_loop_public_id")
    refute_equal completed.fetch("tasks").first.fetch("key"), steer.dig("payload", "task_key"),
      "the steer landed in the continuation, never in the round already on the wire"
    echoed = member_read(steward, "#{loop_path}/tasks/#{steer.dig("payload", "task_key")}").dig("task", "output").to_s
    assert_includes echoed, "also print the sum", "the continuation's sealed request carried the steer"

    settled = events.find { |item| item["type"] == "turn_status" && item.dig("payload", "status") == "completed" }
    refute_nil settled, "the turn-shaped terminal rides the loop's own feed"
    assert_operator follow_up.fetch("sequence"), :<, settled.fetch("sequence"),
      "the queued word landed BEFORE completed — completed means the queue was empty"
    planted = member_read(steward, "#{loop_path}/tasks/#{follow_up.dig("payload", "task_key")}").dig("task", "output").to_s
    assert_includes planted, "and then one more thing", "the planted follow-up round read the queued word"

    # The follower reads the feed on the daemon's own fiber, so its
    # `complete` is a level that lands one hop AFTER the kernel's own read
    # said completed — waited for, never read once (rho_conversation_test's
    # `await_follower` holds the same line). A completed standalone loop
    # stays listed: `forget` drops the store row, never the run.
    followed = nil
    until_ready("the follower never read the turn-shaped completed") do
      row = daemon.control(:get, "/loops").fetch("loops").find { |candidate| candidate.fetch("public_id") == loop_id }
      flunk "the daemon stopped following the loop it authored" if row.nil? && followed
      followed = row
      row if row && row.fetch("complete")
    end
    refute_nil followed, "the daemon follows the loop it authored"
    assert followed.fetch("complete"), "the follower read the turn-shaped completed"
    assert_equal "completed", followed.fetch("status")
  end

  def test_the_shipped_cli_connects_and_reports_through_the_live_daemon
    start_daemon

    out_path = File.join(@home, "connect.out")
    # The subprocess's first act is a ceremony start; the budget is consumed
    # here because the spawn is where the harness decides to spend it.
    E2E::DeviceAuthorizationBudget.consume
    @cli_pid = E2E::ProcessRegistry.spawn(
      CHILD_BUNDLE_ENV.merge(E2E::RhoDaemon::CHILD_DEV_ENV).merge("RHO_HOME" => @home),
      Gem.ruby, Gem.bin_path("bundler", "bundle"), "exec", "ruby", "exe/rho",
      "connect", "--nexus-url", @base_url,
      chdir: RHO_ROOT, out: [out_path, "a"], err: [out_path, "a"], pgroup: true
    )
    started = until_ready("rho connect never printed the code") do
      # UTF-8 by name: the connect line carries an em-dash, and the test
      # process inherits the machine's empty locale.
      text = File.file?(out_path) ? File.read(out_path, encoding: Encoding::UTF_8) : ""
      uri = text[%r{Or open directly: (\S+)}, 1]
      code = text[/and enter: (\S+)/, 1]
      if uri.nil? && Process.waitpid(@cli_pid, Process::WNOHANG)
        E2E::ProcessRegistry.unregister(@cli_pid)
        @cli_pid = nil
        flunk("rho connect exited (#{$?}) before printing the code:\n#{text}")
      end
      uri && code ? { "verification_uri_complete" => uri, "user_code" => code } : nil
    end
    # The shipped CLI's ceremony is the daemon's: full mode, the combined
    # page with the sentence; the CLI itself waits the daemon out.
    E2E::Ceremony.confirm(actor: @actor, started: started.merge("branch" => "combined"))

    exit_status = until_ready("rho connect never finished") do
      next unless Process.waitpid(@cli_pid, Process::WNOHANG)

      E2E::ProcessRegistry.unregister(@cli_pid)
      @cli_pid = nil
      $?
    end
    output = File.read(out_path, encoding: Encoding::UTF_8)
    assert_predicate exit_status, :success?, "rho connect must exit 0, printed:\n#{output}"
    connected = output[/^Connected as .*$/]
    refute_nil connected, "rho connect never reported who this machine became:\n#{output}"
    # The last line names what got paired, per mode (r-modes S-2): a full
    # home names its agent AND its runner.
    assert_match(/runner /, connected, "a full-mode connect names the runner it paired: #{connected}")
    assert_match(/\(private to you\)\.$/, connected)

    reported, cli_status = run_cli("status", "--nexus-url", @base_url)
    assert_equal 0, cli_status
    assert_match(/daemon:    running at http/, reported)
    assert_match(/mode:      full/, reported, "the mode is the second line a person reads:\n#{reported}")
    assert_match(/state:     signed in/, reported)
    assert_match(/^runner:    \S+ serving \d+ tools/, reported, "local truth about this machine's runner:\n#{reported}")

    # THE SHIPPED VERBS, UNPAID. Every one of these is a local read the
    # daemon answers from what it already holds — nothing crosses to a
    # model — so they cost nothing to prove here, and what they prove is
    # that exe/rho dispatches each verb to a running daemon and prints its
    # header line.
    following, cli_status = run_cli("loops", "--nexus-url", @base_url)
    assert_equal 0, cli_status, following
    assert_match(/^\(this daemon is following no loops\)/, following, following)

    processes, cli_status = run_cli("processes", "--nexus-url", @base_url)
    assert_equal 0, cli_status, processes
    assert_match(/^\(no processes\)/, processes, processes)

    runner, cli_status = run_cli("runner", "--nexus-url", @base_url)
    assert_equal 0, cli_status, runner
    assert_match(/^(?:tools|runner):\s/, runner, runner)

    # `retry` is a Ruby keyword, so its Thor verb is the one most likely
    # to go missing in a reshape; `help retry` proves the command is
    # registered under that name. (`rho retry --help` is not a help
    # request to this Thor — it reads `--help` as the LOOP_ID.)
    helped, cli_status = run_cli("help", "retry")
    assert_equal 0, cli_status, helped
    assert_match(/rho retry LOOP_ID/, helped, helped)
  end

  private

    # ---- a second daemon, the rho steward's ----

    # The loop-door case reads the workspace through the MEMBER plane, and
    # the founding owner this file signs in as holds no member token: the
    # steward the world provisions does, so that case runs a daemon of its
    # own, confirmed by the steward in a browser of their own, in a home of
    # its own — the harness's `RhoDaemon`, as every rho journey since uses.
    def steward_daemon!
      world = E2E::ActorProvisioning.world(@base_url)
      steward = world.rho_steward
      @steward_actor = E2E::StewardSession.actor(base_url: @base_url, human: steward)

      @steward_home = Dir.mktmpdir("rho-e2e-steward")
      @steward_daemon = E2E::RhoDaemon.new(base_url: @base_url, home: @steward_home)
      @steward_daemon.start
      E2E::Ceremony.confirm(actor: @steward_actor, started: @steward_daemon.start_ceremony,
        status: -> { @steward_daemon.status })
      adopted = @steward_daemon.await("the steward's daemon never adopted a workspace") do
        document = @steward_daemon.status
        workspace = document["workspace"]
        flunk "workspace error: #{workspace["code"]}" if workspace&.fetch("state") == "error"

        workspace&.fetch("state") == "adopted" ? document : nil
      end
      [@steward_daemon, steward, adopted.dig("workspace", "public_id")]
    end

    # Paced: the member plane admits 120 loop reads a minute per caller, and
    # every rho journey reads as the same steward.
    MEMBER_POLL = 1

    def member_poll(message)
      latest = nil
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + READY_TIMEOUT
      loop do
        latest = yield
        return latest if latest
        flunk "#{message}; last seen #{latest.inspect}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep MEMBER_POLL
      end
    end

    # UTF-8 by name: the test process inherits the machine's empty locale.
    def member_read(steward, path)
      uri = URI.join(@base_url, path)
      request = Net::HTTP::Get.new(uri)
      request["Authorization"] = "Bearer #{steward.member_token}"
      response = Net::HTTP.start(uri.hostname, uri.port) { |http| http.request(request) }
      JSON.parse(response.body.force_encoding(Encoding::UTF_8))
    end

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

    # A CLI verb run to completion, as `cli_command_test.rb` runs it in the
    # unit suite — but here in rho's own bundle against the live daemon.
    # `stdin:` is not a convenience: a provider key may ONLY arrive that
    # way, because an argument is in the shell's history, in `ps`, and in
    # any log that records a command line.
    def run_cli(*argv, stdin: nil)
      mode = stdin.nil? ? "r" : "r+"
      out = IO.popen(
        CHILD_BUNDLE_ENV.merge(E2E::RhoDaemon::CHILD_DEV_ENV).merge("RHO_HOME" => @home),
        [Gem.ruby, Gem.bin_path("bundler", "bundle"), "exec", "ruby", "exe/rho", *argv],
        mode, chdir: RHO_ROOT, err: [:child, :out]
      ) do |io|
        unless stdin.nil?
          io.write(stdin)
          io.close_write
        end
        io.read
      end
      [out, $?.exitstatus]
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

    def one_shot(public_id)
      control(:get, "/one_shots").fetch("one_shots").find { _1.fetch("public_id") == public_id }
    end

    def await_workspace(state)
      until_ready("the daemon never adopted a workspace") do
        document = status["workspace"]
        document if document && document["state"] == state
      end
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
      assert @page.has_text?("Dashboard"), "the owner's session did not reach the dashboard"
    end

    def remove_profile_in_console(profile)
      @actor.visit("/agents/#{profile}")
      @page.click_button "Remove"
      @page.find("#turbo-confirm button[value='confirm']").click

      assert @page.has_text?("Profile removed.")
      assert @page.has_text?("This profile is removed")
    end

    # The registration is member-owned: a steward ends it from their own console, and there is
    # deliberately no administrator counterpart. An Agent is single-instance, so the page offers
    # exactly one revoke.
    def revoke_registration_in_console(profile)
      @actor.visit("/agents/#{profile}")
      assert @page.has_css?("[data-address-id]", count: 1),
        "one Agent, one address — the console must not offer a list to choose from"
      button = @page.find("button[aria-label^='Revoke credentials'], input[aria-label^='Revoke credentials']")
      button.click
      # Turbo's confirmation is a DOM dialog here, not window.confirm, and its
      # confirm branch repeats the verb of the button that opened it — so it is
      # found by value rather than by text.
      @page.find("#turbo-confirm button[value='confirm']").click

      assert @page.has_text?("Not registered"), "the revoked address must be gone from the console"
    end
end
