require "timeout"

module E2E
  # Runs a bounded child command in its own process group. If its caller is
  # interrupted or times out, every descendant is terminated with it.
  class ProcessRunner
    TERMINATION_TIMEOUT = 5
    KILL_REAP_TIMEOUT = 1
    POLL_INTERVAL = 0.05

    @terminate_calls = 0
    @terminate_seconds = 0.0

    class << self
      # How many process groups this process stopped and how long the stops
      # took in all — printed at the end of a run, because a daemon that hits
      # its drain deadline on every stop is a cost nothing else measures.
      attr_reader :terminate_calls, :terminate_seconds

      # `stdin` is how a SECRET reaches a child: an argument is readable by
      # anything that can run `ps`, and an environment variable is inherited by
      # everything the child spawns. A pipe is neither.
      def run(*command, env: {}, chdir: nil, out: $stdout, err: $stderr,
              timeout: nil, deadline: nil, stdin: nil, termination_timeout: TERMINATION_TIMEOUT)
        options = { out: out, err: err, pgroup: true }
        options[:chdir] = chdir if chdir
        reader, writer = IO.pipe if stdin
        options[:in] = reader if stdin
        started_at = monotonic
        finish_deadline = deadline_for(started_at, timeout: timeout, deadline: deadline)

        pid = Process.spawn(env, *command, **options)
        if stdin
          reader.close
          writer.write(stdin)
          writer.close
        end
        wait(pid, deadline: wait_deadline(started_at, finish_deadline, termination_timeout))
      ensure
        terminate(pid, timeout: termination_timeout, deadline: finish_deadline) if pid
        reader&.close unless reader&.closed?
        writer&.close unless writer&.closed?
      end

      def terminate(pid, timeout: TERMINATION_TIMEOUT, deadline: nil)
        started_at = monotonic
        terminate_group(pid, timeout: timeout, deadline: deadline)
      ensure
        @terminate_calls += 1
        @terminate_seconds += monotonic - started_at
      end

      private

        def terminate_group(pid, timeout:, deadline:)
          return unless process_group_alive?(pid)

          final_deadline = [monotonic + timeout, deadline].compact.min
          term_deadline = [final_deadline - KILL_REAP_TIMEOUT, monotonic].max
          signal_group("TERM", pid)
          leader_reaped = false
          while process_group_alive?(pid) && monotonic < term_deadline
            leader_reaped ||= reap(pid)
            pause_until(term_deadline) if process_group_alive?(pid)
          end
          signal_group("KILL", pid) if process_group_alive?(pid)

          while (process_group_alive?(pid) || !leader_reaped) && monotonic < final_deadline
            leader_reaped ||= reap(pid)
            pause_until(final_deadline) if process_group_alive?(pid) || !leader_reaped
          end
          reap(pid) unless leader_reaped
        rescue Errno::ECHILD, Errno::ESRCH
          nil
        end

        def deadline_for(started_at, timeout:, deadline:)
          timeout_deadline = started_at + timeout if timeout
          [timeout_deadline, deadline].compact.min
        end

        def wait_deadline(started_at, deadline, termination_timeout)
          return unless deadline

          duration = [deadline - started_at, 0].max
          termination_reserve = [termination_timeout, duration * 0.2].min
          deadline - termination_reserve
        end

        def wait(pid, deadline:)
          return Process.wait2(pid).last unless deadline

          loop do
            result = Process.wait2(pid, Process::WNOHANG)
            return result.last if result
            raise Timeout::Error, "child command deadline exceeded" if monotonic >= deadline

            pause_until(deadline)
          end
        end

        def process_group_alive?(pid)
          Process.kill(0, -pid)
          true
        rescue Errno::ESRCH
          false
        rescue Errno::EPERM
          true
        end

        def signal_group(signal, pid)
          Process.kill(signal, -pid)
        rescue Errno::ESRCH
          nil
        end

        def reap(pid)
          !Process.waitpid(pid, Process::WNOHANG).nil?
        rescue Errno::ECHILD
          true
        end

        def pause_until(deadline)
          remaining = deadline - monotonic
          sleep [POLL_INTERVAL, remaining].min if remaining.positive?
        end

        def monotonic
          Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end
    end
  end
end
