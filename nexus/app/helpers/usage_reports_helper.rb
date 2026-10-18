module UsageReportsHelper
  def analysis_datetime_value(time)
    time&.in_time_zone("UTC")&.iso8601&.delete_suffix("Z")
  end

  def analysis_amount(counters, cost_unit:)
    if counters.fetch("amount_sample_count").zero?
      t("usage_analysis.no_amount_samples")
    else
      "#{number_with_delimiter(counters.fetch("cost_amount"))} #{cost_unit}"
    end
  end
end
