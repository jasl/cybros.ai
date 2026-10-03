module ModelInvocations
  # Closes the late-evidence window: a terminal attempt still `pending`
  # settlement would hold the reclamation fence shut forever. It writes the
  # receipt too, recording the unknown as unknown, since this is the last moment anything can.
  class CloseAbandonedSettlements
    LATE_EVIDENCE_WINDOW = 7.days
    BATCH_SIZE = 500

    def self.call(...) = new(...).call

    def initialize(batch_size: BATCH_SIZE)
      @batch_size = batch_size
    end

    def call
      # Each settled row leaves the frontier index, so the next wake advances
      # without an enqueue chain.
      failures = []
      closed = stale
        .includes(model_invocation: %i[account workspace one_shot])
        .order(:terminal_at, :id)
        .limit(@batch_size)
        .count do |attempt|
          receipt = record_abandoned(attempt, failures)
          !receipt.nil? &&
            receipt.status == UsageRecord::ABANDONED && attempt.settlement_state == "abandoned"
        end
      # Loud at the end, not at the first row: raising there would head
      # every wake with the same row. Healthy rows settle first, then the
      # error still fails the job so it stays paged.
      raise failures.first.last if failures.any?
      closed
    end

    private

      # Per candidate, so a poisoned row is skipped and the receipt+flip
      # stays atomic for the rows that succeed.
      def record_abandoned(attempt, failures)
        UsageRecords::Record.call(
          attempt: attempt, outcome: nil,
          status: UsageRecord::ABANDONED, error_code: "settlement_abandoned"
        )
      rescue StandardError => error
        Rails.error.report(error, handled: true,
          context: { event: "abandoned_receipt_write_failed", attempt: attempt.public_id })
        failures << [attempt.public_id, error]
        nil
      end

      # `terminal_at` is the terminality witness, so the age gate alone never
      # selects live work; a status predicate would be a second spelling.
      def stale
        ModelInvocationAttempt
          .where(settlement_state: "pending")
          .where(terminal_at: ...LATE_EVIDENCE_WINDOW.ago)
      end
  end
end
