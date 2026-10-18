module ModelUsageRollups
  # Raw receipt reads and rolled reports share the same additive counters.
  module Counters
    COLUMNS = UsageRecord::ROLLUP_COUNTER_COLUMNS

    def self.selections
      table = UsageRecord.arel_table
      [
        Arel.sql("COUNT(*)"),
        *COLUMNS[1..7].map { |column| table.coalesce(table[column].sum, 0) },
        Arel.sql(
          "COUNT(*) FILTER (WHERE status NOT IN (?))" \
            " + COUNT(cost_amount) FILTER (WHERE status IN (?))",
          UsageRecord::COST_EVIDENCE_STATUSES,
          UsageRecord::COST_EVIDENCE_STATUSES
        ),
      ]
    end

    def self.render(counters)
      {
        "request_count" => counters.fetch(:request_count).to_i,
        "input_tokens" => counters.fetch(:input_tokens).to_i,
        "cache_read_tokens" => counters.fetch(:cache_read_tokens).to_i,
        "cache_creation_tokens" => counters.fetch(:cache_creation_tokens).to_i,
        "output_tokens" => counters.fetch(:output_tokens).to_i,
        "reasoning_tokens" => counters.fetch(:reasoning_tokens).to_i,
        "total_tokens" => counters.fetch(:total_tokens).to_i,
        "cost_amount" => counters.fetch(:cost_amount).to_d.to_s("F"),
        "cost_complete" => counters.fetch(:cost_known_request_count) == counters.fetch(:request_count),
      }
    end
  end
end
