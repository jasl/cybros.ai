module Rho
  class Daemon
    class Lineage
      # Admission and shutdown: the count of
      # admitted control handlers `quiesce` drains on the main thread, and the
      # maintenance worker's wait, whose exit latch only `stop_maintenance` sets.
      module Shutdown
        def admit
          @monitor.synchronize do
            next false if @stopping

            @control_operations += 1
            true
          end
        end

        def release
          @monitor.synchronize do
            @control_operations -= 1
            @handlers_changed.broadcast if @control_operations.zero?
          end
        end

        def begin_stop = @monitor.synchronize { @stopping = true }

        def abort_stop = @monitor.synchronize { @stopping = false }

        def quiesce(deadline:)
          limit = @monotonic.call + deadline
          @monitor.synchronize do
            while @control_operations.positive?
              remaining = limit - @monotonic.call
              if remaining <= 0
                raise ConnectionError,
                  "an authenticated control operation did not reach a safe checkpoint before " \
                  "the shutdown deadline"
              end

              @handlers_changed.wait(remaining)
            end
          end
        end

        # `stopped` reads the exit latch only `stop_maintenance` sets; `stopping`
        # merely makes the worker skip its work.
        def maintenance_wait(interval)
          @monitor.synchronize do
            @maintenance_changed.wait(interval) unless @maintenance_stopped || @maintenance_requested
            if @maintenance_stopped
              [true, nil, false]
            else
              requested = @maintenance_requested
              @maintenance_requested = false
              @maintenance_running = true
              [false, (@stopping ? nil : @credentials), requested]
            end
          end
        end

        def maintenance_done = @monitor.synchronize { @maintenance_running = false }

        def stop_maintenance
          @monitor.synchronize do
            @maintenance_stopped = true
            @maintenance_changed.broadcast
          end
        end
      end
    end
  end
end
