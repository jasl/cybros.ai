# Half-hourly bounded steward-shutdown convergence over Agents. The
# source window carries its primary-key cursor through the continuation; a
# partial pass sleeps until the next recurring wake, which restarts it.
class Users::ConvergeJob < ApplicationJob
  BATCH = User::Convergence::BATCH_SIZE

  def perform(after_id = 0)
    result = User.converge(batch_size: BATCH, after_id: after_id)
    Users::StopAgentWorkJob.perform_later if result[:converged].positive?
    self.class.perform_later(result.cursor) if result.more?
  end
end
