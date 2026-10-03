require_relative "../bench_records"
require_relative "records"

module E2E
  module Screen
    # THE WATCH'S REGISTERED STOPS, as pure functions of one snapshot of a running screen — what the
    # stamp's `watch.*` parameters say, applied the same way every poll. `Watch` gathers the snapshot
    # from the job directories and acts on the answer; nothing here reads a file or a clock.
    #
    # Every stop but one owes the ONE whole relaunch under a new stamp: a moved tree, a watch that
    # cannot read its records, spend, wall, a harness-fault class in a record or a job's non-zero
    # exit, a transport storm, lost draws over the count floor, a job whose progress runs ahead of
    # its records, a stalled call. The exception is a hand stop (`STOP.request`) that names no
    # harness-fault class and no record id: it is recorded, the candidate reads NOT LANDED, and no
    # relaunch is owed — a stop by hand is never a discretionary rerun.
    module WatchRules
      # An error class a hand stop names, spelled the way Ruby and this harness name their errors (a
      # stream's `WriteFailed`, a system call's `Errno::ENOENT`); one is a harness fault by the
      # records' one rule (`BenchRecords.harness_fault?`).
      ERROR_CLASS = /\b(?:[A-Z]\w*::)*(?:[A-Z]\w*(?:Error|Exception|Failed)|Errno::[A-Z]+)\b/
      # A record id a hand stop names: `<process>:<objective>#<sample>`.
      RECORD_ID = /\b\d+:[A-Za-z0-9′'-]+#\d+\b/

      Params = Data.define(:spend_stop_usd, :wall_stop_seconds, :stall_flag_seconds, :stall_stop_seconds, :storm_share,
        :storm_min_events, :lost_share, :lost_min_draws, :blind_gap, :take_error_limit, :poll_seconds, :heartbeat_seconds,
        :kill_grace_seconds) do
        # A definition's (or stamp's) `watch` section, every parameter named and numeric; a name the
        # watch does not know or a missing one is refused.
        def self.from(hash)
          numbers = hash.to_h { |key, value| [key.to_s.to_sym, Float(value)] }
          unknown = numbers.keys - members
          missing = members - numbers.keys
          raise ArgumentError, "watch parameters: unknown #{unknown.join(", ")}" if unknown.any?
          raise ArgumentError, "watch parameters: missing #{missing.join(", ")}" if missing.any?

          new(**numbers)
        end

        # The parameters as a stamp carries them, its `watch.<name>` lines.
        def self.from_stamp(stamp) = from(stamp.select { |key, _| key.start_with?("watch.") }.transform_keys { |key| key.delete_prefix("watch.") })

        def lines = to_h.map { |name, value| "watch.#{name}=#{value}" }

        # THE LOST CLASS these parameters register: the watch's stop and the analysis's relaunch read
        # the one rule, from the one stamped pair.
        def lost_rule = Records::Lost.new(share: lost_share, draws: lost_min_draws)
      end

      # One job as the watch last read it. `calls`/`bad_calls` are provider calls from the call stream
      # (bad: ended unreached, in a non-fault error; a call answered after its retries is not one);
      # `draws`/`lost` scored draws from the record stream (lost: a draw a non-fault error ended —
      # any of a task draw's messages); `faults` the records carrying a harness-fault class;
      # `progress` the probe's progress lines; `quiet_seconds` since its last call, record or start;
      # `exit_status` nil while it runs.
      JobState = Data.define(:index, :arm, :model, :planned, :calls, :bad_calls, :draws, :lost, :faults, :progress,
        :quiet_seconds, :exit_status, :stopped) do
        def name = "#{index} #{arm} #{model}"
        def running? = exit_status.nil?
      end
      # A tree the stamp named, as stamped and as it reads now.
      TreeState = Data.define(:tag, :root, :stamped, :now)
      State = Data.define(:spend_usd, :elapsed_seconds, :jobs, :stop_request, :trees, :take_errors)

      module_function

      # The first registered stop the snapshot meets, as its sentence (the class word first), or nil.
      def stop_reason(state, params)
        manual(state) || tree_moved(state) || watch_fault(state, params) || spend(state, params) || wall(state, params) ||
          harness_fault(state) || storm(state, params) || lost(state, params) || blind(state, params) || stall(state, params)
      end

      # The advisory flags, never a stop, by job index: a job quiet past the flag.
      def flags(state, params)
        state.jobs.select { |job| job.running? && job.quiet_seconds >= params.stall_flag_seconds }
          .to_h { |job| [job.index, "STALL-FLAG #{job.name}: no call for #{minutes(job.quiet_seconds)}"] }
      end

      # A stop owes the one relaunch unless it is a hand stop that named no fault.
      def relaunch_owed?(reason) = !reason.start_with?("MANUAL ")

      # A STOP BY HAND that names no fault — a `STOP.request` naming none, a signal to the launch:
      # recorded, the candidate NOT LANDED, and no relaunch owed.
      def hand_stop(what) = "MANUAL #{what} — names no harness-fault class and record id: NOT LANDED, no relaunch owed"

      def manual(state)
        text = state.stop_request&.strip
        if text.nil?
          nil
        elsif text.scan(ERROR_CLASS).any? { |name| BenchRecords.harness_fault?(name) } && text.match?(RECORD_ID)
          "MANUAL-FAULT #{text}"
        else
          hand_stop(text.empty? ? "STOP.request" : text)
        end
      end

      def tree_moved(state)
        moved = state.trees.find { |tree| tree.now != tree.stamped }
        "TREE-MOVED #{moved.tag} tree #{moved.root}: stamped [#{moved.stamped}], now [#{moved.now}]" if moved
      end

      def watch_fault(state, params)
        "WATCH-FAULT #{state.take_errors} records the watch could not take" if state.take_errors >= params.take_error_limit
      end

      def spend(state, params)
        format("SPEND $%.2f ≥ $%.2f", state.spend_usd, params.spend_stop_usd) if state.spend_usd >= params.spend_stop_usd
      end

      def wall(state, params)
        "WALL #{minutes(state.elapsed_seconds)} ≥ #{minutes(params.wall_stop_seconds)}" if state.elapsed_seconds >= params.wall_stop_seconds
      end

      def harness_fault(state)
        faulted = state.jobs.find { |job| job.faults.positive? }
        return "HARNESS-FAULT #{faulted.name}: #{faulted.faults} records carry a harness-fault class" if faulted

        exited = state.jobs.find { |job| !job.running? && !job.exit_status.zero? && !job.stopped }
        "HARNESS-FAULT #{exited.name}: exit=#{exited.exit_status}" if exited
      end

      # A storm reads per job once it has `storm_min_events` bad calls: below that a share is one
      # early loss, not a storm.
      def storm(state, params)
        stormy = state.jobs.find do |job|
          job.bad_calls >= params.storm_min_events && job.bad_calls >= params.storm_share * job.calls
        end
        format("STORM %s: %d of %d calls unreached (%.1f %%)", stormy.name, stormy.bad_calls, stormy.calls,
          100.0 * stormy.bad_calls / stormy.calls) if stormy
      end

      # LOST pools a (model, arm) over its instruments against its planned draws: more than the share
      # AND at least `lost_min_draws`, since one draw of sixteen is already over five per cent.
      def lost(state, params)
        pools = state.jobs.group_by { |job| [job.model, job.arm] }
        found = pools.find { |_key, jobs| params.lost_rule.over?(jobs.sum(&:lost), jobs.sum(&:planned)) }
        return unless found

        (model, arm), jobs = found
        "LOST #{model} #{arm}: #{jobs.sum(&:lost)} of #{jobs.sum(&:planned)} planned draws lost"
      end

      # A job whose progress lines run ahead of its records is writing no stream the spend stop can
      # see.
      def blind(state, params)
        ahead = state.jobs.find { |job| job.progress - job.draws >= params.blind_gap }
        "BLIND #{ahead.name}: #{ahead.progress} progress lines, #{ahead.draws} records" if ahead
      end

      # The stall clock ticks per CALL, so the stop sits above one call's whole retry chain.
      def stall(state, params)
        stalled = state.jobs.find { |job| job.running? && job.quiet_seconds >= params.stall_stop_seconds }
        "STALL-STOP #{stalled.name}: no call for #{minutes(stalled.quiet_seconds)}" if stalled
      end

      def minutes(seconds) = seconds >= 60 ? format("%.1f min", seconds / 60.0) : format("%.0f s", seconds)
      private_class_method :manual, :tree_moved, :watch_fault, :spend, :wall, :harness_fault, :storm, :lost, :blind,
        :stall, :minutes
    end
  end
end
