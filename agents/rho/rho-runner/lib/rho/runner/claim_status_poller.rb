module Rho
  class Runner
    # Each execution reads its original claim on the existing control fiber.
    # The interval caps a Pool's average reads at five per second, leaving
    # room in the executor's read bucket for another process of that address.
    class ClaimStatusPoller
      def initialize(task:, claim_token:, worker_count:, clock:, log:)
        @task = task
        @claim_token = claim_token
        @clock = clock
        @log = log
        @interval = [5.0, worker_count / 5.0].max
        @next_at = @clock.call + @interval
      end

      def wait(now = @clock.call) = [@next_at - now, 0.0].max

      # nil means no observation: not due, or the request could not establish
      # whether this exact claim still stands. Only false cancels execution.
      def poll(now = @clock.call)
        return if now < @next_at

        read
      end

      private

        def read
          delay = @interval
          @task.claim_status(claim_token: @claim_token).active?
        rescue CybrosAgent::Api::NotFound
          false
        rescue CybrosAgent::Api::Conflict => error
          error.code == "not_claimant" ? false : refused(error)
        rescue CybrosAgent::Api::RateLimited, CybrosAgent::DeviceFlow::RateLimited => error
          delay = [delay, error.retry_after].max
          refused(error)
        rescue CybrosAgent::Error => error
          refused(error)
        ensure
          @next_at = @clock.call + delay
        end

        def refused(error)
          code = case error
          in CybrosAgent::Api::Error then error.code
          else error.class.name
          end
          @log.warn("runner_claim_status_unavailable", task: @task.task_key, code: code)
          nil
        end
    end
  end
end
