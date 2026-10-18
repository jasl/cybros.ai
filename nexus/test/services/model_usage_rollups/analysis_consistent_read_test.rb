require "test_helper"

class ModelUsageRollups::AnalysisConsistentReadTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  teardown do
    UsageRecord.where(idempotency_key: %w[analysis-consistent:first analysis-consistent:second]).delete_all
  end

  test "an arriving receipt cannot change Top N after totals and latency were read" do
    attributes = {
      account: accounts(:cybros), model_invocation_public_id: SecureRandom.uuid_v7, attempt_ordinal: 1,
      consumer_user_public_id: users(:member).public_id, provider_id: "dev", catalog_model_ref: "dev/text",
      wire_model_id: "text", workload: "text_generation", purpose: "task", service_class: "interactive",
      admission_shape: "priced", status: "succeeded", recorded_at: Time.utc(2026, 10, 11), duration_ms: 10,
    }
    UsageRecord.create!(**attributes, idempotency_key: "analysis-consistent:first")
    reader = ModelUsageRollups::Analysis.new(account: accounts(:cybros),
      from: Time.utc(2026, 10, 10), to: Time.utc(2026, 10, 12))
    reader.singleton_class.prepend(Module.new do
      define_method(:breakdown) do |totals, total_group_count:|
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            UsageRecord.create!(**attributes, idempotency_key: "analysis-consistent:second",
              attempt_ordinal: 2, duration_ms: 100)
          end
        end.value
        super(totals, total_group_count:)
      end
    end)

    usage = reader.call.report.model_usage
    assert_equal 2, UsageRecord.where(idempotency_key: %w[analysis-consistent:first analysis-consistent:second]).count
    assert_equal 1, usage.totals.fetch("request_count")
    assert_equal 1, usage.breakdown.groups.first.totals.fetch("request_count")
    assert_equal 10, usage.latency.duration_ms.p95
    assert_equal 0, usage.breakdown.other.fetch("request_count")
  end
end
