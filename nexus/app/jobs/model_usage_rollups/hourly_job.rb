module ModelUsageRollups
  # "Hourly" names the bucket, not the cadence: every five minutes, and
  # the report reader adds the unrolled remainder so the lag is invisible.
  # Each full batch asks for one continuation; marked receipts leave the source.
  class HourlyJob < ApplicationJob
    def perform
      HourlyJob.perform_later if BackfillHourly.call.more?
    end
  end
end
