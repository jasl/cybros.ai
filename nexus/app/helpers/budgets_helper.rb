module BudgetsHelper
  def budget_datetime_value(value)
    return if value.blank?

    Time.find_zone!("UTC").iso8601(value.to_s).iso8601.delete_suffix("Z")
  rescue ArgumentError
    value
  end
end
