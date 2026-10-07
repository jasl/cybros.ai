module InferenceRequests
  # Terminal-only: marks a finished InferenceRequest for reclamation and never
  # cancels running work on the caller's behalf.
  class Tombstone
    Result = Data.define(:outcome, :inference_request) do
      def accepted? = outcome == :accepted
    end

    def self.call(...) = new(...).call

    def initialize(inference_request:)
      @inference_request = inference_request
    end

    def call
      # The status is derived from the invocation, so the aggregate is
      # locked first — above `model_invocations` on the ladder — and read once.
      @inference_request.with_lock do
        next Result.new(outcome: :already_tombstoned, inference_request: @inference_request) if @inference_request.tombstoned?

        # Uncached after the lock, or a terminal that committed elsewhere is
        # refused from a pre-lock cached read. The aggregate's terminality,
        # not the call's: a declined answer is not terminal until recorded.
        ApplicationRecord.uncached { @inference_request.reload_model_invocation }
        next Result.new(outcome: :not_terminal, inference_request: @inference_request) unless @inference_request.terminal?

        @inference_request.update!(tombstoned_at: Time.current)
        Result.new(outcome: :accepted, inference_request: @inference_request)
      end
    end
  end
end
