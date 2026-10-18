module ReportWindowParameters
  Window = Data.define(:from, :to, :unit, :invalid_parameter)

  private

    def report_window(unit: nil)
      unit ||= params.key?(:unit) ? params.expect(:unit).to_s : "day"
      if params.key?(:from) || params.key?(:to)
        from_value, to_value = params.expect(:from, :to)
        from = report_time(from_value)
        to = report_time(to_value)
        invalid_parameter = from.nil? ? :from : (:to if to.nil?)
        Window.new(from:, to:, unit:, invalid_parameter:)
      else
        to = Time.current.in_time_zone("UTC").beginning_of_day
        Window.new(from: to - 7.days, to:, unit:, invalid_parameter: nil)
      end
    end

    # Form controls are labeled UTC. Offset-bearing API values retain their
    # instant, and zone-less browser datetime fields are interpreted in UTC.
    def report_time(value)
      Time.find_zone!("UTC").iso8601(value.to_s)
    rescue ArgumentError
      nil
    end
end
