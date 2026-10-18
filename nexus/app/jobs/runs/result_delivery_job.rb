# The kernel mail's process: the quiescence site runs under the loop lock
# and the input door takes the conversation lock, so a settled orphan is
# mailed after commit, never inside the pass. ScheduleSweep rediscovers
# unmailed tips, including a refused attempt.
class Runs::ResultDeliveryJob < ApplicationJob
  def perform(run_id)
    run = Run.find_by(id: run_id)
    return if run.nil? || run.standalone?

    Runs::ResultDelivery.call(run)
  end
end
