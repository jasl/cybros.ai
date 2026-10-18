module InferenceRequests
  # The creator's cancel through the same kernel every authority cut uses:
  # a guarded status update, first terminal wins, idempotent by construction.
  class Cancel
    def self.call(...) = new(...).call

    def initialize(inference_request:)
      @inference_request = inference_request
    end

    # One transaction under the aggregate's lock, the one the converger
    # needs before it can switch, so the two never interleave. The cut
    # first: a fallback the converger minted before the stop took the lock
    # is cut like any running work. Then a DECLINED or OVERLOADED answer — out of the
    # cut's reach, being terminal, and one the converger would run again on
    # the creator's fallback — settles on the spot with no switch. A
    # refusal that commits while the cut waits on its row is terminal when
    # the cut re-checks it, so the settle after it is what records it.
    def call
      cut = ApplicationRecord.transaction do
        @inference_request.lock!
        canceled = ModelInvocation::Cancellation.call(
          scope: ModelInvocation.where(inference_request_id: @inference_request.id),
          reason: "creator_requested"
        )
        ConvergeTerminalEvents.settle_now(@inference_request)
        canceled
      end
      wake_the_convergers if cut.positive?
      @inference_request
    end

    private

      # The cut is instant, being told is not: without a wake a follower
      # keeps following for a minute. `perform_later` already defers to after
      # commit (pinned by the test beside this); the kernel may not name a job, so the wake lives here.
      def wake_the_convergers
        ModelInvocations::ConvergePostCutJob.perform_later
        InferenceRequests::ConvergeTerminalEventsJob.perform_later
      end
  end
end
