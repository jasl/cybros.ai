# Retained evidence of this task's first claimed Runner write. The claim and
# result writers assign these facts before their existing atomic task update;
# retry clears current execution data without replacing this capture.
module AgentRunTask::RunnerWrite
  def capture_runner_write(executor:, claimed_at:)
    if first_runner_write.nil? && target_executor_public_id.present? &&
        addressed_role == "runner" && effect_profile&.fetch("kind") == "write"
      self.first_runner_write = {
        "execution_generation" => execution_generation,
        "runner_executor_public_id" => executor.public_id,
        "claimed_at" => claimed_at.utc.iso8601(6),
      }
    end
  end

  # Metadata has already passed the result boundary's size and shape checks.
  # Presence is significant: an explicit null checkpoint is still a recorded
  # value, and a later generation cannot replace it or fill an absent one.
  def capture_runner_checkpoint(metadata:)
    capture = first_runner_write
    return if capture.nil? || metadata.nil?

    if capture.fetch("execution_generation") == execution_generation &&
        !capture.key?("checkpoint") && metadata.key?("checkpoint")
      self.first_runner_write = capture.merge("checkpoint" => metadata.fetch("checkpoint"))
    end
  end
end
