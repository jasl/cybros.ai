module ModelInvocations
  # Recurring closer for the late-evidence window: without it, a pending
  # settlement with no living writer fences its aggregate out of
  # reclamation forever.
  class CloseAbandonedSettlementsJob < ApplicationJob
    def perform
      CloseAbandonedSettlements.call
    end
  end
end
