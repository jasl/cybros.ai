module Tasks
  # A query over the parked Task variants, shared by attention and the sweep.
  # The instance deadline remains Parked's; the mirror test pins this SQL to it.
  class ParkDeadline
    DEADLINE_SQL = <<~SQL.squish.freeze
      tasks.await_started_at + (
        CASE
        WHEN tasks.status = 'needs_approval'
          THEN CAST(? AS bigint)
        WHEN tasks.type = 'Tasks::ToolTask'
          THEN COALESCE(
            tasks.timeout_ms,
            (tasks.effect_profile->>'timeout_ms')::bigint,
            CAST(? AS bigint)
          )
        ELSE LEAST(
          COALESCE(tasks.await_timeout_ms, CAST(? AS bigint)),
          CAST(? AS bigint)
        )
        END * interval '1 millisecond'
      )
    SQL

    def self.deadline_binds
      [
        ::Tasks::AwaitTask::MAX_HOLD_MS,
        ::Tasks::ToolTask::DEFAULT_TIMEOUT_MS,
        ::Tasks::AwaitTask::DEFAULT_TIMEOUT_MS,
        ::Tasks::AwaitTask::MAX_HOLD_MS,
      ]
    end
  end
end
