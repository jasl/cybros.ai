require "test_helper"
require "support/live_journey"
require "support/evals"
require "json"
require "time"

# THE EVALS RUNNER: one paid lane, booted like every live lane, that runs the selected corpus
# through exe/rho and RECORDS what happened — it measures, it does not gate. Outside test/ on
# purpose: the journey manifest and the sweep's `test/live_*` glob never see it; the Rakefile's
# `evals[glob,model]` sizes the world's patience from the plan and runs this file alone (`rake
# evals_lane_test`).
#
# ONE DAEMON PER CONFIGURATION (the gallery's two-daemons rule): a test
# method per (compaction mode × style × runner_home[× summarizer model][× model under pack]
# [× declared fallback][× image]) the selection needs, defined at load from the plan; its setup
# writes the home's compaction, adaptation and optional fallback settings plus the style's local
# row before the daemon starts (the settings are read at boot), and every run of
# the group goes through that daemon, each in its own project dir.
#
# A CONTAINER FAMILY (terminal-bench, Agents-on- Rails — the tasks name an `image`) runs THROUGH
# THIS SAME LANE: the group builds the derived image once per base (cached by tag: pull → pre-flight
# → build, a failure recorded as `build_failed` on EVERY run of the group, never a lost group),
# pairs the container as the group's runner-mode home (`start_runner_rho!(daemon: Docker::Daemon)`,
# branch B), and each run gets a FRESH container over that home (`restart!`: the image's tree clean,
# the pairing kept — one container per run), the task's `prepare` (the rails patch), the runner's
# tools pointed at the image's WorkingDir, then `rho do <instruction> --dir <workdir> --runner <id>`
# on the HOST's full-mode daemon (its own runner slot stays silent: `point_tools!` on the host is
# never called for these runs), the trace read, the task's `verify_in` (the reward, or their three
# steps) inside the container, and the SAME record shape — `reached`/`succeeded` nil (`—`),
# `task_pass` the one number. `plain` alone (the container's rho streams nothing).
#
# EVERY RUN IS CAUGHT: a driver that raises, a deadline, a cost stop, a red predicate — each is one
# record with its trace salvaged, appended to `runs/<label>/records.jsonl` as it ends; EVERY RUN
# ENDS STOPPED (12a L7: the conversation is stopped once the trace is read, the runner waited idle
# before the next repoint, the spend read AFTER over every loop the feed names), ENDS ITS PROCESSES
# (a group `start_process` left live is killed through `rho kill` once the verification has run)
# and LEAVES NO MEMORY (12a L6: the workspace- and user-scope documents the model wrote are
# deleted, so runs are independent); the full trace (graph, mermaid, tasks, events, spend, the
# summaries' bodies, the sealed request of the last completed round) goes to
# artifacts/evals/<label>/invocation-*/ (git-ignored), the world's logs redacted beside it under `logs/` — the
# run's window, the world's boot once (`boot.world/`) and each group's opening (`boot.<slug>/`), a
# red CONTAINER run's stdout and structured log
# too, read through the container before the home goes (`with_container_evidence`) — and ONE report
# line per run is printed (`ReportLine`). The method asserts at the end that every record was
# WRITTEN, never that every record is green.
#
# Paid, local, opt-in: E2E_LIVE=1; E2E_EVALS_TASKS / _MODELS / _STYLES /
# _RUNS / _LABEL narrow the bench (docs/evals-runbook.md).
class EvalsLaneTest < Minitest::Test
  BENCH = E2E::Evals::Bench.read
  SELECTION = BENCH.subset(ENV)
  CORPUS = E2E::Evals::Corpus.load_all(bench: BENCH)
  RUNS = E2E::Evals::Plan.build(CORPUS, BENCH, SELECTION)
  GROUPS = E2E::Evals::Plan.groups(RUNS)
  ARTIFACTS = File.expand_path("../artifacts/evals", __dir__)

  include E2E::LiveJourney
  include E2E::Evals::MemberPlane
  include E2E::Evals::Pump
  include E2E::Evals::Drivers

  CONFIGURATIONS = GROUPS.keys.to_h { |configuration| ["test_#{configuration.slug}", configuration] }.freeze
  GROUPS.each do |configuration, runs|
    define_method("test_#{configuration.slug}") { run_group(configuration, runs) }
  end

  def self.artifacts
    @artifacts ||= E2E::Evals::Artifacts.new(root: ARTIFACTS, label: SELECTION.label)
  end

  # THE WORLD'S BOOT, copied once per invocation, redacted, under its logs/boot.world/:
  # the world booted before this process (the assets, the database, the server) and outlives every
  # group, so its logs as the first group opens are its boot and the steward's sign-in — in no
  # group's or run's window, and a green world removes its run root. A copy that fails is a warning;
  # the next group tries again.
  def self.copy_world_boot!
    @world_boot ||= E2E::Evals::WorldLog.copy(into: artifacts.logs("boot.world"),
      sources: E2E::Evals::WorldLog.world_sources(handle: E2E.handle))
  rescue StandardError => error
    warn "the world's boot logs could not be copied: #{error.class}: #{error.message}"
  end

  def setup
    @configuration = CONFIGURATIONS[name]
    return if @configuration.nil?

    # EVERY MODEL THE GROUP RUNS gets its provider: one daemon serves the broker's models and the
    # direct DeepSeek floor alike — and every declared refusal fallback, which the kernel refuses
    # to take as a declaration while its provider is off (`Plan.served_models`).
    runs = GROUPS.fetch(@configuration)
    start_live_journey!(runs.first.model, home_prefix: "rho-evals-e2e", models: E2E::Evals::Plan.served_models(runs))
    # THE GROUP'S OPENING is marked on the world's logs once the lane is opted in and before the
    # daemon, the hosts or the keys start, the world's boot copied after the mark — a line written
    # in between lands in both copies, never in neither.
    @opening = E2E::Evals::WorldLog.world_windows(handle: E2E.handle)
    self.class.copy_world_boot!
    # BEFORE THE DAEMON STARTS: the compaction mode and the adaptations knob are read at boot — a
    # preset word is a LOCAL ROW under the home's `adaptations/`, pinned by name; `pack` is the SDK
    # pack's own row for the model, or the gem row plus the candidate.
    write_daemon_home!(settings: @configuration.settings, local_rows: @configuration.local_rows)
  end

  def teardown = finish_live_journey!

  # THE EVALS LANE PRINTS ONE LINE PER RECORD — its verdict and class off
  # `build_record` — never the per-loop teardown line `LiveJourney` prints
  # for a lane that reports nothing itself.
  def reports_own_lines? = true

  # A selection that names no run is a typo'd glob or a model off every
  # selected task's tiers: loud, never an empty green.
  def test_the_selection_names_at_least_one_run
    refute_empty RUNS, "E2E_EVALS_TASKS=#{SELECTION.tasks_glob.inspect} on #{SELECTION.models.inspect} names no run"
  end

  private

    def artifacts = self.class.artifacts

    def run_group(configuration, runs)
      open_group!(configuration, runs)
      puts "\n=== evals: #{runs.size} runs under #{configuration.slug} → #{SELECTION.run_dir}"
      written = runs.map { |run| run_one(run) }
      reds = written.reject { |record| record.dig("verdict", "class").nil? }
      puts "\n#{written.size} records written, #{reds.size} red; artifacts under #{artifacts.directory}"
      assert_equal runs.map(&:key), written.map { |record| E2E::Evals::Records.key(record) }, "every run leaves a record"
    end

    # ONE RUN: its own project dir, its driver, the trace read off the member plane and printed
    # through the binary, the predicate, the verification, the record APPENDED and its line printed,
    # the world's logs. Anything that fails is this run's record — the person's interrupt too: its
    # salvage line lands, then it is re-raised.
    def run_one(run)
      outcome, record = run_and_record(run)
      E2E::Evals::Records.append(SELECTION.run_dir, record)
      puts E2E::Evals::ReportLine.render(record)
      raise outcome[:interrupt] if outcome[:interrupt]

      record
    end

    # THE GROUP OPENS — the daemon paired, the lane priced and opened, the hosts started, the
    # group's runner paired — and its opening is copied, raised or not, before the first run marks
    # its windows.
    def open_group!(configuration, runs)
      connect_and_open_lane!
      start_group_runner!(configuration, runs)
    ensure
      copy_group_opening(configuration)
    end

    # THE GROUP'S OPENING, redacted, under the invocation's logs/boot.<configuration>/: the
    # world's logs from the marks `setup` took (the hosts' start in the process's first group, the
    # ceremony's and the keys' requests) and both homes' pair whole — each home is the group's own,
    # so whole is its boot: the ceremony, the settings and adaptation rows read then. No run's window
    # holds these lines and a green world removes the homes, so this is their one copy. A copy that
    # fails is a warning.
    def copy_group_opening(configuration)
      E2E::Evals::WorldLog.copy(into: artifacts.logs("boot.#{configuration.slug}"),
        sources: E2E::Evals::WorldLog.home_sources(daemon: @daemon, runner: @runner),
        windows: E2E::Evals::WorldLog.since(@opening, handle: E2E.handle))
    rescue StandardError => error
      warn "the group's opening logs could not be copied: #{error.class}: #{error.message}"
    end

    # The group's second home: a container for an image configuration (its
    # runner serves the image's tree), the host's own runner-mode rho for a
    # task that hands off, nothing otherwise.
    def start_group_runner!(configuration, runs)
      if configuration.container?
        @tree_runner = @runner_id = start_container_runner!(configuration, runs.first.task)
      elsif configuration.runner_home
        @runner_id = start_runner_rho!(home_prefix: "rho-evals-runner-e2e")
      end
    end

    # THE CONTAINER RUNNER: the derived image (once per base AND recipe,
    # cached by tag — the app tree's owner is the family's, read off the
    # task's `container_user`, and rides the tag when it is not the
    # default; else pull, pre-flight, build — every line to the artifact's
    # build log) and the image's WorkingDir, then the container paired
    # over a fresh home as the group's runner. A failure anywhere here is
    # the group's `build_failed`: every run records it (plan (2)) and the
    # group ends.
    def start_container_runner!(configuration, task)
      app_owner = E2E::Evals::Docker.app_owner_for(container_user: task.container_user)
      tag = E2E::Evals::Docker.tag_for_base(configuration.image, app_owner: app_owner)
      @image_workdir = task.workdir || ensure_image!(configuration.image, tag, app_owner: app_owner)
      start_runner_rho!(home_prefix: "rho-evals-container-e2e", daemon: lambda { |home|
        # The container's uid (1000 for the rails family) must write the
        # bind-mounted home on a Linux host whose user is another uid.
        File.chmod(0o777, home)
        E2E::Evals::Docker::Daemon.new(base_url: @base_url, home: home, name: "#{tag}-#{Process.pid}",
          port: E2E::Evals::Docker.free_port, tag: tag, task_dir: task.tests_mount, logs_dir: File.join(home, "verifier"),
          user: task.container_user, network: E2E::Evals::Docker.network_for)
      })
    rescue StandardError, Minitest::Assertion => error
      @image_error = "build_failed: #{error.class}: #{error.message.lines.first.to_s.strip[0, 300]}"
      warn @image_error
      nil
    end

    # Pull, pre-flight (apt-get), build — skipped whole when the tag exists —
    # then the WorkingDir off the base; the outputs appended to
    # `logs/<tag>.build.log` under the invocation.
    def ensure_image!(base, tag, app_owner:)
      docker = E2E::Evals::Docker
      log = artifacts.logs("#{tag}.build.log")
      FileUtils.mkdir_p(File.dirname(log))
      unless docker.run!(docker.image_exists_argv(tag)).last.success?
        [docker.pull_argv(base), docker.preflight_argv(base), docker.build_argv(base: base, tag: tag, app_owner: app_owner)].each do |argv|
          output, status = docker.run!(argv)
          File.write(log, "$ #{argv.join(" ")}\n#{output}\n", mode: "a", encoding: Encoding::UTF_8)
          raise "#{argv.first(2).join(" ")} #{base} failed (#{log}):\n#{output.lines.last(20).join}" unless status.success?
        end
      end
      docker.workdir_of(base)
    end

    # THE RUN'S PROCESSES END LAST, once the verification has read the world — a server the task
    # keeps running is what its verifier probes (terminal-bench's kv-store-grpc asks for one "running
    # in the background", and its test checks the port) — and before the next run opens, whatever
    # the run raised (`MemberPlane#end_processes!`: `rho kill` on each home serving tools; the
    # runner-mode home follows no conversation, so its table ends only this way).
    def run_and_record(run)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      started_at = Time.now.utc.iso8601
      task = run.task
      @model = run.model
      # The harness's patience in money is the TASK's (`Bench#cost_stop_usd_for`:
      # its own line under `limits`, else its family's, else the bench's),
      # lowered by the invocation's `E2E_LIVE_COST_STOP_USD` when it names less.
      @cost_stop_usd = SELECTION.cost_stop_usd(BENCH.cost_stop_usd_for(task.name, family: task.family))
      puts "\n--- evals: #{task.name} on #{run.model} (#{run.style}) ##{run.index} -----------------"
      # The run's windows on every log it copies and the runner meters' marks, both taken before
      # the turn opens.
      windows = E2E::Evals::WorldLog.windows(handle: E2E.handle, daemon: @daemon, runner: @runner)
      meters_at_start = meters_now
      seed, project, setup_error = setup_project(run)
      outcome = setup_error ? { trace: E2E::Evals::Trace.empty, stopped: nil, error: setup_error } :
        settled_after_stop(drive(task, project.root, seed))
      outcome = in_flight_of(outcome, windows)
      reset_memory!(outcome[:run])
      # The facts no route serves and every predicate may read: the run's style, model, tier and
      # adaptations row, the refusal fallback it declared (nil when none), the
      # summaries' bodies (the compaction family's pointer rule), the root the tools were pointed
      # at (a call that spells it absolutely searched the whole project), the runner meters'
      # movement over the run (`swept` and `nudged`).
      trace = outcome.fetch(:trace)
      trace = trace.with_facts({ "style" => run.style, "model" => run.model, "adaptations" => @configuration.adaptations_fact,
                                 "summaries" => summaries_of(trace), "root" => project&.root.to_s }
                                 .merge(BENCH.tier_fact(run.model), @configuration.fallback_fact, meter_deltas(meters_at_start)))
      verdict = verdict_of(task, trace)
      verification = verification_of(task, project, seed)
      record = build_record(run, trace, verdict, verification, outcome, started_at: started_at, seconds: elapsed(started))
      record = with_container_evidence(run, record)
      write_artifact(run, trace, record)
      copy_world_logs(run, windows)
      [outcome, record]
    ensure
      end_processes!([@daemon, @runner])
    end

    # THE RUN'S GROUND, before the turn: the seed, the fixture under its own
    # project dir — named by the run's stem, the model in it, and refused
    # when it exists, so no run opens on what another left (a generator
    # that raises — the exit-long corpus writing `<home>/spec-seed`, a
    # shebang chmod — is this run's lane-bug record, never a lost group),
    # the daemon told where the tree is.
    def setup_project(run)
      return setup_container_run(run) if @configuration.container?

      task = run.task
      seed = E2E::Evals::Seed.mint(home: @home, project: File.join(@home, "projects", run.stem), model: run.model)
      project = task.write_environment(File.join(@home, "projects"), run.stem, seed)
      # The previous run's tool calls are done before the ground moves (12a
      # L7): the idle is awaited on `/status` here, because the door judges
      # the directory alone (ACP E1 retired its `work_in_flight` 409) — and
      # a repoint over a running tool once cost every later run of a group
      # as a zero-second record.
      await_runner_idle!([@daemon, @runner])
      point_tools!(@daemon, project.root)
      [seed, project, nil]
    rescue StandardError => error
      [seed, nil, "#{error.class}: #{error.message.lines.first.to_s.strip[0, 300]}"]
    end

    # THE RUN'S GROUND IN A CONTAINER: the group's image error is this run's (a `build_failed`
    # record); else a FRESH container over the paired home with this run's verifier dir (the reward
    # lands in the artifact's `logs/<run>/verifier/`), the GIT-TREE PRE-FLIGHT (a WorkingDir holding
    # a `.git` must answer git as the container's user, else this run is a lane error before the
    # model is asked), the task's own preparation, the RUNNER's tools pointed at the image's
    # WorkingDir. The project is that dir — it lives in the container, and `rho do --dir` only
    # describes it.
    def setup_container_run(run)
      return [nil, nil, @image_error] if @image_error

      task = run.task
      root = task.workdir || @image_workdir
      seed = E2E::Evals::Seed.mint(home: @home, project: root, model: run.model)
      @runner.restart!(logs_dir: artifacts.logs(run.stem, "verifier"))
      @runner.preflight_git_tree!(root)
      task.prepare(@runner)
      point_tools!(@runner, root)
      [seed, ContainerProject.new(root: root), nil]
    rescue StandardError, Minitest::Assertion => error
      [seed, nil, "#{error.class}: #{error.message.lines.first.to_s.strip[0, 300]}"]
    end

    ContainerProject = Data.define(:root)

    # The hidden check: in the lane process against the project dir (the
    # mock corpus), or inside the container (a container family's own
    # verifier, over the image's WorkingDir) — nil when the task has none or
    # the ground never stood.
    def verification_of(task, project, seed)
      return nil unless task.verification && project

      @configuration.container? ? task.verify_in(@runner, workdir: project.root) : task.verify(project, seed)
    end

    # The driver under `caught` (`MemberPlane`: a stop or a raise after
    # the turn opened still traces the opened loop), then the CLI's two
    # debug doors on a run traced whole; the step the driver owes after
    # (`Drivers#after_drive` — the brake's stop) on whichever Run the run
    # left, opened or answered.
    def drive(task, project, seed)
      outcome = caught { send(:"drive_#{task.driver}", task, project, seed) }
      printed_through_the_binary(outcome)
    ensure
      after_drive(task.driver, outcome&.fetch(:run))
    end

    # EVERY RUN ENDS STOPPED (12a L7): once the trace is read the
    # conversation is stopped — a receipt-woken turn or a branch member
    # that outlived the driver spends no further and runs no tool after the
    # next run's repoint — the runner is waited idle, and the spend is read
    # AFTER over every loop the conversation's feed names, so a woken
    # loop's spend lands on the record it belongs to (Runner K's ≥ $4.19
    # runaway was on no record). The trace's loops keep the statuses they
    # were READ at (the measurement); the feed's other loops are appended
    # as they rest now, marked `traced: false` — an ask on one is the
    # model's word to nobody, never a kernel signal
    # (`Trace#untraced_attention_reasons`). WHAT EACH LOOP SAID BY THE
    # STOP rides the facts as `replies` (`{id => rho result}`, the primary
    # first, the woken loops in feed order — the settle_receipts driver's
    # shape, which records its own): a receipt-woken turn's merge is on
    # no route the trace reads, and a loop the stop cut carries what it
    # printed then, its row marking the status. A stop that fails is a
    # warning: the trace stands.
    def settled_after_stop(outcome)
      run = outcome[:run]
      return outcome if run.nil?

      stop_conversation!(run.conversation) if run.conversation
      await_runner_idle!([@daemon, @runner])
      trace = outcome.fetch(:trace)
      loops = loops_after_stop(run, trace)
      spend = spend_of_loops(loops.map { |row| row["id"] })
      with_replies(outcome.merge(trace: trace.with(loops: loops, spend: spend || trace.spend)))
    rescue StandardError => error
      warn "the run could not be settled after its stop: #{error.class}: #{error.message.to_s[0, 200]}"
      outcome
    end

    # The `replies` fact over the settled loops, unless the driver recorded its own. A read that fails
    # is a warning that costs the replies alone: the settled loops and their spend stand.
    def with_replies(settled)
      trace = settled.fetch(:trace)
      if trace.fact(:replies).nil?
        settled.merge(trace: trace.with_facts("replies" => trace.loops.to_h { |row| [row["id"], result_of(row["id"])] }))
      else
        settled
      end
    rescue StandardError => error
      warn "the run's replies could not be read after its stop: #{error.class}: #{error.message.to_s[0, 200]}"
      settled
    end

    # THE STREAM UNDER A HARNESS STOP: a stop before any round settled reads as the lane's unless
    # the model was still streaming when it landed — the loop's frames on the model runner's window
    # (`WorldLog.in_flight`), read off the live file, since the copy is made after the record. A
    # read that fails is a warning: the trace stands.
    def in_flight_of(outcome, windows)
      run = outcome[:run]
      return outcome unless E2E::Evals::Scorecard::HARNESS_STOPS.include?(outcome[:stopped]) && run&.loop

      trace = outcome.fetch(:trace)
      read = E2E::Evals::WorldLog.in_flight(windows: windows, loop_id: run.loop, stopped_at: trace.stopped_at)
      read.nil? ? outcome : outcome.merge(trace: trace.with_facts("in_flight" => read))
    rescue StandardError => error
      warn "the run's stream could not be read: #{error.class}: #{error.message.to_s[0, 200]}"
      outcome
    end

    def loops_after_stop(run, trace)
      known = trace.loops.map { |row| row["id"] }
      named = run.conversation ? loops_on_feed(run.conversation) : []
      trace.loops + (named - known).map { |id| { "id" => id, "status" => loop_row(id).fetch("status"), "traced" => false } }
    end

    # THE MEMORY THE MODEL LEFT IS DELETED (12a L6): one daemon per group
    # is one workspace and one Human for every run, so a `workspace/` or
    # `user/` document written by run 2 rode into run 3's request (a
    # 16 KB "Durable memory" block; cross-task too). After the trace — and
    # after the memory driver's own read — every such document is deleted
    # through the steward's door (the conversation's, which serves all
    # three scopes; the profile's `user/` alone when the run had no
    # conversation) and the count is logged. `conversation/` needs no
    # reset: each run opens a new one. A refusal — a workspace override
    # answering `memory_overridden` — is a warning, never a red run.
    def reset_memory!(run)
      client = CybrosAgent::Client.new(base_url: @base_url, credential: @steward.member_token)
      door = run&.conversation ? client.workspace(workspace_public_id).conversation(run.conversation).memory :
        client.profile.memory
      paths = door.list.map(&:path).grep(%r{\A(?:workspace|user)/})
      paths.each { |path| door.delete(path) }
      puts "memory:  #{paths.size} document(s) deleted#{paths.empty? ? "" : " (#{paths.join(", ")})"}"
    rescue StandardError => error
      warn "the run's memory could not be reset: #{error.class}: #{error.message.to_s[0, 200]}"
    end

    # A print that disagrees with the route is this run's error, its
    # trace kept as read.
    def printed_through_the_binary(outcome)
      return outcome if outcome[:run].nil? || outcome[:error] || outcome[:stopped]

      assert_the_binary_prints_the_route_picture!(outcome[:run].loop, outcome[:trace].graph)
      assert_the_binary_prints_the_sealed_request!(outcome[:run].loop, outcome[:trace].sealed)
      outcome
    rescue StandardError, Minitest::Assertion => error
      outcome.merge(error: "#{error.class}: #{error.message.lines.first.to_s.strip[0, 300]}")
    end

    # A predicate that raises is a lane bug spelled as the reason (`Scorecard#unscored?` reads its
    # head), never a lost record.
    def verdict_of(task, trace)
      task.expected.verdict(trace)
    rescue StandardError => error
      E2E::Evals::Verdict.new(reached: false, succeeded: nil,
        reason: "#{E2E::Evals::Scorecard::PREDICATE_RAISED} #{error.class}: #{error.message[0, 200]}", conduct: {}, facts: {})
    end

    def build_record(run, trace, verdict, verification, outcome, started_at:, seconds:)
      task = run.task
      record = {
        "task" => task.name, "family" => task.family, "capability" => task.capability, "driver" => task.driver,
        "model" => run.model, "style" => run.style, "run" => run.index, "bench_digest" => BENCH.digest,
        "adaptations" => @configuration.adaptations_fact,
        "started_at" => started_at, "seconds" => seconds, "loops" => trace.loops,
        "verdict" => { "reached" => verdict.reached, "succeeded" => verdict.succeeded,
                       "task_pass" => verification&.fetch("pass"), "class" => nil },
        "reason" => verdict.reason, "error" => outcome[:error], "note" => outcome[:note],
        "facts" => trace.structure_facts.merge(trace.facts.except("summaries")).merge(verdict.facts)
          .merge("verification_output" => verification&.fetch("output"))
          .merge(verification&.key?("reward") ? { "reward" => verification["reward"] } : {}),
        "efficiency" => trace.efficiency.merge(
          "compactions_survived" => (verdict.work_survived?(verification&.fetch("pass")) ? trace.compactions.size : 0)
        ),
        "conduct" => verdict.conduct_facts, "conduct_reasons" => verdict.conduct_reasons,
        "stopped" => outcome[:stopped], "artifact" => artifacts.stem(run) + ".json",
      }.compact
      record["verdict"]["class"] = E2E::Evals::Scorecard.classify(record, bench: BENCH)
      record
    end

    # THE CONTAINER'S EVIDENCE OF A RED RUN (the box's chess run: a `lane
    # bug` — the restarted container never announced — whose failure dump
    # held the WORLD's logs alone; the container's stdout reaches
    # `daemon.log` inside the home on `stop`, and the teardown removes the
    # home). Any red of a container run, its verdict classed: the
    # container's stdout and rho's structured log, read THROUGH the
    # container while it stands (`Docker.save_evidence`), land beside the
    # build log as `logs/<tag>.<task>.<model>.<style>.<n>.container.log`
    # and `….rho.log`, redacted; the record's error line names them (a red
    # with no error carries them in its note), so the ledger says where to
    # read. A save that fails is a warning: the record stands as built.
    def with_container_evidence(run, record)
      return record unless @configuration.container? && @runner && record.dig("verdict", "class")

      stem = "#{@runner.tag}.#{run.stem}"
      files = E2E::Evals::Docker.save_evidence(@runner, into: artifacts.logs, stem: stem)
      named = "container evidence: #{files.map { |path| File.join("logs", File.basename(path)) }.join(", ")}"
      key = record["error"] ? "error" : "note"
      record.merge(key => [record[key], named].compact.join(" — "))
    rescue StandardError => error
      warn "the container's evidence of #{run.stem} could not be saved: #{error.class}: #{error.message}"
      record
    end

    # The full trace beside the record: the route's JSON, the joined task rows, the events, the
    # spend, the summaries' bodies (k1's output is the one place the kernel's pointer lines can be
    # read once the world is torn down), the sealed request of the last completed round, and the
    # markdown with the mermaid fenced.
    def write_artifact(run, trace, record)
      artifacts.write(run, trace, record)
    rescue StandardError => error
      warn "the artifact of #{run.stem} could not be written: #{error.class}: #{error.message}"
    end

    def summaries_of(trace)
      return {} if trace.loop_id.nil?

      trace.compactions.filter_map { |item| item["summary_task_key"] }.uniq.to_h do |key|
        [key, task_output(trace.loop_id, key)]
      rescue StandardError => error
        [key, "(not read: #{error.class}: #{error.message})"]
      end
    end

    # THE WORLD'S LOGS PER RUN, redacted, under
    # the invocation's logs/<task>.<model>.<style>.<n>/: the hosts' logs, both homes' pair and
    # each process's own Rails log (`RAILS_LOG_FILE`, never rotated), every one as the run's window
    # from the mark taken before the turn. A copy that fails is a warning: the record is already
    # written.
    def copy_world_logs(run, windows)
      into = artifacts.logs(run.stem)
      E2E::Evals::WorldLog.copy(into: into, sources: {}, windows: windows)
    rescue StandardError => error
      warn "the world's logs could not be copied: #{error.class}: #{error.message}"
    end

    # rho's runner meters now (`swept`, `nudged` off `/status`): the
    # daemon's own runner, plus the runner-mode home's when the
    # configuration has one (a handoff task's tools run there). nil when
    # neither serves the meter.
    def meter_now(name)
      counts = [runner_meter(@daemon, name), (@runner && runner_meter(@runner, name))].compact
      counts.empty? ? nil : counts.sum
    end

    def meters_now = { "swept" => meter_now(:swept), "nudged" => meter_now(:nudged) }

    # Each meter's movement over the run; nil where either side was not read.
    def meter_deltas(at_start)
      meters_now.to_h { |name, now| [name, (at_start[name].nil? || now.nil? ? nil : now - at_start[name])] }
    end

    def elapsed(started) = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round
end
