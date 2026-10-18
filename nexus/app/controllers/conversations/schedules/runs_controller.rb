class Conversations::Schedules::RunsController < Conversations::Schedules::BaseController
  rate_limit to: 60, within: 1.minute, only: :create,
    by: -> { acting_user.public_id }, name: "schedule-run",
    with: -> { render_rate_limited(retry_after: 60) }

  def create = render_schedule_result(::Schedules::Manage.run_now(@job, by: acting_user))
end
