require "fileutils"
require_relative "process_registry"

module E2E
  # K WORLDS, ONE VERDICT. The parent spawns one `rake e2e_group[k]` per
  # group — each a whole `run_e2e_tests` of its own: its own Nexus, mock,
  # hosts, Humans and ledgers — waits for all of them, prints one line per
  # group as it finishes, tails the log of any that failed, and answers
  # true only when every group passed.
  #
  # The children are process groups under ProcessRegistry. This owner stops
  # them before the generic exit sweep, allowing their database cleanup to finish. Each
  # child bounds itself through E2E_DEADLINE_SECONDS; the parent's own wait
  # is that bound per wave plus a grace for reaping, after which stragglers
  # are terminated and counted as failures.
  #
  # `slots` is how many worlds run AT ONCE; the rest start as slots free
  # up. The manifest's groups are a correctness split (E2E::JourneyGroups),
  # the slot count is the machine's: one world holds ~29 Postgres
  # connections at its peak (Puma, the two hosts, the operator's transient
  # runners — measured 2026-09-09), against a default `max_connections` of
  # 100 with a handful already in use.
  class GroupRun
    POLL_INTERVAL = 0.5
    REAP_GRACE_SECONDS = 60
    TAIL_LINES = 60

    Verdict = Data.define(:group, :ok, :seconds, :log)

    def initialize(groups:, deadline:, log_dir:, slots: groups.size, reap_grace: REAP_GRACE_SECONDS,
                   shutdown_timeout: REAP_GRACE_SECONDS)
      raise ArgumentError, "slots must be positive" unless slots.positive?

      @groups = groups
      @deadline = deadline
      @log_dir = log_dir
      @slots = slots
      @reap_grace = reap_grace
      @shutdown_timeout = shutdown_timeout
    end

    # What a group child gets beyond the inherited environment: the assets
    # are already built (shared lock only), the per-group bound, and NO
    # pinned Nexus port — a developer's exported E2E_NEXUS_PORT would make
    # every world reserve the same one. nil unsets; Process.spawn honours it.
    def child_env(_group)
      {
        "E2E_ASSETS_PREPARED" => "1",
        "E2E_DEADLINE_SECONDS" => @deadline.to_s,
        "E2E_NEXUS_PORT" => nil,
      }
    end

    # `command` maps a group key to the argv that runs it. Returns true when
    # every group exited 0 within the bound. The seconds printed per group
    # are the group's OWN, from its spawn — never the time it queued for a
    # slot — so they can be copied into JourneyGroups::WEIGHTS as they are.
    def run(command:, out: $stdout, chdir: nil)
      FileUtils.mkdir_p(@log_dir)
      started = monotonic
      pending = @groups.dup
      running = {}
      verdicts = []
      waves = (@groups.size.to_f / @slots).ceil
      bound = started + (@deadline * waves) + @reap_grace
      loop do
        while running.size < @slots && !pending.empty?
          group = pending.shift
          running[group] = [spawn_group(group, command.call(group), chdir), monotonic]
        end
        break if running.empty? || monotonic > bound

        running.each do |group, (pid, spawned_at)|
          result = Process.wait2(pid, Process::WNOHANG)
          next unless result

          ProcessRegistry.unregister(pid)
          running.delete(group)
          verdicts << report(out, group, result.last.success?, monotonic - spawned_at)
        end
        sleep POLL_INTERVAL unless running.empty?
      end
      running.each do |group, (pid, spawned_at)|
        ProcessRegistry.terminate(pid, timeout: @shutdown_timeout)
        running.delete(group)
        verdicts << report(out, group, false, monotonic - spawned_at, note: "exceeded #{(@deadline * waves) + @reap_grace} s")
      end
      verdicts.reject(&:ok).each { |verdict| out.puts tail(verdict) }
      verdicts.all?(&:ok)
    ensure
      running&.each_value do |pid, _spawned_at|
        ProcessRegistry.terminate(pid, timeout: @shutdown_timeout)
      end
    end

    def log_path(group)
      File.join(@log_dir, "#{group}.log")
    end

    private

      def spawn_group(group, argv, chdir)
        options = { out: [log_path(group), "w"], err: [:child, :out], pgroup: true }
        options[:chdir] = chdir if chdir
        ProcessRegistry.spawn(child_env(group), *argv, **options)
      end

      def report(out, group, ok, seconds, note: nil)
        verdict = Verdict.new(group: group, ok: ok, seconds: seconds.round, log: log_path(group))
        out.puts format("group %-2s %-5s %4d s  %s%s", group, ok ? "pass" : "FAIL", verdict.seconds, verdict.log,
          note ? "  (#{note})" : "")
        verdict
      end

      # The failing group's own output already redacts what it prints; the
      # tail is read as UTF-8 and scrubbed so a stray byte cannot hide it.
      def tail(verdict)
        lines = File.readlines(verdict.log, encoding: Encoding::UTF_8).last(TAIL_LINES).join.scrub
        "---- group #{verdict.group} failed; last #{TAIL_LINES} lines of #{verdict.log} ----\n#{lines}"
      rescue SystemCallError => error
        "---- group #{verdict.group} failed; no log at #{verdict.log} (#{error.class}) ----"
      end

      def monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
  end
end
