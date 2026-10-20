module Rho
  # The task result is the history authority. Neither today's work tree nor
  # the Conversation's current Runner selection participates in this read.
  class RunChanges
    def initialize(workspace)
      @workspace = workspace
    end

    def collect(variant)
      return [] unless variant.run_public_id && variant.runner_effects&.touched?

      runners = variant.runner_effects.runners.map(&:runner_executor_public_id)
      run = @workspace.runs.run(variant.run_public_id)
      snapshot = run.fetch
      finished = snapshot.deliverable&.completed_at || snapshot.completed_at
      latest = {}
      snapshot.tasks.each do |task|
        runner = task.target_executor_public_id
        next unless task.status == "completed" && runners.include?(runner)
        next if finished && task.completed_at && task.completed_at > finished

        document = run.task(task.key).metadata&.fetch("rho.changes", nil)
        next unless document

        key = [runner, document.fetch("root")]
        previous = latest[key]
        # Captures serialize at the checkpoint store. Submission can complete
        # in another order when several tools return together.
        if previous.nil? || document.fetch("captured_at") > previous.fetch("captured_at")
          latest[key] = document.merge("runner" => runner, "run" => variant.run_public_id, "task" => task.key)
        end
      end
      latest.values.reject { |document| document.fetch("files").empty? }
    end
  end
end
