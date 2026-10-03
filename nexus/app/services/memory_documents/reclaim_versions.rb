module MemoryDocuments
  # The backstop for cascades, which delete pointer rows in bulk and leave
  # versions standing. No grace window: nothing can adopt a version by
  # digest, so an unreferenced one is unreferenced for good.
  class ReclaimVersions
    BATCH_SIZE = 1_000

    def self.call(batch: BATCH_SIZE, after_id: 0)
      ids = MemoryDocumentVersion.where(id: (after_id + 1)..)
        .order(:id).limit(batch).pluck(:id)
      # Keep the reference probe correlated to each already-materialized id;
      # flattening it into an anti-join can scan the whole pointer history.
      references = MemoryDocument.where(
        "memory_documents.memory_document_version_id = memory_document_versions.id"
      ).offset(0)

      # RESTRICT arbitrates: a fork that copied a pointer meanwhile makes
      # the database refuse that row, and the next pass rediscovers.
      reclaimed = MemoryDocumentVersion.where(id: ids)
        .where.not(references.arel.exists).delete_all
      Sweeps::Pass.new(counts: { scanned: ids.length, reclaimed: reclaimed },
        cursor: ids.last || after_id, more: batch.positive? && ids.length == batch)
    rescue ActiveRecord::InvalidForeignKey
      Sweeps::Pass.new(counts: { scanned: ids.length, reclaimed: 0 },
        cursor: ids.last || after_id, more: batch.positive? && ids.length == batch)
    end
  end
end
