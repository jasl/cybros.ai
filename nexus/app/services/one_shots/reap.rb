module OneShots
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
      one_shot_ids = candidates.pluck(:id)
      reaped = Drain.call(one_shot_ids: one_shot_ids)

      Sweeps::Pass.new(
        counts: { scanned: one_shot_ids.length, reaped: reaped },
        more: @batch.positive? && one_shot_ids.length == @batch
      )
    end

    private

      def candidates
        OneShot.tombstoned_before(OneShot::RETENTION_PERIOD.ago)
          .where.not(unsettled_obligations.arel.exists)
          .where.not(unsettled_attempt_obligations.arel.exists)
          .order(:tombstoned_at, :id).limit(@batch)
      end

      def unsettled_obligations
        ModelInvocation.nonterminal.where(
          "model_invocations.one_shot_id = one_shots.id"
        )
      end

      # A pending settlement has a receipt writer that may not have run,
      # and it holds no invocation lock on the discarded path.
      def unsettled_attempt_obligations
        ModelInvocationAttempt.where(settlement_state: "pending")
          .joins(:model_invocation)
          .where("model_invocations.one_shot_id = one_shots.id")
      end
  end
end
