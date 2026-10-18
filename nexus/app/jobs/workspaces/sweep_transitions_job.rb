# The convergence sweep: level-triggered, a bounded run that reports more
# enqueues exactly one continuation, and the schedule recovers a lost wake.
class Workspaces::SweepTransitionsJob < ApplicationJob
  BUDGET = 1_000

  def perform(after_id = 0)
    result = Workspaces::SweepTransitions.call(budget: BUDGET, after_id: after_id)
    self.class.perform_later(result.cursor) if result.more?
  end
end
