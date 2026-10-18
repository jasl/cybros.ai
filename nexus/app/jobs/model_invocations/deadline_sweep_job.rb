module ModelInvocations
  # The recurring floor under the deadline sweep; a full batch schedules
  # exactly one continuation. Nothing signals it: a deadline passes by the clock moving.
  class DeadlineSweepJob < ApplicationJob
    def perform(after_id = 0)
      result = DeadlineSweep.call(after_id: after_id)
      self.class.perform_later(result.cursor) if result.more?
    end
  end
end
