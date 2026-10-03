require "digest"
require "json"
require "open3"
require "time"
require_relative "../bench_records"
require_relative "records"
require_relative "stamp"
require_relative "stop"
require_relative "watch_rules"

module E2E
  module Screen
    # THE WATCH: its own process (`bin/screen watch --home H`), started by the launch before any
    # job and alive until every job has ended. Each poll it reads what the jobs wrote — the record
    # stream, the call stream, the log (progress lines and the launch's `exit=N`) — prices the
    # records, takes one snapshot, and applies `WatchRules`: a stop writes `logs/STOPPED` first (the
    # launch starts nothing after it), then TERMs every running job's process group, KILLs what is
    # left after the grace, and records each signal in `logs/stops.tsv`; a job that registers after
    # the stop is stopped the moment it is seen.
    #
    # IT IS OUTCOME-BLIND. It prints one line per record carrying only the job, the draw's place,
    # when, how long, the tokens, the dollars, the retries and an error's class — never a door, a
    # pass or a shape — and one per stop, flag and heartbeat. The orchestrator reads this stream and
    # nothing else until ALL-DONE. `observe: true` prints the same and never stops anything.
    class Watch
      # One job's running tally — a mutable in-process handle the poll stamps, never passed on.
      Tally = Struct.new(:job, :started, :records_at, :calls_at, :log_at, :calls, :bad_calls, :draws, :lost, :faults,
        :progress, :usd, :last_seen, :exit_status, :stopped, :flagged, :kill_at, :term_pending, keyword_init: true)

      # One tree's state: HEAD, the hash of its status over what a screen watches (`WATCHED`), and
      # the hash of the compose builder the evaluator re-reads from disk on every call. The stamp
      # carries it; the watch and the analysis compare against it.
      def self.tree_state(root)
        head, _, head_ok = Open3.capture3("git", "--no-optional-locks", "-C", root, "rev-parse", "HEAD")
        status, _, status_ok = Open3.capture3("git", "--no-optional-locks", "-C", root, "status", "--porcelain", "--", *WATCHED)
        return "unreadable" unless head_ok.success? && status_ok.success?

        builder = File.join(root, "nexus/lib/nexus/compose/builder.js")
        [head.strip, Digest::SHA256.hexdigest(status), File.file?(builder) ? Digest::SHA256.file(builder).hexdigest : "missing"].join(" ")
      end

      attr_reader :stop

      # `pricer` answers a record's dollars (`BenchSpend.pricer` in a launch); `clock` the epoch now;
      # `tree_probe` a root's state.
      def initialize(home, pricer:, observe: false, out: $stdout, clock: -> { Time.now.to_f },
                     tree_probe: ->(root) { Watch.tree_state(root) })
        @home = home
        @pricer = pricer
        @observe = observe
        @out = out
        @clock = clock
        @tree_probe = tree_probe
        @stamp = Stamp.read(home)
        @params = WatchRules::Params.from_stamp(@stamp)
        @jobs = Stamp.jobs(@stamp).to_h { |job| [job.index, job] }
        @launched = Stamp.launched_at(@stamp).to_f
        @tallies = {}
        @take_errors = 0
        @stop = nil
        @last_beat = clock.call
      end

      def run(sleep: ->(seconds) { Kernel.sleep(seconds) })
        say("WATCH", "#{@observe ? "observing" : "enforcing"} #{@home} · #{@jobs.size} jobs · #{@params.lines.join(" ")}")
        loop do
          poll
          break if finished?

          sleep.call(@params.poll_seconds)
        end
        poll
        say("ALL-DONE", "draws #{@tallies.values.sum(&:draws)}/#{@jobs.values.sum(&:planned)} · spend $#{format("%.2f", spend)} · stop #{@stop || "none"}")
        @stop ? 3 : 0
      end

      def poll
        register_started
        @tallies.each_value { |tally| read(tally) }
        enforce unless @observe
        beat
        write_state unless @observe
      end

      def spend = Float(@stamp.fetch("smoke_spend_usd", 0)) + @tallies.values.sum(&:usd)

      # Every job the launch started has ended: the launch has written how many it started, the
      # watch has registered that many, and each has its `exit=N` — or, once the watch has stopped
      # the screen, a group with no process left in it (a launch that died writes no `exit=N`, and
      # nothing else would end the watch). Before a stop the exit line is waited for, since the
      # harness-fault stop reads its status.
      def finished?
        launched = logs("launched.done")
        File.exist?(launched) && Integer(File.read(launched, encoding: Encoding::UTF_8)) == @tallies.size &&
          @tallies.values.all? { |tally| tally.exit_status || (@stop && gone?(tally)) }
      end

      def snapshot
        WatchRules::State.new(spend_usd: spend, elapsed_seconds: @clock.call - @launched, jobs: @tallies.values.map { |tally| job_state(tally) },
          stop_request: (File.read(logs("STOP.request"), encoding: Encoding::UTF_8) if File.exist?(logs("STOP.request"))),
          trees: trees, take_errors: @take_errors)
      end

      private

        # The launch appends `index<TAB>started-epoch` as it starts each job.
        def register_started
          return unless File.exist?(logs("jobs.tsv"))

          File.readlines(logs("jobs.tsv"), chomp: true, encoding: Encoding::UTF_8).each do |line|
            index, started = line.split("\t")
            next if index.nil? || @tallies.key?(Integer(index))

            job = @jobs.fetch(Integer(index))
            @tallies[job.index] = Tally.new(job: job, started: Float(started), records_at: 0, calls_at: 0, log_at: 0, calls: 0,
              bad_calls: 0, draws: 0, lost: 0, faults: 0, progress: 0, usd: 0.0, last_seen: Float(started), flagged: false)
            say("START", "#{job.index} #{job.arm} #{job.instrument} #{job.model} n=#{job.n}×#{job.objectives.size}")
            late_start(@tallies[job.index]) if @stop && !@observe
          end
        end

        def read(tally)
          path = tally.job.path(@home)
          tally.log_at = each_line(log_of(tally.job), tally.log_at) { |line| take_log(tally, line) }
          tally.calls_at = each_line(File.join(path, BenchRecords::CALLS), tally.calls_at) { |line| take_call(tally, JSON.parse(line)) }
          tally.records_at = each_line(File.join(path, BenchRecords::RECORDS), tally.records_at) { |line| take_guarded(tally, line) }
        end

        def take_log(tally, line)
          tally.progress += 1 if line.match?(BenchRecords::PROGRESS)
          tally.exit_status ||= Integer(line.delete_prefix("exit=")) if line.match?(/\Aexit=-?\d+\z/)
        end

        # A BAD CALL ended unreached — a provider's error, its attempts spent. A call the transport
        # asked again and that then answered is a draw like any other, a rate limit waited out: its
        # retries print on its record's line, and the wall stop bounds the time their pauses took.
        def take_call(tally, call)
          tally.calls += 1
          tally.bad_calls += 1 if call["error_class"] && !BenchRecords.harness_fault?(call["error_class"])
          tally.last_seen = [tally.last_seen, Time.iso8601(call.fetch("recorded_at")).to_f].max
        end

        # A record the watch cannot take is an alarm and is not counted; enough of them stop the
        # screen, since the spend stop cannot see what the watch cannot take.
        def take_guarded(tally, line)
          take_record(tally, JSON.parse(line))
        rescue StandardError => error
          @take_errors += 1
          say("ALARM", "TAKE-ERROR #{tally.job.index}: #{error.class}: #{error.message[0, 160]}")
        end

        # A record is read as the analysis reads its draw (`Records`, by the job's instrument): a
        # harness fault, a lost draw (a failed call), its calls' tokens, retries and seconds.
        def take_record(tally, record)
          usd = Float(@pricer.call(record))
          draw = record.merge("instrument" => tally.job.instrument)
          tally.draws += 1
          tally.usd += usd
          tally.faults += 1 if Records.fault?(draw)
          tally.lost += 1 if Records.lost?(draw)
          tally.last_seen = [tally.last_seen, Time.iso8601(record.fetch("recorded_at")).to_f].max
          say("RECORD", blind_line(draw, usd))
        end

        def blind_line(draw, usd)
          usages = Records.usages(draw)
          tokens = Records::TOKENS.map { |key| usages.sum { |usage| usage[key].to_i } }
          error = Records.errors(draw).first
          format("%s %s %s %s #%s %s %.1fs tokens(%d %d %d %d) $%.4f retries %d %s", draw["arm"], draw["process"], draw["model"],
            draw["objective"], draw["sample"], draw["recorded_at"], Records.seconds(draw), *tokens, usd, Records.retries(draw),
            error&.split(": ", 2)&.first || "-")
        end

        def job_state(tally)
          WatchRules::JobState.new(index: tally.job.index, arm: tally.job.arm, model: tally.job.model, planned: tally.job.planned,
            calls: tally.calls, bad_calls: tally.bad_calls, draws: tally.draws, lost: tally.lost, faults: tally.faults,
            progress: tally.progress, quiet_seconds: @clock.call - tally.last_seen, exit_status: tally.exit_status,
            stopped: !tally.stopped.nil?)
        end

        def trees
          %w[with without].filter_map do |tag|
            root = @stamp["tree.#{tag}.root"]
            WatchRules::TreeState.new(tag: tag, root: root, stamped: @stamp.fetch("tree.#{tag}.state"), now: @tree_probe.call(root)) if root
          end
        end

        def enforce
          state = snapshot
          if @stop.nil?
            reason = WatchRules.stop_reason(state, @params)
            reason ? stop_all(reason) : flag(state)
          end
          @tallies.each_value { |tally| follow_up(tally) }
        end

        def flag(state)
          WatchRules.flags(state, @params).each do |index, flag|
            tally = @tallies.fetch(index)
            next if tally.flagged

            tally.flagged = true
            say("ALARM", flag)
          end
        end

        # The first stop recorded wins: a launch that faulted wrote its own before the exits its
        # fault caused reached the watch.
        def stop_all(reason)
          @stop = reason
          say("ALARM", "STOPPED already records #{Stop.reason(@home)}") unless Stop.record(@home, reason)
          say("STOP", "#{reason} — #{WatchRules.relaunch_owed?(reason) ? "the one whole relaunch is owed" : "no relaunch owed"}")
          @tallies.each_value { |tally| terminate(tally, "stop: #{reason}") if tally.exit_status.nil? }
        end

        def late_start(tally)
          say("ALARM", "LATE-START #{tally.job.index} registered after the stop — stopping it")
          terminate(tally, "late start after: #{@stop}")
        end

        def terminate(tally, why)
          tally.stopped = why
          tally.term_pending = signal(tally, "TERM") == "no pgid"
          tally.kill_at = @clock.call + @params.kill_grace_seconds
        end

        # A TERM that found no pgid yet is sent once it exists; a job still running past the grace
        # is killed.
        def follow_up(tally)
          return unless tally.exit_status.nil? && tally.stopped

          if tally.term_pending && pgid(tally)
            tally.term_pending = false
            signal(tally, "TERM")
          end
          return unless tally.kill_at && @clock.call >= tally.kill_at && !tally.term_pending

          tally.kill_at = nil
          signal(tally, "KILL")
        end

        def signal(tally, name)
          group = pgid(tally)
          outcome = if group
            begin
              ::Process.kill(name, -group)
              "sent"
            rescue Errno::ESRCH, Errno::EPERM # macOS answers EPERM once only zombies remain in the group
              "gone"
            end
          else
            "no pgid"
          end
          File.write(logs("stops.tsv"), "#{Time.now.utc.iso8601}\t#{tally.job.index}\t#{name}\t#{group}\t#{outcome}\t#{tally.stopped}\n", mode: "a")
          outcome
        end

        def pgid(tally)
          path = File.join(tally.job.path(@home), "pgid")
          Integer(File.read(path, encoding: Encoding::UTF_8).strip) if File.exist?(path)
        end

        # No process is left in the job's group: reaped by the launch, or by the system once the
        # launch itself is gone. Zombies (EPERM on macOS) are still the live launch's to reap.
        def gone?(tally)
          group = pgid(tally)
          ::Process.kill(0, -group) if group
          false
        rescue Errno::ESRCH
          true
        rescue Errno::EPERM
          false
        end

        def beat
          now = @clock.call
          return if now - @last_beat < @params.heartbeat_seconds

          @last_beat = now
          running = @tallies.values.count { |tally| tally.exit_status.nil? }
          say("HEARTBEAT", format("elapsed %.1f min · draws %d/%d · spend $%.2f · running %d of %d started", (now - @launched) / 60,
            @tallies.values.sum(&:draws), @jobs.values.sum(&:planned), spend, running, @tallies.size))
        end

        def write_state
          state = { "at" => Time.now.utc.iso8601, "spend_usd" => spend.round(6), "stop" => @stop,
                    "jobs" => @tallies.transform_values { |tally| tally.to_h.slice(:calls, :bad_calls, :draws, :lost, :faults, :progress, :usd, :exit_status, :stopped) } }
          File.write("#{logs("watch-state.json")}.tmp", JSON.pretty_generate(state))
          File.rename("#{logs("watch-state.json")}.tmp", logs("watch-state.json"))
        end

        # Complete lines appended since `offset`; the new offset after the last one taken.
        def each_line(path, offset)
          return offset unless File.exist?(path)

          chunk = File.binread(path, nil, offset).to_s
          body = chunk[0..chunk.rindex("\n")] if chunk.include?("\n")
          return offset unless body

          body.force_encoding(Encoding::UTF_8).each_line(chomp: true) { |line| yield line }
          offset + body.bytesize
        end

        def log_of(job) = logs("#{job.index}.log")
        def logs(name) = File.join(@home, "logs", name)

        def say(kind, message)
          @out.puts("#{Time.now.utc.iso8601} #{kind} #{message}")
          @out.flush
        end
    end
  end
end
