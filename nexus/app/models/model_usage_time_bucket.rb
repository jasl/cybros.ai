# The UTC time-bucket rollup: hour is the fine grain, month the coarse cache,
# no day buckets (day series group hours). Rebuildable from the receipts;
# never accounting truth.
class ModelUsageTimeBucket < ApplicationRecord
  BUCKET_KINDS = %w[hour month].freeze
  # Named exactly as the receipt names them; account_id is a dimension too,
  # so the digest key is tenant-complete. The predecessor's agent-tenancy
  # trio and conversation dimension do not exist here.
  DIMENSION_COLUMNS = %i[
    account_id
    consumer_user_public_id
    payer_user_public_id
    workspace_public_id
    billing_subject_key
    provider_id
    catalog_model_ref
    workload
    status
  ].freeze
  COUNTER_COLUMNS = UsageRecord::ROLLUP_COUNTER_COLUMNS
  ADDITIVE_COUNTER_UPDATE = Arel.sql(<<~SQL.squish).freeze
    request_count = model_usage_time_buckets.request_count + EXCLUDED.request_count,
    input_tokens = model_usage_time_buckets.input_tokens + EXCLUDED.input_tokens,
    cache_read_tokens = model_usage_time_buckets.cache_read_tokens + EXCLUDED.cache_read_tokens,
    cache_creation_tokens = model_usage_time_buckets.cache_creation_tokens + EXCLUDED.cache_creation_tokens,
    output_tokens = model_usage_time_buckets.output_tokens + EXCLUDED.output_tokens,
    reasoning_tokens = model_usage_time_buckets.reasoning_tokens + EXCLUDED.reasoning_tokens,
    total_tokens = model_usage_time_buckets.total_tokens + EXCLUDED.total_tokens,
    cost_amount = model_usage_time_buckets.cost_amount + EXCLUDED.cost_amount,
    cost_known_request_count = model_usage_time_buckets.cost_known_request_count + EXCLUDED.cost_known_request_count,
    rolled_up_at = EXCLUDED.rolled_up_at,
    updated_at = EXCLUDED.updated_at
  SQL

  # The binding discipline every sibling carries (the re-audit's gap): the
  # identity is pinned by the digest, and nothing may re-home a bucket.
  attr_readonly :account_id, :bucket_kind, :bucket_start_at, :aggregation_key

  belongs_to :account

  validates :bucket_kind, inclusion: { in: BUCKET_KINDS }
  validates :bucket_start_at, :aggregation_key, :rolled_up_at, presence: true

  class << self
    def increment_for_usage_records(records, bucket_kind:, rolled_up_at:)
      # Shared bucket rows are create-or-incremented by every overlapping
      # drain: apply in sorted [bucket_start_at, aggregation_key] order so
      # concurrent batches never lock the same buckets in opposite orders.
      groups = grouped_bucket_attributes(records, bucket_kind: bucket_kind)
        .sort_by { |group| [group.fetch(:bucket_start_at), group.fetch(:aggregation_key)] }
      return if groups.empty?

      written_at = Time.current
      rows = groups.map do |group|
        group.fetch(:dimensions).merge(
          bucket_kind: bucket_kind,
          bucket_start_at: group.fetch(:bucket_start_at),
          aggregation_key: group.fetch(:aggregation_key),
          **group.fetch(:counters),
          rolled_up_at: rolled_up_at,
          created_at: written_at,
          updated_at: written_at
        )
      end
      upsert_all(
        rows,
        unique_by: "index_model_usage_time_buckets_on_identity",
        on_duplicate: ADDITIVE_COUNTER_UPDATE,
        returning: false,
        record_timestamps: false
      )
    end

    def bucket_start_for(time, bucket_kind)
      utc = time.in_time_zone("UTC")
      case bucket_kind
      when "hour" then utc.beginning_of_hour
      when "month" then utc.beginning_of_month
      else raise ArgumentError, "unsupported model usage bucket: #{bucket_kind}"
      end
    end

    def aggregation_key_for(dimensions)
      payload = DIMENSION_COLUMNS.index_with { |column| dimensions.fetch(column)&.to_s }
      Digest::SHA256.hexdigest(ActiveSupport::JSON.encode(payload))
    end

    private

      def grouped_bucket_attributes(records, bucket_kind:)
        records.each_with_object({}) do |record, groups|
          bucket_start_at = bucket_start_for(record.recorded_at, bucket_kind)
          dimensions = DIMENSION_COLUMNS.index_with { |column| record.public_send(column) }
          aggregation_key = aggregation_key_for(dimensions)
          group = groups[[bucket_start_at, aggregation_key]] ||= {
            bucket_start_at: bucket_start_at,
            aggregation_key: aggregation_key,
            dimensions: dimensions,
            counters: COUNTER_COLUMNS.index_with(0),
          }

          record.rollup_counters.each do |column, value|
            group.fetch(:counters)[column] += value
          end
        end.values
      end
  end
end
