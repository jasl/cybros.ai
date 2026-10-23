module MemoryCollections
  # Tombstones remain identities. Scan them, including already-empty ones, in
  # index order before inspecting any contents; each invocation has independent
  # source and document budgets. Repeated wakes and lost wakes are harmless.
  class Purge
    def self.call(batch:, after_deleted_at: nil, after_id: 0)
      scope = MemoryCollection.where.not(deleted_at: nil)
      if after_deleted_at
        scope = scope.where("(deleted_at, id) > (?, ?)", Time.zone.iso8601(after_deleted_at), after_id)
      end
      rows = scope.order(:deleted_at, :id).limit(batch).to_a
      processed = 0
      last = nil
      rows.each do |row|
        break if processed == batch

        processed += row.purge_documents(limit: batch - processed)
        last = row
      rescue ActiveRecord::RecordNotFound
        # An owner collector won after the source snapshot.
        last = row
      end
      # A full content budget can leave this collection partially drained.
      # Repeat the previous window; otherwise advance across even empty rows.
      cursor = if processed == batch || last.nil?
        [after_deleted_at, after_id]
      else
        [last.deleted_at.iso8601(6), last.id]
      end
      Sweeps::Pass.new(counts: { scanned: rows.length, processed: processed },
        cursor: cursor, more: batch.positive? && (processed == batch || rows.length == batch))
    end
  end
end
