# The per-subject cumulative usage cache, maintained in the receipt-write
# transaction and rebuildable from the receipts; it dies with its subject,
# while accounting truth stays in usage_records.
class ModelUsageSummary < ApplicationRecord
  SUBJECT_KINDS = { one_shot: "one_shot" }.freeze
  COUNTER_COLUMNS = UsageRecord::ROLLUP_COUNTER_COLUMNS

  attr_readonly :account_id, :subject_kind, :subject_id

  belongs_to :account

  validates :subject_kind, inclusion: { in: SUBJECT_KINDS.values }
  validates :subject_id, presence: true

  class << self
    def increment_for_usage_record(record, subject_id: nil)
      return if record.one_shot_public_id.nil?

      subject_id ||= OneShot.where(public_id: record.one_shot_public_id).pick(:id)
      return if subject_id.nil?

      summary = create_or_find_by!(
        subject_kind: SUBJECT_KINDS.fetch(:one_shot), subject_id: subject_id
      ) { |row| row.account = record.account }
      update_counters(summary.id, record.rollup_counters.merge(touch: true))
    end

    # PublicUsage's vocabulary over the whole attempt history, zeros when
    # nothing was recorded; `cost_complete` is the aggregate statement.
    def public_projection(subject_kind:, subject_id:)
      summary = find_by(subject_kind: subject_kind, subject_id: subject_id)
      row = COUNTER_COLUMNS.index_with { |column| summary&.public_send(column) || 0 }
      input = row.fetch(:input_tokens)
      cache_read = [row.fetch(:cache_read_tokens), input].min
      {
        "request_count" => row.fetch(:request_count),
        "input_tokens" => input,
        "cache_read_tokens" => row.fetch(:cache_read_tokens),
        "uncached_input_tokens" => input - cache_read,
        "cache_creation_tokens" => row.fetch(:cache_creation_tokens),
        "cache_hit_rate" => UsageRecord.cache_hit_rate(input, cache_read),
        "output_tokens" => row.fetch(:output_tokens),
        "reasoning_tokens" => row.fetch(:reasoning_tokens),
        "total_tokens" => row.fetch(:total_tokens),
        "cost_amount" => row.fetch(:cost_amount).to_d.to_s("F"),
        "cost_complete" => row.fetch(:cost_known_request_count) == row.fetch(:request_count),
      }.compact
    end
  end
end
