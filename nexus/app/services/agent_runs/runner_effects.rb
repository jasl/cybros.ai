module AgentRuns
  # A claimed write may have changed its Runner even without an accepted
  # result. Read the retained first claim, independent of retry's current
  # address, claim and result columns. Checkpoints are opaque Runner data.
  module RunnerEffects
    module_function

    def rows(scope)
      scope.where.not(first_runner_write: nil).joins(:agent_run)
        .select("agent_run_tasks.*", "agent_runs.public_id AS run_public_id")
    end

    # One query for the first captured write per Runner in every named run.
    def first_writes(agent_run_ids)
      return {} if agent_run_ids.empty?

      first_rows(AgentRunTask.where(agent_run_id: agent_run_ids), per_run: true).group_by(&:agent_run_id)
    end

    # Fork readers group across all reachable successors; transcript readers
    # group within each run. Both order by the first claim, never task order.
    def first_rows(scope, per_run: false)
      runner = "agent_run_tasks.first_runner_write->>'runner_executor_public_id'"
      partitions = per_run ? "agent_run_tasks.agent_run_id, #{runner}" : runner
      claimed_at = "(agent_run_tasks.first_runner_write->>'claimed_at')::timestamptz"
      windowed = rows(scope).select(
        "ROW_NUMBER() OVER (PARTITION BY #{partitions} ORDER BY #{claimed_at}, agent_run_tasks.id) AS position"
      )
      AgentRunTask.from(windowed, :ranked).select("ranked.*").where("ranked.position = 1")
        .order(Arel.sql("(ranked.first_runner_write->>'claimed_at')::timestamptz, ranked.id"))
    end

    def unavailable = { status: "unavailable", runners: [], reason: "execution_details_pruned" }

    def fact(rows, details_pruned_at: nil)
      return unavailable if details_pruned_at

      runners = Array(rows).map { |row| entry(row, row.run_public_id) }
      { status: runners.empty? ? "untouched" : "touched", runners: runners }
    end

    # The run presenter already loaded its tasks; derive the same projection
    # without another query. The capture's timestamp has one UTC encoding.
    def from_tasks(tasks, run_public_id:, details_pruned_at: nil)
      return unavailable if details_pruned_at

      rows = tasks.select(&:first_runner_write)
        .sort_by { |task| [task.first_runner_write.fetch("claimed_at"), task.id] }
        .uniq { |task| task.first_runner_write.fetch("runner_executor_public_id") }
      runners = rows.map { |row| entry(row, run_public_id) }
      { status: runners.empty? ? "untouched" : "touched", runners: runners }
    end

    def entry(row, run_public_id)
      capture = row.first_runner_write
      entry = {
        runner_executor_public_id: capture.fetch("runner_executor_public_id"),
        run_public_id: run_public_id,
        task_key: row.node_key,
      }
      entry[:checkpoint] = capture.fetch("checkpoint") if capture.key?("checkpoint")
      entry
    end
  end
end
