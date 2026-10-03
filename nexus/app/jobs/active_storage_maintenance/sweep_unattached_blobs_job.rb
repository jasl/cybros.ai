module ActiveStorageMaintenance
  # The Rails-native unattached-blob sweep: a crash between upload and
  # attach leaves a blob no destroy will ever reclaim. Two days of grace,
  # since nothing legitimate stages for days.
  class SweepUnattachedBlobsJob < ApplicationJob
    queue_as :default

    GRACE = 2.days
    BATCH = 500

    def perform
      ActiveStorage::Blob.unattached
        .where(created_at: ..GRACE.ago)
        .limit(BATCH)
        .find_each(&:purge_later)
    end
  end
end
