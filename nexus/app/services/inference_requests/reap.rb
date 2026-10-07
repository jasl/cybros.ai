module InferenceRequests
  # Selects aged tombstones with no collection obligation and hands each
  # to Drain.
  class Reap
    class << self
      def call(...)
        new(...).call
      end
    end

    def initialize(batch:)
      @batch = batch
    end

    def call
      inference_request_ids = candidates.pluck(:id)
      reaped = Drain.call(inference_request_ids: inference_request_ids)

      Sweeps::Pass.new(
        counts: { scanned: inference_request_ids.length, reaped: reaped },
        more: @batch.positive? && inference_request_ids.length == @batch
      )
    end

    private

      def candidates
        InferenceRequest.tombstoned_before(InferenceRequest::RETENTION_PERIOD.ago)
          .where.not(unsettled_obligations.arel.exists)
          .where.not(unsettled_attempt_obligations.arel.exists)
          .order(:tombstoned_at, :id).limit(@batch)
      end

      def unsettled_obligations
        ModelInvocation.nonterminal.where(
          "model_invocations.inference_request_id = inference_requests.id"
        )
      end

      # A pending settlement has a receipt writer that may not have run,
      # and it holds no invocation lock on the discarded path.
      def unsettled_attempt_obligations
        ModelInvocationAttempt.where(settlement_state: "pending")
          .joins(:model_invocation)
          .where("model_invocations.inference_request_id = inference_requests.id")
      end
  end
end
