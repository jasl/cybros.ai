module ModelUsageRollups
  # Folds unrolled receipts into the hour and month buckets. The cursor is
  # the per-row flag, not a watermark, and increments commit with the flag,
  # so every receipt contributes exactly once.
  class BackfillHourly
    DEFAULT_BATCH_SIZE = 1_000

    def self.call(...) = new(...).call

    def initialize(batch_size: DEFAULT_BATCH_SIZE, rolled_up_at: nil)
      @batch_size = batch_size
      @rolled_up_at = rolled_up_at
    end

    def call
      processed = process_batch
      Sweeps::Pass.new(counts: { processed: processed },
        more: @batch_size.positive? && processed == @batch_size)
    end

    private

      def process_batch
        records = []
        rolled_up_at = @rolled_up_at || Time.current

        UsageRecord.transaction do
          records = UsageRecord
            .where(hourly_rolled_up_at: nil)
            .order(:recorded_at, :id)
            .lock("FOR UPDATE SKIP LOCKED")
            .limit(@batch_size)
            .to_a

          if records.any?
            ModelUsageTimeBucket.increment_for_usage_records(
              records, bucket_kind: "hour", rolled_up_at: rolled_up_at
            )
            ModelUsageTimeBucket.increment_for_usage_records(
              records, bucket_kind: "month", rolled_up_at: rolled_up_at
            )
            UsageRecord.where(id: records.map(&:id)).update_all(
              hourly_rolled_up_at: rolled_up_at, updated_at: rolled_up_at
            )
          end
        end

        records.length
      end
  end
end
