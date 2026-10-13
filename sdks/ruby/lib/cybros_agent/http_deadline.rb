require "httpx"

module CybrosAgent
  # HTTPX's total_request_timeout starts when request headers are emitted, so
  # resolve, connect, and TLS can each spend their own default budget before
  # it ever runs. This plugin installs one selector-level timer before those
  # state machines start, making the caller's budget the real deadline. Both
  # transports use it: a long-running host must never be able to spend a
  # minute inside a two-second call.
  module HttpDeadline
    module InstanceMethods
      private

      def receive_requests(requests, selector)
        started_at = HTTPX::Utils.now
        timers = []
        session = self
        selector_hook = Module.new do
          define_method(:initial_call) do
            super()

            requests.each do |request|
              timeout = request.total_request_timeout
              next if timeout.nil? || timeout.infinite?

              remaining = timeout - HTTPX::Utils.elapsed_time(started_at)
              remaining = 0 if remaining.negative?
              timer = after(remaining) do
                session.__send__(:expire_request, request, self, timeout)
              end
              timer.label = :total_request_timeout
              request.active_timeouts << timer
              timers << timer
            end
          end
        end

        selector.singleton_class.prepend(selector_hook)
        super
      ensure
        timers&.each(&:cancel)
      end

      def expire_request(request, selector, timeout)
        response = request.response
        return if response&.finished?

        error = HTTPX::TotalRequestTimeoutError.new(
          request,
          response.is_a?(HTTPX::Response) ? response : nil,
          timeout
        )
        selector.each.to_a.each { |selectable| selectable.force_close(true) }
        request.handle_error(error) unless request.response&.finished?
      end
    end
  end
end
