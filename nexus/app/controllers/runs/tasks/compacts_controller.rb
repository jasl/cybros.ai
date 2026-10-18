class Runs::Tasks::CompactsController < Runs::BaseController
  rate_limit to: 60, within: 1.minute, only: :create,
    by: -> { acting_user.public_id }, name: "task-compaction",
    with: -> { render_rate_limited(retry_after: 60) }

  def create
    adjudicate(Runs::Tasks::Compact, notice: "runs_console.compaction_accepted")
  end
end
