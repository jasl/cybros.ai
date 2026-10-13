module ModelProviders
  class DiscoverModels
    module FetchDeadline
      module InstanceMethods
        private

          def receive_requests(requests, selector)
            selector.extend(SelectorMethods)
            selector.fetch_deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + requests.fetch(0).request_timeout
            super
          ensure
            selector.fetch_deadline = nil
          end
      end

      module SelectorMethods
        attr_writer :fetch_deadline

        def next_tick
          return super unless @fetch_deadline

          # HTTPX can reset its timer accounting when TLS installs request
          # timers. Recompute the absolute budget at each native I/O tick.
          remaining = [@fetch_deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC), 0].max
          timer = after(remaining) do
            error = HTTPX::TimeoutError.new(remaining, "Provider directory deadline exceeded")
            each_connection.to_a.each { |connection| connection.on_error(error) }
          end
          super
        ensure
          timer&.cancel
        end
      end
    end
  end
end
