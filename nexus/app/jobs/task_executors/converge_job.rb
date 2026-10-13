# Half-hourly bounded executor convergence. Human-shutdown and reap walks
# carry independent cursors; nil parks a completed walk for this chain. The
# next recurring wake calls without arguments and revisits blocked markers.
class TaskExecutors::ConvergeJob < ApplicationJob
  BATCH = TaskExecutor::Convergence::BATCH_SIZE

  def perform(shutdown_after_id = 0, reap_after_id = 0)
    result = TaskExecutor.converge(
      batch_size: BATCH,
      shutdown_after_id: shutdown_after_id,
      reap_after_id: reap_after_id
    )
    self.class.perform_later(*result.cursor) if result.more?
  end
end
