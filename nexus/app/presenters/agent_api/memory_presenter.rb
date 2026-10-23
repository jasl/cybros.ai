module AgentAPI
  # One document shape for all three memory doors: the listing entry carries
  # what the model-facing `memory_ls` carries (path, row identity/version, size, the CONTENT's
  # age) plus the description a skill row carries (null on a plain
  # document); the full document adds its content.
  class MemoryPresenter
    class << self
      def listing(entries)
        entries.map do |entry|
          { path: entry.path, collection_public_id: entry.collection_public_id, public_id: entry.public_id, lock_version: entry.lock_version,
            bytesize: entry.bytesize, description: entry.description,
            written_at: entry.written_at }
        end
      end

      def full(document, path: document.path)
        { path: path, collection_public_id: document.memory_collection.public_id, public_id: document.public_id, lock_version: document.lock_version,
          bytesize: document.bytesize, description: document.description,
          content: document.content,
          written_at: document.memory_document_version.created_at }
      end

      def search(result)
        { matches: result.matches.map(&:to_h), truncated: result.truncated }
      end
    end
  end
end
