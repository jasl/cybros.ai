require "socket"

module Rho
  module T3
    # The extension owns this foreground process, independently of every coding
    # assignment. A conversation Stop must never stop another assignment's service.
    class LocalServer
      START_TIMEOUT = 15
      STOP_TIMEOUT = 2
      POLL_SECONDS = 0.05

      def initialize(settings:, native:)
        @settings, @native = settings, native
        @process = nil
      end

      def start
        return if running?

        @native.prepare
        if listening?
          raise Runner::Extensions::PrerequisiteError,
            "The local T3 port is already in use. Choose another listen port in the T3 plugin settings or stop the existing service, then enable the plugin again."
        end

        @process = Runner::OwnedProcess.spawn(@native.environment,
          "t3", "serve", "--host", "127.0.0.1", "--port", @settings.listen_port.to_s,
          "--base-dir", @native.server_root, chdir: @native.work_root,
          in: File::NULL, out: File::NULL, err: File::NULL, unsetenv_others: true)
        deadline = monotonic + START_TIMEOUT
        loop do
          unless running?
            raise Runner::Extensions::PrerequisiteError,
              "The local T3 process exited during startup. Run `t3 serve` in the same environment to check its runtime, repair the installation, then enable the plugin again."
          end
          break if listening?
          if monotonic >= deadline
            raise Runner::Extensions::PrerequisiteError,
              "The local T3 service did not listen before the startup timeout. Check `t3 serve` in the same environment and the configured listen port, then enable the plugin again."
          end

          sleep(POLL_SECONDS)
        end
        nil
      rescue Errno::ENOENT
        stop
        raise Runner::Extensions::PrerequisiteError,
          "The local T3 executable is not installed or its runtime is unavailable. Install T3 and Node.js in the runner environment, " \
          "make `t3` available on PATH, then enable the plugin again.", cause: nil
      rescue Errno::EACCES
        stop
        raise Runner::Extensions::PrerequisiteError,
          "The local T3 service could not access its executable or files. Check executable permissions and access to the T3 plugin directory, " \
          "then enable the plugin again.", cause: nil
      rescue Exception
        stop
        raise
      end

      def running? = @process && @process.poll.nil?

      def stop
        process, @process = @process, nil
        return unless process

        process.terminate
        deadline = monotonic + STOP_TIMEOUT
        sleep(POLL_SECONDS) while process.poll.nil? && monotonic < deadline
        process.kill_and_reap
        nil
      end

      private

        def listening?
          Socket.tcp("127.0.0.1", @settings.listen_port, connect_timeout: 0.1) { true }
        rescue SystemCallError, IOError
          false
        end

        def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
