module UsageRecords
  # Each full receipt batch yields the worker before continuing. The recurring
  # minute recovers a lost trigger; SKIP LOCKED makes overlapping passes safe.
  class SettleSpendJob < ApplicationJob
    def perform
      SettleSpendJob.perform_later if SettleSpend.call.more?
    end
  end
end
