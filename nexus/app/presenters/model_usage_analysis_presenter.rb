class ModelUsageAnalysisPresenter
  def self.full(report)
    {
      # These exact query bounds retain database microseconds; ordinary event
      # timestamps, including as_of, keep the API's shared encoding precision.
      from: report.from.in_time_zone("UTC").iso8601(6),
      to: report.to.in_time_zone("UTC").iso8601(6),
      as_of: report.as_of, cost_unit: report.cost_unit,
      model_usage: usage(report.model_usage),
    }
  end

  def self.usage(usage)
    {
      totals: usage.totals,
      status_counts: usage.status_counts,
      latency: usage.latency.to_h.transform_values(&:to_h),
      breakdown: {
        **usage.breakdown.to_h.except(:groups),
        groups: usage.breakdown.groups.map(&:to_h),
      },
    }
  end
end
