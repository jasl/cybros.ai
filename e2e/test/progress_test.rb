require "test_helper"
require "cgi/escape"
require "fileutils"
require "json"
require "monitor"
require "securerandom"
require "tmpdir"
require "time"
require "cybros_agent/realtime"
require "support/actor_provisioning"
require "support/ceremony"
require "support/device_authorization_budget"
require "support/rho_daemon"
require "support/secret_hygiene"
require "support/steward_session"

# THE EXECUTOR PROGRESS FEED: what an executor is doing RIGHT NOW rides the host's `progress` feed
# as EPHEMERAL FRAMES — a `bash` tail posted under the call's claim, a process's output posted under
# the conversation's binding — stored nowhere, replayed never, one frame per key per interval. ONE
# full-mode rho daemon is BOTH producers (its runner's `bash` and its Processes pump); the SHIPPED
# realtime client is the subscriber, through `conversation.progress(realtime:)`; the kernel's stamps
# are what is read. The fences' negatives (`not_claimant`, `not_bound`, `frame_too_large`, a settled
# row) are the nexus controller suite's — no grant, no world.
#
# ONE CEREMONY PER FILE (the `processes` shape): one daemon, one RHO_HOME,
# one grant. The daemon's process pump runs under the harness knob
# `RHO_PROGRESS_INTERVAL_MS=20` — FASTER than the kernel admits — so the
# per-key bound the subscriber observes is the KERNEL's, never the pump's.
class ProgressTest < Minitest::Test
  MODEL = "dev/mock-text".freeze
  POLL = 1
  AWAIT_SECONDS = 90
  # The kernel's cadence floor, read off the pack rather than restated.
  MIN_INTERVAL_MS = JSON.parse(File.read(
    File.expand_path("../../contracts/nexus/v1/size_bounds.json", __dir__), encoding: Encoding::UTF_8
  )).fetch("progress_min_interval_ms")
  # A call that prints for ~3 s: several tails under one claim.
  TICKING = "for i in 1 2 3 4 5 6 7 8; do echo tick $i; sleep 0.4; done".freeze
  # A server that keeps printing long after the turn ended: frames under
  # the conversation's binding with no claim anywhere.
  SERVER = "for i in $(seq 1 400); do echo srv $i; sleep 0.25; done".freeze
  # Twenty lines inside 200 ms on one key: the burst the kernel bounds.
  BURST_COUNT = 20
  BURST = "for i in $(seq 1 #{BURST_COUNT}); do echo burst $i; sleep 0.01; done; sleep 120".freeze
  AT = /\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z\z/

  World = Struct.new(:daemon, :home, :steward, :actor, :workspace_public_id, keyword_init: true)

  class << self
    attr_reader :world

    def boot_world!(base_url)
      steward = E2E::ActorProvisioning.world(base_url).rho_steward
      actor = E2E::StewardSession.actor(base_url: base_url, human: steward)
      home = Dir.mktmpdir("rho-progress-e2e")
      daemon = E2E::RhoDaemon.new(base_url: base_url, home: home, env: { "RHO_PROGRESS_INTERVAL_MS" => "20" })
      @world = World.new(daemon: daemon, home: home, steward: steward, actor: actor)
      daemon.start
      E2E::Ceremony.confirm(actor: actor, started: daemon.start_ceremony, status: -> { daemon.status })
      @world.workspace_public_id = await_workspace_adopted(daemon)
      E2E.enable_dev_lane!
      E2E.hosts.start
      @world
    end

    def await_workspace_adopted(daemon)
      daemon.await("the daemon never reported workspace adopted") do
        document = daemon.status
        workspace = document["workspace"]
        raise "the daemon reported a workspace error: #{workspace["code"]}" if workspace&.fetch("state") == "error"

        workspace&.fetch("state") == "adopted" ? workspace.fetch("public_id") : nil
      end
    end

    def stop_world!
      world = @world
      @world = nil
      return if world.nil?

      begin
        world.daemon&.stop
      rescue StandardError => error
        warn "Could not stop the rho daemon: #{error.class}: #{error.message}"
      end
      FileUtils.remove_entry(world.home) if world.home && File.directory?(world.home)
    end
  end

  Minitest.after_run { ProgressTest.stop_world! }

  # THE SHIPPED SUBSCRIBER, on its own thread and reactor: the frames a
  # blocking CLI call would otherwise leave to pile up in the socket's
  # buffer are drained as they arrive. Stopped by closing the client from
  # inside its reactor.
  class Subscriber
    attr_reader :frames

    def initialize(base_url:, credential:, workspace_public_id:, conversation_public_id:)
      @frames = []
      @monitor = Monitor.new
      @stop = false
      @ready = Thread::Queue.new
      @thread = Thread.new do
        Sync do
          endpoint = CybrosAgent::Realtime::Endpoint.new(base_url: base_url, credential: credential)
          client = CybrosAgent::Realtime::Client.new(endpoint: endpoint)
          context = CybrosAgent::Client.new(base_url: base_url, credential: credential)
            .workspace(workspace_public_id).conversation(conversation_public_id)
          subscription = context.progress(realtime: client).call
          pump = Async { subscription.each { |frame| @monitor.synchronize { @frames << frame } } }
          @ready << true
          sleep 0.1 until @stop
          client.close
          begin
            pump.wait
          rescue StandardError
            nil
          end
        end
      end
      @ready.pop
    end

    def snapshot = @monitor.synchronize { @frames.dup }

    def stop
      @stop = true
      @thread.join(10)
      snapshot
    end
  end

  def setup
    @base_url = E2E.base_url
    @world = self.class.world || self.class.boot_world!(@base_url)
    @daemon = @world.daemon
    @steward = @world.steward
    @workspace_public_id = @world.workspace_public_id
    @client = CybrosAgent::Client.new(base_url: @base_url, credential: @steward.member_token)
    @workspace = @client.workspace(@workspace_public_id)
    @subscribers = []
  end

  def teardown
    @subscribers.each(&:stop)
    return if passed?

    warn_log(@daemon&.log_path, "rho daemon stdout")
    warn_log(@daemon&.rho_log_path, "rho structured log")
    %i[runner jobs].each do |host|
      warn_log(E2E.hosts.log_path(host), "nexus #{host}")
    rescue StandardError
      nil
    end
  rescue StandardError => error
    warn "Could not capture the progress E2E logs: #{error.class}: #{error.message}"
  end

  # TURN 1 opens the conversation. Subscribed through the shipped client,
  # TURN 2 runs a printing `bash` (tails under its claim), starts a server
  # (lines under the conversation's binding, long after the turn) and a
  # burst printer (the kernel's per-key bound): (1) every frame arrives as
  # a `ProgressFrame` with the kernel's stamps; (2) a subscriber that joins
  # later sees only what follows; (3) the burst's key yields frames at
  # least one interval apart, carrying only lines the pump posted; (4) the
  # primary's rows do not move while the frames flow and the cable's do;
  # (5) `rho watch` prints the frames indented under their keys.
  def test_the_frames_reach_a_subscriber_with_the_kernels_stamps_bounded_per_key_and_stored_nowhere
    conversation, _turn, loop_one = rho_do(script(["bash", { "command" => "echo warm" }]))
    await_loop_status(loop_one, "completed")

    early = subscribe(conversation)
    said, status = @daemon.cli("say", conversation, script(
      ["bash", { "command" => TICKING }],
      ["start_process", { "command" => SERVER, "name" => "srv" }],
      ["start_process", { "command" => BURST, "name" => "burst" }],
      answered: 1
    ))
    assert_predicate status, :success?, "rho say failed:\n#{said}"
    loop_two = await_next_loop(conversation, after: loop_one)
    # (5) THE VERB, started while the call runs: `rho watch` on the loop
    # the daemon now follows, reading the frames as they land. Its
    # patience is the file's (`AWAIT_SECONDS`), not a shorter one: a wake
    # the kernel loses is recovered by its minute floor (the recurring
    # sweeps), and a watcher that gives up under that floor pins the
    # kernel's latency, never the verb's output.
    await("the daemon never followed #{loop_two}") do
      Array(@daemon.control(:get, "/loops")["loops"]).any? { |row| Array(row["loops"]).include?(loop_two) } || nil
    end
    watcher = @daemon.cli_background("watch", loop_two, "--timeout", AWAIT_SECONDS.to_s)
    row = await_loop_status(loop_two, "completed")
    bash_key = tool_task(row, "bash").key
    server_id = process_id(loop_two, tool_task(row, "start_process").key)
    burst_id = process_id(loop_two, row.tasks.select { |task| task.tool_name == "start_process" }.last.key)
    claimant = @workspace.agent_loop(loop_two).task(bash_key).task.claimed_by&.executor_public_id
    refute_nil claimant, "the bash call was claimed by the daemon's runner"
    assert_equal @daemon.status.dig("identity", "runner_executor_public_id"), claimant,
      "the daemon's own runner row is the claimant, and the stamp below names it"

    # (1) THE STAMPS, off the shipped projection — no test double.
    tails = await("no bash tail reached the subscriber") { some(frames_of(early, "executor_progress") { |f| f.task_key == bash_key }) }
    tails.each do |frame|
      assert_instance_of CybrosAgent::Api::ProgressFrame, frame
      assert_equal [loop_two, bash_key, "bash", claimant],
        [frame.agent_loop_public_id, frame.task_key, frame.tool_name, frame.executor_public_id]
      assert_match AT, frame.at, "the kernel stamps `at` to the millisecond"
      assert_match(/tick \d/, frame.text_tail.to_s)
    end
    assert_operator tails.length, :>=, 2, "a call printing for three seconds posts more than one tail: #{tails.map(&:text_tail).inspect}"
    lines = await("no server line reached the subscriber") { server_lines(early, server_id) }
    server_frames = frames_of(early, "process_output") { |f| f.process_id == server_id }
    server_frames.each do |frame|
      assert_equal [conversation, server_id, claimant],
        [frame.conversation_public_id, frame.process_id, frame.executor_public_id]
      assert_nil frame.agent_loop_public_id, "a process frame is keyed by its HOST, never a claim"
      assert_match AT, frame.at
    end
    assert_includes lines, "srv 1", "the first subscriber saw the server's first line: #{lines.first(5).inspect}"

    # (2) A LATE SUBSCRIBER SEES WHAT FOLLOWS: nothing replays.
    seen_before = server_lines(early, server_id).map { |line| line[/\d+/].to_i }.max
    late = subscribe(conversation)
    late_lines = await("no server line reached the late subscriber") { server_lines(late, server_id) }
    refute_includes late_lines, "srv 1"
    assert_operator late_lines.map { |line| line[/\d+/].to_i }.min, :>, seen_before,
      "the late subscriber's first line follows what the early one had seen: #{late_lines.first(3).inspect}"

    # (3) THE PER-KEY BOUND IS THE KERNEL'S: the pump posted the burst's twenty lines at 20 ms; the
    # feed carries them at most one frame per `min_interval_ms`. The gap invariant is the pin; how
    # many frames or lines the window admits depends on the host's clock against the pump's (a count
    # over a fixed real-time window — measured over a fixed real-time window), so the counts are
    # bounded by what the pump posted, never by the window.
    await("no burst frame reached the subscriber") { some(frames_of(early, "process_output") { |f| f.process_id == burst_id }) }
    sleep 1
    burst_frames = frames_of(early, "process_output") { |f| f.process_id == burst_id }
    stamps = burst_frames.map { |frame| Time.iso8601(frame.at) }
    gaps = stamps.each_cons(2).map { |a, b| ((b - a) * 1000).round }
    assert gaps.all? { |gap| gap >= MIN_INTERVAL_MS }, "≤ 1 frame per key per #{MIN_INTERVAL_MS} ms; gaps #{gaps.inspect}"
    burst_lines = burst_frames.flat_map(&:lines).grep(/\Aburst \d+\z/)
    posted = (1..BURST_COUNT).map { |i| "burst #{i}" }
    assert_equal burst_lines, burst_lines & posted,
      "every burst line the feed carries is one the pump posted, and none twice: #{burst_lines.inspect}"
    assert_operator burst_frames.length, :<=, BURST_COUNT, "no more frames than posts: #{burst_frames.length}"

    # (4) NOTHING IS STORED: while the server's frames flow and nothing else
    # happens, the primary's rows stand and the cable's grow. THE RECEIVED
    # WINDOW SITS INSIDE THE COUNTED ONE, by construction: a count is a
    # `bin/rails runner` (`table_counts!`) read mid-process, and the cable
    # delivers a row's frame AFTER its insert, in insertion order — so the
    # baseline tally is read only once a frame stamped after the first
    # count returned has arrived (every row inserted before that count is
    # delivered by then), and the second tally is read BEFORE the second
    # count (a received frame's row is already there). Read the other way,
    # a frame delivered between the second count and its tally is received
    # with its row outside the window (12 received, 11 rows; under load,
    # 2026-09-14).
    before_counts = E2E.operator.table_counts!
    counted_at = Time.now
    await("no frame stamped after the first count reached the subscriber") do
      some(early.snapshot.select { |frame| Time.iso8601(frame.at) > counted_at })
    end
    before_frames = early.snapshot.length
    sleep 2
    received = early.snapshot.length - before_frames
    after_counts = E2E.operator.table_counts!
    assert_operator received, :>=, 2, "the server kept printing through the window"
    %w[agent_loop_nodes conversation_event_items content_bodies].each do |table|
      assert_equal before_counts.fetch(table), after_counts.fetch(table), "#{table} moved across a frames-only window"
    end
    assert_operator after_counts.fetch("solid_cable_messages") - before_counts.fetch("solid_cable_messages"), :>=, received,
      "the cable database grows by the accepted frames (#{received} received)"

    # (5) THE VERB: `rho watch` printed the frames indented under the key
    # that produced them — the call's tail under its task key, the
    # server's lines under its process id — beside the task table.
    watched = watcher.read.to_s.force_encoding(Encoding::UTF_8).scrub
    watcher.close
    assert_predicate $?, :success?, "rho watch failed:\n#{watched}"
    assert_match(/^  #{Regexp.escape(bash_key)}\s+│ tick \d$/, watched, watched)
    assert_match(/^  #{Regexp.escape(server_id)}\s+│ srv \d+$/, watched, watched)
    assert_match(/^status:\s+completed$/, watched, watched)
  ensure
    @daemon.cli("kill", server_id) if server_id
    @daemon.cli("kill", burst_id) if burst_id
  end

  private

    def script(*calls, answered: 0)
      padded = [calls.first] * answered + calls
      encoded = padded.map { |name, arguments| "#{name}:#{CGI.escape(JSON.generate(arguments))}" }
      "!mock tool_call=#{encoded.join(",")} -- run what the script says"
    end

    def rho_do(prompt)
      output, status = @daemon.cli("do", prompt, "--model", MODEL, "--dir", project)
      assert_predicate status, :success?, "rho do failed:\n#{output}"
      ids = %w[conversation turn loop].map { |line| output[/^#{line}:\s+(\S+)/, 1] }
      refute_includes ids, nil, "rho do printed fewer than three ids:\n#{output}"
      ids
    end

    def project
      @project ||= File.join(@world.home, "project").tap { |dir| FileUtils.mkdir_p(dir) }
    end

    def subscribe(conversation)
      Subscriber.new(base_url: @base_url, credential: @steward.member_token,
        workspace_public_id: @workspace_public_id, conversation_public_id: conversation).tap { |s| @subscribers << s }
    end

    def frames_of(subscriber, type, &filter)
      subscriber.snapshot.select { |frame| frame.type == type && (filter.nil? || filter.call(frame)) }
    end

    def server_lines(subscriber, id)
      some(frames_of(subscriber, "process_output") { |f| f.process_id == id }.flat_map(&:lines).grep(/\Asrv \d+\z/))
    end

    # `await`'s word for "not yet": an empty list is nil.
    def some(list) = list.empty? ? nil : list

    def agent_loop(loop_id) = @workspace.agent_loop(loop_id)

    def tool_task(row, name)
      row.tasks.find { |task| task.kind == "tool_task" && task.tool_name == name } ||
        flunk("the mock never called #{name}: #{row.tasks.map { |t| "#{t.kind}/#{t.tool_name}/#{t.status}" }.inspect}")
    end

    # The id `start_process` answered: `pN (pid …) running — name`.
    def process_id(loop_id, key)
      output = agent_loop(loop_id).task(key).output.to_s
      output[/\A(p\d+) \(pid \d+\) running/, 1] || flunk("start_process did not answer a running id:\n#{output}")
    end

    def await_loop_status(loop_id, status)
      await("the loop #{loop_id} never reached #{status}", every: POLL) do
        row = agent_loop(loop_id).fetch
        flunk "the loop #{loop_id} failed: #{row.failure_reason.inspect}" if row.status == "failed"
        row if row.status == status
      end
    end

    def await_next_loop(conversation, after:)
      known = Array(after)
      chat = @workspace.conversations.conversation(conversation)
      await("no turn after #{known.join(", ")} started on #{conversation}", every: POLL) do
        chat.turns.list.items.filter_map { |turn| turn.active_variant&.agent_loop_public_id }
          .find { |loop_id| !known.include?(loop_id) }
      end
    end

    def await(message, every: 0.2)
      latest = nil
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + AWAIT_SECONDS
      loop do
        latest = yield
        return latest if latest
        flunk "#{message}; last seen #{latest.inspect}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep every
      end
    end

    def warn_log(path, label)
      return unless path && File.file?(path)

      warn "---- #{label} (#{path}) ----"
      warn File.read(path, encoding: Encoding::UTF_8).lines.last(80).join
    end
end
