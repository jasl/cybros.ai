require "test_helper"

# The EXACT claim's race pin (item-7 review): the report's two reads share
# ONE snapshot, so a drain batch committing between them cannot vanish from
# both sides. Without the REPEATABLE READ bridge the bucket read misses the
# increments (old snapshot) and the raw read then excludes the flagged rows
# (new statement, new snapshot) — the receipt counts zero times.
class ModelUsageRollups::UsageReportTornReadTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @account = accounts(:cybros)
    @member = users(:member)
  end

  teardown do
    UsageRecord.where(account_id: @account.id).delete_all
    ModelUsageTimeBucket.where(account_id: @account.id).delete_all
  end

  test "a drain committing between the two reads is still counted exactly once" do
    UsageRecord.create!(
      account: @account, idempotency_key: "torn:1",
      model_invocation_public_id: SecureRandom.uuid_v7, attempt_ordinal: 1,
      consumer_user_public_id: @member.public_id,
      provider_id: "dev", catalog_model_ref: "dev/text",
      wire_model_id: "text", workload: "text_generation",
      purpose: "inference_request", service_class: "interactive",
      admission_shape: "priced", status: "succeeded",
      recorded_at: Time.utc(2026, 8, 21, 10, 15), input_tokens: 100,
      cost_amount: BigDecimal("0.1"), cost_unit: "USD"
    )

    report = ModelUsageRollups::UsageReport.new(
      account: @account, from: Time.utc(2026, 8, 21, 10), to: Time.utc(2026, 8, 21, 11),
      unit: "hour"
    )
    drained = Queue.new
    report.singleton_class.prepend(Module.new do
      define_method(:bucket_rows) do
        rows = super()
        # The drain lands its batch — increments AND flags, one commit — on
        # another connection between the report's two reads.
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            ModelUsageRollups::BackfillHourly.call
          end
        end.join
        drained << true
        rows
      end
    end)

    result = report.call

    assert_equal 1, drained.size, "the drain really ran between the two reads"
    assert_equal 0, UsageRecord.where(hourly_rolled_up_at: nil).count,
      "the drain really committed"
    assert_equal 1, result.totals.fetch("request_count"),
      "one snapshot for both reads: the mid-read drain neither hides the receipt nor doubles it"
    assert_equal 100, result.totals.fetch("input_tokens")
  end
end
