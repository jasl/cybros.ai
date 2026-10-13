require "monitor"

module Rho
  class Runner
    module Extensions
      # A registration owns its resources. Removing its published contributions
      # stops new calls; a call already holding this owner may finish before cleanup.
      class Resources
        attr_writer :dispatch
        attr_reader :failures

        def initialize(extension:, log: nil)
          @extension, @log = extension, log
          @monitor = Monitor.new
          @cleanups = []
          @retirements = []
          @failures = []
          @users = 0
          @retiring = false
          @disposed = false
          @dispatch = ->(&cleanup) { cleanup.call }
        end

        def own(on_retire: false, &cleanup)
          @monitor.synchronize do
            raise RegistrationError, "#{@extension} has been retired" if @retiring

            (on_retire ? @retirements : @cleanups) << cleanup
          end
          self
        end

        def acquire
          @monitor.synchronize do
            raise RegistrationError, "#{@extension} has been retired" if @retiring

            @users += 1
          end
          self
        end

        def release
          ready = @monitor.synchronize do
            @users -= 1
            @retiring && @users.zero?
          end
          # Calls can finish on a worker thread. Connections and reactor tasks
          # are disposed on the host that created them.
          @dispatch.call { dispose } if ready
        end

        def retire
          ready, retirements = @monitor.synchronize do
            callbacks = @retiring ? [] : @retirements.reverse
            @retiring = true
            [@users.zero?, callbacks]
          end
          # Autonomous pollers stop when the owner loses publication. Connections
          # needed by accepted calls remain until those calls have drained.
          cleanup(retirements)
          dispose if ready
          ready
        end

        def disposed? = @monitor.synchronize { @disposed }

        private

          def dispose
            cleanups = @monitor.synchronize do
              next [] if @disposed

              @disposed = true
              @cleanups.reverse
            end
            cleanup(cleanups)
          end

          def cleanup(callbacks)
            callbacks.each do |callback|
              callback.call
            rescue StandardError => error
              @failures << error.class.name
              @log&.warn("extension_cleanup_failed", extension: @extension, error_class: error.class.name)
            end
          end
      end
    end
  end
end
