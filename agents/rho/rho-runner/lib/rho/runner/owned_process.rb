module Rho
  class Runner
    # Owns a command plus an unreaped process-group identity guard. The guard
    # reserves the PGID after the command is reaped, so a final group signal
    # cannot hit a newly reused PID. Guard reap and ownership release are one
    # mutex transition, making late cancellation callbacks harmless.
    class OwnedProcess
      POLL_SECONDS = 0.01
      # true(1) lives in /usr/bin on merged-/usr systems (macOS, Fedora,
      # Debian) but only in /bin on Alpine/busybox, and NixOS has neither
      # guaranteed — resolve once instead of hardcoding one layout.
      GROUP_IDENTITY_GUARD_CANDIDATES = %w[/usr/bin/true /bin/true].freeze
      private_constant :GROUP_IDENTITY_GUARD_CANDIDATES

      def self.group_identity_guard
        @group_identity_guard ||=
          GROUP_IDENTITY_GUARD_CANDIDATES.find { |path| File.executable?(path) } ||
          raise(Error,
                "no true(1) binary for the process-group identity guard " \
                "(looked for #{GROUP_IDENTITY_GUARD_CANDIDATES.join(", ")})")
      end

      attr_reader :pid, :group_pid

      def self.spawn(*argv, **options)
        if options.key?(:pgroup)
          raise ArgumentError, "OwnedProcess owns the process group"
        end

        group_pid = Process.spawn(
          group_identity_guard,
          in: File::NULL, out: File::NULL, err: File::NULL, pgroup: true
        )
        pid = Process.spawn(*argv, **options.merge(pgroup: group_pid))
        new(pid, group_pid:)
      rescue Exception
        cleanup_failed_spawn(pid:, group_pid:)
        raise
      end

      def self.cleanup_failed_spawn(pid:, group_pid:)
        if group_pid
          begin
            Process.kill("KILL", -group_pid)
          rescue Errno::ESRCH, Errno::EPERM
            nil
          end
        end
        [pid, group_pid].compact.each do |child_pid|
          Process.waitpid(child_pid)
        rescue Errno::ECHILD
          nil
        end
      end
      private_class_method :cleanup_failed_spawn

      def initialize(pid,
                     group_pid:,
                     waitpid: ->(owned_pid, flags) { Process.waitpid2(owned_pid, flags) },
                     signal: ->(owned_group_pid) { Process.kill("KILL", -owned_group_pid) },
                     sleeper: ->(seconds) { sleep(seconds) })
        @pid = pid
        @group_pid = group_pid
        @waitpid = waitpid
        @signal = signal
        @sleeper = sleeper
        @mutex = Mutex.new
        @status = nil
        @group_status = nil
        @signaled = false
        @released = false
      end

      def poll
        @mutex.synchronize do
          return @status if @status

          reaped_pid, status = @waitpid.call(pid, Process::WNOHANG)
          @status = status if reaped_pid
          @status
        end
      end

      def wait(check_cancellation: true)
        loop do
          status = poll
          return status if status

          ExecutionContext.current&.raise_if_cancelled! if check_cancellation
          @sleeper.call(POLL_SECONDS)
        end
      end

      # A SIGNAL THAT IS NOT THE FINAL ONE. `cancel` is the latch: KILL to
      # the group, once, and the group is as good as gone. A dev server
      # deserves a TERM first so it can close its port and its children —
      # and TERM must not flip the latch, or the KILL that has to follow a
      # server that ignored it would be refused as already sent. No-op
      # once the guard is reaped: the PGID may be somebody else's by then.
      def terminate(signal = "TERM")
        @mutex.synchronize do
          return false if @released

          begin
            Process.kill(signal, -group_pid)
          rescue Errno::ESRCH, Errno::EPERM
            return false
          end
        end
        true
      end

      # Signal only. Reaping belongs to the worker's ensure path.
      def cancel
        @mutex.synchronize do
          return false if @released || @signaled

          begin
            @signal.call(group_pid)
          rescue Errno::ESRCH, Errno::EPERM
            nil
          end
          @signaled = true
        end
        true
      end

      def kill_and_reap
        cancel
        status = wait(check_cancellation: false)
        reap_group_guard
        status
      end

      private

      def reap_group_guard
        loop do
          status = @mutex.synchronize do
            next @group_status if @group_status

            reaped_pid, group_status = @waitpid.call(group_pid, Process::WNOHANG)
            if reaped_pid
              @group_status = group_status
              @released = true
            end
            @group_status
          end
          return status if status

          @sleeper.call(POLL_SECONDS)
        end
      end
    end
  end
end
