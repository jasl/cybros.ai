module SchedulesHelper
  def schedule_title(job)
    job.name.presence || t("schedules_console.untitled")
  end

  def schedule_time(time)
    time ? time.utc.strftime("%Y-%m-%d %H:%M:%S UTC") : t("schedules_console.not_set")
  end

  def schedule_rule(rule)
    case rule.fetch("kind")
    when "once"
      t("schedules_console.rules.once", at: schedule_time(Time.iso8601(rule.fetch("run_at"))))
    when "interval"
      t("schedules_console.rules.interval", seconds: rule.fetch("every_seconds"), at: schedule_time(Time.iso8601(rule.fetch("starts_at"))))
    when "daily"
      t("schedules_console.rules.daily", time: rule.fetch("local_time"), zone: rule.fetch("time_zone"))
    else
      JSON.generate(rule)
    end
  end

  def schedule_refusal(reason)
    t("schedules_console.refusals.#{reason}", default: [
      :"conversation_reading.refusals.#{reason}",
      :"work_console.error.codes.#{reason}",
      reason.to_s.humanize,
    ])
  end

  def schedule_list_parameters
    params.permit(:workspace_public_id, :status, :order, :limit, :return_to).to_h
  end
end
