module ModelInvocations
  # The admission trigger: the recurring pass is the floor, precise wakes ride
  # above it, and a lost one costs latency only. A full batch re-triggers
  # itself, so throughput is bounded by capacity, not cadence.
  class AdmitQueuedWorkJob < ApplicationJob
    def perform
      result = AdmitQueuedWork.call

      # Contention means another admitter held the lock, not that there was
      # nothing to do. A full batch means the same thing from the other side.
      self.class.perform_later if result.lock_contended? || result.more?
    end
  end
end
