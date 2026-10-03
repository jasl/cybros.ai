module ModelInvocations
  # The recurring owner of post-cut convergence. Level-triggered: a pass
  # derives what it does from current rows and needs no authority-cut enqueue.
  class ConvergePostCutJob < ApplicationJob
    def perform(after_id = 0)
      result = ConvergePostCut.call(after_id: after_id)
      self.class.perform_later(result.cursor) if result.more?
    end
  end
end
