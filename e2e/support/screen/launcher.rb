require "fileutils"
require "json"
require "time"
require_relative "../bench_client"
require_relative "../bench_spend"
require_relative "../manual_client"
require_relative "../provider_lanes"
require_relative "analysis"
require_relative "cells"
require_relative "definition"
require_relative "job"
require_relative "readout"
require_relative "records"
require_relative "stage0"
require_relative "stamp"
require_relative "stop"
require_relative "watch"

module E2E
  module Screen
    # THE JOBS OF ONE LAUNCH (or its smoke), each its probe's test run as its own process, in its
    # arm's tree, under its own process group: `<dir>/pgid` written the moment it starts, its
    # stdout and stderr in its log, `exit=N` appended when it is reaped, and `index<TAB>started` in
    # `logs/jobs.tsv` so the watch picks it up. The environment is the job's recipe over a clean
    # base; a paid job alone gets its lane's key, from the keys file, never the launcher's own
    # environment.
    class JobRunner
      # A job's process: its probe's test file under its tree's bundle.
      PROBE = ->(job) { ["bundle", "exec", "ruby", "-I.", job.test] }

      def initialize(home:, definition:, trees:, client:, keys: {}, inject: {}, stall_seconds: nil, log: nil, command: PROBE)
        @home = home
        @definition = definition
        @trees = trees
        @client = client
        @keys = keys
        @inject = inject
        @stall_seconds = stall_seconds
        @log = log || ->(job) { File.join(home, "logs", "#{job.index}.log") }
        @command = command
        @running = {}
      end

      def running = @running.values

      def start(job)
        FileUtils.mkdir_p([job.path(@home), File.dirname(@log.call(job))])
        pid = ::Process.spawn(env_of(job), *@command.call(job),
          chdir: File.join(@definition.tree_root(job.arm, @trees), "e2e"), pgroup: true, unsetenv_others: true,
          out: [@log.call(job), "a"], err: [:child, :out], in: File::NULL)
        File.write(File.join(job.path(@home), "pgid"), "#{pid}\n")
        File.write(File.join(File.dirname(@log.call(job)), "jobs.tsv"), "#{job.index}\t#{Time.now.to_f}\n", mode: "a")
        @running[pid] = job
      end

      # The jobs that ended since the last reap, each `exit=N` in its log (a signal reads 128+N).
      def reap
        @running.keys.filter_map do |pid|
          _, status = ::Process.wait2(pid, ::Process::WNOHANG)
          next unless status

          job = @running.delete(pid)
          File.write(@log.call(job), "exit=#{status.exitstatus || 128 + status.termsig}\n", mode: "a")
          job
        end
      end

      def signal_all(name)
        @running.each_key do |pid|
          ::Process.kill(name, -pid)
        rescue Errno::ESRCH, Errno::EPERM # a group already gone (macOS answers EPERM for one left as zombies)
          nil
        end
      end

      # Every job at once, waited for; past the deadline each group is stopped. Whatever ends the
      # wait early — an interrupt, a fault — stops every group still running before it goes on, since
      # a job in its own group is beyond the terminal's reach.
      def run_to_end(jobs, deadline:, sleep: ->(seconds) { Kernel.sleep(seconds) })
        jobs.each { |job| start(job) }
        until @running.empty?
          reap
          stop_all(sleep: sleep) if Time.now.to_f >= deadline && @running.any?
          sleep.call(0.2)
        end
      ensure
        stop_all(sleep: sleep) if @running.any?
      end

      # TERM every group, KILL what is left after the grace, reap them all.
      def stop_all(grace: 10, sleep: ->(seconds) { Kernel.sleep(seconds) })
        signal_all("TERM")
        settle(Time.now.to_f + grace, sleep)
        signal_all("KILL")
        settle(Float::INFINITY, sleep)
      end

      private

        def settle(until_time, sleep)
          loop do
            reap
            break if @running.empty? || Time.now.to_f >= until_time

            sleep.call(0.2)
          end
        end

        def env_of(job)
          env = Screen.child_env.merge(job.env(home: @home, screen: @definition.name, client: @client,
            max_output_tokens: @definition.max_output_tokens))
          if @client == "fake"
            env.merge({ "E2E_BENCH_FAKE_INJECT" => @inject[job.index]&.join(","),
                        "E2E_BENCH_FAKE_STALL_SECONDS" => @stall_seconds&.to_s }.compact)
          else
            name = ProviderLanes.route(job.model).lane.key_name
            env.merge(name => @keys.fetch(name) { raise Refused, "the keys file holds no #{name} for #{job.model}" })
          end
        end
    end

    # THE LAUNCH: Stage 0 and the stamp; the watch, started first as its own process; the jobs of the
    # stamp's table, floors first, as many in flight per lane as the caps allow, none started after a
    # stop; then, after ALL-DONE, the last act — each job's report from its records (a blind job
    # deferred it), the count, the analysis, and the readout. A failure or a signal after the stamp
    # and before a job starts voids the stamp; after, it is a registered stop (`Stop`): the launch
    # stops every job itself, since each runs in its own group beyond the terminal's reach, and the
    # last act still runs, its analysis writing the stop. A dead watch stops every job, since nothing
    # else would enforce the stops. Exit 0 when the analysis decided the batch; 3 when it wrote a stop
    # in place of a verdict; 1 when no analysis was written; 2 when the launch refused.
    class Launcher
      POLL_SECONDS = 1.0
      WATCH_START_SECONDS = 60
      BIN = File.expand_path("../../bin/screen", __dir__)
      # The watch's process: this checkout's `bin/screen watch` under this launch's own Ruby.
      WATCH = ->(home) { [Gem.ruby, BIN, "watch", "--home", home] }
      # Each instrument's own report writer, run in the job's tree over its records.
      REPORT = <<~RUBY.freeze
        require "json"
        records = File.readlines(ARGV.fetch(0), chomp: true, encoding: Encoding::UTF_8).map { |line| JSON.parse(line) }
        case ARGV.fetch(1)
        when "compose" then require "support/compose_bench"; E2E::ComposeBench::Report.write_all(records)
        when "task" then require "support/task_bench"; E2E::TaskBench::Report.write_offline(records)
        else raise ArgumentError, "no report for \#{ARGV.fetch(1)}"
        end
      RUBY

      # The watch process, reaped once.
      Child = Struct.new(:pid, :status, keyword_init: true) do
        def alive? = status.nil? && (self.status = ::Process.wait2(pid, ::Process::WNOHANG)&.last).nil?
        def wait = status || (self.status = ::Process.wait2(pid).last)
      end

      def initialize(definition:, trees:, home:, mode:, out: $stdout, keys_path: nil, inject: {}, stall_seconds: nil,
                     supersedes: nil, repo_root: nil, stage0: {}, analysis: nil, cells: nil, pricer: nil, job_command: JobRunner::PROBE,
                     watch_command: WATCH, sleep: ->(seconds) { Kernel.sleep(seconds) })
        @storm_relaunch = supersedes && storm?(supersedes)
        @definition = @storm_relaunch ? definition.after_storm : definition
        @trees = trees
        @home = home
        @mode = mode
        @out = out
        @keys_path = keys_path
        @inject = inject
        @stall_seconds = stall_seconds
        @supersedes = supersedes
        # Normal runs write the readout under the with tree's ignored artifacts. A rehearsal
        # keeps it in its own home; a fake relaunch reuses the home it supersedes as its ledger.
        @repo_root = repo_root || (mode == "fake" ? File.join(supersedes || home, "readout") : trees.fetch("with"))
        fake_rates = ->(**options) { Rates.call(**options, derive: method(:rehearsal_rates)) }
        @stage0_options = (mode == "fake" ? { rates: fake_rates } : {}).merge(stage0)
        @analysis = analysis || Analysis
        @cells = cells || Cells
        @pricer = pricer || BenchSpend.pricer(home)
        @job_command = job_command
        @watch_command = watch_command
        @sleep = sleep
      end

      def call
        paid_gate if @mode == "real"
        FileUtils.mkdir_p(File.join(@home, "logs"))
        say("launch #{@definition.name} · #{@mode} · home #{@home}")
        stamp
        return done_dry if @mode == "dry"

        watch = start_watch
        run_jobs(watch)
        finish(watch)
      rescue Refused => error
        say("REFUSED #{error.message}")
        2
      end

      private

        # A rehearsal can use catalog refs and fictional wire fixtures in the same definition.
        def rehearsal_rates(root:, models:)
          fictional, ordinary = models.partition { |model| model.start_with?("fake/") }
          catalog = ordinary.empty? ? {} : BenchSpend.derive(root: root, models: ordinary)
          catalog.merge(FakeBenchAdapter.rates(root: root, models: fictional))
        end

        # A paid launch is opted into by its own environment and holds every key its models need
        # before anything is stamped.
        def paid_gate
          ManualClient.validate!(ENV)
          raise Refused, "fake models require --fake" if @definition.drawn_models.any? { |model| model.start_with?("fake/") }

          missing = @definition.drawn_models.map { |model| ProviderLanes.route(model).lane.key_name }
            .uniq.reject { |name| keys.key?(name) }
          raise Refused, "the keys file holds no #{missing.join(", ")}" if missing.any?
        end

        # The smoke's jobs are numbered from 1 like the screen's, so a rehearsal's injections and
        # stall reach the screen's jobs alone: one meant for screen job 1 would otherwise fail the
        # smoke, or price its spend into the stamp.
        def stamp
          smoke = lambda do |jobs|
            deadline = Time.now.to_f + Float(@definition.smoke.fetch("timeout_seconds"))
            runner(log: ->(job) { Smoke.log(@home, job) }, inject: {}, stall_seconds: nil).run_to_end(jobs, deadline: deadline, sleep: @sleep)
          end
          path = Stage0.new(definition: @definition, trees: @trees, home: @home, mode: @mode, smoke_runner: smoke,
            pricer: @pricer, analysis: @analysis, supersedes: @supersedes, readout_root: @repo_root, **@stage0_options).call
          say("STAMPED #{path}")
        end

        def done_dry
          say("DRY: the rehearsal stamp is written; no job starts")
          0
        end

        # The watch process, alive and enforcing before the first job; one that never prints its
        # WATCH line, or a signal while it starts, voids the stamp and takes the watch with it.
        def start_watch
          log = logs("watch.log")
          watch = Child.new(pid: ::Process.spawn(*@watch_command.call(@home), out: log, err: [:child, :out], in: File::NULL,
            pgroup: true))
          deadline = Time.now.to_f + WATCH_START_SECONDS
          begin
            @sleep.call(0.2) until watching?(log) || !watch.alive? || Time.now.to_f > deadline
          rescue SignalException => error
            abandon(watch, "the launch received #{signal_of(error)} before its first job")
          end
          abandon(watch, "the watch did not start (logs/watch.log)") unless watching?(log) && watch.alive?
          watch
        end

        def watching?(log) = File.exist?(log) && File.read(log, encoding: Encoding::UTF_8).include?(" WATCH ")

        # A failure before any job started voids the stamp; after, it is a registered stop: every
        # job stopped and reaped, the watch told how many started, and the last act left to read it.
        # A fault owes the one relaunch; a signal (Ctrl-C, a TERM, a closed terminal) is a stop by hand
        # and owes none.
        def run_jobs(watch)
          jobs = runner
          drive(jobs, watch)
        rescue SignalException => error
          stop_launch(jobs, watch, WatchRules.hand_stop("the launch received #{signal_of(error)}"))
        rescue StandardError => error
          stop_launch(jobs, watch, "LAUNCH-FAULT #{error.class}: #{error.message[0, 200]}")
        end

        def stop_launch(jobs, watch, reason)
          if File.exist?(logs("jobs.tsv"))
            Stop.record(@home, reason)
            jobs.stop_all(sleep: @sleep)
            done_starting(File.readlines(logs("jobs.tsv")).size)
            say("STOPPED after the first job: #{reason}")
          else
            abandon(watch, "the launch stopped before its first job (#{reason})")
          end
        end

        # Nothing drew: the watch is stopped and the stamp voided.
        def abandon(watch, why)
          ::Process.kill("TERM", -watch.pid) if watch.alive?
          void(why)
        end

        def signal_of(error) = "SIG#{Signal.signame(error.signo)}"

        # The stamp's order (floors first); a job starts only while every cap its model counts against
        # has room, and none starts once the watch has stopped the screen — the jobs it is stopping
        # are still reaped here, since their `exit=N` is what the watch waits for. After a storm the
        # rest wait the registered stagger, counted from the moment the last floor started (from the
        # first poll when no floor is registered).
        def drive(jobs, watch)
          pending = registered
          started = 0
          held_until = nil
          until pending.empty? && jobs.running.empty?
            jobs.reap
            break halt(jobs) unless watch.alive?

            pending = [] if stopped?
            held_until ||= Time.now.to_f + @definition.stagger_seconds if @storm_relaunch && pending.none? { |job| floor?(job) }
            open = pending.select { |job| floor?(job) || !@storm_relaunch || (held_until && Time.now.to_f >= held_until) }
            launched = start_fitting(jobs, open)
            started += launched.size
            pending -= launched
            done_starting(started) if pending.empty?
            @sleep.call(POLL_SECONDS)
          end
          done_starting(started)
        end

        def floor?(job) = @definition.floors.include?(job.model)

        # The jobs of `open` that fit the caps, started in order.
        def start_fitting(jobs, open)
          open.select do |job|
            fits = @definition.caps.all? do |prefix, cap|
              !job.model.start_with?(prefix) || jobs.running.count { |running| running.model.start_with?(prefix) } < cap
            end
            jobs.start(job) if fits
            fits
          end
        end

        # How many jobs the launch started, written once nothing more will start — whole, by a
        # rename, since the watch reads the count; the watch ends when it has seen that many exit.
        def done_starting(started)
          unless File.exist?(logs("launched.done"))
            File.write("#{logs("launched.done")}.tmp", "#{started}\n")
            File.rename("#{logs("launched.done")}.tmp", logs("launched.done"))
          end
        end

        # NO WATCH, NO SCREEN: with the watch dead, nothing would enforce a stop, so the launch
        # stops every job itself.
        def halt(jobs)
          Stop.record(@home, "WATCH-DIED the watch exited while #{jobs.running.size} jobs ran")
          say("THE WATCH DIED — stopping every job")
          jobs.stop_all(sleep: @sleep)
        end

        def finish(watch)
          status = watch.wait
          say("ALL-DONE (watch exit #{status.exitstatus}) #{File.read(logs("watch.log"), encoding: Encoding::UTF_8).lines.last.to_s.strip}")
          last_act
        end

        # THE LAST ACT: the deferred reports, the count, the analysis, the readout — a stopped batch's
        # too, its analysis writing the stop and its readout keeping it in the screen's ledger.
        def last_act
          registered.each { |job| report(job) }
          File.write(File.join(@home, "counts.txt"), "#{counts.join("\n")}\n")
          path = @analysis.run(@definition, @home)
          return not_done("the analysis wrote nothing") unless path && File.exist?(path)

          cells = @cells.extract(Records.landed(registered, @home))
          dest = Readout.write(home: @home, definition: @definition, root: @repo_root, cells: cells)
          stop = Stop.reason(@home)
          if stop
            say("STOPPED: #{path}; readout #{dest} — #{stop}")
            3
          else
            say("DONE: #{path}; readout #{dest}")
            0
          end
        end

        # The stamp's job table, the one every reader after the stamp reads.
        def registered = @registered ||= Stamp.jobs(Stamp.read(@home))

        def report(job)
          return if records(job).empty?

          out, ok = COMMAND.call(["bundle", "exec", "ruby", "-I.", "-e", REPORT, File.join(job.path(@home), Records::FILE), job.instrument],
            chdir: File.join(@definition.tree_root(job.arm, @trees), "e2e"),
            env: { "E2E_BENCH_DIR" => job.path(@home), "E2E_BENCH_CAPTURES_DIR" => File.join(job.path(@home), "captures") })
          say("report #{job.index}: #{ok ? "written" : "FAILED #{out.lines.last.to_s.strip}"}")
        end

        def counts
          launched_at = Stamp.launched_at(Stamp.read(@home))
          registered.map do |job|
            problems = job.count_problems(records(job), launched_at: launched_at)
            "#{problems.empty? ? "ok " : "BAD"} #{job.index} #{job.dir}: #{records(job).size}/#{job.planned}#{" — #{problems.join("; ")}" if problems.any?}"
          end
        end

        def records(job) = Records.written(job, @home)

        def not_done(why)
          say("NOT DONE: #{why}")
          1
        end

        def void(why)
          voided = Stamp.void(@home)
          raise Refused, "#{why} — the stamp is void (#{voided}); nothing drew"
        end

        def runner(log: nil, inject: @inject, stall_seconds: @stall_seconds)
          JobRunner.new(home: @home, definition: @definition, trees: @trees, client: @mode == "real" ? "real" : "fake",
            keys: @mode == "real" ? keys : {}, inject: inject, stall_seconds: stall_seconds, log: log, command: @job_command)
        end

        # The provider keys, `NAME=value` lines (an `export ` prefix and quotes allowed); a line
        # that does not parse is refused without being printed, since it may hold a key.
        def keys
          @keys ||= File.readlines(@keys_path, chomp: true, encoding: Encoding::UTF_8).each_with_index.filter_map do |line, number|
            next if line.strip.empty? || line.strip.start_with?("#")

            name, value = line.delete_prefix("export ").split("=", 2)
            raise Refused, "the keys file's line #{number + 1} is not NAME=value" unless value && name.match?(/\A[A-Z0-9_]+\z/)

            [name, value.strip.delete_prefix("\"").delete_suffix("\"").delete_prefix("'").delete_suffix("'")]
          end.to_h
        end

        def storm?(home) = Stop.reason(home)&.then { |reason| Stop.kind(reason) == "STORM" }

        def stopped? = File.exist?(Stop.path(@home))
        def logs(name) = File.join(@home, "logs", name)

        def say(line)
          @out.puts("#{Time.now.utc.iso8601} #{line}")
          @out.flush
        end
    end
  end
end
