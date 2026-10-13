require_relative "process_runner"

module E2E
  # Owns long-lived subprocess groups that outlive the stack process which
  # spawned them. Per-test teardown is the normal path; the suite and process
  # exit sweeps are the fallback when an interrupt skips that teardown.
  class ProcessRegistry
    # The outer journey runner reserves five seconds for its own teardown.
    # Finish the nested sweep before that runner escalates to KILL.
    SWEEP_TERMINATION_TIMEOUT = 3

    @owned_pids = {}
    @sweeps_installed = false

    class << self
      def spawn(*command, **options)
        register(Process.spawn(*command, **options))
      end

      def register(pid)
        install_sweeps
        owned_pids[pid] = true
        pid
      end

      def unregister(pid)
        owned_pids.delete(pid)
      end

      def terminate(pid, timeout: ProcessRunner::TERMINATION_TIMEOUT, deadline: nil)
        ProcessRunner.terminate(pid, timeout:, deadline:)
        unregister(pid)
      end

      def drain
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + SWEEP_TERMINATION_TIMEOUT
        owned_pids.keys.each do |pid|
          terminate(pid, deadline:)
        rescue StandardError => error
          warn "Could not stop registered E2E process group #{pid}: #{error.class}: #{error.message}"
        end
      end

      private

        def install_sweeps
          return if @sweeps_installed

          @sweeps_installed = true
          # The process exit sweep first: it is the one every owner gets. The
          # `rake e2e` parent has `Minitest` defined by minitest/test_task
          # alone, without `after_run` — so that hook is installed only where
          # the runner is actually loaded.
          at_exit { E2E::ProcessRegistry.drain }
          Minitest.after_run { E2E::ProcessRegistry.drain } if defined?(Minitest) && Minitest.respond_to?(:after_run)
        end

        def owned_pids
          @owned_pids
        end
    end
  end
end
