module ModelUsageRollups
  module Percentiles
    Sample = Data.define(:sample_count, :missing_count, :p50, :p95)

    # Callers supply Arel nodes; the fixed SQL retains PostgreSQL's nearest-rank semantics.
    def self.selections(expression)
      [
        expression.count,
        Arel.sql("percentile_disc(0.5) WITHIN GROUP (ORDER BY ?)", expression),
        Arel.sql("percentile_disc(0.95) WITHIN GROUP (ORDER BY ?)", expression),
      ]
    end

    def self.sample(values, total:)
      count, p50, p95 = values
      Sample.new(sample_count: count, missing_count: total - count, p50: p50&.to_i, p95: p95&.to_i)
    end
  end
end
