require "test_helper"

# The model plane's recovery paths are all recurring jobs, and every one of
# them was invisible outside the Rails suite: `config/recurring.yml` declared
# a `production:` block only, while development runs Solid Queue through
# `bin/jobs`. Solid Queue registered zero recurring tasks there — so admission
# never ticked, no deadline was swept, no cut was converged, and no stalled
# attempt was re-driven, in the one environment where someone would have
# noticed before deploying. The predecessor ran the same schedule in both.
class ModelInvocations::RecurringScheduleTest < ActiveSupport::TestCase
  OWNERS = {
    "admit_queued_model_invocations" => ModelInvocations::AdmitQueuedWorkJob,
    "sweep_model_invocation_deadlines" => ModelInvocations::DeadlineSweepJob,
    "converge_post_cut_model_invocation_attempts" => ModelInvocations::ConvergePostCutJob,
    "converge_one_shot_terminal_events" => OneShots::ConvergeTerminalEventsJob,
    "redrive_stalled_model_invocation_attempts" => ModelInvocations::RedriveStalledJob,
  }.freeze

  test "every model-plane recovery owner ticks every minute" do
    production = recurring_schedule

    OWNERS.each do |key, job|
      entry = production.fetch(key)
      assert_equal job.name, entry.fetch("class")
      assert_equal "every minute", entry.fetch("schedule")
    end
  end

  test "development runs the same schedule, or none of it runs at all" do
    assert_equal recurring_schedule, recurring_schedule("development"),
      "a development block that drifts from production is a schedule nobody exercises"
  end
end
