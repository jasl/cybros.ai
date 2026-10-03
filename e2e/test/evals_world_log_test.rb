require "test_helper"
require "support/evals"
require "support/secret_hygiene"
require "tmpdir"

# THE WORLD'S LOG PER PAID RUN, PINNED: the sources are named flat so two homes' `daemon.log` cannot
# collide, every log a run copies — the hosts' stdout logs, the world's own Rails logs (one file per
# process under the run root, never rotated), the daemon's pair — rides as the RUN'S WINDOW from a
# mark taken before the turn, since one world and one home serve a whole label; `sources` stays the
# whole-copy list for a caller that wants every line; every copy is REDACTED, and a source that is
# not there is listed in the MANIFEST rather than raised. Pure Ruby over a tmpdir.
class EvalsWorldLogTest < Minitest::Test
  L = E2E::Evals::WorldLog
  D = E2E::Evals::Drawing
  Home = Struct.new(:log_path, :rho_log_path)

  def test_the_sources_are_the_worlds_logs_then_both_homes_named_flat_and_the_rails_logs_are_windows
    Dir.mktmpdir("evals-world-log") do |root|
      log_dir = File.join(root, "world")
      FileUtils.mkdir_p(log_dir)
      %w[server.log model_runner.log jobs.log rails.log jobs.rails.log model_runner.rails.log].each do |name|
        File.write(File.join(log_dir, name), "#{name}\n")
      end
      File.write(File.join(log_dir, "operator.json"), "{}")
      daemon = Home.new(File.join(root, "home", "daemon.log"), File.join(root, "home", "log", "rho.log"))
      runner = Home.new(File.join(root, "runner", "daemon.log"), File.join(root, "runner", "log", "rho.log"))
      sources = L.sources(handle: { "log_dir" => log_dir }, daemon: daemon, runner: runner)
      assert_equal %w[nexus.jobs.log nexus.model_runner.log nexus.server.log daemon.log rho.log runner.daemon.log runner.rho.log],
        sources.keys, "the Rails logs are not whole sources"
      assert_equal daemon.rho_log_path, sources["rho.log"]
      assert_equal runner.log_path, sources["runner.daemon.log"]
      assert_equal %w[nexus.jobs.log nexus.model_runner.log nexus.server.log daemon.log rho.log],
        L.sources(handle: { "log_dir" => log_dir }, daemon: daemon).keys
      # The per-process Rails logs are the world's own files under the run
      # root, each marked at its size now — never a window of the
      # checkout's shared log.
      windows = L.rails_windows(handle: { "log_dir" => log_dir })
      assert_equal %w[nexus.jobs.rails.log nexus.model_runner.rails.log nexus.rails.log], windows.map(&:name)
      assert_equal File.join(log_dir, "jobs.rails.log"), windows.first.path
      assert_equal "jobs.rails.log\n".bytesize, windows.first.from
      assert_equal 0, L.mark("nexus.rails.log", File.join(log_dir, "absent.rails.log")).from, "a file not there yet is marked at 0"
      refute_respond_to L, :development_log, "the shared checkout log is not a source any more"
      # EVERY LOG A RUN COPIES, marked now under the name its whole copy would take: the sources in
      # their order, then the Rails logs.
      marked = L.windows(handle: { "log_dir" => log_dir }, daemon: daemon, runner: runner)
      assert_equal sources.keys + windows.map(&:name), marked.map(&:name)
      assert_equal sources.values + windows.map(&:path), marked.map(&:path)
      assert_equal "server.log\n".bytesize, marked.find { |window| window.name == "nexus.server.log" }.from
      assert_equal [0, 0], marked.select { |window| window.name.end_with?("daemon.log") }.map(&:from),
        "a home's log not there yet is marked at 0"
    end
  end

  # ONE WORLD AND ONE DAEMON HOME SERVE A WHOLE LABEL: the hosts' stdout logs grow for the world's
  # life and the daemon opens `daemon.log` in append mode, so a whole copy of sample N would hold
  # samples 1..N. Every log is the run's window instead: each run's copy is its own lines — never
  # the world's boot, never an earlier run's — and its MANIFEST names the byte it starts from.
  def test_each_runs_copy_of_one_worlds_and_one_homes_logs_holds_only_that_runs_lines
    Dir.mktmpdir("evals-world-log") do |root|
      log_dir = File.join(root, "world")
      FileUtils.mkdir_p([log_dir, File.join(root, "home", "log")])
      daemon = Home.new(File.join(root, "home", "daemon.log"), File.join(root, "home", "log", "rho.log"))
      logs = { "nexus.server.log" => "server.log", "nexus.model_runner.log" => "model_runner.log",
               "nexus.jobs.rails.log" => "jobs.rails.log" }.transform_values { |name| File.join(log_dir, name) }
               .merge("daemon.log" => daemon.log_path, "rho.log" => daemon.rho_log_path)
      logs.each_value { |path| File.write(path, "the boot of #{File.basename(path)}\n") }

      copies = %w[first second].map do |run|
        windows = L.windows(handle: { "log_dir" => log_dir }, daemon: daemon)
        logs.each_value { |path| File.write(path, "the #{run} run on #{File.basename(path)}\n", mode: "a") }
        L.copy(into: File.join(root, run), sources: {}, windows: windows)
        File.join(root, run)
      end

      copies.zip(%w[first second]).each do |into, run|
        logs.each do |name, path|
          assert_equal "the #{run} run on #{File.basename(path)}\n", File.read(File.join(into, name), encoding: Encoding::UTF_8),
            "the #{run} run's #{name} is that run's own lines"
        end
      end
      manifest = File.read(File.join(copies.last, L::MANIFEST), encoding: Encoding::UTF_8)
      logs.each do |name, path|
        from = "the boot of #{File.basename(path)}\nthe first run on #{File.basename(path)}\n".bytesize
        assert_includes manifest, "#{name}: window from byte #{from}\n"
      end
    end
  end

  # WHAT NO RUN'S WINDOW HOLDS IS COPIED ONCE: the world booted before the lane's process, so its
  # logs as the first group opens are its boot, copied whole ONCE (`boot.world`); a group's opening
  # — the hosts' start in the first group, the ceremony's requests, the daemon's and the runner's
  # boot — lands before the group's first run marks its windows, so it is copied from the world's
  # marks taken before the group opened (a log that appeared since, from its top) and the homes'
  # pair whole, each home being the group's own. Every line of a log lands in exactly one copy.
  def test_the_worlds_boot_once_and_each_groups_opening_hold_what_no_runs_window_does
    Dir.mktmpdir("evals-world-log") do |root|
      log_dir = File.join(root, "world")
      handle = { "log_dir" => log_dir }
      world = ->(name) { File.join(log_dir, name) }
      append = lambda do |path, line|
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, "#{line}\n", mode: "a")
      end
      %w[bun_install.log rails_db_prepare.log server.log rails.log].each { |name| append.(world.(name), "the world's boot") }

      homes = %w[first second].to_h do |group|
        opening = L.world_windows(handle: handle)
        L.copy(into: File.join(root, "boot.world"), sources: L.world_sources(handle: handle)) if group == "first"
        home = Home.new(File.join(root, group, "daemon.log"), File.join(root, group, "log", "rho.log"))
        %w[model_runner.log model_runner.rails.log].each { |name| append.(world.(name), "the hosts' start") } if group == "first"
        append.(world.("server.log"), "the #{group} group's ceremony")
        [home.log_path, home.rho_log_path].each { |path| append.(path, "the #{group} daemon's boot") }
        L.copy(into: File.join(root, "boot.#{group}"), sources: L.home_sources(daemon: home),
          windows: L.since(opening, handle: handle))
        windows = L.windows(handle: handle, daemon: home)
        [world.("server.log"), world.("model_runner.rails.log"), home.log_path].each { |path| append.(path, "the #{group} group's run") }
        L.copy(into: File.join(root, "run.#{group}"), sources: {}, windows: windows)
        [group, home]
      end

      read = ->(dir, name) { File.read(File.join(root, dir, name), encoding: Encoding::UTF_8) }
      assert_equal %w[MANIFEST nexus.bun_install.log nexus.rails.log nexus.rails_db_prepare.log nexus.server.log],
        Dir.children(File.join(root, "boot.world")).sort, "the world's boot is its own logs, whole, before any host started"
      assert_equal "the world's boot\n", read.("boot.world", "nexus.server.log")
      assert_equal "the first group's ceremony\n", read.("boot.first", "nexus.server.log")
      assert_equal "the hosts' start\n", read.("boot.first", "nexus.model_runner.rails.log"), "a log the opening created is copied from its top"
      assert_equal "", read.("boot.second", "nexus.model_runner.log"), "the hosts start once per process"
      assert_equal "the second daemon's boot\n", read.("boot.second", "rho.log")
      %w[boot.world boot.first run.first boot.second run.second].then do |order|
        { "nexus.server.log" => world.("server.log"), "nexus.model_runner.rails.log" => world.("model_runner.rails.log") }.each do |name, path|
          assert_equal File.read(path), order.filter_map { |dir| File.file?(File.join(root, dir, name)) && read.(dir, name) }.join,
            "every line of #{name} is in exactly one copy"
        end
      end
      homes.each do |group, home|
        assert_equal File.read(home.log_path), read.("boot.#{group}", "daemon.log") + read.("run.#{group}", "daemon.log"),
          "the #{group} daemon's boot is its opening's, its run's lines the run's"
      end
    end
  end

  def test_copies_are_redacted_whole_a_window_is_the_runs_own_lines_and_a_missing_source_is_listed_not_raised
    Dir.mktmpdir("evals-world-log") do |root|
      secret = E2E::SecretHygiene.register("evals-secret-#{SecureRandom.hex(6)}")
      source = File.join(root, "server.log")
      File.write(source, "boot ok\nbearer #{secret} used\ntoken sk-cybros-member-v1-abcdef\n")
      rails_log = File.join(root, "rails.log")
      File.write(rails_log, "before the run\n")
      window = L.mark("nexus.rails.log", rails_log)
      File.write(rails_log, "the run's own lines\nbearer #{secret} again\n", mode: "a")
      into = File.join(root, "copied")
      written = L.copy(into: into, sources: { "nexus.server.log" => source, "rho.log" => File.join(root, "absent.log") },
        windows: [window, L.mark("nexus.jobs.rails.log", File.join(root, "absent.rails.log"))])
      assert_equal [File.join(into, "nexus.server.log"), File.join(into, "nexus.rails.log")], written
      text = File.read(File.join(into, "nexus.server.log"), encoding: Encoding::UTF_8)
      refute_includes text, secret
      assert_includes text, "bearer [REDACTED] used"
      assert_includes text, "token [REDACTED]"
      assert_equal "the run's own lines\nbearer [REDACTED] again\n", File.read(File.join(into, "nexus.rails.log"), encoding: Encoding::UTF_8),
        "a Rails log is copied from its mark: the run's own lines, redacted"
      manifest = File.read(File.join(into, L::MANIFEST), encoding: Encoding::UTF_8)
      assert_match(/^nexus\.server\.log: \d+ bytes from #{Regexp.escape(source)}$/, manifest)
      assert_includes manifest, "nexus.rails.log: window from byte #{"before the run\n".bytesize}\n"
      assert_includes manifest, "rho.log: skipped (#{File.join(root, "absent.log")} is not a file)"
      assert_includes manifest, "nexus.jobs.rails.log: skipped (#{File.join(root, "absent.rails.log")} is not a file)"
    end
  end

  def test_a_rails_log_shorter_than_its_mark_was_reopened_by_a_restarted_host_and_is_copied_from_its_top
    Dir.mktmpdir("evals-world-log") do |root|
      rails_log = File.join(root, "jobs.rails.log")
      File.write(rails_log, "a long first life of the jobs host\n")
      window = L.mark("nexus.jobs.rails.log", rails_log)
      File.write(rails_log, "fresh\n")
      into = File.join(root, "copied")
      L.copy(into: into, sources: {}, windows: [window])
      assert_equal "fresh\n", File.read(File.join(into, "nexus.jobs.rails.log"), encoding: Encoding::UTF_8)
      assert_includes File.read(File.join(into, L::MANIFEST), encoding: Encoding::UTF_8),
        "nexus.jobs.rails.log: window from byte 0 (reopened under its mark)\n"
    end
  end

  # WAS THE MODEL STREAMING WHEN THE HARNESS STOPPED IT: every frame the kernel broadcast rides the
  # model runner's Rails log as a Solid Cable INSERT (the transcript stream's deltas, the progress
  # stream's `round_started`), hex-escaped, so the loop's frames are read off the window's inserts
  # — never off the `[ActionCable] Broadcasting` lines, which the log truncates. A partial INSERT (a
  # live file's last line) is skipped and counted; a window with no INSERT at all is not read (nil),
  # apart from a loop that has no frame on it.
  def test_in_flight_reads_the_loops_frames_off_the_solid_cable_inserts
    Dir.mktmpdir("evals-world-log") do |root|
      t0 = Time.utc(2026, 9, 24, 19, 36, 0)
      path = File.join(root, "model_runner.rails.log")
      File.write(path, "a line of the previous run\n")
      window = L.mark(L::MODEL_RUNNER_LOG, path)
      first = cable_insert("progress", t0 - 1, "frame" => { "type" => "round_started", "agent_loop_public_id" => "loop-a", "task_key" => "r1" })
      truncated = cable_insert("transcript", t0 + 6, "event" => { "type" => "text_delta", "agent_loop_public_id" => "loop-a", "task_key" => "r1" })
      File.write(path, [
        first,
        cable_insert("transcript", t0, "event" => { "type" => "reasoning_delta", "agent_loop_public_id" => "loop-a", "task_key" => "r1" }),
        cable_insert("transcript", t0 + 2, "event" => { "type" => "reasoning_delta", "agent_loop_public_id" => "loop-b", "task_key" => "r1" }),
        "[ActionCable] Broadcasting to agent_api:v1:conversation:c-1:transcript: {event: {type: \"reasoning_delta\", agent_loop_pub\n",
        cable_insert("transcript", t0 + 5, "event" => { "type" => "reasoning_delta", "agent_loop_public_id" => "loop-a", "task_key" => "r1" }),
        truncated[0, truncated.index("7b22") + 40],
      ].join, mode: "a")
      stopped_at = (t0 + 17).iso8601(3)

      read = L.in_flight(windows: [L.mark("nexus.rails.log", File.join(root, "rails.log")), window], loop_id: "loop-a", stopped_at: stopped_at)
      assert_equal({ "task_key" => "r1", "frames" => 2, "by_type" => { "reasoning_delta" => 2 },
                     "first_frame_at" => t0.iso8601(6), "last_frame_at" => (t0 + 5).iso8601(6), "last_frame_age_s" => 12.0,
                     "attempts" => 1, "stream_resets" => 0, "unparsed" => 1 }, read)
      assert_nil L.in_flight(windows: [window], loop_id: "loop-a", stopped_at: nil)["last_frame_age_s"], "no stop time, no age"
      unknown = L.in_flight(windows: [window], loop_id: "loop-c", stopped_at: stopped_at)
      assert_equal [0, nil, 1], unknown.values_at("frames", "last_frame_age_s", "unparsed"), "a loop with no frame on the window"

      assert_nil L.in_flight(windows: [L.mark(L::MODEL_RUNNER_LOG, path)], loop_id: "loop-a", stopped_at: stopped_at),
        "a window holding no INSERT is not read"
      assert_nil L.in_flight(windows: [], loop_id: "loop-a", stopped_at: stopped_at), "no model runner window"
      past_the_first = window.with(from: window.from + first.bytesize)
      after = L.in_flight(windows: [past_the_first], loop_id: "loop-a", stopped_at: stopped_at)
      assert_equal [2, nil, 0], after.values_at("frames", "task_key", "attempts"), "a frame before the mark is the previous run's"
      reopened = L.in_flight(windows: [window.with(from: File.size(path) + 1)], loop_id: "loop-a", stopped_at: stopped_at)
      assert_equal read, reopened, "a file shorter than its mark was reopened under it and is read from its top"
    end
  end

  # THE STOP'S TIME, off the feed the trace holds: the primary loop's first `canceling`/`canceled`
  # status — the harness's stop lands before the trace is salvaged — else the latest turn_status,
  # else nil. Never the record's `started_at + seconds`, which covers the settle and the artifact.
  def test_the_traces_stop_time_is_the_primary_loops_cancel_else_the_latest_turn_status
    status = ->(loop_id, word, at) { D.event("turn_status", { "agent_loop_public_id" => loop_id, "loop_status" => word }).merge("occurred_at" => at) }
    graph = D.graph([D.n("r1", "model_task", status: "running")], [])
    events = [status.("loop-1", "running", "2026-09-24T19:26:40.869Z"), status.("loop-2", "canceling", "2026-09-24T19:30:00.000Z"),
              status.("loop-1", "canceling", "2026-09-24T19:36:44.850Z"), status.("loop-1", "canceled", "2026-09-24T19:36:45.105Z")]
    assert_equal "2026-09-24T19:36:44.850Z", D.trace(graph, [], events).stopped_at
    assert_equal "2026-09-24T19:30:00.000Z", D.trace(graph, [], events.first(2)).stopped_at, "another loop's cancel is no stop of the primary"
    assert_nil D.trace(graph, [], [D.event("input_accepted", { "origin" => "person" })]).stopped_at
  end

  private

    # One Solid Cable INSERT line as the model runner's Rails log writes it: the channel and the
    # payload hex-escaped, `created_at` in UTC with no zone.
    def cable_insert(stream, at, payload)
      hex = ->(text) { text.unpack1("H*") }
      "  \e[1m\e[36mSolidCable::Message Insert (0.3ms)\e[0m  \e[1m\e[32mINSERT INTO \"solid_cable_messages\" " \
        "(\"channel\",\"channel_hash\",\"created_at\",\"payload\") VALUES ('\\x#{hex.("agent_api:v1:conversation:c-1:#{stream}")}', " \
        "-2309751435268083693, '#{at.utc.strftime("%Y-%m-%d %H:%M:%S.%6N")}', '\\x#{hex.(JSON.generate(payload))}') " \
        "ON CONFLICT  DO NOTHING RETURNING \"id\" /*application='Nexus'*/\e[0m\n"
    end
end
