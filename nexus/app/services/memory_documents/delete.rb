module MemoryDocuments
  # A delete is a delete: a fork copies pointer rows, so a child owns every
  # document it can see and needs no whiteout. `revises` is the
  # conversation the delete is for, owed the same fence a write owes. The
  # caller holds the anchor row, as `Write` says. HTTP callers supply a
  # condition; native tools explicitly pass nil to delete the current path.
  class Delete
    Result = Data.define(:outcome) do
      def deleted? = outcome == :deleted
    end

    def self.call(anchor:, expected:, revises: nil)
      MemoryDocument.transaction do
        document = anchor.documents.find_by(name: anchor.name)
        next Result.new(outcome: :stale_object) if expected && !expected.matches?(document)
        next Result.new(outcome: :memory_not_found) if document.nil?

        version_id = document.memory_document_version_id
        document.destroy!
        MemoryDocumentVersion.reclaim(version_id)
        revises&.note_context_change
        Result.new(outcome: :deleted)
      end
    end
  end
end
