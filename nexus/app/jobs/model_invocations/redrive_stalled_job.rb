module ModelInvocations
  # The recurring floor under the rediscovery scan: every row it finds
  # lost its primary trigger, so in a healthy deployment it does nothing.
  class RedriveStalledJob < ApplicationJob
    def perform(after_id = 0, budget: RedriveStalled::BUDGET)
      result = RedriveStalled.call(after_id: after_id, budget: budget)
      self.class.perform_later(result.cursor) if result.more?
    end
  end
end
