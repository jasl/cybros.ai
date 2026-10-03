$LOAD_PATH.unshift File.expand_path("..", __dir__)

require "bigdecimal"
require "fileutils"
require "json"
require "minitest/autorun"
require "minitest/mock"
require "open3"
require "stringio"
require "tmpdir"
require "yaml"
require "support/screen/launcher"

# THE LAUNCH, END TO END IN FAKE MODE, OVER REAL PROCESSES: Stage 0 stamps (its bundle-bound gates
# are the test's recorders), the watch starts as its own process before any job, each job runs in
# its tree's `e2e/` in its own process group with exactly the bench variables and no key, floors
# first and never more in flight on a lane than its cap, `exit=N` lands in its log, and the last act
# writes the count, the analysis and the readout. The probe each job runs is a stub script in a
# scratch tree that draws like a probe (one record per objective × sample through `BenchRecords`,
# one progress line each); the watch is the real `Watch` over a flat pricer. A dead watch stops
# every job; so does an interrupted launch, as a stop by hand; a stop reaches the analysis, which
# writes it in place of a verdict; a relaunch after a storm holds the rest the registered stagger
# behind the floors; a watch that never starts voids the stamp; a rehearsal's injection reaches the
# screen's jobs and never the smoke's; a paid job alone gets its lane's key.
class ScreenLauncherHarnessTest < Minitest::Test
  S = E2E::Screen
  FAKE = File.expand_path("../support/fixtures/screen/fake", __dir__)
  SUPPORT = File.expand_path("../support", __dir__)
  EXPECTED_BENCH_VARIABLES = %w[
    E2E_BENCH_ARM E2E_BENCH_BLIND E2E_BENCH_CACHE_KEY E2E_BENCH_CAPTURES_DIR E2E_BENCH_CLIENT E2E_BENCH_DIR
    E2E_BENCH_MAX_OUTPUT_TOKENS E2E_BENCH_MODELS E2E_BENCH_PROCESS E2E_BENCH_SAMPLES E2E_BENCH_SAMPLE_FIRST
    E2E_BENCH_STYLES
  ].freeze

  # A PROBE STAND-IN: it records the environment it was given, then draws like the probe it stands
  # for — the smoke's cache lane reads its second draw from the cache — and exits 0.
  STUB = <<~RUBY.freeze
    require "json"
    require "time"
    require #{File.join(SUPPORT, "bench_records").inspect}
    env = ENV.to_h
    dir = env.fetch("E2E_BENCH_DIR")
    control = JSON.parse(File.read(File.expand_path("../stub.json", __dir__)))
    File.write(File.join(dir, "env.json"), JSON.generate(env.select { |key, _| key.start_with?("E2E_", "RAILS_") || key.end_with?("_API_KEY") }))
    File.write(File.join(dir, "span.json"), JSON.generate("started" => Time.now.to_f))
    if control["stop"] && env.fetch("E2E_BENCH_PROCESS") == "1" && !dir.include?("/smoke/")
      File.write(File.expand_path("../../../logs/STOP.request", dir), "NoMethodError in 1:O1#1")
    end
    sleep control.fetch("seconds") unless dir.include?("/smoke/")
    objectives = (env["E2E_BENCH_OBJECTIVES"] || env.fetch("E2E_TASK_OBJECTIVES")).split(",")
    first = Integer(env.fetch("E2E_BENCH_SAMPLE_FIRST"))
    objectives.each do |objective|
      (first...(first + Integer(env.fetch("E2E_BENCH_SAMPLES")))).each do |index|
        usage = { "input_tokens" => 9_020, "output_tokens" => 30, "cache_creation_tokens" => 9_000 }
        usage = usage.merge("cache_read_tokens" => 9_000) if index > first
        record = { "objective" => objective, "model" => env.fetch("E2E_BENCH_MODELS"), "style" => env.fetch("E2E_BENCH_STYLES"),
                   "sample" => index, "usage" => usage }
        E2E::BenchRecords.append(dir, record)
        puts E2E::BenchRecords.progress_line(record)
      end
    end
    File.write(File.join(dir, "span.json"), JSON.generate("started" => JSON.parse(File.read(File.join(dir, "span.json")))["started"], "ended" => Time.now.to_f))
  RUBY

  Analysis = Data.define(:written) do
    def run(_definition, home)
      return unless written

      File.join(home, "analysis.md").tap { |path| File.write(path, "verdict=REHEARSAL\n") }
    end
  end
  # The real analysis over the definition's own clauses, priced flat.
  RealAnalysis = Data.define do
    def run(definition, home) = E2E::Screen::Analysis.run(definition, home, price: ->(_draw) { BigDecimal("0.001") })
  end
  Cells = Data.define do
    def extract(records) = records.group_by { |record| record.values_at("arm", "model", "objective") }.map { |key, rows| { "cell" => key, "draws" => rows.size } }
  end

  def test_a_fake_launch_runs_every_job_behind_its_watch_and_writes_the_readout
    with_tree do |tree, home, out|
      status = launcher(tree, home, out).call
      assert_equal 0, status, out.string
      definition = S::Definition.load(FAKE)
      jobs = definition.jobs
      jobs.each do |job|
        env = JSON.parse(File.read(File.join(job.path(home), "env.json")))
        own = job.instrument == "compose" ? %w[E2E_BENCH_OBJECTIVES E2E_BENCH_ROWS] : %w[E2E_TASK_OBJECTIVES]
        assert_equal (EXPECTED_BENCH_VARIABLES + own).sort, env.keys.grep(/\AE2E_/).sort, "exactly the bench variables: #{job.dir}"
        assert_equal ["fake", "1", nil, nil], env.values_at("E2E_BENCH_CLIENT", "E2E_BENCH_BLIND", "E2E_LIVE", "RAILS_ENV"),
          "a fake job carries no paid opt-in"
        assert_equal "fake-rehearsal/#{job.arm}/#{job.lane}", env.fetch("E2E_BENCH_CACHE_KEY")
        assert_empty env.keys.grep(/_API_KEY\z/), "a fake job reads no key"
        assert_match(/\Aexit=0\z/, File.readlines(File.join(home, "logs", "#{job.index}.log"), chomp: true).last)
        assert File.exist?(File.join(job.path(home), "pgid"))
      end
      started = File.readlines(File.join(home, "logs", "jobs.tsv"), chomp: true).map { |line| Integer(line.split("\t").first) }
      assert_equal jobs.map(&:index), started, "floors first, then the definition's order"
      watch_log = File.read(File.join(home, "logs", "watch.log"))
      assert_operator watch_log.index(" WATCH "), :<, watch_log.index(" START "), "the watch runs before the first job"
      assert_includes watch_log, "ALL-DONE"
      assert File.readlines(File.join(home, "counts.txt"), chomp: true).all? { |line| line.start_with?("ok ") }, File.read(File.join(home, "counts.txt"))
      readout = File.join(tree, "e2e/artifacts/screen-readouts/fake-rehearsal")
      assert_equal %w[analysis.md cells.jsonl counts.txt stamp.txt], Dir.children(readout).sort
      assert_equal "fake", S::Stamp.read(home).fetch("mode")
      assert_includes out.string, "DONE:"
    end
  end

  def test_a_fake_launch_combines_fictional_rates_with_catalog_rates
    with_tree do |tree, home, out|
      model = "fixture/catalog-model"
      cell = @definition.cells.first.with(models: [model], objectives: ["O1"], n: 1)
      E2E::ProviderLanes.stub(:route, nil) { @definition = @definition.with(cells: @definition.cells + [cell]) }
      fictional = E2E::FakeBenchAdapter.rates(root: tree, models: @definition.drawn_models - [model])
      catalog = fictional.fetch("fake/chat-a").merge("rates" => { "input_per_mtok" => "7", "output_per_mtok" => "19" })
      derived = []
      derive = lambda do |root:, models:|
        derived << [root, models]
        { model => catalog }
      end

      E2E::BenchSpend.stub(:derive, derive) { assert_equal 0, launcher(tree, home, out, rates: nil).call, out.string }
      assert_equal [[tree, [model]]], derived, "only ordinary model refs use the tree's catalog"
      assert_equal fictional.merge(model => catalog), JSON.parse(File.read(S::Rates.path(home)))
    end
  end

  # THE CAPS: one in flight per lane here, so no two jobs of a lane overlap.
  def test_no_lane_has_more_jobs_in_flight_than_its_cap
    with_tree(caps: { "fake/" => 1 }) do |tree, home, out|
      assert_equal 0, launcher(tree, home, out).call, out.string
      spans = S::Definition.load(FAKE).jobs.map { |job| [job.lane, JSON.parse(File.read(File.join(job.path(home), "span.json")))] }
      spans.group_by(&:first).each do |lane, lane_spans|
        ordered = lane_spans.map(&:last).sort_by { |span| span["started"] }
        ordered.each_cons(2) { |one, next_one| assert_operator one["ended"], :<=, next_one["started"], "#{lane} overlapped" }
      end
    end
  end

  def test_the_launch_exits_one_when_the_analysis_writes_nothing
    with_tree do |tree, home, out|
      assert_equal 1, launcher(tree, home, out, analysis: Analysis.new(written: false)).call
      assert_includes out.string, "NOT DONE: the analysis wrote nothing"
    end
  end

  # NO WATCH, NO SCREEN: a watch that dies mid-run leaves STOPPED and every job's group stopped;
  # the last act still runs, and the analysis reads the stop.
  def test_a_dead_watch_stops_every_job
    with_tree(seconds: 20) do |tree, home, out|
      dying = ->(_home) { [Gem.ruby, "-e", "puts 'now WATCH dying'; $stdout.flush; sleep 1.5"] }
      launcher(tree, home, out, watch_command: dying).call
      assert_match(/WATCH-DIED/, File.read(File.join(home, "logs", "STOPPED")))
      exits = Dir[File.join(home, "logs", "*.log")].reject { |log| log.end_with?("watch.log") }
        .map { |log| File.readlines(log, chomp: true).last }
      assert exits.any?, "some job had started"
      assert exits.all? { |line| %w[exit=143 exit=137].include?(line) }, exits.inspect
    end
  end

  # THE WATCH'S STOP: nothing more starts, the jobs it stops are still reaped (their `exit=N` is
  # what the watch waits for), and the launch ends with the count of what started — and the stop
  # is the analysis: no clause is read, the machine lines owe the relaunch, the launch exits 3.
  def test_a_stop_by_the_watch_ends_the_launch_with_every_started_job_reaped
    with_tree(seconds: 20, stop: true, caps: { "fake/" => 1 }) do |tree, home, out|
      assert_equal 3, launcher(tree, home, out, analysis: RealAnalysis.new).call, out.string
      assert_match(/MANUAL-FAULT NoMethodError in 1:O1#1/, File.read(File.join(home, "logs", "STOPPED")))
      assert_equal %w[STOPPED MANUAL-FAULT], S::Analysis.machine_lines(File.join(home, "analysis.md")).values_at("verdict", "relaunch")
      refute_includes File.read(File.join(home, "analysis.md")), "## Verdict", "a stopped batch decides nothing"
      assert_equal File.read(File.join(home, "analysis.md")), File.read(File.join(tree, "e2e/artifacts/screen-readouts/fake-rehearsal/analysis.md")),
        "the stop is read out into the screen's ledger"
      started = File.readlines(File.join(home, "logs", "jobs.tsv"), chomp: true).map { |line| line.split("\t").first }
      assert_operator started.size, :<, S::Definition.load(FAKE).jobs.size, "nothing started after the stop"
      assert_equal started.size.to_s, File.read(File.join(home, "logs", "launched.done")).strip
      exits = started.map { |index| File.readlines(File.join(home, "logs", "#{index}.log"), chomp: true).last }
      assert exits.all? { |line| %w[exit=143 exit=137].include?(line) }, exits.inspect
      assert_includes File.read(File.join(home, "logs", "watch.log")), "ALL-DONE"
    end
  end

  # A REHEARSAL'S INJECTION reaches the screen's jobs alone: the smoke's jobs are numbered from 1
  # too, and a `blind@1` that reached smoke job 1 would fail Stage 0 instead of meeting the BLIND
  # stop it stands for.
  def test_an_injection_reaches_the_screens_job_and_never_the_smokes
    with_tree do |tree, home, out|
      launcher(tree, home, out, inject: { 1 => ["blind"] }).call
      assert_includes out.string, "STAMPED", out.string
      assert_match(/\A\S+ BLIND 1 base fake\/responses: \d+ progress lines, 0 records/, File.read(File.join(home, "logs", "STOPPED")))
      smoke = Dir[File.join(home, "smoke", "**", "env.json")].map { |path| JSON.parse(File.read(path)) }
      assert_equal 4, smoke.size
      assert smoke.none? { |env| env.key?("E2E_BENCH_FAKE_INJECT") }, "no smoke job reads an injection"
      first = S::Definition.load(FAKE).jobs.first
      assert_equal "blind", JSON.parse(File.read(File.join(first.path(home), "env.json"))).fetch("E2E_BENCH_FAKE_INJECT")
    end
  end

  # AN INTERRUPTED LAUNCH stops every job it started — each in its own group, beyond the terminal's
  # reach — records a stop by hand (no relaunch is owed for one), writes how many it started, and
  # the watch, seeing them all ended, ends too.
  def test_an_interrupted_launch_stops_every_job_and_the_watch_ends
    with_tree(seconds: 20) do |tree, home, out|
      jobs = S::Definition.load(FAKE).jobs.to_h { |job| [job.index.to_s, job] }
      started = -> { File.readlines(File.join(home, "logs", "jobs.tsv"), chomp: true).map { |line| jobs.fetch(line.split("\t").first) } }
      # Once every started job is up (a TERM while Ruby boots exits 1, which reads as a fault).
      up = -> { File.exist?(File.join(home, "logs", "jobs.tsv")) && started.call.all? { |job| File.exist?(File.join(job.path(home), "span.json")) } }
      interrupted = []
      interrupting = lambda do |seconds|
        if interrupted.empty? && up.call
          interrupted << true
          raise Interrupt
        end
        Kernel.sleep([seconds, 0.1].min)
      end
      assert_equal 3, launcher(tree, home, out, analysis: RealAnalysis.new, sleep: interrupting).call, out.string
      assert_includes out.string, "STOPPED after the first job: MANUAL the launch received SIGINT"
      stopped = S::Stop.reason(home)
      assert_match(/\AMANUAL the launch received SIGINT/, stopped)
      refute S::WatchRules.relaunch_owed?(stopped), "an interrupt is a stop by hand"
      assert_equal %w[NOT-LANDED none], S::Analysis.machine_lines(File.join(home, "analysis.md")).values_at("verdict", "relaunch"),
        "a stop by hand reads NOT LANDED and owes no relaunch"
      assert_equal started.call.size.to_s, File.read(File.join(home, "logs", "launched.done")).strip
      exits = started.call.map { |job| File.readlines(File.join(home, "logs", "#{job.index}.log"), chomp: true).last }
      assert exits.all? { |line| %w[exit=143 exit=137].include?(line) }, exits.inspect
      watch_log = File.join(home, "logs", "watch.log")
      deadline = Time.now.to_f + 20
      Kernel.sleep 0.1 until File.read(watch_log, encoding: Encoding::UTF_8).include?("ALL-DONE") || Time.now.to_f > deadline
      assert_includes File.read(watch_log, encoding: Encoding::UTF_8), "ALL-DONE", "the watch ends once every job it saw has ended"
    end
  end

  # AFTER A STORM the relaunch runs the registered post-storm layout: the floors start first, and the
  # rest only once the stagger has passed since the last floor started.
  def test_a_relaunch_after_a_storm_holds_the_rest_the_stagger_behind_the_floors
    with_tree(stagger_seconds: 2) do |tree, home, out|
      old = File.join(File.dirname(home), "stormed")
      S::Stamp.write(old, [%w[mode fake], ["screen", @definition.name], ["launched_at", "2026-09-28T10:00:00Z"]])
      FileUtils.mkdir_p(File.join(old, "logs"))
      File.write(S::Stop.path(old), "2026-09-28T10:05:00Z STORM 3 base m: 3 of 3 calls unreached (100.0 %)\n")
      assert_equal 0, launcher(tree, home, out, supersedes: old).call, out.string
      jobs = S::Stamp.jobs(S::Stamp.read(home))
      assert_equal @definition.after_storm.jobs, jobs, "the post-storm layout is the stamp's"
      started = File.readlines(File.join(home, "logs", "jobs.tsv"), chomp: true).to_h do |line|
        index, at = line.split("\t")
        [Integer(index), Float(at)]
      end
      floors, rest = jobs.partition { |job| @definition.floors.include?(job.model) }
      last_floor = floors.map { |job| started.fetch(job.index) }.max
      late = rest.reject { |job| started.fetch(job.index) >= last_floor + 2 }
      assert_empty late.map(&:index), "every other job waits the stagger behind the last floor"
    end
  end

  # THE SMOKE'S JOBS are stopped by whatever ends their wait early: an interrupt during the smoke
  # leaves no paid job running.
  def test_a_run_to_end_interrupted_stops_every_job_it_started
    with_tree(seconds: 20) do |tree, home, _out|
      definition = S::Definition.load(FAKE)
      runner = S::JobRunner.new(home: home, definition: definition, trees: { "with" => tree, "without" => tree }, client: "fake",
        log: ->(job) { S::Smoke.log(home, job) },
        command: ->(_job) { [Gem.ruby, "-e", "File.write(File.join(ENV.fetch('E2E_BENCH_DIR'), 'up'), ''); sleep 20"] })
      jobs = S::Smoke.jobs(definition)
      interrupted = []
      interrupting = lambda do |seconds|
        if interrupted.empty? && jobs.all? { |job| File.exist?(File.join(job.path(home), "up")) }
          interrupted << true
          raise Interrupt
        end
        Kernel.sleep([seconds, 0.1].min)
      end
      assert_raises(Interrupt) { runner.run_to_end(jobs, deadline: Time.now.to_f + 600, sleep: interrupting) }
      assert_empty runner.running
      exits = jobs.map { |job| File.readlines(S::Smoke.log(home, job), chomp: true).last }
      assert exits.all? { |line| %w[exit=143 exit=137].include?(line) }, exits.inspect
    end
  end

  # A WATCH THAT NEVER STARTS voids the stamp: it is kept aside, the slot freed, nothing drew.
  def test_a_watch_that_never_starts_voids_the_stamp
    with_tree do |tree, home, out|
      silent = ->(_home) { [Gem.ruby, "-e", "exit 1"] }
      assert_equal 2, launcher(tree, home, out, watch_command: silent).call
      refute File.exist?(S::Stamp.path(home))
      assert_equal 1, Dir[File.join(home, "stamp.void-*.txt")].size
      refute File.exist?(File.join(home, "logs", "jobs.tsv")), "no job started"
      assert_includes out.string, "the stamp is void"
    end
  end

  # A PAID LAUNCH is the manual lanes' own opt-in: without it nothing is stamped and nothing starts.
  def test_a_paid_launch_without_its_opt_in_is_refused_before_anything_is_stamped
    with_tree do |tree, home, out|
      paid = S::Launcher.new(definition: @definition, trees: { "with" => tree, "without" => tree }, home: home, mode: "real", out: out,
        keys_path: File.join(tree, "absent.env"), pricer: ->(_record) { 0.0 })
      previous = ENV.delete("E2E_LIVE")
      begin
        assert_raises(ArgumentError) { paid.call }
      ensure
        ENV["E2E_LIVE"] = previous if previous
      end
      refute File.exist?(File.join(home, "stamp.txt"))
    end
  end

  def test_a_paid_launch_refuses_fake_models_before_reading_keys_or_stamping
    with_tree do |tree, home, out|
      paid = S::Launcher.new(definition: @definition, trees: { "with" => tree, "without" => tree }, home: home,
        mode: "real", out: out, keys_path: File.join(tree, "absent.env"))
      E2E::ManualClient.stub(:validate!, true) { assert_equal 2, paid.call }
      assert_includes out.string, "fake models require --fake"
      refute File.exist?(S::Stamp.path(home))
    end
  end

  # Key selection is independent of the model catalog and never exports unrelated keys.
  def test_a_paid_job_gets_its_lanes_key_and_nothing_else
    with_tree do |tree, home, _out|
      definition = S::Definition.load(FAKE)
      job = definition.jobs.first.with(model: "fixture/text", lane: "fixture")
      lane = E2E::ProviderLanes::Lane.new(provider_id: "fixture", format: "openai_responses",
        base_url: "https://provider.example", key_name: "TEST_API_KEY")
      route = E2E::ProviderLanes::Route.new(ref: job.model, lane: lane, model: "text")
      E2E::ProviderLanes.stub(:route, route) do
        runner = S::JobRunner.new(home: home, definition: definition, trees: { "with" => tree, "without" => tree }, client: "real",
          keys: { "TEST_API_KEY" => "placeholder", "OTHER_API_KEY" => "unrelated" }, command: stub_command)
        runner.start(job)
        sleep 0.05 while runner.reap.empty?
        env = JSON.parse(File.read(File.join(job.path(home), "env.json")))
        assert_equal ["TEST_API_KEY"], env.keys.grep(/_API_KEY\z/)
        assert_equal "placeholder", env.fetch("TEST_API_KEY")
        assert_equal %w[real 1 development], env.values_at("E2E_BENCH_CLIENT", "E2E_LIVE", "RAILS_ENV")
        error = assert_raises(S::Refused) do
          S::JobRunner.new(home: home, definition: definition, trees: { "with" => tree, "without" => tree }, client: "real", keys: {},
            command: stub_command).start(job)
        end
        assert_includes error.message, "TEST_API_KEY"
      end
    end
  end

  private

    def launcher(tree, home, out, analysis: Analysis.new(written: true), watch_command: flat_watch, inject: {}, supersedes: nil,
                 sleep: ->(seconds) { Kernel.sleep([seconds, 0.1].min) }, rates: Recorder.new([["rates_sha256", "0" * 64]]))
      S::Launcher.new(definition: @definition, trees: { "with" => tree, "without" => tree }, home: home, mode: "fake", out: out,
        repo_root: tree, analysis: analysis, cells: Cells.new, pricer: ->(_record) { 0.001 }, job_command: stub_command,
        watch_command: watch_command, inject: inject, supersedes: supersedes, sleep: sleep,
        stage0: { busy: -> { [[], 0.1] }, bytes: Recorder.new([]), rates: rates }.compact)
    end

    # A collaborator answering `call(**)` with fixed pairs.
    Recorder = Data.define(:pairs) do
      def call(**) = pairs
    end

    def stub_command = ->(_job) { [Gem.ruby, "test/stub_probe.rb"] }

    # The real watch over a flat pricer, as its own process.
    def flat_watch
      lambda do |home|
        [Gem.ruby, "-I", File.expand_path("..", __dir__), "-e",
         "require 'support/screen/watch'; exit E2E::Screen::Watch.new(ARGV[0], pricer: ->(_r) { 0.001 }).run", home]
      end
    end

    # A scratch tree: a git repository holding the design the definition registers, a stub probe
    # under `e2e/test/`, and the stub's control file; a definition copy with the given caps and
    # post-storm stagger, beside the fake definition's clauses.
    def with_tree(seconds: 0.2, caps: nil, stop: false, stagger_seconds: nil)
      Dir.mktmpdir("screen-launcher") do |scratch|
        tree = File.join(scratch, "tree")
        design = "e2e/support/fixtures/screen/fake/design.md"
        FileUtils.mkdir_p([File.join(tree, File.dirname(design)), File.join(tree, "e2e/test")])
        FileUtils.cp(File.join(FAKE, "design.md"), File.join(tree, design))
        File.write(File.join(tree, "e2e/test/stub_probe.rb"), STUB)
        File.write(File.join(tree, "e2e/stub.json"), JSON.generate("seconds" => seconds, "stop" => stop))
        Open3.capture2e("git", "init", "-q", "-b", "main", tree)
        @definition = definition(scratch, caps, stagger_seconds)
        yield tree, File.join(scratch, "home"), StringIO.new
      end
    end

    def definition(scratch, caps, stagger_seconds)
      dir = File.join(scratch, "definition")
      FileUtils.mkdir_p(dir)
      yaml = YAML.safe_load_file(File.join(FAKE, "screen.yml"))
      yaml["caps"] = caps if caps
      yaml["relaunch"]["post_storm"]["stagger_seconds"] = stagger_seconds if stagger_seconds
      File.write(File.join(dir, "screen.yml"), YAML.dump(yaml))
      FileUtils.cp(File.join(FAKE, "clauses.rb"), dir)
      S::Definition.load(dir)
    end
end
