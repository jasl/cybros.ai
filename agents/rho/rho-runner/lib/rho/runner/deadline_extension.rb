module Rho
  # Reopened by `rho/runner.rb`, which holds the loop itself.
  class Runner
    # THE CLAIMANT'S ASK FOR MORE TIME, timed (executor.md "Extend"). A handler with no clamp of its own — a
    # tools provider's, the delegated compaction — is extended ONCE AT HALF
    # ITS PARK and again at each half while it runs: ask early enough that
    # a refused or slow ask still leaves the clamp its headroom, late enough
    # that a handler that finishes never asks at all. A tool that clamps
    # itself (bash) is never given one of these.
    #
    # `request` is the task run's own door, called with nothing — the ask
    # is the row's own park, never one measured here; `park_seconds` times
    # the asking alone. It answers `[handler_deadline, deadline_at, park_seconds]` — the
    # new local clamp, kernel deadline and remaining granted park — or
    # nil when the kernel refused. ONE REFUSAL STOPS THE ASKING: the
    # deadline the kernel would not move is the deadline, and asking again
    # at the next half would meet the same answer.
    class DeadlineExtension
      attr_reader :due_at, :deadline_at

      def initialize(park_seconds:, deadline_at:, clock:, &request)
        raise ArgumentError, "park_seconds must be positive" unless park_seconds.positive?

        @deadline_at = deadline_at
        @clock = clock
        @request = request
        @due_at = clock.call + (park_seconds / 2.0)
        @stopped = false
      end

      def stopped? = @stopped

      def due?(now = @clock.call) = !@stopped && now >= @due_at

      # Seconds until the next ask; nil once the asking stopped.
      def wait(now = @clock.call)
        return nil if @stopped

        [@due_at - now, 0.0].max
      end

      # Asks once. Answers the new handler deadline, or nil — and re-arms at
      # half the remaining grant. A shorter renewal must not inherit the
      # first claim's longer interval.
      def call
        return nil if @stopped

        answer = @request.call
        if answer.nil?
          @stopped = true
          return nil
        end

        deadline, @deadline_at, park = answer
        @due_at = @clock.call + ([park, 0.0].max / 2.0)
        deadline
      end
    end
  end
end
