module ContentUploads
  # Bytes never named are the ordinary residue of two-step staging.
  # Destroying the row purges through `dependent: :purge_later`; a bound
  # upload cannot be reaped because the RESTRICT FK refuses, and the residual race corrupts nothing.
  class SweepUnboundJob < ApplicationJob
    queue_as :default

    BATCH = ContentUpload::REAP_BATCH_SIZE

    def perform(after_created_at = nil, after_id = 0)
      result = ContentUpload.reap(
        batch: BATCH, after_created_at: after_created_at, after_id: after_id
      )
      self.class.perform_later(*result.cursor) if result.more?
    end
  end
end
